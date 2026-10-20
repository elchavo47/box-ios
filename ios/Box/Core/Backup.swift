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

/// Paylaşılabilir çalma listesi (.boxlist). İnternet şarkıları YouTube kimliğiyle, kendi dosyaların
/// adı ve sanatçısıyla taşınır (içe aktaran cihazda aynı dosya varsa eşleşir, yoksa YouTube'da aranabilir).
struct SharedPlaylist: Codable, Identifiable {
    var kind = "box.playlist"
    var version: Int? = 2
    var name: String
    var items: [SearchResult]
    var locals: [SharedLocal]? = nil

    var id: String { name + "#\(items.count)#\(locals?.count ?? 0)" }
    var count: Int { items.count + (locals?.count ?? 0) }
}

struct SharedLocal: Codable, Hashable {
    var title: String
    var artist: String
    var album: String?
    var duration: Int
    /// Dosya adı (uzantısıyla); aynı dosya içe aktaran cihazda da varsa doğrudan eşleşir.
    var file: String?
}

/// Birden fazla liste tek dosyada.
struct SharedBundle: Codable {
    var kind = "box.playlists"
    var version = 2
    var lists: [SharedPlaylist]
}

/// .boxlist dosyasının içi: tek liste ya da liste paketi.
enum SharedListFile {
    static func read(from url: URL) -> [SharedPlaylist]? {
        if let bundle = BackupService.read(SharedBundle.self, from: url), bundle.kind == "box.playlists" { return bundle.lists }
        if let single = BackupService.read(SharedPlaylist.self, from: url), single.kind == "box.playlist" { return [single] }
        return nil
    }

    static func data(for lists: [SharedPlaylist]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return lists.count == 1 ? try? encoder.encode(lists[0]) : try? encoder.encode(SharedBundle(lists: lists))
    }

    static func fileName(for lists: [SharedPlaylist]) -> String {
        lists.count == 1 ? lists[0].name : "Box listeleri (\(lists.count))"
    }

    /// Paylaşım ekranı için geçici dosya.
    static func write(_ lists: [SharedPlaylist]) -> URL? {
        guard let data = data(for: lists) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(FileService.sanitize(fileName(for: lists)))
            .appendingPathExtension("boxlist")
        try? FileManager.default.removeItem(at: url)
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }
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
