import Foundation
import UniformTypeIdentifiers

/// Kitaplık yedeği: listeler, beğeniler, kapaklar, dinleme geçmişi. Müzik dosyaları dahil değil.
struct LibraryBackup: Codable {
    var kind = "box.backup"
    var version = 1
    var createdAt = Date()
    var playlists: [Playlist]
    var favorites: [String]
    var remoteMeta: [String: SearchResult]
    var videoPaths: [String: String]
    var recentPaths: [String]
    var playCounts: [String: Int]
    var covers: [String: Data]
}

/// Paylaşılabilir çalma listesi (.boxlist). Şarkılar YouTube kimliğiyle taşınır.
struct SharedPlaylist: Codable {
    var kind = "box.playlist"
    var name: String
    var items: [SearchResult]
}

extension UTType {
    static let boxPlaylist = UTType(exportedAs: "com.aydworks.box.playlist", conformingTo: .json)
    static let boxBackup = UTType(exportedAs: "com.aydworks.box.backup", conformingTo: .json)
}

enum BackupService {
    static func write<T: Encodable>(_ value: T, name: String, ext: String) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return nil }
        let safe = FileService.sanitize(name)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe).appendingPathExtension(ext)
        try? FileManager.default.removeItem(at: url)
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }
}
