import AVFoundation
import AVKit
import SwiftUI

/// One camera's live HLS playback. Tuya stream URLs expire, so a failed or stalled stream
/// allocates a fresh URL and starts over.
@MainActor
@Observable
final class CameraPlayer {
    enum State: Equatable {
        case connecting
        case playing
        case failed(String)
    }

    let player = AVPlayer()
    private(set) var state: State = .connecting
    var isMuted = true {
        didSet { player.isMuted = isMuted }
    }

    private let cameraID: String
    private var loadTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var failures = 0

    init(cameraID: String) {
        self.cameraID = cameraID
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = true
    }

    func start(using store: DeviceStore) {
        loadTask?.cancel()
        watchTask?.cancel()
        state = .connecting
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await store.streamURL(for: cameraID)
                guard !Task.isCancelled else { return }
                let item = AVPlayerItem(url: url)
                item.preferredForwardBufferDuration = 2
                player.replaceCurrentItem(with: item)
                player.play()
                watch(item, store: store)
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        loadTask?.cancel()
        watchTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func watch(_ item: AVPlayerItem, store: DeviceStore) {
        watchTask = Task { [weak self] in
            // Poll instead of KVO: cheap, and keeps everything on the main actor.
            var stalledSince: Date?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                if item.status == .failed {
                    retry(after: item.error?.localizedDescription ?? "Stream failed", store: store)
                    return
                }
                if player.timeControlStatus == .playing {
                    state = .playing
                    failures = 0
                    stalledSince = nil
                } else if state == .playing || stalledSince != nil {
                    let since = stalledSince ?? .now
                    stalledSince = since
                    if Date.now.timeIntervalSince(since) > 12 {
                        retry(after: "Stream stalled", store: store)
                        return
                    }
                }
            }
        }
    }

    private func retry(after message: String, store: DeviceStore) {
        failures += 1
        guard failures <= 3 else {
            state = .failed(message)
            return
        }
        start(using: store)
    }
}

/// AVPlayerView without its own controls; the tile draws glass controls on top.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspectFill
        view.allowsPictureInPicturePlayback = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
