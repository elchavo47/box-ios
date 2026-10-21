import Foundation
import Network
import SwiftUI

/// Kullanıcı ayarları (bu cihazda).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("set.wifiOnlyDownloads") var wifiOnlyDownloads = false { willSet { objectWillChange.send() } }
    @AppStorage("set.crossfade") var crossfadeSeconds = 0.0 { willSet { objectWillChange.send() } }
    @AppStorage("set.eqPreset") var eqPresetRaw = EQPreset.flat.rawValue { willSet { objectWillChange.send() } }
    @AppStorage("set.autoRadio") var autoRadio = true { willSet { objectWillChange.send() } }
    /// Yalnızca premium kullanıcılar Tarayıcı sekmesini gizleyebilir.
    @AppStorage("set.hideBrowser") var hideBrowser = false { willSet { objectWillChange.send() } }
    @AppStorage("set.normalize") var normalizeVolume = false { willSet { objectWillChange.send() } }
    @AppStorage("set.onboarded") var onboarded = false { willSet { objectWillChange.send() } }
    @AppStorage("set.searchSuggestions") var searchSuggestions = true { willSet { objectWillChange.send() } }
    @AppStorage("set.visualizer") var visualizer = true { willSet { objectWillChange.send() } }

    var eqPreset: EQPreset {
        get { EQPreset(rawValue: eqPresetRaw) ?? .flat }
        set { eqPresetRaw = newValue.rawValue }
    }
}

/// Ekolayzer hazır ayarları: 5 bant (60, 230, 910, 3600, 14000 Hz), dB.
enum EQPreset: String, CaseIterable, Identifiable {
    case flat, bass, vocal, acoustic, treble, night

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat: return L("Kapalı")
        case .bass: return L("Bas")
        case .vocal: return L("Vokal")
        case .acoustic: return L("Akustik")
        case .treble: return L("Tiz")
        case .night: return L("Gece (yumuşak)")
        }
    }

    var gains: [Float] {
        switch self {
        case .flat: return [0, 0, 0, 0, 0]
        case .bass: return [6, 4, 0, -1, 0]
        case .vocal: return [-2, -1, 3, 4, 1]
        case .acoustic: return [3, 1, 1, 2, 3]
        case .treble: return [-1, 0, 0, 3, 6]
        case .night: return [2, 1, 0, -2, -4]
        }
    }

    static let frequencies: [Float] = [60, 230, 910, 3600, 14000]
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
