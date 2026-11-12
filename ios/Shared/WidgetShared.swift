import Foundation

/// Uygulama ile ana ekran widget'ı arasında paylaşılan veri (App Group klasörü).
enum BoxShared {
    static let group = "group.com.aydworks.box"

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    static var snapshotURL: URL? { container?.appendingPathComponent("widget.json") }

    static func imageURL(_ name: String) -> URL? { container?.appendingPathComponent(name) }
}

struct WidgetTrack: Codable, Hashable {
    var title: String
    var artist: String
    /// App Group klasöründeki kapak dosyasının adı
    var art: String?
}

struct WidgetSnapshot: Codable {
    var now: WidgetTrack?
    var playing: Bool
    var recent: [WidgetTrack]

    static var empty: WidgetSnapshot { WidgetSnapshot(now: nil, playing: false, recent: []) }

    static func load() -> WidgetSnapshot {
        guard let url = BoxShared.snapshotURL, let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return .empty }
        return value
    }

    func save() {
        guard let url = BoxShared.snapshotURL, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
