import Foundation

@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var user: BoxUser?
    @Published private(set) var token: String?
    @Published var isWorking = false
    @Published private(set) var quota: Quota?

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

    func logout() async {
        if let token {
            _ = try? await APIClient.shared.send("auth/logout", method: "POST", token: token, as: EmptyResponse.self)
        }
        clear()
    }

    func deleteAccount(password: String) async throws {
        guard let token else { return }
        isWorking = true
        defer { isWorking = false }

        _ = try await APIClient.shared.send(
            "me/delete", method: "POST", body: ["password": password], token: token, as: EmptyResponse.self
        )
        clear()
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
