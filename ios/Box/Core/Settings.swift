import Foundation
import Network
import SwiftUI

/// Kullanıcı ayarları (bu cihazda).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("set.wifiOnlyDownloads") var wifiOnlyDownloads = false { willSet { objectWillChange.send() } }
    @AppStorage("set.crossfade") var crossfadeSeconds = 0.0 { willSet { objectWillChange.send() } }
    @AppStorage("set.autoRadio") var autoRadio = true { willSet { objectWillChange.send() } }
    /// Yalnızca premium kullanıcılar Tarayıcı sekmesini gizleyebilir.
    @AppStorage("set.hideBrowser") var hideBrowser = false { willSet { objectWillChange.send() } }
    @AppStorage("set.normalize") var normalizeVolume = false { willSet { objectWillChange.send() } }
    @AppStorage("set.onboarded") var onboarded = false { willSet { objectWillChange.send() } }
    @AppStorage("set.searchSuggestions") var searchSuggestions = true { willSet { objectWillChange.send() } }
    @AppStorage("set.visualizer") var visualizer = true { willSet { objectWillChange.send() } }

    /// Ekolayzer (Premium); değişince çalan şarkıya hemen uygulanır.
    @Published var eq = EQSettings.load() {
        didSet { if eq != oldValue { eq.save() } }
    }
}

/// 10 bantlı ekolayzer ayarı (Premium). Bu cihazda saklanır.
struct EQSettings: Codable, Equatable {
    static let bandCount = 10
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let range: ClosedRange<Float> = -12...12
    static let boostRange: ClosedRange<Float> = 0...10

    var enabled = false
    var gains = [Float](repeating: 0, count: EQSettings.bandCount)
    /// Ses yükseltme (dB). Taşmayı yumuşak sınırlayıcı önler.
    var boost: Float = 0
    /// Seçili hazır ayar; elle oynanınca "custom".
    var preset = EQPresetID.flat.rawValue

    var isNeutral: Bool { !enabled || (gains.allSatisfy { $0 == 0 } && boost == 0) }

    static func label(for frequency: Float) -> String {
        frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
    }

    private static let key = "set.eq10"

    static func load() -> EQSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              var value = try? JSONDecoder().decode(EQSettings.self, from: data) else { return EQSettings() }
        if value.gains.count != bandCount { value.gains = [Float](repeating: 0, count: bandCount) }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// Ekolayzer hazır ayarları (32 Hz … 16 kHz, dB).
enum EQPresetID: String, CaseIterable, Identifiable {
    case flat, bass, bassBoost, vocal, pop, rock, electronic, hiphop, acoustic, classical, jazz, treble, night, speaker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat: return L("Düz")
        case .bass: return L("Bas")
        case .bassBoost: return L("Güçlü bas")
        case .vocal: return L("Vokal")
        case .pop: return "Pop"
        case .rock: return "Rock"
        case .electronic: return L("Elektronik")
        case .hiphop: return "Hip-hop"
        case .acoustic: return L("Akustik")
        case .classical: return L("Klasik")
        case .jazz: return L("Caz")
        case .treble: return L("Tiz")
        case .night: return L("Gece (yumuşak)")
        case .speaker: return L("Küçük hoparlör")
        }
    }

    var gains: [Float] {
        switch self {
        case .flat: return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bass: return [5, 4, 3, 1, 0, 0, 0, 0, 0, 0]
        case .bassBoost: return [8, 7, 5, 2, 0, -1, 0, 0, 0, 0]
        case .vocal: return [-2, -2, -1, 0, 2, 4, 4, 3, 1, 0]
        case .pop: return [-1, 0, 2, 3, 3, 1, 0, 0, 1, 1]
        case .rock: return [4, 3, 2, 0, -1, -1, 1, 3, 4, 4]
        case .electronic: return [5, 4, 2, 0, -2, 0, 1, 2, 4, 5]
        case .hiphop: return [6, 5, 2, 3, -1, -1, 1, 0, 2, 3]
        case .acoustic: return [3, 3, 2, 1, 1, 1, 2, 3, 3, 2]
        case .classical: return [3, 2, 1, 0, 0, 0, 0, 1, 2, 3]
        case .jazz: return [3, 2, 1, 2, -1, -1, 0, 1, 2, 3]
        case .treble: return [-1, -1, 0, 0, 0, 1, 2, 4, 5, 6]
        case .night: return [2, 2, 1, 0, 0, -1, -2, -3, -4, -4]
        case .speaker: return [-6, -4, 0, 3, 3, 2, 1, 1, 0, -1]
        }
    }
}

/// İnternet bağlantısı durumu.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isOnline = true
    @Published private(set) var isExpensive = false

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            Task { @MainActor in
                guard let self else { return }
                if self.isOnline != online { self.isOnline = online }
                if self.isExpensive != expensive { self.isExpensive = expensive }
            }
        }
        monitor.start(queue: DispatchQueue(label: "box.network"))
    }
}
