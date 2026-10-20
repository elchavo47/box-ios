import Foundation

struct Track: Identifiable, Hashable {
    /// Kimlik dosya yoludur; aynı şarkının iki kopyası (ör. internet şarkısı) eşit sayılır.
    static func == (lhs: Track, rhs: Track) -> Bool { lhs.relativePath == rhs.relativePath }
    func hash(into hasher: inout Hasher) { hasher.combine(relativePath) }

    /// Belgeler klasörüne göre göreli yol; kimlik olarak kullanılır.
    let relativePath: String
    let url: URL
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var addedAt: Date
    var fileSize: Int64
    /// İndirilmemiş, internetten dinlenen şarkı (YouTube).
    var remote: SearchResult? = nil

    var id: String { relativePath }

    var isRemote: Bool { remote != nil }

    /// Kapak henüz yokken gösterilecek küçük resim (bantsız).
    var artworkFallback: URL? {
        guard let remote else { return nil }
        // YouTube Music'in kare albüm kapağı varsa onu kullan (bantsız, yüksek çözünürlük).
        if let square = remote.squareCoverURL { return square }
        return URL(string: "https://i.ytimg.com/vi/\(remote.id)/mqdefault.jpg")
    }

    static func remote(_ result: SearchResult) -> Track {
        Track(
            relativePath: "yt:" + result.id,
            url: StreamCache.fileURL(for: result.id),
            title: result.title,
            artist: result.channel,
            album: "",
            duration: Double(result.duration),
            addedAt: Date(timeIntervalSince1970: 0),
            fileSize: 0,
            remote: result
        )
    }

    var displayArtist: String {
        artist.isEmpty ? "Bilinmeyen sanatçı" : artist
    }
}

struct Playlist: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var paths: [String]
    var createdAt: Date
    /// YouTube'dan içe aktarılan, henüz indirilmemiş olabilecek şarkılar.
    var remote: [SearchResult]?
    var sourceID: String?
    /// Kullanıcının seçtiği kapak (Application Support/Box/covers içindeki dosya adı).
    var coverFile: String?
    /// Hesaba kayıt: son değişiklik zamanı ve sunucudaki kapağın adresi (bu cihazdaki kapak onunla aynıysa).
    var updatedAt: Date?
    var coverURL: String?

    /// Hesapla eşitlenen içerik (kapak ve zaman damgası hariç); değişti mi diye karşılaştırmak için.
    var syncContent: SyncContent {
        SyncContent(name: name, paths: paths, remote: remote ?? [], sourceID: sourceID)
    }

    struct SyncContent: Equatable {
        let name: String
        let paths: [String]
        let remote: [SearchResult]
        let sourceID: String?
    }

    init(id: UUID = UUID(), name: String, paths: [String] = [], createdAt: Date = Date(), remote: [SearchResult]? = nil, sourceID: String? = nil) {
        self.id = id
        self.name = name
        self.paths = paths
        self.createdAt = createdAt
        self.remote = remote
        self.sourceID = sourceID
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
    let avatarUrl: String?
    /// Apple ile giriş bağlı mı (eski sunucuda yok).
    var appleLinked: Bool? = nil
    /// Şifresi var mı; yalnızca Apple ile açılan hesaplarda false.
    var hasPassword: Bool? = nil

    var avatarURL: URL? { avatarUrl.flatMap(URL.init(string:)) }

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
    /// YouTube Music: sanatçı ve albüm sayfasına gitmek için (eski sonuçlarda yok).
    var artistId: String? = nil
    var albumId: String? = nil
    var album: String? = nil

    var thumbnailURL: URL? {
        thumbnail.flatMap(URL.init(string:))
    }

    /// YouTube Music kare kapağı (ör. lh3.googleusercontent.com/...=w544-h544), istenen boyutta.
    var squareCoverURL: URL? { squareCover(size: 544) }

    func squareCover(size: Int) -> URL? {
        guard let thumbnail, thumbnail.contains("googleusercontent.com") || thumbnail.contains("ggpht.com") else { return nil }
        let resized = thumbnail.replacingOccurrences(of: #"=w\d+-h\d+[^/]*$"#, with: "=w\(size)-h\(size)-l90-rj", options: .regularExpression)
        return URL(string: resized)
    }

    /// Siyah bantsız, yüksek çözünürlüklü kapak.
    var maxResURL: URL? {
        URL(string: "https://i.ytimg.com/vi/\(id)/maxresdefault.jpg")
    }
}

struct SearchResponse: Decodable {
    let results: [SearchResult]
    /// Aramayla eşleşen sanatçı (en üstte gösterilir; eski düzen).
    let artist: ArtistCard?
    /// YouTube Music düzeni: en iyi sonuç ve karışık sonuçlar (şarkı, video, albüm, sanatçı, liste).
    var top: MusicItem? = nil
    var items: [MusicItem]? = nil
}

/// Karışık arama sonucu.
struct MusicItem: Decodable, Hashable, Identifiable {
    enum Kind: String, Decodable {
        case song, video, album, artist, playlist, other

        init(from decoder: Decoder) throws {
            self = Kind(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .other
        }
    }

    let type: Kind
    let itemID: String
    let title: String
    var channel: String? = nil
    var thumbnail: String? = nil
    var duration: Int? = nil
    var artistId: String? = nil
    var albumId: String? = nil
    var album: String? = nil
    var views: String? = nil
    var year: String? = nil
    var albumType: String? = nil
    var subscribers: String? = nil
    var author: String? = nil
    var itemCount: String? = nil
    var children: [MusicItem]? = nil

    var id: String { type.rawValue + ":" + itemID }

    enum CodingKeys: String, CodingKey {
        case type, title, channel, thumbnail, duration, artistId, albumId, album, views, year, albumType, subscribers, author, itemCount, children
        case itemID = "id"
    }

    var isPlayable: Bool { type == .song || type == .video }

    /// Eski biçimdeki şarkı sonucunu karışık sonuca çevirir.
    static func song(_ result: SearchResult) -> MusicItem {
        MusicItem(type: .song, itemID: result.id, title: result.title, channel: result.channel, thumbnail: result.thumbnail, duration: result.duration, artistId: result.artistId, albumId: result.albumId, album: result.album)
    }

    /// Şarkı / video ise çalınabilir sonuç.
    var result: SearchResult? {
        guard isPlayable else { return nil }
        return SearchResult(id: itemID, title: title, channel: channel ?? "", thumbnail: thumbnail, duration: duration ?? 0, artistId: artistId, albumId: albumId, album: album)
    }

    var thumbnailURL: URL? {
        // Videolarda bantsız 16:9 küçük resim (kare kırpılınca siyah şerit kalmasın).
        if isPlayable, type == .video || !(thumbnail ?? "").contains("googleusercontent.com") {
            return URL(string: "https://i.ytimg.com/vi/\(itemID)/mqdefault.jpg")
        }
        if let thumbnail, let url = URL(string: thumbnail) {
            // YouTube Music kare kapakları: yüksek çözünürlüklü iste.
            if thumbnail.contains("googleusercontent.com") || thumbnail.contains("ggpht.com") {
                let resized = thumbnail.replacingOccurrences(of: #"=w\d+-h\d+[^/]*$"#, with: "=w240-h240-l90-rj", options: .regularExpression)
                return URL(string: resized) ?? url
            }
            return url
        }
        if isPlayable { return URL(string: "https://i.ytimg.com/vi/\(itemID)/hqdefault.jpg") }
        return nil
    }
}

// MARK: - YouTube Music sayfaları

struct ArtistCard: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let thumbnail: String?
    var thumbnailURL: URL? { thumbnail.flatMap(URL.init(string:)) }
}

struct AlbumCard: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let artist: String?
    let year: String?
    let type: String?
    let thumbnail: String?
    var thumbnailURL: URL? { thumbnail.flatMap(URL.init(string:)) }
}

struct ArtistPage: Decodable {
    struct Info: Decodable {
        let id: String
        let name: String
        let thumbnail: String?
        let description: String?
        let listeners: String?
        var thumbnailURL: URL? { thumbnail.flatMap(URL.init(string:)) }
    }
    let artist: Info
    let songs: [SearchResult]
    let albums: [AlbumCard]
    let singles: [AlbumCard]
    let related: [ArtistCard]
}

struct AlbumPage: Decodable {
    struct Info: Decodable {
        let id: String
        let title: String
        let artist: String?
        let artistId: String?
        let year: String?
        let type: String?
        let thumbnail: String?
        var thumbnailURL: URL? { thumbnail.flatMap(URL.init(string:)) }
    }
    let album: Info
    let tracks: [SearchResult]
}

/// Uygulamadaki bildirim kutusu.
struct InboxItem: Decodable, Identifiable, Hashable {
    let id: Int
    let title: String
    let body: String
    let open: String?
    let createdAt: String

    var date: Date? { ISO8601DateFormatter().date(from: createdAt) }
}

struct InboxResponse: Decodable {
    let items: [InboxItem]
}

struct DownloadLinkResponse: Decodable {
    let url: String
    let expiresAt: Int
    /// Yalnızca dinleme bağlantısında: tam dosyanın adresi (önbellek için).
    let fileUrl: String?
    let videoUrl: String?
}

struct FeedSection: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let items: [SearchResult]
}

struct FeedGenre: Decodable, Identifiable, Hashable {
    let key: String
    let title: String
    var id: String { key }
}

struct FeedResponse: Decodable {
    let sections: [FeedSection]
    let genres: [FeedGenre]
}

struct GenreResponse: Decodable {
    let title: String
    let results: [SearchResult]
}

struct YouTubePlaylist: Decodable, Hashable {
    let id: String
    let title: String
    let channel: String
    let thumbnail: String?
    let items: [SearchResult]
}

struct PlaylistResponse: Decodable {
    let playlist: YouTubePlaylist
}
