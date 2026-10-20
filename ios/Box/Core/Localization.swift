import Foundation
import SwiftUI

/// Uygulama içi dil desteği.
///
/// Kaynak dil Türkçe: koddaki her metin `L("Türkçe metin")` ile yazılır, anahtar metnin kendisidir.
/// Diğer diller `i18n/<kod>.json` dosyalarından okunur (yoksa Türkçe görünür). Değişkenli metinlerde
/// `{0}`, `{1}` yer tutucuları kullanılır: `L("{0} şarkı", count)`. Çoğul gereken dillerde çeviri
/// {"one": "{0} song", "other": "{0} songs"} biçimindedir; ilk sayı değişkenine göre seçilir.
///
/// Dil seçimi: "Otomatik" telefonun (ya da iOS Ayarlar › Box › Dil) dilini izler; desteklenmeyen
/// dillerde İngilizce açılır. Uygulama içinden seçilen dil yeniden başlatmadan uygulanır.
final class Lang: ObservableObject {
    static let shared = Lang()

    struct Language: Identifiable, Hashable {
        let code: String
        /// Kendi dilindeki adı (seçim listesinde).
        let name: String
        var id: String { code }
        var rtl: Bool { code == "ar" || code == "fa" }
    }

    static let supported: [Language] = [
        .init(code: "tr", name: "Türkçe"),
        .init(code: "en", name: "English"),
        .init(code: "de", name: "Deutsch"),
        .init(code: "fr", name: "Français"),
        .init(code: "es", name: "Español"),
        .init(code: "it", name: "Italiano"),
        .init(code: "pt-BR", name: "Português (Brasil)"),
        .init(code: "nl", name: "Nederlands"),
        .init(code: "ru", name: "Русский"),
        .init(code: "uk", name: "Українська"),
        .init(code: "pl", name: "Polski"),
        .init(code: "az", name: "Azərbaycanca"),
        .init(code: "ar", name: "العربية"),
        .init(code: "fa", name: "فارسی"),
        .init(code: "hi", name: "हिन्दी"),
        .init(code: "id", name: "Bahasa Indonesia"),
        .init(code: "ja", name: "日本語"),
        .init(code: "ko", name: "한국어"),
        .init(code: "zh-Hans", name: "简体中文"),
        .init(code: "zh-Hant", name: "繁體中文"),
        .init(code: "sv", name: "Svenska"),
        .init(code: "el", name: "Ελληνικά"),
        .init(code: "ro", name: "Română"),
        .init(code: "cs", name: "Čeština"),
        .init(code: "hu", name: "Magyar"),
        .init(code: "vi", name: "Tiếng Việt"),
        .init(code: "th", name: "ไทย"),
    ]

    private static let choiceKey = "box.language"

    /// "auto" ya da dil kodu.
    @Published var choice: String {
        didSet {
            guard choice != oldValue else { return }
            UserDefaults.standard.set(choice, forKey: Self.choiceKey)
            apply()
        }
    }

    /// Kullanılan dil (otomatikte çözülmüş hali).
    @Published private(set) var code: String = "tr"

    private var table: [String: Any] = [:]
    private let lock = NSLock()

    private init() {
        choice = UserDefaults.standard.string(forKey: Self.choiceKey) ?? "auto"
        apply()
    }

    var language: Language { Self.supported.first { $0.code == code } ?? Self.supported[0] }
    var isRTL: Bool { language.rtl }
    var locale: Locale { Locale(identifier: code == "zh-Hans" ? "zh_CN" : code == "zh-Hant" ? "zh_TW" : code.replacingOccurrences(of: "-", with: "_")) }
    var layoutDirection: LayoutDirection { isRTL ? .rightToLeft : .leftToRight }

    /// Sunucuya giden dil (Accept-Language).
    var serverCode: String { code }

    /// Otomatik: iOS'un bu uygulama için seçtiği dil (Ayarlar › Box › Dil ya da telefonun dili).
    static func resolveAutomatic() -> String {
        // Locale.preferredLanguages, Ayarlar › Box › Dil seçimini de yansıtır. Bundle.preferredLocalizations
        // desteklenmeyen dillerde geliştirme diline (tr) düştüğü için önce kullanıcının dil listesine bakılır.
        for raw in Locale.preferredLanguages {
            if let match = match(raw) { return match }
        }
        return "en"
    }

    static func match(_ raw: String) -> String? {
        let id = raw.replacingOccurrences(of: "_", with: "-")
        let lower = id.lowercased()
        if lower.hasPrefix("zh") {
            if lower.contains("hant") || lower.hasSuffix("-tw") || lower.hasSuffix("-hk") || lower.hasSuffix("-mo") { return "zh-Hant" }
            return "zh-Hans"
        }
        if lower.hasPrefix("pt") { return "pt-BR" }
        let base = String(lower.split(separator: "-").first ?? "")
        return supported.first { $0.code == base }?.code
    }

    private func apply() {
        let resolved = choice == "auto" ? Self.resolveAutomatic() : (Self.supported.contains { $0.code == choice } ? choice : Self.resolveAutomatic())
        let loaded = resolved == "tr" ? [:] : Self.loadTable(resolved)
        lock.lock()
        table = loaded
        lock.unlock()
        if code != resolved { code = resolved } else { objectWillChange.send() }
    }

    private static func loadTable(_ code: String) -> [String: Any] {
        guard let url = Bundle.main.url(forResource: code, withExtension: "json", subdirectory: "i18n")
                ?? Bundle.main.url(forResource: code, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    fileprivate func translate(_ key: String, _ args: [Any]) -> String {
        lock.lock()
        let entry = table[key]
        let current = code
        lock.unlock()
        var template = key
        if let text = entry as? String, !text.isEmpty {
            template = text
        } else if let forms = entry as? [String: String] {
            let count = args.lazy.compactMap(Self.number).first ?? 0
            let category = Plural.category(for: count, language: current)
            template = forms[category] ?? forms["other"] ?? key
        }
        guard !args.isEmpty else { return template }
        var out = template
        for (index, arg) in args.enumerated() {
            out = out.replacingOccurrences(of: "{\(index)}", with: Self.describe(arg, locale: locale))
        }
        return out
    }

    private static func number(_ value: Any) -> Double? {
        switch value {
        case let v as Int: return Double(v)
        case let v as Int64: return Double(v)
        case let v as Double: return v
        case let v as Float: return Double(v)
        case let v as CGFloat: return Double(v)
        default: return nil
        }
    }

    private static func describe(_ value: Any, locale: Locale) -> String {
        switch value {
        case let v as String: return v
        case let v as Int: return v.formatted(.number.locale(locale).grouping(.never))
        case let v as Double: return v.formatted(.number.locale(locale).precision(.fractionLength(0...1)))
        default: return String(describing: value)
        }
    }
}

/// Metni seçili dile çevirir. Anahtar Türkçe metnin kendisidir.
func L(_ key: String, _ args: Any...) -> String {
    Lang.shared.translate(key, args)
}

/// CLDR çoğul kuralları (yalnızca desteklenen diller için, tam sayılar).
enum Plural {
    static func category(for value: Double, language: String) -> String {
        let n = abs(value)
        let i = Int(n)
        let isInt = n == Double(i)
        let lang = String(language.split(separator: "-").first ?? "")
        switch lang {
        case "ja", "ko", "zh", "vi", "th", "id":
            return "other"
        case "fr", "pt", "hi", "fa":
            return i == 0 || i == 1 ? "one" : "other"
        case "ru", "uk":
            guard isInt else { return "other" }
            if i % 10 == 1 && i % 100 != 11 { return "one" }
            if (2...4).contains(i % 10) && !(12...14).contains(i % 100) { return "few" }
            return "many"
        case "pl":
            guard isInt else { return "other" }
            if i == 1 { return "one" }
            if (2...4).contains(i % 10) && !(12...14).contains(i % 100) { return "few" }
            return "many"
        case "cs":
            guard isInt else { return "other" }
            if i == 1 { return "one" }
            if (2...4).contains(i) { return "few" }
            return "other"
        case "ro":
            guard isInt else { return "other" }
            if i == 1 { return "one" }
            if i == 0 || (1...19).contains(i % 100) { return "few" }
            return "other"
        case "ar":
            guard isInt else { return "other" }
            if i == 0 { return "zero" }
            if i == 1 { return "one" }
            if i == 2 { return "two" }
            if (3...10).contains(i % 100) { return "few" }
            if (11...99).contains(i % 100) { return "many" }
            return "other"
        default:
            return isInt && i == 1 ? "one" : "other"
        }
    }
}
