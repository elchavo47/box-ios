import Foundation

enum AppConfig {
    /// Box sunucusu (backend 2.x).
    static let apiBase = URL(string: "https://dev.aydworks.com.tr/api/v1/")!

    /// İndirilen şarkıların kaydedileceği klasör (Belgeler içinde).
    static let downloadsFolderName = "İndirilenler"

    /// Başka uygulamalardan "Box ile aç" denilen dosyaların klasörü.
    static let inboxFolderName = "Gelenler"

    static let audioExtensions: Set<String> = [
        "m4a", "mp3", "aac", "wav", "aif", "aiff", "caf", "flac", "alac", "mp4", "m4b", "opus", "ogg"
    ]

    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var appVersion: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(shortVersion) (\(build))"
    }
}
