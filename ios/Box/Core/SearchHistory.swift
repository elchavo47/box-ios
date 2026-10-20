import SwiftUI
import Foundation

/// Son aramalar ve son bakılan sonuçlar (yalnızca bu cihazda).
@MainActor
final class SearchHistory: ObservableObject {
    @Published private(set) var queries: [String] = []
    @Published private(set) var results: [SearchResult] = []

    private let queriesKey = "box.search.queries"
    private let resultsKey = "box.search.results"

    init() {
        queries = UserDefaults.standard.stringArray(forKey: queriesKey) ?? []
        if let data = UserDefaults.standard.data(forKey: resultsKey),
           let saved = try? JSONDecoder().decode([SearchResult].self, from: data) {
            results = saved
        }
    }

    func add(query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        queries.removeAll { $0.compare(text, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        queries.insert(text, at: 0)
        if queries.count > 20 { queries.removeLast(queries.count - 20) }
        UserDefaults.standard.set(queries, forKey: queriesKey)
    }

    func remove(query: String) {
        queries.removeAll { $0 == query }
        UserDefaults.standard.set(queries, forKey: queriesKey)
    }

    func add(result: SearchResult) {
        results.removeAll { $0.id == result.id }
        results.insert(result, at: 0)
        if results.count > 15 { results.removeLast(results.count - 15) }
        if let data = try? JSONEncoder().encode(results) {
            UserDefaults.standard.set(data, forKey: resultsKey)
        }
    }

    func clear() {
        queries = []
        results = []
        UserDefaults.standard.removeObject(forKey: queriesKey)
        UserDefaults.standard.removeObject(forKey: resultsKey)
    }
}

/// Sunucudan gelen uzaktan ayarlar: bakım, zorunlu güncelleme, duyuru.
@MainActor
final class ServerState: ObservableObject {
    @Published private(set) var maintenanceMessage: String?
    @Published private(set) var updateRequired = false
    @Published var announcement: RemoteConfig.Announcement?
    @Published private(set) var registrationOpen = true

    private let seenKey = "box.announcement.seen"
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .boxServerState, object: nil, queue: .main) { [weak self] note in
            guard let error = note.object as? APIError else { return }
            Task { @MainActor in
                if error.maintenance { self?.maintenanceMessage = error.message }
                if error.updateRequired { self?.updateRequired = true }
            }
        }
    }

    func refresh() async {
        guard let config: RemoteConfig = try? await APIClient.shared.send("config") else { return }
        maintenanceMessage = config.maintenance.on ? config.maintenance.message : nil
        registrationOpen = config.registrationOpen
        let required = Self.isVersion(AppConfig.shortVersion, lowerThan: config.minAppVersion)
        if updateRequired != required {
            withAnimation(.easeOut(duration: 0.3)) { updateRequired = required }
        }
        if let item = config.announcement, UserDefaults.standard.string(forKey: seenKey) != item.id {
            announcement = item
        }
    }

    func dismissAnnouncement() {
        if let id = announcement?.id { UserDefaults.standard.set(id, forKey: seenKey) }
        announcement = nil
    }

    static func isVersion(_ a: String, lowerThan b: String) -> Bool {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(left.count, right.count) {
            let l = i < left.count ? left[i] : 0
            let r = i < right.count ? right[i] : 0
            if l != r { return l < r }
        }
        return false
    }
}
