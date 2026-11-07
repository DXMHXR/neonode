import CoreImage.CIFilterBuiltins
import SwiftUI

struct LoginView: View {
    @Environment(DeviceStore.self) private var store

    private enum Step: Equatable {
        case userCode
        case scan(qrToken: String)
        case expired
        case cloudProject
    }

    @State private var step: Step = .userCode
    @AppStorage("smartLifeUserCode") private var userCode = ""
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if step != .userCode {
                    GlassIconButton(systemImage: "chevron.left", help: "Back") { step = .userCode }
                }
                Text(step == .cloudProject ? "Cloud Project" : "Sign In")
                    .font(.title2.weight(.bold))
                Spacer()
            }

            switch step {
            case .userCode: userCodeStep
            case .scan(let token): scanStep(token)
            case .expired: expiredStep
            case .cloudProject: CloudProjectForm()
            }

            if let message = store.errorMessage {
                ErrorBanner(message: message) { store.errorMessage = nil }
            }
        }
        .padding(16)
        .animation(.smooth(duration: 0.28), value: step)
    }

    // MARK: - Steps

    private var userCodeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in with your Smart Life or Tuya Smart account.")
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("In Smart Life, open **Me › Settings › Account and Security › User Code**.")
                } icon: {
                    Image(systemName: "1.circle.fill").foregroundStyle(.tint)
                }
                Label {
                    Text("Paste the code below, then scan the QR code with the app.")
                } icon: {
                    Image(systemName: "2.circle.fill").foregroundStyle(.tint)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            TextField("User Code", text: $userCode)
                .textFieldStyle(.plain)
                .font(.body.monospaced())
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassEffect(.regular.interactive(), in: .capsule)
                .onSubmit(startLogin)

            HStack {
                Button("Use a Cloud project") { step = .cloudProject }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: startLogin) {
                    if isWorking {
                        ProgressView().controlSize(.small).frame(width: 80)
                    } else {
                        Text("Continue").frame(minWidth: 80)
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(trimmedCode.isEmpty || isWorking)
                .keyboardShortcut(.defaultAction)
            }

            Text("Smart Life lists this sign-in as Home Assistant: neo-node uses the login Tuya made for it.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func scanStep(_ token: String) -> some View {
        VStack(spacing: 14) {
            QRCodeImage(payload: SmartLifeLogin.qrPayload(for: token))
                .frame(width: 188, height: 188)
                .padding(14)
                .background(.white, in: .rect(cornerRadius: 22))
                .padding(8)
                .glassEffect(.regular, in: .rect(cornerRadius: 30))
                .frame(maxWidth: .infinity)

            VStack(spacing: 4) {
                Text("Scan with the Smart Life app")
                    .font(.headline)
                Text("Tap the scan icon at the top of the Me tab, then confirm the login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(isWorking ? "Loading your devices…" : "Waiting for confirmation…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: token) { await waitForScan(token) }
    }

    private var expiredStep: some View {
        VStack(spacing: 12) {
            Image(systemName: "qrcode")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("The QR code expired")
                .font(.headline)
            Button("New QR Code", action: startLogin)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    // MARK: - Flow

    private var trimmedCode: String { userCode.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func startLogin() {
        guard !trimmedCode.isEmpty, !isWorking else { return }
        isWorking = true
        store.errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                step = .scan(qrToken: try await SmartLifeLogin.requestQRCode(userCode: trimmedCode))
            } catch {
                store.errorMessage = error.localizedDescription
                step = .userCode
            }
        }
    }

    private func waitForScan(_ token: String) async {
        let deadline = Date.now.addingTimeInterval(4 * 60)
        while !Task.isCancelled, Date.now < deadline {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            guard let session = try? await SmartLifeLogin.result(qrToken: token, userCode: trimmedCode) else { continue }
            isWorking = true
            await store.signIn(.smartLife(session))
            isWorking = false
            if !store.isConfigured { step = .userCode }
            return
        }
        if !Task.isCancelled { step = .expired }
    }
}

struct QRCodeImage: View {
    let payload: String

    var body: some View {
        if let image = Self.render(payload) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "qrcode").resizable().scaledToFit()
        }
    }

    private static func render(_ payload: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

/// Fallback: keys from a Tuya Cloud project (platform.tuya.com) with the app account linked.
struct CloudProjectForm: View {
    @Environment(DeviceStore.self) private var store
    @State private var accessID = ""
    @State private var accessSecret = ""
    @State private var region: TuyaRegion = .singapore
    @State private var isConnecting = false

    private var credentials: TuyaCredentials {
        TuyaCredentials(
            accessID: accessID.trimmingCharacters(in: .whitespacesAndNewlines),
            accessSecret: accessSecret.trimmingCharacters(in: .whitespacesAndNewlines),
            region: region
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create a Cloud project at platform.tuya.com, link your app account under Devices › Link App Account, then paste the project's keys.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                field("Access ID") { TextField("Access ID / Client ID", text: $accessID) }
                field("Access Secret") { SecureField("Access Secret / Client Secret", text: $accessSecret) }
                field("Data center") {
                    Picker("Data center", selection: $region) {
                        ForEach(TuyaRegion.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
            }
            .textFieldStyle(.plain)
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))

            HStack {
                Spacer()
                Button {
                    isConnecting = true
                    Task {
                        await store.signIn(.cloudProject(credentials))
                        isConnecting = false
                    }
                } label: {
                    if isConnecting {
                        ProgressView().controlSize(.small).frame(width: 80)
                    } else {
                        Text("Connect").frame(minWidth: 80)
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(credentials.accessID.isEmpty || credentials.accessSecret.isEmpty || isConnecting)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .glassEffect(.regular.interactive(), in: .capsule)
        }
    }
}
