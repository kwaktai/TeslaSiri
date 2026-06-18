import SwiftUI

struct SignInBanner: View {
    let onSignIn: () -> Void
    let isAuthenticating: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "car.side.fill")
                    .font(.title2)
                    .frame(width: 48, height: 48)
                    .background(Color.white.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 5) {
                    Text("Connect your Tesla")
                        .font(.title3.weight(.bold))
                    Text("Live status, drives, charging, and software updates—all in one place.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                onSignIn()
            } label: {
                HStack(spacing: 8) {
                    if isAuthenticating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "person.crop.circle.badge.plus")
                    }

                    Text(isAuthenticating ? "Signing in…" : "Sign In to Tesla Fleet")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(isAuthenticating)
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
}

#Preview("Idle") {
    ZStack {
        AppScreenBackground()

        SignInBanner(onSignIn: {}, isAuthenticating: false)
            .padding()
    }
}

#Preview("Authenticating") {
    ZStack {
        AppScreenBackground()

        SignInBanner(onSignIn: {}, isAuthenticating: true)
            .padding()
    }
}
