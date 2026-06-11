import SwiftUI

struct SignInBanner: View {
    let onSignIn: () -> Void
    let isAuthenticating: Bool

    var body: some View {
        CardContainer(title: "Sign in to Tesla Fleet", systemImage: "person.crop.circle.badge.plus") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connect your Tesla account to load live vehicle data, drives, charging, and software update state.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    onSignIn()
                } label: {
                    HStack {
                        if isAuthenticating {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isAuthenticating ? "Signing in…" : "Sign In")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isAuthenticating)
            }
        }
    }
}

#Preview("Idle") {
    SignInBanner(onSignIn: {}, isAuthenticating: false)
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Authenticating") {
    SignInBanner(onSignIn: {}, isAuthenticating: true)
        .padding()
        .background(Color(uiColor: .systemGroupedBackground))
}
