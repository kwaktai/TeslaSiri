import FleetKit
import SwiftUI
import TeslaFleetTransport

struct SignInBanner: View {
    let onSignIn: (String, String) -> Void
    let isAuthenticating: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var serverURL = TeslaFleetAPI.defaultBaseURLString
    @State private var apiKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            bannerHeader

            connectionField(title: "Server URL", text: $serverURL, secure: false)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                .submitLabel(.next)

            connectionField(title: "API key", text: $apiKey, secure: true)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .submitLabel(.go)
                .onSubmit(connect)

            Button(action: connect) {
                HStack(spacing: 8) {
                    if isAuthenticating {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "key.fill")
                    }

                    Text(isAuthenticating ? "Connecting…" : "Connect")
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(isAuthenticating || trimmedKey.isEmpty || normalizedURL == nil)

            tokenHelp
        }
        .padding(20)
        .appSurface(cornerRadius: 28)
        .onAppear {
            serverURL = FleetSharedTokenStore.shared.serverBaseURL().absoluteString
        }
    }

    @ViewBuilder
    private var bannerHeader: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                bannerIcon
                bannerCopy
            }
        } else {
            HStack(alignment: .top, spacing: 14) {
                bannerIcon
                bannerCopy
            }
        }
    }

    private var bannerIcon: some View {
        Image(systemName: "car.side.fill")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityHidden(true)
    }

    private var bannerCopy: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Connect your Tesla")
                .font(.title3.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Enter the server URL and API key. Live status and commands use that server. The key stays in Keychain.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var tokenHelp: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                generateTokenLink
                keychainNote
            }
        } else {
            HStack {
                generateTokenLink
                Spacer()
                keychainNote
            }
        }
    }

    private var generateTokenLink: some View {
        Text(WattieCopy.text(
            "Default server is \(TeslaFleetAPI.defaultBaseURLString).",
            "기본 서버는 \(TeslaFleetAPI.defaultBaseURLString)입니다."
        ))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var keychainNote: some View {
        Label("Stored in Keychain", systemImage: "lock.fill")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedURL: URL? {
        TeslaFleetAPI.normalizedBaseURL(from: serverURL)
    }

    private func connectionField(title: String, text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure {
                SecureField(text: text, prompt: Text(LocalizedStringKey(title))) {
                    Text(LocalizedStringKey(title))
                }
            } else {
                TextField(text: text, prompt: Text(LocalizedStringKey(title))) {
                    Text(LocalizedStringKey(title))
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .background(AppTheme.insetSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AppTheme.hairline)
        }
    }

    private func connect() {
        guard let url = normalizedURL, !trimmedKey.isEmpty, !isAuthenticating else { return }
        onSignIn(url.absoluteString, trimmedKey)
    }
}

#Preview("Idle") {
    ScrollView {
        SignInBanner(onSignIn: { _, _ in }, isAuthenticating: false)
            .padding()
    }
    .background {
        AppScreenBackground()
    }
}

#Preview("Authenticating") {
    ScrollView {
        SignInBanner(onSignIn: { _, _ in }, isAuthenticating: true)
            .padding()
    }
    .background {
        AppScreenBackground()
    }
}
