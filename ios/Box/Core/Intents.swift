import AppIntents
import Foundation

/// Siri ve Kısayollar'dan gelen komutlar uygulamadaki oynatıcıya bu köprüyle ulaşır.
enum BoxAction {
    case playFavorites
    case shuffleLibrary
    case playPlaylist(String)
    case togglePlayPause
    case nextTrack
}

@MainActor
final class IntentBridge {
    static let shared = IntentBridge()

    /// Uygulama hazır olunca atanır; hazır değilken gelen komut `pending`te bekler.
    var handler: ((BoxAction) -> Void)? {
        didSet {
            guard let handler, let action = pending else { return }
            pending = nil
            handler(action)
        }
    }
    private var pending: BoxAction?

    func send(_ action: BoxAction) {
        if let handler { handler(action) } else { pending = action }
    }
}

// MARK: - Liste varlığı (Kısayollar'da liste seçmek için)

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

// MARK: - Komutlar

struct PlayFavoritesIntent: AppIntent {
    static var title: LocalizedStringResource = "Beğendiklerimi çal"
    static var description = IntentDescription("Beğendiğin şarkıları çalar.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.shared.send(.playFavorites)
        return .result()
    }
}

struct ShuffleLibraryIntent: AppIntent {
    static var title: LocalizedStringResource = "Kitaplığımı karıştır"
    static var description = IntentDescription("Bütün kitaplığını karışık çalar.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.shared.send(.shuffleLibrary)
        return .result()
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
        IntentBridge.shared.send(.playPlaylist(playlist.id))
        return .result()
    }
}

struct TogglePlayPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Oynat / duraklat"
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.shared.send(.togglePlayPause)
        return .result()
    }
}

struct NextTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Sonraki şarkı"
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentBridge.shared.send(.nextTrack)
        return .result()
    }
}

// MARK: - Siri ifadeleri

struct BoxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayFavoritesIntent(),
            phrases: [
                "\(.applicationName) ile beğendiklerimi çal",
                "\(.applicationName)'ta beğendiklerimi çal",
                "Play my favorites in \(.applicationName)",
            ],
            shortTitle: "Beğendiklerimi çal",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: ShuffleLibraryIntent(),
            phrases: [
                "\(.applicationName) ile kitaplığımı karıştır",
                "Shuffle my library in \(.applicationName)",
            ],
            shortTitle: "Kitaplığı karıştır",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "\(.applicationName) ile \(\.$playlist) listesini çal",
                "Play \(\.$playlist) in \(.applicationName)",
            ],
            shortTitle: "Listeyi çal",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: TogglePlayPauseIntent(),
            phrases: [
                "\(.applicationName) oynat veya duraklat",
                "Pause or resume \(.applicationName)",
            ],
            shortTitle: "Oynat / duraklat",
            systemImageName: "playpause.fill"
        )
        AppShortcut(
            intent: NextTrackIntent(),
            phrases: [
                "\(.applicationName) sonraki şarkı",
                "Next song in \(.applicationName)",
            ],
            shortTitle: "Sonraki şarkı",
            systemImageName: "forward.fill"
        )
    }
}
