import AuthenticationServices
import CryptoKit
import GoogleSignIn
import Security
import UIKit
import DayDoCore

enum SignInNonce {
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

struct GoogleAuthPayload: Sendable {
    let idToken: String
    let displayName: String?
    let avatarUrl: String?
}

struct AppleAuthPayload: Sendable {
    let identityToken: String
    let nonce: String
}

enum LocalAuthHelperError: LocalizedError {
    case missingPresenter
    case missingToken(String)

    var errorDescription: String? {
        switch self {
        case .missingPresenter:
            return "無法開啟登入視窗，請再試一次。"
        case let .missingToken(message):
            return message
        }
    }
}

enum AuthErrorMessage {
    static func text(for error: Error) -> String {
        if let authError = error as? AuthError {
            return authError.localizedDescription
        }
        if let localError = error as? LocalAuthHelperError {
            return localError.localizedDescription
        }
        if let syncError = error as? SyncError {
            switch syncError {
            case .retryable:
                return "網路連線失敗，請再試一次"
            case .signedOut:
                return "登入已失效，請重新登入"
            case .protocolError:
                return "驗證失敗，請再試一次"
            }
        }
        if error is URLError {
            return "網路連線失敗，請再試一次"
        }
        return "驗證失敗，請再試一次"
    }
}

@MainActor
enum AuthPresentationHelper {
    static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.flatMap(\.windows).first
    }

    static func topViewController() -> UIViewController? {
        var top = keyWindow()?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    /// Runs interactive Google Sign-In and returns `nil` when the user cancels.
    static func signInWithGoogle() async throws -> GoogleAuthPayload? {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-DayDoDebugStub") {
            let suggestedName = ProcessInfo.processInfo.arguments.contains("-DayDoDebugNoProviderName") ? nil : "測試者"
            return GoogleAuthPayload(idToken: "debug-google-token", displayName: suggestedName, avatarUrl: nil)
        }
#endif
        guard let presenter = topViewController() else {
            throw LocalAuthHelperError.missingPresenter
        }
        if let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
           !clientID.isEmpty,
           GIDSignIn.sharedInstance.configuration == nil {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString, !idToken.isEmpty else {
                throw LocalAuthHelperError.missingToken("無法取得 Google ID Token。")
            }
            let profileName = result.user.profile?.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let suggestedName = (profileName?.isEmpty == false) ? profileName : nil
            let rawAvatarURL = (result.user.profile?.hasImage == true)
                ? result.user.profile?.imageURL(withDimension: 256)
                : nil
            let suggestedAvatarUrl = (rawAvatarURL?.scheme?.lowercased() == "https") ? rawAvatarURL?.absoluteString : nil
            return GoogleAuthPayload(idToken: idToken, displayName: suggestedName, avatarUrl: suggestedAvatarUrl)
        } catch {
            let nsError = error as NSError
            if nsError.domain == kGIDSignInErrorDomain,
               nsError.code == GIDSignInError.canceled.rawValue {
                return nil
            }
            throw error
        }
    }

    /// Clears the local GoogleSignIn SDK session so linking Google never leaves a stale
    /// `GIDSignIn` session that could overwrite the account's avatar on next launch.
    static func signOutGoogleSession() {
        GIDSignIn.sharedInstance.signOut()
    }

    /// Runs interactive Sign in with Apple (used for linking Apple from Settings) and returns `nil` when canceled.
    static func signInWithApple() async throws -> AppleAuthPayload? {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-DayDoDebugStub") {
            return AppleAuthPayload(identityToken: "debug-apple-link-token", nonce: "debug-apple-nonce")
        }
#endif
        let runner = AppleSignInRunner()
        return try await runner.perform()
    }
}

@MainActor
private final class AppleSignInRunner: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<AppleAuthPayload?, Error>?
    private var rawNonce: String = ""
    private var retainedSelf: AppleSignInRunner?

    func perform() async throws -> AppleAuthPayload? {
        let nonce = SignInNonce.random()
        rawNonce = nonce
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = SignInNonce.sha256Hex(nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.retainedSelf = self
            controller.performRequests()
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        AuthPresentationHelper.keyWindow() ?? ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let cont = continuation
        continuation = nil
        retainedSelf = nil
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8),
              !identityToken.isEmpty else {
            cont?.resume(throwing: LocalAuthHelperError.missingToken("無法讀取 Apple 登入憑證，請再試一次。"))
            return
        }
        cont?.resume(returning: AppleAuthPayload(identityToken: identityToken, nonce: rawNonce))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let cont = continuation
        continuation = nil
        retainedSelf = nil
        if let authError = error as? ASAuthorizationError, authError.code == .canceled {
            cont?.resume(returning: nil)
            return
        }
        cont?.resume(throwing: error)
    }
}
