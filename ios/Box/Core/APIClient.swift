import Foundation

struct APIError: LocalizedError {
    let message: String
    let status: Int

    var errorDescription: String? { message }
}

private struct ErrorEnvelope: Decodable {
    let ok: Bool?
    let error: String?
}

final class APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private let decoder: JSONDecoder

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)

        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    func send<T: Decodable>(
        _ action: String,
        method: String = "GET",
        query: [String: String] = [:],
        body: [String: Any]? = nil,
        token: String? = nil,
        as type: T.Type = T.self
    ) async throws -> T {
        var components = URLComponents(url: AppConfig.apiBase, resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "action", value: action)]
        items.append(contentsOf: query.map { URLQueryItem(name: $0.key, value: $0.value) })
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(token, forHTTPHeaderField: "X-Box-Token")
        }

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
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
            throw APIError(message: envelope?.error ?? "Beklenmeyen bir hata oluştu (\(status)).", status: status)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError(message: "Sunucudan geçersiz yanıt geldi.", status: status)
        }
    }
}
