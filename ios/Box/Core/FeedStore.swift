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

    /// Dinleme geçmişine göre en çok dinlenen sanatçılar.
    static func seeds(from library: LibraryStore) -> [String] {
        var score: [String: Int] = [:]
        for track in library.tracks {
            let name = track.displayArtist
            guard name != "Bilinmeyen sanatçı" else { continue }
            score[name, default: 0] += 1 + (library.playCounts[track.relativePath] ?? 0) * 3
        }
        for (offset, track) in library.recentlyPlayed.prefix(10).enumerated() {
            score[track.displayArtist, default: 0] += 10 - offset
        }
        return score.sorted { $0.value > $1.value }.prefix(3).map(\.key)
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
        guard let token else { throw APIError(message: "Giriş yapman gerekiyor.", status: 401) }
        return try await APIClient.shared.send("feed/genre", query: ["key": key], token: token)
    }

    func reset() {
        sections = []
        genres = []
        loadedAt = nil
    }
}
