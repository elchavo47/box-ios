import AuthenticationServices
import CryptoKit
import Foundation

/// Apple ile giriş için tek kullanımlık değer (nonce) ve sonucun sunucuya gidecek hali.
struct AppleSignInRequest {
    let rawNonce: String

    init() {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        rawNonce = String(bytes.map { charset[Int($0) % charset.count] })
    }

    /// Apple'a gönderilen hali: SHA-256 (sunucu ham değerle karşılaştırır).
    var hashedNonce: String {
        SHA256.hash(data: Data(rawNonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func configure(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
        request.nonce = hashedNonce
    }

    struct Result {
        let identityToken: String
        let authorizationCode: String?
        let nonce: String
        let name: String?
    }

    /// nil: kullanıcı vazgeçti.
    func result(from outcome: Swift.Result<ASAuthorization, Error>) throws -> Result? {
        switch outcome {
        case .failure(let error):
            if let auth = error as? ASAuthorizationError, auth.code == .canceled { return nil }
            throw APIError(message: "Apple ile giriş yapılamadı.", status: 0)
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                throw APIError(message: "Apple ile giriş yapılamadı.", status: 0)
            }
            let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
            var name: String?
            if let components = credential.fullName {
                let formatted = PersonNameComponentsFormatter().string(from: components).trimmingCharacters(in: .whitespaces)
                if !formatted.isEmpty { name = formatted }
            }
            return Result(identityToken: token, authorizationCode: code, nonce: rawNonce, name: name)
        }
    }
}
