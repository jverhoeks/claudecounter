import SwiftUI
import ClaudeCounterCore

/// Inline, collapsible editor for the desk-device publisher, mounted in
/// `PopoverView`'s scroll area the same way `SourcesEditorView` is.
/// URL persists via `AppSettings`; the write token goes to the Keychain
/// through `AppState.setDeviceToken`.
struct DeviceSettingsView: View {
    @ObservedObject var state: AppState
    @Binding var isExpanded: Bool

    @State private var url: String
    @State private var token: String
    @State private var message: String?
    @State private var sending = false

    init(state: AppState, isExpanded: Binding<Bool>) {
        self.state = state
        self._isExpanded = isExpanded
        _url = State(initialValue: state.settings.deviceURL)
        _token = State(initialValue: state.deviceToken ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Device")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { isExpanded = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            Text("Publishes spend and usage to a Cloudflare Worker for the desk display. Empty URL turns publishing off. See cloudflare/README.md.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("https://claudecounter.<account>.workers.dev/state", text: $url)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            SecureField("Write token", text: $token)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))

            if let message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(message.hasPrefix("Error") ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    save()
                    Task {
                        sending = true
                        let out = await state.publishDevice(force: true)
                        sending = false
                        switch out {
                        case .none: message = "Publishing is off (empty URL)."
                        case .sent: message = "Sent."
                        case .unchanged: message = "Unchanged."
                        case .failed(let m): message = "Error: \(m)"
                        }
                    }
                } label: {
                    Text(sending ? "Sending…" : "Send now").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .disabled(sending)
                Spacer()
                Button {
                    save()
                } label: {
                    Text("Save").font(.system(size: 11, weight: .semibold))
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private func save() {
        state.setDeviceURL(url)
        do {
            try state.setDeviceToken(token)
            message = "Saved."
        } catch {
            message = "Error: could not store token in Keychain (\(error))"
        }
    }
}
