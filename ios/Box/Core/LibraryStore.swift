import AVFoundation
import Foundation
import UIKit

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    /// Son çalınanlar (en yeni başta, en fazla 60).
    @Published private(set) var recentPaths: [String] = []
    @Published private(set) var playCounts: [String: Int] = [:]
    /// YouTube video kimliği → kitaplıktaki dosya yolu.
    @Published private(set) var videoPaths: [String: String] = [:]

    let documents: URL
    private let supportDirectory: URL
    private var metadataCache: [String: CachedMetadata] = [:]
    private var rescanRequested = false

    private var playlistsFile: URL { supportDirectory.appendingPathComponent("playlists.json") }
    private var favoritesFile: URL { supportDirectory.appendingPathComponent("favorites.json") }
    private var metadataFile: URL { supportDirectory.appendingPathComponent("metadata-cache.json") }
    private var historyFile: URL { supportDirectory.appendingPathComponent("history.json") }
    private var videoPathsFile: URL { supportDirectory.appendingPathComponent("video-paths.json") }

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
        metadataCache = Self.load([String: CachedMetadata].self, from: metadataFile) ?? [:]
        videoPaths = Self.load([String: String].self, from: videoPathsFile) ?? [:]
        if let history = Self.load(History.self, from: historyFile) {
            recentPaths = history.recent
            playCounts = history.counts
        }
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

            found.append(Track(
                relativePath: path,
                url: url,
                title: meta.title,
                artist: meta.artist,
                album: meta.album,
                duration: meta.duration,
                addedAt: values.creationDate ?? modified,
                fileSize: size
            ))
        }

        metadataCache = metadataCache.filter { seenPaths.contains($0.key) }
        Self.save(metadataCache, to: metadataFile)

        tracks = found.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
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
        tracks.first { $0.relativePath == path }
    }

    func tracks(for playlist: Playlist) -> [Track] {
        let index = trackIndex
        var result = playlist.paths.compactMap { index[$0] }
        if let remote = playlist.remote {
            let have = Set(result.map(\.relativePath))
            for item in remote {
                if let path = downloadedPath(for: item.id), let local = index[path] {
                    if !have.contains(path) { result.append(local) }
                } else {
                    result.append(.remote(item))
                }
            }
        }
        return result
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
        tracks.filter { favorites.contains($0.relativePath) }
    }

    var recentlyAdded: [Track] {
        Array(tracks.sorted { $0.addedAt > $1.addedAt }.prefix(12))
    }

    // MARK: - Dinleme geçmişi

    func recordPlay(_ track: Track) {
        guard !track.isRemote else { return }
        let path = track.relativePath
        recentPaths.removeAll { $0 == path }
        recentPaths.insert(path, at: 0)
        if recentPaths.count > 60 { recentPaths.removeLast(recentPaths.count - 60) }
        playCounts[path, default: 0] += 1
        saveHistory()
    }

    var recentlyPlayed: [Track] {
        let index = trackIndex
        return recentPaths.compactMap { index[$0] }
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
        let prefix = AppConfig.downloadsFolderName + "/"
        return tracks.filter { $0.relativePath.hasPrefix(prefix) }.sorted { $0.addedAt > $1.addedAt }
    }

    struct TrackGroup: Identifiable, Hashable {
        let name: String
        let tracks: [Track]
        var id: String { name }
        var duration: Double { tracks.reduce(0) { $0 + $1.duration } }
    }

    var artists: [TrackGroup] {
        Dictionary(grouping: tracks, by: \.displayArtist)
            .map { TrackGroup(name: $0.key, tracks: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var albums: [TrackGroup] {
        Dictionary(grouping: tracks.filter { !$0.album.isEmpty }, by: \.album)
            .map { TrackGroup(name: $0.key, tracks: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var trackIndex: [String: Track] {
        Dictionary(tracks.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func saveHistory() {
        Self.save(History(recent: recentPaths, counts: playCounts), to: historyFile)
    }

    var totalSize: Int64 {
        tracks.reduce(0) { $0 + $1.fileSize }
    }

    // MARK: - Favoriler

    func isFavorite(_ track: Track) -> Bool {
        favorites.contains(track.relativePath)
    }

    func toggleFavorite(_ track: Track) {
        if favorites.contains(track.relativePath) {
            favorites.remove(track.relativePath)
        } else {
            favorites.insert(track.relativePath)
        }
        Self.save(Array(favorites), to: favoritesFile)
    }

    // MARK: - Çalma listeleri

    @discardableResult
    func createPlaylist(name: String, paths: [String] = []) -> Playlist {
        let playlist = Playlist(name: name.isEmpty ? "Yeni liste" : name, paths: paths)
        playlists.append(playlist)
        savePlaylists()
        return playlist
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        playlists[index].name = name
        savePlaylists()
    }

    func deletePlaylist(_ id: UUID) {
        removeCover(for: id)
        playlists.removeAll { $0.id == id }
        savePlaylists()
    }

    func add(_ tracks: [Track], to id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        for track in tracks where !playlists[index].paths.contains(track.relativePath) {
            playlists[index].paths.append(track.relativePath)
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
            return videoPaths.first { $0.value == track.relativePath }?.key
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

    private func savePlaylists() {
        Self.save(playlists, to: playlistsFile)
    }

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
        Self.save(Array(favorites), to: favoritesFile)
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
        Self.save(Array(favorites), to: favoritesFile)
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
