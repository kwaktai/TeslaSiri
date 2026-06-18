import SwiftUI

struct SignInBanner: View {
    let onSignIn: (String) -> Void
    let isAuthenticating: Bool

    @State private var accessToken = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "car.side.fill")
                    .font(.title2)
                    .frame(width: 48, height: 48)
                    .background(Color.white.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 5) {
                    Text("Connect with Tessie")
                        .font(.title3.weight(.bold))
                    Text("Use a Tessie access token for live status, drive history, charging, and vehicle controls.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SecureField(text: $accessToken, prompt: Text("Tessie access token").foregroundStyle(.white.opacity(0.58))) {
                Text("Tessie access token")
            }
                .foregroundStyle(.white)
                .tint(.white)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16))
                }
                .onSubmit(connect)

            HStack {
                Link(destination: TessieAccessTokenStore.developerSettingsURL) {
                    Label("Generate a token", systemImage: "arrow.up.right.square")
                }
                .font(.footnote.weight(.semibold))

                Spacer()

                Text("Stored in Keychain")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.62))
            }

            Button(action: connect) {
                HStack(spacing: 8) {
                    if isAuthenticating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "key.fill")
                    }

                    Text(isAuthenticating ? "Connecting…" : "Connect Tessie")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(isAuthenticating || trimmedToken.isEmpty)
        }
        .padding(20)
        .foregroundStyle(.white)
        .background {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.10, green: 0.18, blue: 0.34),
                                Color(red: 0.18, green: 0.09, blue: 0.28)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .fill(Color.accentColor.opacity(0.38))
                    .frame(width: 160, height: 160)
                    .blur(radius: 30)
                    .offset(x: 64, y: 70)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75)
        }
        .shadow(color: Color.black.opacity(0.16), radius: 18, y: 9)
    }

    private var trimmedToken: String {
        accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func connect() {
        guard !trimmedToken.isEmpty, !isAuthenticating else { return }
        onSignIn(trimmedToken)
    }
}

#Preview("Idle") {
    ZStack {
        AppScreenBackground()

        SignInBanner(onSignIn: { _ in }, isAuthenticating: false)
            .padding()
    }
}

#Preview("Authenticating") {
    ZStack {
        AppScreenBackground()

        SignInBanner(onSignIn: { _ in }, isAuthenticating: true)
            .padding()
    }
}
