import AuthenticationServices
import CryptoKit
import GoogleSignIn
import Security
import SwiftUI
import UIKit
import DayDoCore

struct SignInView: View {
    @Environment(AppModel.self) private var model

    var logoNamespace: Namespace.ID? = nil
    var logoRevealed: Bool = true
    var contentRevealed: Bool = true

    @State private var currentRawNonce: String?
    @State private var errorText: String?
    @State private var pendingSwitchCredential: SyncAuthCredential?
    @State private var pendingSwitchUnsyncedCount = 0
    @State private var confirmSwitchAccount = false

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 16) {
                    Group {
                        if logoRevealed {
                            Image("LaunchLogo")
                                .resizable()
                                .frame(width: 120, height: 120)
                                .matchedGeometryIfPresent(id: "launchLogo", in: logoNamespace)
                                .transition(.identity)
                        } else {
                            Color.clear
                                .frame(width: 120, height: 120)
                        }
                    }

                    VStack(spacing: 16) {
                        Text("DayDo")
                            .txt(34, .bold)
                            .foregroundStyle(Palette.text)

                        Text("待辦與日曆，跨裝置即時同步")
                            .txt(15)
                            .foregroundStyle(Palette.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .opacity(contentRevealed ? 1 : 0)
                }

                Spacer()

                VStack(spacing: 12) {
                    if let errorText {
                        Text(errorText)
                            .txt(13)
                            .foregroundStyle(Palette.danger)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .card(12, color: Palette.raised)
                    }

                    SignInWithAppleButton(.signIn) { request in
                        let rawNonce = SignInNonce.random()
                        currentRawNonce = rawNonce
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = SignInNonce.sha256Hex(rawNonce)
                    } onCompletion: { result in
                        handleAppleResult(result)
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityIdentifier("signIn.apple")
                    .disabled(model.isSigningIn)

                    Button {
                        signInWithGoogle()
                    } label: {
                        HStack(spacing: 10) {
                            Text("G")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(Palette.text)
                            Text("使用 Google 登入")
                                .txt(17, .semibold)
                                .foregroundStyle(Palette.text)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Palette.raised)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Palette.separatorSoft, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("signIn.google")
                    .disabled(model.isSigningIn)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 44)
                .opacity(contentRevealed ? 1 : 0)
            }

            if model.isSigningIn {
                Color.black.opacity(0.45).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView().tint(Palette.text)
                    Text("正在登入並同步資料…")
                        .txt(14, .medium)
                        .foregroundStyle(Palette.textBody)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .card(18, color: Palette.card)
            }
        }
        .alert("切換帳號？", isPresented: $confirmSwitchAccount) {
            Button("取消", role: .cancel) {
                pendingSwitchCredential = nil
            }
            Button("清除並登入", role: .destructive) {
                guard let credential = pendingSwitchCredential else { return }
                pendingSwitchCredential = nil
                Task {
                    await confirmAccountSwitch(with: credential)
                }
            }
        } message: {
            if pendingSwitchUnsyncedCount > 0 {
                Text("這支手機上還有另一個帳號的資料。要清除這些資料並改用這個帳號登入嗎？\n其中 \(pendingSwitchUnsyncedCount) 筆修改還沒同步，會一併刪除")
            } else {
                Text("這支手機上還有另一個帳號的資料。要清除這些資料並改用這個帳號登入嗎？")
            }
        }
    }

    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8),
                  !identityToken.isEmpty,
                  let rawNonce = currentRawNonce else {
                errorText = "無法讀取 Apple 登入憑證，請再試一次。"
                return
            }
            currentRawNonce = nil
            Task {
                await performSignIn(.apple(identityToken: identityToken, nonce: rawNonce))
            }
        case .failure(let error):
            currentRawNonce = nil
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return
            }
            errorText = error.localizedDescription
        }
    }

    private func signInWithGoogle() {
        errorText = nil
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-DayDoDebugStub") {
            Task {
                await performSignIn(.google(idToken: "debug-google-token"))
            }
            return
        }
#endif
        guard let presenter = topViewController() else {
            errorText = "無法開啟 Google 登入視窗。"
            return
        }
        if let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
           !clientID.isEmpty,
           GIDSignIn.sharedInstance.configuration == nil {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
        Task {
            do {
                let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
                guard let idToken = result.user.idToken?.tokenString, !idToken.isEmpty else {
                    errorText = "無法取得 Google ID Token。"
                    return
                }
                await performSignIn(.google(idToken: idToken))
            } catch {
                let nsError = error as NSError
                if nsError.domain == kGIDSignInErrorDomain,
                   nsError.code == GIDSignInError.canceled.rawValue {
                    return
                }
                errorText = error.localizedDescription
            }
        }
    }

    private func performSignIn(_ credential: SyncAuthCredential) async {
        errorText = nil
        do {
            try await model.signIn(with: credential)
        } catch {
            if isDifferentUserError(error) {
                pendingSwitchCredential = credential
                pendingSwitchUnsyncedCount = await model.unsyncedChangeCount()
                confirmSwitchAccount = true
                return
            }
            errorText = error.localizedDescription
        }
    }

    private func confirmAccountSwitch(with credential: SyncAuthCredential) async {
        errorText = nil
        do {
            try await model.replaceAccountAndSignIn(with: credential)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func isDifferentUserError(_ error: Error) -> Bool {
        guard case let SyncError.protocolError(message) = error else { return false }
        return message.contains("Already signed in as a different user")
    }

    private func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.flatMap(\.windows).first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

private enum SignInNonce {
    static func random(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var bytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            if status != errSecSuccess {
                fatalError("Unable to generate random nonce: \(status)")
            }
            for byte in bytes where remaining > 0 {
                if Int(byte) < charset.count * (256 / charset.count) {
                    result.append(charset[Int(byte) % charset.count])
                    remaining -= 1
                }
            }
        }
        return result
    }

    static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
