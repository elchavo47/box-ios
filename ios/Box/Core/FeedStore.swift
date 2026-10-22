import Foundation

/// Ana sayfadaki "Sana özel" öneriler (premium).
@MainActor
final class FeedStore: ObservableObject {
    @Published private(set) var sections: [FeedSection] = []
    @Published private(set) var genres: [FeedGenre] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var loadedAt: Date?
    private var loadedSeeds: [String] = []

    /// Dinleme geçmişine göre en çok dinlenen sanatçılar. Belirleyici olan dinleme sayısı ve son dinlenenler;
    /// kitaplıkta çok dosyası olan ama dinlenmeyen sanatçı öne geçmesin diye dosya sayısının etkisi küçüktür.
    static func seeds(from library: LibraryStore) -> [String] {
        var score: [String: Int] = [:]
        for track in library.tracks {
            let name = track.displayArtist
            guard name != L("Bilinmeyen sanatçı") else { continue }
            score[name, default: 0] += 1 + (library.playCounts[track.relativePath] ?? 0) * 4
        }
        for (offset, track) in library.recentlyPlayed.prefix(20).enumerated() where track.displayArtist != L("Bilinmeyen sanatçı") {
            score[track.displayArtist, default: 0] += (20 - offset) * 2
        }
        return score.sorted { $0.value > $1.value }.prefix(5).map(\.key)
    }

    func load(token: String?, seeds: [String], force: Bool = false) async {
        guard let token else { return }
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 1800, loadedSeeds == seeds, !sections.isEmpty { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response: FeedResponse = try await APIClient.shared.send(
                "feed", query: ["artists": seeds.joined(separator: "|")], token: token
            )
            sections = response.sections
            genres = response.genres
            loadedAt = Date()
            loadedSeeds = seeds
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
        }
    }

    func genre(_ key: String, token: String?) async throws -> GenreResponse {
        guard let token else { throw APIError(message: L("Giriş yapman gerekiyor."), status: 401) }
        return try await APIClient.shared.send("feed/genre", query: ["key": key], token: token)
    }

    /// Bir şarkıya benzer şarkılar (radyo).
    func radio(for track: Track, exclude: [String], token: String?) async -> [SearchResult] {
        guard let token else { return [] }
        struct Response: Decodable { let results: [SearchResult] }
        let response: Response? = try? await APIClient.shared.send(
            "radio",
            query: ["artist": track.displayArtist, "title": track.title, "exclude": exclude.suffix(80).joined(separator: ",")],
            token: token
        )
        return response?.results ?? []
    }

    func suggestions(for query: String, token: String?) async -> [String] {
        guard let token, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        struct Response: Decodable { let suggestions: [String] }
        let response: Response? = try? await APIClient.shared.send("suggest", query: ["q": query], token: token)
        return response?.suggestions ?? []
    }

    func reset() {
        sections = []
        genres = []
        loadedAt = nil
    }
}

/// "Sana özel" bölümünün açılma koşulu: tarz birkaç arama ve dinlemeden sonra belirlenir.
/// Bir kez açılınca geçmiş silinse de açık kalır.
enum TasteProgress {
    static let searchesKey = "box.taste.searches"
    static let unlockedKey = "box.taste.unlocked"
    static let neededSearches = 2
    static let neededListens = 2
    /// Uygulamayı uzun süredir kullanan ve çok dinlemesi olan biri aramadan da açılsın.
    static let establishedListens = 8

    static func recordSearch() {
        let current = UserDefaults.standard.integer(forKey: searchesKey)
        if current < 1000 { UserDefaults.standard.set(current + 1, forKey: searchesKey) }
    }

    static func listens(_ library: LibraryStore) -> Int {
        library.playCounts.values.filter { $0 > 0 }.count
    }

    static func isReady(searches: Int, listens: Int) -> Bool {
        if UserDefaults.standard.bool(forKey: unlockedKey) { return true }
        let ready = (searches >= neededSearches && listens >= neededListens) || listens >= establishedListens
        if ready { UserDefaults.standard.set(true, forKey: unlockedKey) }
        return ready
    }
}
