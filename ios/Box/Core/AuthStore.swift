import Foundation
import UIKit

@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var user: BoxUser?
    @Published private(set) var token: String?
    @Published var isWorking = false
    @Published private(set) var quota: Quota?

    /// Çıkıştan önce: hesaba gönderilmemiş kitaplık değişiklikleri gönderilsin.
    var beforeLogout: (() async -> Void)?
    var onAccountDeleted: ((Int) -> Void)?

    private let tokenKey = "box.token"
    private let userCacheKey = "box.cachedUser"

    var isLoggedIn: Bool { token != nil && user != nil }
    var isPremium: Bool { user?.premium == true }

    init() {
        token = KeychainStore.get(tokenKey)

        if token != nil,
           let data = UserDefaults.standard.data(forKey: userCacheKey),
           let cached = try? JSONDecoder().decode(BoxUser.self, from: data) {
            user = cached
        }
    }

    func login(email: String, password: String) async throws {
        try await authenticate(path: "auth/login", body: [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": password,
        ])
    }

    func register(name: String, email: String, password: String) async throws {
        try await authenticate(path: "auth/register", body: [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": password,
        ])
    }

    /// Apple ile giriş: hesap yoksa oluşturulur.
    func signInWithApple(_ result: AppleSignInRequest.Result) async throws {
        var body: [String: Any] = ["identity_token": result.identityToken, "nonce": result.nonce]
        if let code = result.authorizationCode { body["authorization_code"] = code }
        if let name = result.name { body["name"] = name }
        try await authenticate(path: "auth/apple", body: body)
    }

    /// Var olan hesaba Apple ile girişi bağlar.
    func linkApple(_ result: AppleSignInRequest.Result) async throws {
        guard let token else { return }
        isWorking = true
        defer { isWorking = false }
        var body: [String: Any] = ["identity_token": result.identityToken, "nonce": result.nonce]
        if let code = result.authorizationCode { body["authorization_code"] = code }
        let response: UserResponse = try await APIClient.shared.send("me/apple", method: "POST", body: body, token: token)
        store(token: token, user: response.user)
    }

    func unlinkApple() async throws {
        guard let token else { return }
        isWorking = true
        defer { isWorking = false }
        let response: UserResponse = try await APIClient.shared.send("me/apple", method: "POST", body: ["remove": true], token: token)
        store(token: token, user: response.user)
    }

    private func authenticate(path: String, body: [String: Any]) async throws {
        isWorking = true
        defer { isWorking = false }

        let response: AuthResponse = try await APIClient.shared.send(path, method: "POST", body: body)
        store(token: response.token, user: response.user)
    }

    /// Premium durumu backend'den değişmiş olabilir; açılışta ve ön plana gelince çağrılır.
    func refresh() async {
        guard let token else { return }

        do {
            let response: UserResponse = try await APIClient.shared.send("me", token: token)
            store(token: token, user: response.user)
            quota = response.quota
        } catch let error as APIError where error.status == 401 || error.status == 403 {
            clear()
        } catch {
            // Ağ hatası: önbellekteki kullanıcıyla devam et.
        }
    }

    func updateName(_ name: String) async throws {
        guard let token else { return }
        isWorking = true
        defer { isWorking = false }

        let response: UserResponse = try await APIClient.shared.send(
            "me", method: "POST", body: ["name": name], token: token
        )
        store(token: token, user: response.user)
    }

    /// Profil fotoğrafını yükler; sunucu eskisini siler.
    func uploadAvatar(_ image: UIImage) async throws {
        guard let token else { return }
        isWorking = true
        defer { isWorking = false }
        let square = ArtworkCache.downscale(ArtworkCache.squareCrop(image.normalizedOrientation()), maxSide: 400)
        guard let data = square.jpegData(compressionQuality: 0.82) else { throw APIError(message: L("Fotoğraf hazırlanamadı."), status: 0) }
        let response: UserResponse = try await APIClient.shared.send("me/avatar", method: "POST", body: ["image": data.base64EncodedString()], token: token)
        store(token: token, user: response.user)
    }

    func removeAvatar() async throws {
        guard let token else { return }
        isWorking = true
        defer { isWorking = false }
        let response: UserResponse = try await APIClient.shared.send("me/avatar", method: "POST", body: ["remove": true], token: token)
        store(token: token, user: response.user)
    }

    func logout() async {
        if token != nil, let beforeLogout {
            // Ağ yoksa uzun bekletme: en fazla birkaç saniye (bekleyenler cihazda saklanır).
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await beforeLogout() }
                group.addTask { try? await Task.sleep(nanoseconds: 6_000_000_000) }
                await group.next()
                group.cancelAll()
            }
        }
        if let token {
            await PushManager.shared.unregister(session: token)
            _ = try? await APIClient.shared.send("auth/logout", method: "POST", token: token, as: EmptyResponse.self)
        }
        clear()
    }

    /// Şifresi olmayan (yalnızca Apple ile açılmış) hesaplarda şifre yerine onay gönderilir.
    func deleteAccount(password: String) async throws {
        guard let token else { return }
        isWorking = true
        defer { isWorking = false }

        let body: [String: Any] = user?.hasPassword == false ? ["confirm": "SIL"] : ["password": password]
        _ = try await APIClient.shared.send(
            "me/delete", method: "POST", body: body, token: token, as: EmptyResponse.self
        )
        let id = user?.id
        clear()
        if let id { onAccountDeleted?(id) }
    }

    private func store(token: String, user: BoxUser) {
        self.token = token
        self.user = user
        KeychainStore.set(token, for: tokenKey)

        if let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: userCacheKey)
        }
    }

    private func clear() {
        token = nil
        user = nil
        quota = nil
        KeychainStore.set(nil, for: tokenKey)
        UserDefaults.standard.removeObject(forKey: userCacheKey)
    }
}
