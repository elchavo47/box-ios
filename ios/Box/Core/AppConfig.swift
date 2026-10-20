import Foundation

enum AppConfig {
    /// Hostingdeki Box API adresi (backend/api/index.php).
    /// Backend'i başka bir klasöre koyarsan burayı değiştir.
    static let apiBase = URL(string: "https://dev.aydworks.com.tr/box/api/index.php")!

    /// İndirilen şarkıların kaydedileceği klasör (Belgeler içinde).
    static let downloadsFolderName = "İndirilenler"

    /// Başka uygulamalardan "Box ile aç" denilen dosyaların klasörü.
    static let inboxFolderName = "Gelenler"

    static let audioExtensions: Set<String> = [
        "m4a", "mp3", "aac", "wav", "aif", "aiff", "caf", "flac", "alac", "mp4", "m4b", "opus", "ogg"
    ]

    static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
