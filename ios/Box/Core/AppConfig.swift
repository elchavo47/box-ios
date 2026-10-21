import Foundation

enum AppConfig {
    /// Box sunucusu (backend 2.x).
    static let apiBase = URL(string: "https://dev.aydworks.com.tr/api/v1/")!

    /// İndirilen şarkıların kaydedileceği klasör (Belgeler içinde).
    static let downloadsFolderName = "İndirilenler"

    /// Başka uygulamalardan "Box ile aç" denilen dosyaların klasörü.
    static let inboxFolderName = "Gelenler"
    static let browserFolderName = "İndirilenler"

    static let audioExtensions: Set<String> = [
        "m4a", "mp3", "aac", "wav", "aif", "aiff", "caf", "flac", "alac", "mp4", "m4b", "opus", "ogg"
    ]

    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    static var appVersion: String {
        "\(shortVersion) (\(buildNumber))"
    }
}

/// Cihaz bilgisi (sunucudaki "Cihazlarım" listesi için).
enum DeviceInfo {
    /// Bu kurulum için sabit kimlik (Anahtar Zinciri'nde; uygulama yeniden kurulunca da çoğunlukla korunur).
    static let identifier: String = {
        let key = "box.deviceID"
        if let saved = KeychainStore.get(key), !saved.isEmpty { return saved }
        let fresh = UUID().uuidString.lowercased()
        KeychainStore.set(fresh, for: key)
        return fresh
    }()

    /// Donanım model kodu, ör. "iPhone17,1".
    static let model: String = {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }()

    static let system: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }()
}
