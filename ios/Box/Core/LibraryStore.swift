import AVFoundation
import Foundation
import UIKit

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [Track] = [] { didSet { tracksChanged() } }
    @Published var playlists: [Playlist] = []
    @Published var favorites: Set<String> = []
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    /// Son çalınanlar (en yeni başta, en fazla 60).
    @Published private(set) var recentPaths: [String] = []
    @Published private(set) var playCounts: [String: Int] = [:]
    /// YouTube video kimliği → kitaplıktaki dosya yolu.
    @Published private(set) var videoPaths: [String: String] = [:] { didSet { rebuildVideoIndex() } }
    /// Dinlenen / beğenilen internet şarkılarının bilgileri ("yt:ID" → sonuç).
    @Published private(set) var remoteMeta: [String: SearchResult] = [:]
    /// Kullanıcının düzelttiği şarkı bilgileri (dosyaya dokunmadan).
    @Published private(set) var tagOverrides: [String: TagOverride] = [:]
    /// Dinleme istatistikleri. Saniyede birkaç kez güncellendiği için yayınlanmaz;
    /// yayınlansaydı kitaplığı izleyen bütün ekranlar sürekli yeniden çizilirdi (kasma).
    private(set) var stats = ListenStats()

    // MARK: Hesaba kayıt (LibrarySync.swift)
    /// Sunucuya gönderilmeyi bekleyen değişiklikler; uygulama kapansa da kaybolmaz.
    var syncState = LibrarySyncState()
    /// Son kaydedilen hâl: neyin değiştiğini bulmak için (her değişiklik buradan geçer).
    var savedPlaylists: [UUID: Playlist] = [:]
    var savedOrder: [UUID] = []
    var savedFavorites: Set<String> = []
    /// Sunucudan gelen hâl uygulanırken değişiklikler "bekleyen" sayılmaz.
    var applyingRemote = false
    var syncTask: Task<Void, Never>?
    var syncDebounce: Task<Void, Never>?
    var pendingResync = false
    var syncToken: () -> String? = { nil }
    @Published var syncStatus: LibrarySyncStatus = .idle

    /// Hızlı arama tabloları (her satırda tüm kitaplığı taramamak için).
    private var trackByPath: [String: Track] = [:]
    private var pathToVideoID: [String: String] = [:]
    private var derived = Derived()

    private struct Derived {
        var artists: [TrackGroup]?
        var albums: [TrackGroup]?
        var downloaded: [Track]?
        var recent: [Track]?
        var totalSize: Int64?
    }

    /// İnternet şarkıları (indirilmemiş) yalnızca premium'da görünür ve çalınır.
    /// Kapalıyken son çalınanlar, beğeniler, listeler vb. yalnızca cihazdaki dosyaları gösterir.
    var allowsRemote = false {
        didSet {
            guard allowsRemote != oldValue else { return }
            derived = Derived()
            objectWillChange.send()
        }
    }

    private func tracksChanged() {
        trackByPath = Dictionary(tracks.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        derived = Derived()
    }

    private func rebuildVideoIndex() {
        pathToVideoID = Dictionary(videoPaths.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
    }

    struct TagOverride: Codable, Equatable {
        var title: String?
        var artist: String?
        var album: String?
        var coverFile: String?
    }

    struct ListenStats: Codable {
        var byDay: [String: Double] = [:]
        var byArtist: [String: Double] = [:]
        var byTrack: [String: Double] = [:]
        var titles: [String: String] = [:]
    }

    let documents: URL
    private let supportDirectory: URL
    private var metadataCache: [String: CachedMetadata] = [:]
    private var rescanRequested = false

    private var playlistsFile: URL { supportDirectory.appendingPathComponent("playlists.json") }
    private var favoritesFile: URL { supportDirectory.appendingPathComponent("favorites.json") }
    private var metadataFile: URL { supportDirectory.appendingPathComponent("metadata-cache.json") }
    private var historyFile: URL { supportDirectory.appendingPathComponent("history.json") }
    private var videoPathsFile: URL { supportDirectory.appendingPathComponent("video-paths.json") }
    private var remoteMetaFile: URL { supportDirectory.appendingPathComponent("remote-meta.json") }
    private var tagsFile: URL { supportDirectory.appendingPathComponent("tag-overrides.json") }
    private var statsFile: URL { supportDirectory.appendingPathComponent("listen-stats.json") }
    var syncStateFile: URL { supportDirectory.appendingPathComponent("library-sync.json") }
    var accountsDirectory: URL { supportDirectory.appendingPathComponent("accounts", isDirectory: true) }
    private var lastStatsSave = Date()

    private struct History: Codable {
        var recent: [String]
        var counts: [String: Int]
    }

    init() {
        let fm = FileManager.default
        documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        supportDirectory = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Box", isDirectory: true)

        try? fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(
            at: documents.appendingPathComponent(AppConfig.downloadsFolderName, isDirectory: true),
            withIntermediateDirectories: true
        )

        playlists = Self.load([Playlist].self, from: playlistsFile) ?? []
        favorites = Set(Self.load([String].self, from: favoritesFile) ?? [])
        syncState = Self.load(LibrarySyncState.self, from: syncStateFile) ?? LibrarySyncState()
        metadataCache = Self.load([String: CachedMetadata].self, from: metadataFile) ?? [:]
        videoPaths = Self.load([String: String].self, from: videoPathsFile) ?? [:]
        rebuildVideoIndex()
        remoteMeta = Self.load([String: SearchResult].self, from: remoteMetaFile) ?? [:]
        tagOverrides = Self.load([String: TagOverride].self, from: tagsFile) ?? [:]
        stats = Self.load(ListenStats.self, from: statsFile) ?? ListenStats()
        registerCoverOverrides()
        if let history = Self.load(History.self, from: historyFile) {
            recentPaths = history.recent
            playCounts = history.counts
        }
        canonicalizeFavorites()
        markSaved()
    }

    // MARK: - Tarama

    func refresh() async {
        if isScanning {
            rescanRequested = true
            return
        }

        isScanning = true
        defer { isScanning = false; hasScanned = true }

        repeat {
            rescanRequested = false
            await scan()
        } while rescanRequested
    }

    private nonisolated static func collectAudioFiles(in root: URL, keys: [URLResourceKey]) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator where AppConfig.audioExtensions.contains(url.pathExtension.lowercased()) {
            urls.append(url)
        }
        return urls
    }

    private func scan() async {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey]

        var found: [Track] = []
        var seenPaths = Set<String>()

        let urls = Self.collectAudioFiles(in: documents, keys: keys)

        for url in urls {
            guard AppConfig.audioExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }

            let path = relativePath(for: url)
            let modified = values.contentModificationDate ?? Date.distantPast
            let size = Int64(values.fileSize ?? 0)
            seenPaths.insert(path)

            var meta = metadataCache[path]
            if meta == nil || meta?.modified != modified || meta?.size != size {
                meta = await Self.readMetadata(url: url, modified: modified, size: size)
                metadataCache[path] = meta
            }

            guard let meta else { continue }

            let tag = tagOverrides[path]
            found.append(Track(
                relativePath: path,
                url: url,
                title: tag?.title ?? meta.title,
                artist: tag?.artist ?? meta.artist,
                album: tag?.album ?? meta.album,
                duration: meta.duration,
                addedAt: values.creationDate ?? modified,
                fileSize: size
            ))
        }

        metadataCache = metadataCache.filter { seenPaths.contains($0.key) }
        Self.save(metadataCache, to: metadataFile)

        tracks = found.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Tek bir yeni dosyayı tüm kitaplığı taramadan ekler (toplu indirmede kasmasın).
    func addFile(_ url: URL) async {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return await refresh() }
        let path = relativePath(for: url)
        let modified = values.contentModificationDate ?? Date()
        let size = Int64(values.fileSize ?? 0)
        let meta = await Self.readMetadata(url: url, modified: modified, size: size)
        metadataCache[path] = meta
        let tag = tagOverrides[path]
        let track = Track(relativePath: path, url: url, title: tag?.title ?? meta.title, artist: tag?.artist ?? meta.artist, album: tag?.album ?? meta.album, duration: meta.duration, addedAt: values.creationDate ?? modified, fileSize: size)
        var updated = tracks.filter { $0.relativePath != path }
        let insertAt = updated.firstIndex { $0.title.localizedCaseInsensitiveCompare(track.title) == .orderedDescending } ?? updated.count
        updated.insert(track, at: insertAt)
        tracks = updated
        scheduleMetadataSave()
    }

    private var metadataSaveTask: Task<Void, Never>?

    private func scheduleMetadataSave() {
        metadataSaveTask?.cancel()
        metadataSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            Self.save(self.metadataCache, to: self.metadataFile)
        }
    }

    private static func readMetadata(url: URL, modified: Date, size: Int64) async -> CachedMetadata {
        let asset = AVURLAsset(url: url)
        var title = ""
        var artist = ""
        var album = ""
        var duration = 0.0

        if let time = try? await asset.load(.duration), time.isNumeric {
            duration = time.seconds
        }

        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey else { continue }
                let value = (try? await item.load(.stringValue)) ?? nil

                switch key {
                case .commonKeyTitle: title = value ?? title
                case .commonKeyArtist: artist = value ?? artist
                case .commonKeyAlbumName: album = value ?? album
                default: break
                }
            }
        }

        if title.trimmingCharacters(in: .whitespaces).isEmpty {
            title = url.deletingPathExtension().lastPathComponent
        }

        return CachedMetadata(title: title, artist: artist, album: album, duration: duration, modified: modified, size: size)
    }

    func relativePath(for url: URL) -> String {
        let base = documents.standardizedFileURL.resolvingSymlinksInPath().path
        let full = url.standardizedFileURL.resolvingSymlinksInPath().path

        if full.hasPrefix(base) {
            return String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        return url.lastPathComponent
    }

    func track(forPath path: String) -> Track? {
        trackByPath[path]
    }

    /// Box'a YouTube'dan indirilmiş yerel dosya mı?
    func isDownloadedFile(_ path: String) -> Bool {
        path.hasPrefix(AppConfig.downloadsFolderName + "/") || pathToVideoID[path] != nil
    }

    func tracks(for playlist: Playlist) -> [Track] {
        let index = trackIndex
        var result = playlist.paths.compactMap { index[$0] }
        if let remote = playlist.remote {
            let have = Set(result.map(\.relativePath))
            for item in remote {
                if let path = downloadedPath(for: item.id), let local = index[path] {
                    if !have.contains(path) { result.append(local) }
                } else if allowsRemote {
                    result.append(.remote(item))
                }
            }
        }
        return result
    }

    // MARK: - Etiket düzenleme

    /// Şarkının adını, sanatçısını, albümünü ve kapağını Box içinde değiştirir (dosya bozulmaz).
    func editTags(of track: Track, title: String, artist: String, album: String, cover: UIImage?, removeCover: Bool) {
        let path = track.relativePath
        var tag = tagOverrides[path] ?? TagOverride()
        tag.title = title.trimmingCharacters(in: .whitespaces).isEmpty ? nil : title.trimmingCharacters(in: .whitespaces)
        tag.artist = artist.trimmingCharacters(in: .whitespaces).isEmpty ? nil : artist.trimmingCharacters(in: .whitespaces)
        tag.album = album.trimmingCharacters(in: .whitespaces).isEmpty ? nil : album.trimmingCharacters(in: .whitespaces)
        if removeCover, let old = tag.coverFile {
            try? FileManager.default.removeItem(at: coversDirectory.appendingPathComponent(old))
            tag.coverFile = nil
        }
        if let cover {
            try? FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
            let prepared = ArtworkCache.downscale(ArtworkCache.squareCrop(cover.normalizedOrientation()), maxSide: 900)
            let name = "tag-\(UUID().uuidString).jpg"
            if let data = prepared.jpegData(compressionQuality: 0.88), (try? data.write(to: coversDirectory.appendingPathComponent(name))) != nil {
                if let old = tag.coverFile { try? FileManager.default.removeItem(at: coversDirectory.appendingPathComponent(old)) }
                tag.coverFile = name
            }
        }
        tagOverrides[path] = tag
        Self.save(tagOverrides, to: tagsFile)
        if let index = tracks.firstIndex(where: { $0.relativePath == path }) {
            let meta = metadataCache[path]
            tracks[index].title = tag.title ?? meta?.title ?? tracks[index].title
            tracks[index].artist = tag.artist ?? meta?.artist ?? ""
            tracks[index].album = tag.album ?? meta?.album ?? ""
        }
        registerCoverOverrides()
        let url = track.url
        Task {
            await ArtworkCache.shared.invalidate(url)
            NotificationCenter.default.post(name: .boxArtworkReady, object: url)
        }
    }

    func resetTags(of track: Track) {
        if let file = tagOverrides[track.relativePath]?.coverFile {
            try? FileManager.default.removeItem(at: coversDirectory.appendingPathComponent(file))
        }
        tagOverrides[track.relativePath] = nil
        Self.save(tagOverrides, to: tagsFile)
        registerCoverOverrides()
        Task { await refresh() }
        let url = track.url
        Task {
            await ArtworkCache.shared.invalidate(url)
            NotificationCenter.default.post(name: .boxArtworkReady, object: url)
        }
    }

    private func registerCoverOverrides() {
        var map: [String: URL] = [:]
        for (path, tag) in tagOverrides {
            guard let file = tag.coverFile else { continue }
            map[documents.appendingPathComponent(path).standardizedFileURL.path] = coversDirectory.appendingPathComponent(file)
        }
        Task { await ArtworkCache.shared.setOverrides(map) }
    }

    // MARK: - Dinleme istatistikleri

    func addListen(_ track: Track, seconds: Double) {
        let day = Self.dayKey(Date())
        stats.byDay[day, default: 0] += seconds
        stats.byArtist[track.displayArtist, default: 0] += seconds
        stats.byTrack[track.relativePath, default: 0] += seconds
        if stats.titles[track.relativePath] == nil { stats.titles[track.relativePath] = track.title }
        // Diske en fazla 20 saniyede bir yaz (arka plana geçerken de yazılır).
        if Date().timeIntervalSince(lastStatsSave) > 20 {
            lastStatsSave = Date()
            Self.save(stats, to: statsFile)
        }
    }

    func flushStats() {
        Self.save(stats, to: statsFile)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    // MARK: - Akıllı listeler

    var mostPlayed: [Track] {
        playCounts.sorted { $0.value > $1.value }.prefix(25).compactMap { resolve(path: $0.key) }
    }

    var forgotten: [Track] {
        let recent = Set(recentPaths.prefix(40))
        return tracks.filter { (playCounts[$0.relativePath] ?? 0) > 0 && !recent.contains($0.relativePath) }
            .sorted { (playCounts[$0.relativePath] ?? 0) > (playCounts[$1.relativePath] ?? 0) }
            .prefix(50).map { $0 }
    }

    var addedThisMonth: [Track] {
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        return tracks.filter { $0.addedAt >= cutoff }.sorted { $0.addedAt > $1.addedAt }
    }

    /// Çalan sırayı (yerel ve internet şarkıları) yeni bir liste olarak kaydeder.
    @discardableResult
    func createPlaylist(name: String, tracks list: [Track]) -> Playlist {
        let local = list.filter { !$0.isRemote }.map(\.relativePath)
        let remote = list.compactMap(\.remote)
        let playlist = Playlist(name: name.isEmpty ? L("Sıram") : name, paths: local, remote: remote.isEmpty ? nil : remote)
        playlists.append(playlist)
        savePlaylists()
        return playlist
    }

    // MARK: - Yedekleme ve paylaşma

    func makeBackup() -> LibraryBackup {
        var covers: [String: Data] = [:]
        for playlist in playlists {
            if let file = playlist.coverFile, let data = try? Data(contentsOf: coversDirectory.appendingPathComponent(file)) {
                covers[file] = data
            }
        }
        return LibraryBackup(playlists: playlists, favorites: Array(favorites), remoteMeta: remoteMeta, videoPaths: videoPaths, recentPaths: recentPaths, playCounts: playCounts, covers: covers)
    }

    /// Yedeği mevcut kitaplıkla birleştirir (hiçbir şey silinmez). Eklenen liste sayısını döner.
    @discardableResult
    func restore(_ backup: LibraryBackup) -> Int {
        try? FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
        for (file, data) in backup.covers {
            try? data.write(to: coversDirectory.appendingPathComponent(file), options: .atomic)
        }
        var added = 0
        for playlist in backup.playlists {
            if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
                playlists[index] = playlist
            } else {
                playlists.append(playlist)
                added += 1
            }
        }
        favorites.formUnion(backup.favorites)
        remoteMeta.merge(backup.remoteMeta) { current, _ in current }
        videoPaths.merge(backup.videoPaths) { current, _ in current }
        for path in backup.recentPaths.reversed() where !recentPaths.contains(path) { recentPaths.append(path) }
        playCounts.merge(backup.playCounts) { max($0, $1) }
        savePlaylists()
        saveFavorites()
        Self.save(remoteMeta, to: remoteMetaFile)
        Self.save(videoPaths, to: videoPathsFile)
        saveHistory()
        return added
    }

    /// Paylaşmak için: internet / Box'a indirilmiş şarkılar YouTube kimliğiyle, kendi dosyaların adıyla.
    func shared(_ list: [Track], name: String) -> SharedPlaylist {
        var items: [SearchResult] = []
        var locals: [SharedLocal] = []
        var seen = Set<String>()
        for track in list {
            if let remote = track.remote {
                if seen.insert(remote.id).inserted { items.append(remote) }
            } else if let id = videoID(forPath: track.relativePath) {
                if seen.insert(id).inserted {
                    items.append(remoteMeta["yt:" + id] ?? SearchResult(id: id, title: track.title, channel: track.artist, thumbnail: nil, duration: Int(track.duration)))
                }
            } else {
                locals.append(SharedLocal(title: track.title, artist: track.artist, album: track.album.isEmpty ? nil : track.album, duration: Int(track.duration.rounded()), file: track.url.lastPathComponent))
            }
        }
        return SharedPlaylist(name: name, items: items, locals: locals.isEmpty ? nil : locals)
    }

    func sharedPlaylist(for playlist: Playlist) -> SharedPlaylist {
        shared(tracks(for: playlist), name: playlist.name)
    }

    /// Paylaşılan listedeki kendi dosyalarını bu cihazdaki kitaplıkla eşleştirir.
    /// Dönen: eşleşen yollar ve bulunamayanlar.
    func matchLocals(_ locals: [SharedLocal]) -> (paths: [String], missing: [SharedLocal]) {
        func norm(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "tr_TR"))
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        var byFile: [String: Track] = [:]
        var byTitleArtist: [String: Track] = [:]
        var byTitle: [String: [Track]] = [:]
        for track in tracks {
            byFile[track.url.lastPathComponent.lowercased()] = byFile[track.url.lastPathComponent.lowercased()] ?? track
            byTitleArtist[norm(track.title) + "|" + norm(track.artist)] = byTitleArtist[norm(track.title) + "|" + norm(track.artist)] ?? track
            byTitle[norm(track.title), default: []].append(track)
        }
        var paths: [String] = []
        var missing: [SharedLocal] = []
        for item in locals {
            var found: Track?
            if let file = item.file?.lowercased(), let t = byFile[file] { found = t }
            if found == nil { found = byTitleArtist[norm(item.title) + "|" + norm(item.artist)] }
            if found == nil, let candidates = byTitle[norm(item.title)] {
                let close = candidates.filter { abs(Int($0.duration.rounded()) - item.duration) <= 3 }
                if close.count == 1 { found = close[0] }
            }
            if let found, !paths.contains(found.relativePath) { paths.append(found.relativePath) }
            else if found == nil { missing.append(item) }
        }
        return (paths, missing)
    }

    /// Paylaşılan listeyi kitaplığa ekler. `extra`: YouTube'da bulunan (dosyası olmayan) şarkılar.
    @discardableResult
    func importShared(_ shared: SharedPlaylist, localPaths: [String]? = nil, extra: [SearchResult] = []) -> Playlist {
        let paths = localPaths ?? matchLocals(shared.locals ?? []).paths
        var items = shared.items
        for item in extra where !items.contains(where: { $0.id == item.id }) { items.append(item) }
        let playlist = Playlist(name: shared.name.isEmpty ? L("Paylaşılan liste") : shared.name, paths: paths, remote: items.isEmpty ? nil : items)
        playlists.append(playlist)
        savePlaylists()
        return playlist
    }

    // MARK: - Liste kapakları

    private var coversDirectory: URL { supportDirectory.appendingPathComponent("covers", isDirectory: true) }
    private let coverCache = NSCache<NSString, UIImage>()

    func coverImage(for playlist: Playlist) -> UIImage? {
        guard let file = playlist.coverFile else { return nil }
        if let cached = coverCache.object(forKey: file as NSString) { return cached }
        guard let image = UIImage(contentsOfFile: coversDirectory.appendingPathComponent(file).path) else { return nil }
        coverCache.setObject(image, forKey: file as NSString)
        return image
    }

    /// Seçilen fotoğrafı kare kırpıp kapak olarak kaydeder (yalnızca bu cihazda).
    func setCover(_ image: UIImage, for id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
        let prepared = ArtworkCache.downscale(ArtworkCache.squareCrop(image.normalizedOrientation()), maxSide: 900)
        guard let data = prepared.jpegData(compressionQuality: 0.88) else { return }
        if let old = playlists[index].coverFile {
            try? FileManager.default.removeItem(at: coversDirectory.appendingPathComponent(old))
            coverCache.removeObject(forKey: old as NSString)
        }
        let name = "\(id.uuidString)-\(Int(Date().timeIntervalSince1970)).jpg"
        do {
            try data.write(to: coversDirectory.appendingPathComponent(name), options: .atomic)
            playlists[index].coverFile = name
            savePlaylists()
        } catch {}
    }

    func removeCover(for id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }), let old = playlists[index].coverFile else { return }
        try? FileManager.default.removeItem(at: coversDirectory.appendingPathComponent(old))
        coverCache.removeObject(forKey: old as NSString)
        playlists[index].coverFile = nil
        savePlaylists()
    }

    // MARK: - YouTube eşleştirme

    /// Bu video daha önce indirildiyse kitaplıktaki yolu.
    func downloadedPath(for videoID: String) -> String? {
        if let path = videoPaths[videoID], track(forPath: path) != nil { return path }
        return nil
    }

    func localTrack(for result: SearchResult) -> Track? {
        if let path = downloadedPath(for: result.id) { return track(forPath: path) }
        // Eski sürümde indirilenler: dosya adından eşleştir.
        let legacy = AppConfig.downloadsFolderName + "/" + FileService.sanitize(result.title) + ".m4a"
        return track(forPath: legacy)
    }

    /// İndirilmiş dosyanın YouTube kimliği (videosunu açmak için).
    func videoID(forPath path: String) -> String? {
        pathToVideoID[path]
    }

    func setDownloadedPath(_ path: String, for videoID: String) {
        videoPaths[videoID] = path
        Self.save(videoPaths, to: videoPathsFile)
    }

    /// YouTube listesini Box listesi olarak kaydeder (indirilmemiş şarkılar internetten çalar).
    @discardableResult
    func importPlaylist(_ list: YouTubePlaylist) -> Playlist {
        if let index = playlists.firstIndex(where: { $0.sourceID == list.id }) {
            playlists[index].remote = list.items
            playlists[index].name = list.title
            savePlaylists()
            return playlists[index]
        }
        let playlist = Playlist(name: list.title, remote: list.items, sourceID: list.id)
        playlists.append(playlist)
        savePlaylists()
        return playlist
    }

    var favoriteTracks: [Track] {
        var result = tracks.filter { favorites.contains($0.relativePath) }
        let have = Set(result.map(\.relativePath))
        for path in favorites where path.hasPrefix("yt:") {
            if let track = resolve(path: path), !have.contains(track.relativePath) { result.append(track) }
        }
        return result
    }

    var recentlyAdded: [Track] {
        if let cached = derived.recent { return cached }
        let value = Array(tracks.sorted { $0.addedAt > $1.addedAt }.prefix(12))
        derived.recent = value
        return value
    }

    // MARK: - Dinleme geçmişi

    /// İnternet şarkısını hatırlar (geçmiş, beğeni ve öneriler için).
    func remember(_ result: SearchResult) {
        let key = "yt:" + result.id
        guard remoteMeta[key] != result else { return }
        remoteMeta[key] = result
        if remoteMeta.count > 400 {
            let keep = Set(recentPaths).union(favorites)
            remoteMeta = remoteMeta.filter { keep.contains($0.key) }
        }
        Self.save(remoteMeta, to: remoteMetaFile)
    }

    /// Yol (yerel ya da "yt:ID") → çalınabilir şarkı. İndirilmişse yerel dosya döner.
    func resolve(path: String) -> Track? {
        if let local = track(forPath: path) { return local }
        guard let meta = remoteMeta[path] else { return nil }
        if let local = localTrack(for: meta) { return local }
        return allowsRemote ? .remote(meta) : nil
    }

    func recordPlay(_ track: Track) {
        if let remote = track.remote { remember(remote) }
        let path = track.relativePath
        recentPaths.removeAll { $0 == path }
        recentPaths.insert(path, at: 0)
        if recentPaths.count > 60 { recentPaths.removeLast(recentPaths.count - 60) }
        playCounts[path, default: 0] += 1
        saveHistory()
    }

    var recentlyPlayed: [Track] {
        var seen = Set<String>()
        return recentPaths.compactMap { resolve(path: $0) }.filter { seen.insert($0.relativePath).inserted }
    }

    /// Ana sayfadaki "Hızlı seçimler": en çok dinlenenler, yoksa son eklenenler.
    var quickPicks: [Track] {
        let played = tracks.filter { (playCounts[$0.relativePath] ?? 0) > 0 }
            .sorted { (playCounts[$0.relativePath] ?? 0) > (playCounts[$1.relativePath] ?? 0) }
        var picks = Array(played.prefix(16))
        if picks.count < 16 {
            let have = Set(picks.map(\.relativePath))
            picks += recentlyAdded.filter { !have.contains($0.relativePath) }.prefix(16 - picks.count)
        }
        return picks
    }

    var downloadedTracks: [Track] {
        if let cached = derived.downloaded { return cached }
        let prefix = AppConfig.downloadsFolderName + "/"
        let value = tracks.filter { $0.relativePath.hasPrefix(prefix) }.sorted { $0.addedAt > $1.addedAt }
        derived.downloaded = value
        return value
    }

    struct TrackGroup: Identifiable, Hashable {
        let name: String
        let tracks: [Track]
        var id: String { name }
        var duration: Double { tracks.reduce(0) { $0 + $1.duration } }
    }

    var artists: [TrackGroup] {
        if let cached = derived.artists { return cached }
        let value = Dictionary(grouping: tracks, by: \.displayArtist)
            .map { TrackGroup(name: $0.key, tracks: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        derived.artists = value
        return value
    }

    var albums: [TrackGroup] {
        if let cached = derived.albums { return cached }
        let value = Dictionary(grouping: tracks.filter { !$0.album.isEmpty }, by: \.album)
            .map { TrackGroup(name: $0.key, tracks: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        derived.albums = value
        return value
    }

    private var trackIndex: [String: Track] { trackByPath }

    private func saveHistory() {
        Self.save(History(recent: recentPaths, counts: playCounts), to: historyFile)
    }

    var totalSize: Int64 {
        if let cached = derived.totalSize { return cached }
        let value = tracks.reduce(Int64(0)) { $0 + $1.fileSize }
        derived.totalSize = value
        return value
    }

    // MARK: - Favoriler

    func isFavorite(_ track: Track) -> Bool {
        if favorites.contains(track.relativePath) { return true }
        // İnternetten beğenilip sonra indirilen şarkı da beğenili sayılır.
        if !track.isRemote, let id = videoID(forPath: track.relativePath) { return favorites.contains("yt:" + id) }
        return false
    }

    func toggleFavorite(_ track: Track) {
        if let remote = track.remote { remember(remote) }
        // Box'a indirilmiş şarkı YouTube kimliğiyle beğenilir: hesapta her cihazda aynı şarkı olsun.
        if !track.isRemote, let id = videoID(forPath: track.relativePath) {
            let key = "yt:" + id
            if favorites.contains(key) || favorites.contains(track.relativePath) {
                favorites.remove(key)
                favorites.remove(track.relativePath)
            } else {
                if remoteMeta[key] == nil {
                    remember(SearchResult(id: id, title: track.title, channel: track.artist, thumbnail: nil, duration: Int(track.duration)))
                }
                favorites.insert(key)
            }
            saveFavorites()
            return
        }
        if favorites.contains(track.relativePath) {
            favorites.remove(track.relativePath)
        } else {
            favorites.insert(track.relativePath)
        }
        saveFavorites()
    }

    // MARK: - Çalma listeleri

    @discardableResult
    func createPlaylist(name: String, paths: [String] = []) -> Playlist {
        let playlist = Playlist(name: name.isEmpty ? L("Yeni liste") : name, paths: paths)
        playlists.append(playlist)
        savePlaylists()
        return playlist
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        playlists[index].name = name
        savePlaylists()
    }

    /// Kitaplıkta basılı tutup sürükleyerek liste sırasını değiştirme.
    func movePlaylists(from source: IndexSet, to destination: Int) {
        playlists.move(fromOffsets: source, toOffset: destination)
        savePlaylists()
    }

    func deletePlaylist(_ id: UUID) {
        removeCover(for: id)
        playlists.removeAll { $0.id == id }
        savePlaylists()
    }

    func add(_ tracks: [Track], to id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        for track in tracks {
            if let remote = track.remote {
                // İndirilmemiş şarkı: liste internetten çalar, indirilince yerel dosyaya geçer.
                remember(remote)
                var list = playlists[index].remote ?? []
                if !list.contains(where: { $0.id == remote.id }) { list.append(remote) }
                playlists[index].remote = list
            } else if !playlists[index].paths.contains(track.relativePath) {
                playlists[index].paths.append(track.relativePath)
            }
        }
        savePlaylists()
    }

    func removeTracks(at offsets: IndexSet, from id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let visible = tracks(for: playlists[index])
        let chosen = offsets.compactMap { visible.indices.contains($0) ? visible[$0] : nil }
        let toRemove = Set(chosen.map(\.relativePath))
        playlists[index].paths.removeAll { toRemove.contains($0) }
        let remoteIDs = Set(chosen.compactMap { track -> String? in
            if let r = track.remote { return r.id }
            return pathToVideoID[track.relativePath]
        })
        playlists[index].remote?.removeAll { remoteIDs.contains($0.id) }
        savePlaylists()
    }

    func moveTracks(from source: IndexSet, to destination: Int, in id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        guard playlists[index].remote == nil else { return }
        var visible = tracks(for: playlists[index]).map(\.relativePath)
        visible.move(fromOffsets: source, toOffset: destination)
        let missing = playlists[index].paths.filter { !visible.contains($0) }
        playlists[index].paths = visible + missing
        savePlaylists()
    }

    func playlist(_ id: UUID) -> Playlist? {
        playlists.first { $0.id == id }
    }

    /// Bütün liste değişiklikleri buradan geçer: neyin değiştiğini bulur, hesaba gönderilecekler arasına ekler.
    func savePlaylists() {
        if !applyingRemote { recordPlaylistChanges() }
        Self.save(playlists, to: playlistsFile)
        if !applyingRemote { scheduleSync() }
    }

    func saveFavorites() {
        if !applyingRemote { recordFavoriteChanges() }
        Self.save(Array(favorites), to: favoritesFile)
        if !applyingRemote { scheduleSync() }
    }

    /// Sunucudan gelen hâli diske yazar (bekleyen değişiklik sayılmaz).
    func persistLibrary() {
        Self.save(playlists, to: playlistsFile)
        Self.save(Array(favorites), to: favoritesFile)
        Self.save(remoteMeta, to: remoteMetaFile)
        saveSyncState()
    }

    func saveSyncState() {
        Self.save(syncState, to: syncStateFile)
    }

    /// Hesap değişiminde: listeleri, beğenileri ve bekleyen değişiklikleri doğrudan değiştirir.
    func replaceLibrary(playlists newPlaylists: [Playlist], favorites newFavorites: Set<String>, state: LibrarySyncState) {
        applyingRemote = true
        playlists = newPlaylists
        favorites = newFavorites
        syncState = state
        applyingRemote = false
        persistLibrary()
        markSaved()
    }

    /// Diskteki hâlin bir kopyası (hesap arşivi için).
    func archiveFiles() -> (playlists: [Playlist], favorites: [String]) {
        (playlists, Array(favorites))
    }

    static func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? { load(type, from: url) }
    static func saveJSON<T: Encodable>(_ value: T, to url: URL) { save(value, to: url) }

    func mergeRemoteMeta(_ items: [SearchResult]) {
        var changed = false
        for item in items where remoteMeta["yt:" + item.id] == nil {
            remoteMeta["yt:" + item.id] = item
            changed = true
        }
        if changed { Self.save(remoteMeta, to: remoteMetaFile) }
    }

    var coversFolder: URL { coversDirectory }
    func coverCacheRemove(_ file: String) { coverCache.removeObject(forKey: file as NSString) }

    // MARK: - Dosya işlemleri sonrası güncelleme

    /// Dosya ya da klasör taşındığında / yeniden adlandırıldığında listeleri ve favorileri günceller.
    func pathMoved(from oldURL: URL, to newURL: URL) {
        let oldPath = relativePath(for: oldURL)
        let newPath = relativePath(for: newURL)

        func remap(_ path: String) -> String {
            if path == oldPath { return newPath }
            if path.hasPrefix(oldPath + "/") { return newPath + path.dropFirst(oldPath.count) }
            return path
        }

        playlists = playlists.map { playlist in
            var copy = playlist
            copy.paths = playlist.paths.map(remap)
            return copy
        }
        favorites = Set(favorites.map(remap))
        recentPaths = recentPaths.map(remap)
        videoPaths = videoPaths.mapValues(remap)
        Self.save(videoPaths, to: videoPathsFile)
        playCounts = Dictionary(playCounts.map { (remap($0.key), $0.value) }, uniquingKeysWith: +)
        saveHistory()

        var newCache: [String: CachedMetadata] = [:]
        for (key, value) in metadataCache {
            newCache[remap(key)] = value
        }
        metadataCache = newCache

        savePlaylists()
        saveFavorites()
        Self.save(metadataCache, to: metadataFile)
    }

    func pathDeleted(_ url: URL) {
        let path = relativePath(for: url)

        func keep(_ candidate: String) -> Bool {
            candidate != path && !candidate.hasPrefix(path + "/")
        }

        playlists = playlists.map { playlist in
            var copy = playlist
            copy.paths = playlist.paths.filter(keep)
            return copy
        }
        favorites = favorites.filter(keep)
        recentPaths = recentPaths.filter(keep)
        videoPaths = videoPaths.filter { keep($0.value) }
        Self.save(videoPaths, to: videoPathsFile)
        playCounts = playCounts.filter { keep($0.key) }
        saveHistory()

        savePlaylists()
        saveFavorites()
    }

    // MARK: - İçe aktarma

    /// Başka uygulamalardan ya da dosya seçiciden gelen dosyaları kopyalar.
    @discardableResult
    func importFiles(_ urls: [URL], into folder: URL) async -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var count = 0

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            // Zaten Belgeler içindeyse kopyalamaya gerek yok.
            if url.standardizedFileURL.path.hasPrefix(documents.standardizedFileURL.path) {
                continue
            }

            let destination = FileService.uniqueURL(for: url.lastPathComponent, in: folder)
            do {
                try fm.copyItem(at: url, to: destination)
                count += 1
            } catch {
                continue
            }
        }

        await refresh()
        return count
    }

    // MARK: - JSON yardımcıları

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension UIImage {
    /// Kamera fotoğraflarının yönünü düzeltir (kırpmadan önce).
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}
