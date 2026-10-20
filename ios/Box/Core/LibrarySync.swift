import Foundation
import UIKit

/// Hesaba bağlı kitaplık: çalma listeleri, beğenilenler ve liste kapakları sunucuya kaydedilir.
///
/// - Her değişiklik `savePlaylists()` / `saveFavorites()` içinde fark olarak bulunur ve "bekleyen" olarak
///   diske yazılır (çevrimdışıyken de kaybolmaz), kısa bir beklemeden sonra sunucuya gönderilir.
/// - Sunucu her öğe için en son değişeni tutar ve hesabın güncel kitaplığını döner; uygulama
///   bekleyen (henüz gönderilmemiş) değişikliklerini koruyarak onu uygular.
/// - Çıkış yapılınca hesabın kitaplığı cihazda hesaba özel bir klasöre kaldırılır, liste ve beğeniler
///   boşalır; aynı hesapla tekrar girilince geri gelir, başka hesapla girilince o hesabınki gelir.
struct LibrarySyncState: Codable {
    /// Bu kitaplık kimin? nil: misafir (giriş yapılmamış).
    var owner: Int?
    /// Sunucuya gönderilmeyi bekleyen listeler (kimlik → değişiklik zamanı).
    var dirty: [UUID: Date] = [:]
    /// Silinen listeler (kimlik → silinme zamanı).
    var deleted: [UUID: Date] = [:]
    /// Beğeni değişiklikleri (anahtar → açık/kapalı ve zaman).
    var favorites: [String: FavoriteChange] = [:]
    /// Liste sırası değiştiyse zamanı.
    var orderChangedAt: Date?
    /// Kapağı yüklenecek / kaldırılacak listeler.
    var covers: Set<UUID> = []
    var lastSync: Date?

    struct FavoriteChange: Codable, Equatable {
        var on: Bool
        var at: Date
    }

    var hasPending: Bool { !dirty.isEmpty || !deleted.isEmpty || !favorites.isEmpty || orderChangedAt != nil || !covers.isEmpty }
}

enum LibrarySyncStatus: Equatable {
    case idle, syncing, failed(String)
}

// MARK: - Sunucu biçimi

private struct SyncPlaylistOut: Encodable {
    let id: String
    let name: String
    let paths: [String]
    let remote: [SearchResult]
    let source_id: String?
    let created_at: Int64
    let updated_at: Int64
    let deleted: Bool
}

private struct SyncFavoriteOut: Encodable {
    let key: String
    let on: Bool
    let at: Int64
    let meta: SearchResult?
}

private struct SyncOrderOut: Encodable {
    let ids: [String]
    let at: Int64
}

private struct SyncRequest: Encodable {
    var playlists: [SyncPlaylistOut] = []
    var favorites: [SyncFavoriteOut] = []
    var order: SyncOrderOut?
}

struct LibraryStateResponse: Decodable {
    let playlists: [RemotePlaylist]
    let favorites: [RemoteFavorite]
    let orderAt: Int64?

    struct RemotePlaylist: Decodable {
        let id: String
        let name: String
        let paths: [String]
        let remote: [SearchResult]
        let sourceId: String?
        let coverUrl: String?
        let position: Int
        let createdAt: Int64
        let updatedAt: Int64
        let deleted: Bool
    }

    struct RemoteFavorite: Decodable {
        let key: String
        let on: Bool
        let at: Int64
        let meta: SearchResult?
    }
}

private struct CoverResponse: Decodable {
    let coverUrl: String?
}

private extension Date {
    var millis: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
    init(millis: Int64) { self.init(timeIntervalSince1970: Double(millis) / 1000) }
}

// MARK: - Değişiklikleri bulma

extension LibraryStore {
    /// Diskteki hâli "son kaydedilen" olarak işaretle.
    func markSaved() {
        savedPlaylists = Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        savedOrder = playlists.map(\.id)
        savedFavorites = favorites
    }

    func recordPlaylistChanges() {
        let now = Date()
        var current: [UUID: Playlist] = [:]
        for index in playlists.indices {
            let id = playlists[index].id
            let old = savedPlaylists[id]
            if old == nil || old?.syncContent != playlists[index].syncContent {
                playlists[index].updatedAt = now
                syncState.dirty[id] = now
                syncState.deleted[id] = nil
            }
            if old?.coverFile != playlists[index].coverFile {
                syncState.covers.insert(id)
            }
            current[id] = playlists[index]
        }
        for id in savedPlaylists.keys where current[id] == nil {
            syncState.deleted[id] = now
            syncState.dirty[id] = nil
            syncState.covers.remove(id)
        }
        let order = playlists.map(\.id)
        // Yalnızca ekleme/silme değil, var olan listelerin sırası değiştiyse sırayı da gönder.
        let kept = savedOrder.filter { current[$0] != nil }
        let shared = order.filter { savedPlaylists[$0] != nil }
        if kept != shared { syncState.orderChangedAt = now }
        savedPlaylists = current
        savedOrder = order
        saveSyncState()
    }

    func recordFavoriteChanges() {
        let now = Date()
        for key in favorites.subtracting(savedFavorites) { syncState.favorites[key] = .init(on: true, at: now) }
        for key in savedFavorites.subtracting(favorites) { syncState.favorites[key] = .init(on: false, at: now) }
        savedFavorites = favorites
        saveSyncState()
    }

    /// Eski sürümde indirilmiş şarkılar dosya yoluyla beğenilmişti; hesapta her cihazda aynı olsun diye
    /// YouTube kimliğine çevir (bilgisi biliniyorsa).
    func canonicalizeFavorites() {
        var changed = false
        for key in favorites where !key.hasPrefix("yt:") {
            guard let id = videoID(forPath: key), remoteMeta["yt:" + id] != nil else { continue }
            favorites.remove(key)
            favorites.insert("yt:" + id)
            changed = true
        }
        if changed { persistLibrary() }
    }

    // MARK: - Hesap değişimi

    /// Giriş / çıkış / hesap değişiminde çağrılır. `userID` nil: çıkış yapıldı.
    func activateAccount(_ userID: Int?) {
        let owner = syncState.owner
        guard owner != userID else {
            if userID != nil { requestSync(immediately: true) }
            return
        }
        // Eski sürümden gelen kitaplık: sahibi yok ama giriş yapılmış. Bu hesabın kitaplığı sayılır,
        // ilk eşitlemede sunucuya yüklenir.
        if owner == nil, let userID, !UserDefaults.standard.bool(forKey: "box.library.ownerSet") {
            UserDefaults.standard.set(true, forKey: "box.library.ownerSet")
            syncState.owner = userID
            saveSyncState()
            requestSync(immediately: true)
            return
        }
        UserDefaults.standard.set(true, forKey: "box.library.ownerSet")
        syncTask?.cancel()
        syncDebounce?.cancel()

        // Önceki hesabın kitaplığını kendi klasörüne kaldır.
        if let owner { archive(for: owner) }

        guard let userID else {
            // Çıkış: misafir kitaplığı boş başlar.
            replaceLibrary(playlists: [], favorites: [], state: LibrarySyncState())
            syncStatus = .idle
            return
        }

        // Giriş: bu hesabın bu cihazdaki kitaplığı (varsa) + giriş yapmadan önce oluşturulanlar.
        let guestPlaylists = owner == nil ? playlists : []
        let guestFavorites = owner == nil ? favorites : []
        var state = LibrarySyncState()
        var lists: [Playlist] = []
        var favs: Set<String> = []
        if let saved = loadArchive(for: userID) {
            lists = saved.playlists
            favs = Set(saved.favorites)
            state = saved.state
        }
        state.owner = userID
        let now = Date()
        for var playlist in guestPlaylists where !lists.contains(where: { $0.id == playlist.id }) {
            playlist.updatedAt = now
            state.dirty[playlist.id] = now
            if playlist.coverFile != nil { state.covers.insert(playlist.id) }
            lists.append(playlist)
        }
        for key in guestFavorites where !favs.contains(key) {
            favs.insert(key)
            state.favorites[key] = .init(on: true, at: now)
        }
        replaceLibrary(playlists: lists, favorites: favs, state: state)
        requestSync(immediately: true)
    }

    private struct Archive: Codable {
        var playlists: [Playlist]
        var favorites: [String]
        var state: LibrarySyncState
    }

    private func archiveURL(for userID: Int) -> URL {
        accountsDirectory.appendingPathComponent("\(userID).json")
    }

    private func archive(for userID: Int) {
        try? FileManager.default.createDirectory(at: accountsDirectory, withIntermediateDirectories: true)
        Self.saveJSON(Archive(playlists: playlists, favorites: Array(favorites), state: syncState), to: archiveURL(for: userID))
    }

    private func loadArchive(for userID: Int) -> Archive? {
        Self.loadJSON(Archive.self, from: archiveURL(for: userID))
    }

    /// Hesap silindiğinde: bu cihazdaki kopyası da silinsin.
    func forgetAccount(_ userID: Int) {
        try? FileManager.default.removeItem(at: archiveURL(for: userID))
        if syncState.owner == userID {
            syncState = LibrarySyncState()
            replaceLibrary(playlists: [], favorites: [], state: LibrarySyncState())
        }
    }

    // MARK: - Eşitleme

    /// Değişiklikten kısa süre sonra gönder (art arda değişiklikler tek istekte gitsin).
    func scheduleSync() {
        guard syncState.owner != nil else { return }
        syncDebounce?.cancel()
        syncDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.requestSync(immediately: true)
        }
    }

    func requestSync(immediately: Bool = false) {
        guard syncState.owner != nil, syncToken() != nil else { return }
        if !immediately { return scheduleSync() }
        if syncTask != nil { pendingResync = true; return }
        syncTask = Task { [weak self] in
            await self?.runSync(allowResync: true)
            guard let self else { return }
            self.syncTask = nil
            if self.pendingResync {
                self.pendingResync = false
                self.requestSync(immediately: true)
            }
        }
    }

    /// Bekleyenleri gönderir, hesabın güncel kitaplığını alır; çıkıştan önce de beklenir.
    func syncNow() async {
        if let task = syncTask { await task.value }
        requestSync(immediately: true)
        if let task = syncTask { await task.value }
    }

    private func runSync(allowResync: Bool) async {
        guard let token = syncToken(), let owner = syncState.owner else { return }
        syncStatus = .syncing
        do {
            var response: LibraryStateResponse
            if syncState.dirty.isEmpty && syncState.deleted.isEmpty && syncState.favorites.isEmpty && syncState.orderChangedAt == nil {
                response = try await APIClient.shared.send("me/library", token: token)
            } else {
                let (requests, sent) = buildRequests()
                var last: LibraryStateResponse?
                for request in requests {
                    let data = try JSONEncoder().encode(request)
                    let result: LibraryStateResponse = try await APIClient.shared.send("me/library", method: "POST", bodyData: data, token: token)
                    last = result
                }
                guard syncState.owner == owner, let state = last else { syncStatus = .idle; return }
                response = state
                clearSent(sent)
            }
            guard syncState.owner == owner, !Task.isCancelled else { syncStatus = .idle; return }
            let marked = apply(response)
            // Sunucuda olmayan listeler / beğeniler (ilk eşitleme) hemen yüklensin; bir kez.
            if marked > 0, allowResync {
                return await runSync(allowResync: false)
            }
            await uploadCovers(token: token)
            await downloadCovers(response)
            syncState.lastSync = Date()
            saveSyncState()
            syncStatus = .idle
        } catch {
            syncStatus = .failed((error as? APIError)?.message ?? "Kitaplık eşitlenemedi.")
        }
    }

    private struct SentSnapshot {
        var dirty: [UUID: Date] = [:]
        var deleted: [UUID: Date] = [:]
        var favorites: [String: LibrarySyncState.FavoriteChange] = [:]
        var orderAt: Date?
    }

    /// Bekleyen değişikliklerden istek(ler) oluşturur; çok büyükse birkaç parçaya böler.
    private func buildRequests() -> ([SyncRequest], SentSnapshot) {
        var sent = SentSnapshot()
        var requests: [SyncRequest] = []
        var current = SyncRequest()
        var size = 0
        let limit = 3_000_000
        let encoder = JSONEncoder()

        func flush() {
            if !current.playlists.isEmpty || !current.favorites.isEmpty || current.order != nil {
                requests.append(current)
            }
            current = SyncRequest()
            size = 0
        }

        for (id, at) in syncState.dirty {
            guard let playlist = playlists.first(where: { $0.id == id }) else { continue }
            let out = SyncPlaylistOut(
                id: id.uuidString,
                name: playlist.name,
                paths: playlist.paths,
                remote: syncRemote(for: playlist),
                source_id: playlist.sourceID,
                created_at: playlist.createdAt.millis,
                updated_at: (playlist.updatedAt ?? at).millis,
                deleted: false
            )
            let bytes = (try? encoder.encode(out).count) ?? 0
            if size + bytes > limit { flush() }
            current.playlists.append(out)
            size += bytes
            sent.dirty[id] = at
        }
        for (id, at) in syncState.deleted {
            current.playlists.append(SyncPlaylistOut(id: id.uuidString, name: "", paths: [], remote: [], source_id: nil, created_at: at.millis, updated_at: at.millis, deleted: true))
            sent.deleted[id] = at
        }
        for (key, change) in syncState.favorites {
            current.favorites.append(SyncFavoriteOut(key: key, on: change.on, at: change.at.millis, meta: key.hasPrefix("yt:") ? remoteMeta[key] : nil))
            sent.favorites[key] = change
        }
        if let at = syncState.orderChangedAt {
            current.order = SyncOrderOut(ids: playlists.map(\.id.uuidString), at: at.millis)
            sent.orderAt = at
        }
        flush()
        if requests.isEmpty { requests.append(SyncRequest()) }
        return (requests, sent)
    }

    /// Listedeki Box'a indirilmiş dosyaları YouTube kimliğiyle de gönder: başka cihazda internetten çalsın.
    private func syncRemote(for playlist: Playlist) -> [SearchResult] {
        var items = playlist.remote ?? []
        var have = Set(items.map(\.id))
        for path in playlist.paths {
            guard let id = videoID(forPath: path), !have.contains(id) else { continue }
            let track = track(forPath: path)
            let meta = remoteMeta["yt:" + id] ?? SearchResult(id: id, title: track?.title ?? "", channel: track?.artist ?? "", thumbnail: nil, duration: Int(track?.duration ?? 0))
            items.append(meta)
            have.insert(id)
        }
        return items
    }

    /// Gönderilenleri bekleyenlerden çıkar (gönderim sırasında yeniden değişenler kalır).
    private func clearSent(_ sent: SentSnapshot) {
        for (id, at) in sent.dirty where syncState.dirty[id] == at { syncState.dirty[id] = nil }
        for (id, at) in sent.deleted where syncState.deleted[id] == at { syncState.deleted[id] = nil }
        for (key, change) in sent.favorites where syncState.favorites[key] == change { syncState.favorites[key] = nil }
        if let at = sent.orderAt, syncState.orderChangedAt == at { syncState.orderChangedAt = nil }
        saveSyncState()
    }

    /// Sunucudaki hâli uygular; henüz gönderilmemiş yerel değişiklikler korunur.
    @discardableResult
    private func apply(_ state: LibraryStateResponse) -> Int {
        var marked = 0
        var byID: [UUID: Playlist] = Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var serverOrder: [(UUID, Int)] = []
        var known = Set<UUID>()
        var metas: [SearchResult] = []

        for remote in state.playlists {
            guard let id = UUID(uuidString: remote.id) else { continue }
            known.insert(id)
            let pending = syncState.dirty[id] != nil || syncState.deleted[id] != nil
            if remote.deleted {
                if !pending, let local = byID[id] {
                    if let file = local.coverFile { removeCoverFile(file) }
                    byID[id] = nil
                }
                continue
            }
            serverOrder.append((id, remote.position))
            guard !pending else { continue }
            var playlist = byID[id] ?? Playlist(id: id, name: remote.name, createdAt: Date(millis: remote.createdAt))
            playlist.name = remote.name
            playlist.createdAt = Date(millis: remote.createdAt)
            playlist.updatedAt = Date(millis: remote.updatedAt)
            playlist.sourceID = remote.sourceId
            // Bu cihazdaki yerel dosyalar: sunucudaki yollar; Box'a indirilenler internet listesinde de var.
            playlist.paths = remote.paths
            let localIDs = Set(remote.paths.compactMap { videoID(forPath: $0) })
            let items = remote.remote.filter { !localIDs.contains($0.id) || downloadedPath(for: $0.id) == nil }
            playlist.remote = items.isEmpty ? nil : items
            byID[id] = playlist
        }

        // Sunucuda hiç olmayan ve bekleyen değişikliği olmayan liste: yüklenmemiş demektir, yükle.
        let now = Date()
        for (id, playlist) in byID where !known.contains(id) && syncState.dirty[id] == nil {
            syncState.dirty[id] = playlist.updatedAt ?? now
            marked += 1
            if playlist.coverFile != nil { syncState.covers.insert(id) }
        }

        // Sıra: bekleyen sıra değişikliği yoksa sunucununki; yeni (henüz gönderilmemiş) listeler sonda.
        let ordered: [Playlist]
        if syncState.orderChangedAt == nil {
            let position = Dictionary(serverOrder, uniquingKeysWith: { first, _ in first })
            let localOrder = playlists.map(\.id)
            let serverSorted = byID.keys.filter { position[$0] != nil }.sorted { (position[$0] ?? 0) < (position[$1] ?? 0) }
            let rest = localOrder.filter { byID[$0] != nil && position[$0] == nil }
            let newOnes = byID.keys.filter { !localOrder.contains($0) && position[$0] == nil }
            ordered = (serverSorted + rest + newOnes).compactMap { byID[$0] }
        } else {
            let localOrder = playlists.map(\.id)
            let newOnes = serverOrder.map { $0.0 }.filter { !localOrder.contains($0) }
            ordered = (localOrder + newOnes).compactMap { byID[$0] }
        }

        // Beğenilenler
        var favs = favorites
        var serverKeys = Set<String>()
        for remote in state.favorites {
            serverKeys.insert(remote.key)
            if let meta = remote.meta { metas.append(meta) }
            guard syncState.favorites[remote.key] == nil else { continue }
            if remote.on { favs.insert(remote.key) } else { favs.remove(remote.key) }
        }
        for key in favs where !serverKeys.contains(key) && syncState.favorites[key] == nil {
            syncState.favorites[key] = .init(on: true, at: now)
            marked += 1
        }

        mergeRemoteMeta(metas)
        applyingRemote = true
        playlists = ordered
        favorites = favs
        applyingRemote = false
        persistLibrary()
        markSaved()
        return marked
    }

    // MARK: - Kapaklar

    private func uploadCovers(token: String) async {
        for id in syncState.covers {
            guard let index = playlists.firstIndex(where: { $0.id == id }) else {
                syncState.covers.remove(id)
                continue
            }
            // Liste sunucuya henüz ulaşmadıysa kapak sonra.
            guard syncState.dirty[id] == nil else { continue }
            var body: [String: Any] = ["id": id.uuidString]
            if let file = playlists[index].coverFile {
                guard let data = try? Data(contentsOf: coversFolder.appendingPathComponent(file)) else {
                    syncState.covers.remove(id)
                    continue
                }
                body["image"] = data.base64EncodedString()
            } else {
                body["remove"] = true
            }
            do {
                let response: CoverResponse = try await APIClient.shared.send("me/library/cover", method: "POST", body: body, token: token)
                guard let current = playlists.firstIndex(where: { $0.id == id }) else { continue }
                applyingRemote = true
                playlists[current].coverURL = response.coverUrl
                applyingRemote = false
                syncState.covers.remove(id)
            } catch let error as APIError where error.status == 404 || error.status == 400 {
                syncState.covers.remove(id)
            } catch {
                break
            }
        }
        persistLibrary()
        markSaved()
    }

    /// Sunucudaki kapak bu cihazdakinden farklıysa indir (ya da kaldırıldıysa sil).
    private func downloadCovers(_ state: LibraryStateResponse) async {
        var changed = false
        for remote in state.playlists where !remote.deleted {
            guard let id = UUID(uuidString: remote.id), !syncState.covers.contains(id),
                  let index = playlists.firstIndex(where: { $0.id == id }),
                  playlists[index].coverURL != remote.coverUrl else { continue }
            if let urlString = remote.coverUrl, let url = URL(string: urlString) {
                guard let result = try? await URLSession.shared.data(from: url),
                      (result.1 as? HTTPURLResponse)?.statusCode == 200, UIImage(data: result.0) != nil,
                      let current = playlists.firstIndex(where: { $0.id == id }) else { continue }
                try? FileManager.default.createDirectory(at: coversFolder, withIntermediateDirectories: true)
                let name = "\(id.uuidString)-\(Int(Date().timeIntervalSince1970)).jpg"
                guard (try? result.0.write(to: coversFolder.appendingPathComponent(name), options: .atomic)) != nil else { continue }
                if let old = playlists[current].coverFile { removeCoverFile(old) }
                playlists[current].coverFile = name
                playlists[current].coverURL = urlString
            } else {
                if let old = playlists[index].coverFile { removeCoverFile(old) }
                playlists[index].coverFile = nil
                playlists[index].coverURL = nil
            }
            changed = true
        }
        if changed {
            persistLibrary()
            markSaved()
        }
    }

    private func removeCoverFile(_ file: String) {
        try? FileManager.default.removeItem(at: coversFolder.appendingPathComponent(file))
        coverCacheRemove(file)
    }
}
