import AppIntents
import Foundation

extension Notification.Name {
    static let boxShortcut = Notification.Name("box.shortcut")
}

/// Siri ve Kestirmeler: "Box'ta beğenilenleri çal" gibi komutlar.
enum BoxShortcutAction: String {
    case favorites, shuffle, recent, resume, toggle, next, playlist
}

struct PlayFavoritesIntent: AppIntent {
    static var title: LocalizedStringResource = "Beğenilenleri çal"
    static var description = IntentDescription("Box'ta beğendiğin şarkıları karıştırarak çalar.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .boxShortcut, object: BoxShortcutAction.favorites.rawValue)
        return .result()
    }
}

struct ShuffleLibraryIntent: AppIntent {
    static var title: LocalizedStringResource = "Kitaplığı karıştır"
    static var description = IntentDescription("Box'taki bütün şarkıları karıştırarak çalar.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .boxShortcut, object: BoxShortcutAction.shuffle.rawValue)
        return .result()
    }
}

struct PlayRecentIntent: AppIntent {
    static var title: LocalizedStringResource = "Son çalınanları çal"
    static var description = IntentDescription("Box'ta son dinlediğin şarkıları çalar.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .boxShortcut, object: BoxShortcutAction.recent.rawValue)
        return .result()
    }
}

struct ResumeIntent: AppIntent {
    static var title: LocalizedStringResource = "Kaldığım yerden devam et"
    static var description = IntentDescription("Box'ta en son çalan şarkıya kaldığı yerden devam eder.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .boxShortcut, object: BoxShortcutAction.resume.rawValue)
        return .result()
    }
}

// MARK: - Liste seçerek çalma ("Araba listemi çal")

struct PlaylistEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Liste"
    static var defaultQuery = PlaylistQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct PlaylistQuery: EntityStringQuery {
    /// Uygulama kapalıyken de çalışsın diye listeler doğrudan dosyadan okunur.
    private static func stored() -> [PlaylistEntity] {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Box", isDirectory: true)
            .appendingPathComponent("playlists.json")
        guard let data = try? Data(contentsOf: url),
              let lists = try? JSONDecoder().decode([Playlist].self, from: data) else { return [] }
        return lists.map { PlaylistEntity(id: $0.id.uuidString, name: $0.name) }
    }

    func entities(for identifiers: [String]) async throws -> [PlaylistEntity] {
        Self.stored().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [PlaylistEntity] {
        Self.stored().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [PlaylistEntity] {
        Self.stored()
    }
}

struct PlayPlaylistIntent: AppIntent {
    static var title: LocalizedStringResource = "Listeyi çal"
    static var description = IntentDescription("Seçtiğin çalma listesini çalar (ör. Araba listem).")
    static var openAppWhenRun = true

    @Parameter(title: "Liste")
    var playlist: PlaylistEntity

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$playlist) listesini çal")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .boxShortcut, object: BoxShortcutAction.playlist.rawValue, userInfo: ["id": playlist.id])
        return .result()
    }
}

struct TogglePlayPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Oynat / duraklat"
    static var description = IntentDescription("Çalan müziği duraklatır ya da sürdürür.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .boxShortcut, object: BoxShortcutAction.toggle.rawValue)
        return .result()
    }
}

struct NextTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Sonraki şarkı"
    static var description = IntentDescription("Sıradaki şarkıya geçer.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .boxShortcut, object: BoxShortcutAction.next.rawValue)
        return .result()
    }
}

struct BoxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayFavoritesIntent(), phrases: ["\(.applicationName)'ta beğenilenleri çal", "\(.applicationName) beğenilenler"], shortTitle: "Beğenilenler", systemImageName: "heart.fill")
        AppShortcut(intent: ShuffleLibraryIntent(), phrases: ["\(.applicationName)'ta karışık çal", "\(.applicationName) karıştır"], shortTitle: "Karışık çal", systemImageName: "shuffle")
        AppShortcut(intent: PlayRecentIntent(), phrases: ["\(.applicationName)'ta son çalınanları çal"], shortTitle: "Son çalınanlar", systemImageName: "clock")
        AppShortcut(intent: PlayPlaylistIntent(), phrases: ["\(.applicationName)'ta \(\.$playlist) listesini çal", "\(.applicationName) \(\.$playlist) çal"], shortTitle: "Listeyi çal", systemImageName: "music.note.list")
        AppShortcut(intent: TogglePlayPauseIntent(), phrases: ["\(.applicationName) oynat duraklat"], shortTitle: "Oynat / duraklat", systemImageName: "playpause.fill")
        AppShortcut(intent: NextTrackIntent(), phrases: ["\(.applicationName) sonraki şarkı"], shortTitle: "Sonraki şarkı", systemImageName: "forward.fill")
        AppShortcut(intent: ResumeIntent(), phrases: ["\(.applicationName)'ta devam et", "\(.applicationName) kaldığım yerden"], shortTitle: "Devam et", systemImageName: "play.fill")
    }
}
