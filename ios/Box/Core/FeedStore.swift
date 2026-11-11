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

    /// Yayıncı / etiket / derleme kanalları gerçek sanatçı değildir; tohum olmasınlar.
    private static let channelWords: Set<String> = [
        "müzik", "muzik", "music", "records", "record", "plak", "production", "productions", "prodüksiyon",
        "entertainment", "yapım", "yapim", "kanal", "channel", "tv", "radyo", "radio", "network"
    ]

    /// İnternet şarkısının "sanatçı"sı çoğu zaman kanal adıdır: "- Topic", VEVO, Official eklerini temizler,
    /// yayıncı kanallarını (ör. "… Müzik") eler. Cihazdaki dosyaların etiketine dokunmaz.
    static func seedName(_ raw: String, isRemote: Bool) -> String? {
        var name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != L("Bilinmeyen sanatçı") else { return nil }
        guard isRemote else { return name }
        for suffix in [" - Topic", "VEVO", " Official", " Resmi"] {
            name = name.replacingOccurrences(of: suffix, with: "", options: .caseInsensitive)
        }
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let words = Set(name.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
        return words.isDisjoint(with: channelWords) ? name : nil
    }

    /// Zevk puanı. Beğeni en güçlü sinyal, yeterince dinlenen şarkılar sonra gelir; hemen atlananlar puanı düşürür.
    /// İnternetten dinlenen (indirilmemiş) şarkılar da sayılır.
    static func seeds(from library: LibraryStore) -> [String] {
        var score: [String: Int] = [:]
        func add(_ track: Track, _ points: Int) {
            guard let name = seedName(track.displayArtist, isRemote: track.isRemote) else { return }
            score[name, default: 0] += points
        }
        // Kitaplıktaki dosyalar: küçük bir taban puan.
        for track in library.tracks { add(track, 1) }
        // Yeterince dinlenen şarkılar (cihazdaki ve internetten dinlenen).
        for (path, count) in library.playCounts where count > 0 {
            if let track = library.resolve(path: path) { add(track, count * 4) }
        }
        // Beğeniler.
        for track in library.favoriteTracks { add(track, 10) }
        // Dinlemeden atlananlar.
        for (path, skips) in library.skipCounts where skips > 0 {
            if let track = library.resolve(path: path) { add(track, -skips * 3) }
        }
        for (offset, track) in library.recentlyPlayed.prefix(20).enumerated() {
            // Hemen atlanıp bir daha dinlenmeyen şarkı "son dinlenen" olarak zevk puanı kazanmasın.
            if (library.playCounts[track.relativePath] ?? 0) == 0, (library.skipCounts[track.relativePath] ?? 0) > 0 { continue }
            add(track, (20 - offset) * 2)
        }
        // Kendi oluşturduğu ya da içe aktardığı listeler de tarzı gösterir.
        for playlist in library.playlists {
            for path in playlist.paths.prefix(200) {
                if let track = library.resolve(path: path) { add(track, 2) }
            }
            for item in (playlist.remote ?? []).prefix(200) {
                if let name = seedName(item.channel, isRemote: true) { score[name, default: 0] += 2 }
            }
        }
        return score.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(5).map(\.key)
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

    /// İçe aktarılan / oluşturulan listelerde bu kadar şarkı varsa tarz bunlardan hemen çıkarılır.
    static let neededPlaylistSongs = 10

    @MainActor static func listens(_ library: LibraryStore) -> Int {
        library.playCounts.values.filter { $0 > 0 }.count
    }

    @MainActor static func playlistSongs(_ library: LibraryStore) -> Int {
        library.playlists.reduce(0) { $0 + max($1.paths.count, $1.remote?.count ?? 0) }
    }

    static func isReady(searches: Int, listens: Int, playlistSongs: Int = 0) -> Bool {
        if UserDefaults.standard.bool(forKey: unlockedKey) { return true }
        let ready = (searches >= neededSearches && listens >= neededListens) || listens >= establishedListens || playlistSongs >= neededPlaylistSongs
        if ready { UserDefaults.standard.set(true, forKey: unlockedKey) }
        return ready
    }
}
