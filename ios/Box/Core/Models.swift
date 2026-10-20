import Foundation

struct Track: Identifiable, Hashable {
    /// Belgeler klasörüne göre göreli yol; kimlik olarak kullanılır.
    let relativePath: String
    let url: URL
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var addedAt: Date
    var fileSize: Int64

    var id: String { relativePath }

    var displayArtist: String {
        artist.isEmpty ? "Bilinmeyen sanatçı" : artist
    }
}

struct Playlist: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var paths: [String]
    var createdAt: Date

    init(id: UUID = UUID(), name: String, paths: [String] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.paths = paths
        self.createdAt = createdAt
    }
}

/// Dosya meta verisi önbelleği (her açılışta tüm dosyaları tekrar okumamak için).
struct CachedMetadata: Codable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var modified: Date
    var size: Int64
}

// MARK: - API modelleri

struct BoxUser: Codable, Equatable {
    let id: Int
    let email: String
    let name: String
    let premium: Bool
    let premiumUntil: String?
    let createdAt: String?

    var premiumUntilDate: Date? {
        guard let premiumUntil else { return nil }
        return ISO8601DateFormatter().date(from: premiumUntil)
    }
}

struct AuthResponse: Decodable {
    let token: String
    let user: BoxUser
}

struct UserResponse: Decodable {
    let user: BoxUser
    let quota: Quota?
}

struct Quota: Decodable, Equatable {
    let downloadsLimit: Int
    let downloadsUsed: Int
    let downloadsLeft: Int?
    let searchesLimit: Int
    let searchesUsed: Int
    let searchesLeft: Int?
}

struct RemoteConfig: Decodable {
    struct Maintenance: Decodable { let on: Bool; let message: String }
    struct Announcement: Decodable { let title: String; let body: String; let id: String }

    let maintenance: Maintenance
    let minAppVersion: String
    let registrationOpen: Bool
    let announcement: Announcement?
    let supportEmail: String?
}

struct EmptyResponse: Decodable {}

struct SearchResult: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let channel: String
    let thumbnail: String?
    let duration: Int

    var thumbnailURL: URL? {
        thumbnail.flatMap(URL.init(string:))
    }

    /// Siyah bantsız, yüksek çözünürlüklü kapak.
    var maxResURL: URL? {
        URL(string: "https://i.ytimg.com/vi/\(id)/maxresdefault.jpg")
    }
}

struct SearchResponse: Decodable {
    let results: [SearchResult]
}

struct DownloadLinkResponse: Decodable {
    let url: String
    let expiresAt: Int
}
