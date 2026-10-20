import Foundation

struct APIError: LocalizedError {
    let message: String
    let status: Int
    var maintenance = false
    var updateRequired = false

    var errorDescription: String? { message }
}

private struct ErrorEnvelope: Decodable {
    let ok: Bool?
    let error: String?
    let maintenance: Bool?
    let updateRequired: Bool?
}

extension Notification.Name {
    /// Sunucu bakım ya da zorunlu güncelleme bildirdiğinde yayınlanır.
    static let boxServerState = Notification.Name("box.serverState")
}

final class APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private let decoder: JSONDecoder

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)

        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    /// `path` örnekleri: "auth/login", "me", "search".
    func send<T: Decodable>(
        _ path: String,
        method: String = "GET",
        query: [String: String] = [:],
        body: [String: Any]? = nil,
        bodyData: Data? = nil,
        token: String? = nil,
        as type: T.Type = T.self
    ) async throws -> T {
        var components = URLComponents(url: AppConfig.apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppConfig.shortVersion, forHTTPHeaderField: "X-Box-Version")
        // Panelde ve "Cihazlarım"da cihazı tanımak için (ad, iOS ve uygulama sürümü).
        request.setValue(AppConfig.buildNumber, forHTTPHeaderField: "X-Box-Build")
        request.setValue(DeviceInfo.identifier, forHTTPHeaderField: "X-Box-Device-ID")
        request.setValue(DeviceInfo.model, forHTTPHeaderField: "X-Box-Device")
        request.setValue(DeviceInfo.system, forHTTPHeaderField: "X-Box-OS")

        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(token, forHTTPHeaderField: "X-Box-Token")
        }

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else if let bodyData {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
            request.timeoutInterval = 90
        }

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError(message: "Sunucuya ulaşılamadı. İnternet bağlantını kontrol et.", status: 0)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200..<300).contains(status) else {
            let envelope = try? decoder.decode(ErrorEnvelope.self, from: data)
            let error = APIError(
                message: envelope?.error ?? "Beklenmeyen bir hata oluştu (\(status)).",
                status: status,
                maintenance: envelope?.maintenance == true,
                updateRequired: envelope?.updateRequired == true
            )
            if error.maintenance || error.updateRequired {
                await MainActor.run {
                    NotificationCenter.default.post(name: .boxServerState, object: error)
                }
            }
            throw error
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError(message: "Sunucudan geçersiz yanıt geldi.", status: status)
        }
    }
}
