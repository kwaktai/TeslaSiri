import SwiftUI

struct SignInBanner: View {
    let onSignIn: (String) -> Void
    let isAuthenticating: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var accessToken = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            bannerHeader

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
                .frame(minHeight: 48)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16))
                }
                .onSubmit(connect)

            tokenHelp

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
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
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
            .font(.title2)
            .padding(11)
            .background(Color.white.opacity(0.12), in: Circle())
    }

    private var bannerCopy: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Connect with Tessie")
                .font(.title3.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Use a Tessie access token for live status, drive history, charging, and vehicle controls.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
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
        Link(destination: TessieAccessTokenStore.developerSettingsURL) {
            Label("Generate a token", systemImage: "arrow.up.right.square")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote.weight(.semibold))
    }

    private var keychainNote: some View {
        Text("Stored in Keychain")
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.62))
            .fixedSize(horizontal: false, vertical: true)
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
    ScrollView {
        SignInBanner(onSignIn: { _ in }, isAuthenticating: false)
            .padding()
    }
    .background {
        AppScreenBackground()
    }
}

#Preview("Authenticating") {
    ScrollView {
        SignInBanner(onSignIn: { _ in }, isAuthenticating: true)
            .padding()
    }
    .background {
        AppScreenBackground()
    }
}
