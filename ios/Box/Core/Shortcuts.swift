import AppIntents
import Foundation

extension Notification.Name {
    static let boxShortcut = Notification.Name("box.shortcut")
}

/// Siri ve Kestirmeler: "Box'ta beğenilenleri çal" gibi komutlar.
enum BoxShortcutAction: String {
    case favorites, shuffle, recent, resume
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

struct BoxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayFavoritesIntent(), phrases: ["\(.applicationName)'ta beğenilenleri çal", "\(.applicationName) beğenilenler"], shortTitle: "Beğenilenler", systemImageName: "heart.fill")
        AppShortcut(intent: ShuffleLibraryIntent(), phrases: ["\(.applicationName)'ta karışık çal", "\(.applicationName) karıştır"], shortTitle: "Karışık çal", systemImageName: "shuffle")
        AppShortcut(intent: PlayRecentIntent(), phrases: ["\(.applicationName)'ta son çalınanları çal"], shortTitle: "Son çalınanlar", systemImageName: "clock")
        AppShortcut(intent: ResumeIntent(), phrases: ["\(.applicationName)'ta devam et", "\(.applicationName) kaldığım yerden"], shortTitle: "Devam et", systemImageName: "play.fill")
    }
}
