import Foundation
import UIKit

/// İndirmeden dinlenen şarkıların geçici önbelleği (kitaplıkta görünmez).
@MainActor
final class StreamCache: ObservableObject {
    @Published private(set) var preparing: Set<String> = []

    private weak var auth: AuthStore?
    private var tasks: [String: Task<URL, Error>] = [:]
    private let maxBytes: Int64 = 1_200_000_000

    nonisolated static var folder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BoxStream", isDirectory: true)
    }

    nonisolated static func fileURL(for videoID: String) -> URL {
        folder.appendingPathComponent(videoID).appendingPathExtension("m4a")
    }

    func attach(auth: AuthStore) {
        self.auth = auth
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
    }

    func isCached(_ videoID: String) -> Bool {
        FileManager.default.fileExists(atPath: Self.fileURL(for: videoID).path)
    }

    /// Dosya hazırsa hemen, değilse sunucudan alıp döner.
    func resolve(_ result: SearchResult) async throws -> URL {
        let target = Self.fileURL(for: result.id)
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
            return target
        }
        if let task = tasks[result.id] { return try await task.value }

        let task = Task<URL, Error> { [weak self] in
            guard let token = self?.auth?.token else {
                throw APIError(message: "Dinlemek için giriş yap.", status: 401)
            }
            let link: DownloadLinkResponse = try await APIClient.shared.send("stream", query: ["video_id": result.id], token: token)
            guard let url = URL(string: link.fileUrl ?? link.url) else { throw APIError(message: "Geçersiz bağlantı.", status: 0) }
            let temp = try await FileDownloader.download(from: url) { _ in }
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let artwork = await DownloadManager.fetchArtwork(result)
            let partial = Self.folder.appendingPathComponent(result.id + ".part").appendingPathExtension("m4a")
            try? FileManager.default.removeItem(at: partial)
            let tagged = await DownloadManager.writeMetadata(source: temp, destination: partial, title: result.title, artist: result.channel, artwork: artwork)
            try? FileManager.default.removeItem(at: target)
            if tagged {
                try FileManager.default.moveItem(at: partial, to: target)
                try? FileManager.default.removeItem(at: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: target)
            }
            await ArtworkCache.shared.invalidate(target)
            NotificationCenter.default.post(name: .boxArtworkReady, object: target)
            return target
        }

        tasks[result.id] = task
        preparing.insert(result.id)
        defer {
            tasks[result.id] = nil
            preparing.remove(result.id)
        }
        let url = try await task.value
        trim()
        return url
    }

    private var links: [String: (url: URL, video: URL?, expires: Date)] = [:]
    private var linkTasks: [String: Task<(url: URL, video: URL?, expires: Date), Error>] = [:]
    private var warmed: [String: Date] = [:]

    private func link(for videoID: String) async throws -> (url: URL, video: URL?, expires: Date) {
        if let cached = links[videoID], cached.expires > Date() { return cached }
        if let task = linkTasks[videoID] { return try await task.value }
        let task = Task<(url: URL, video: URL?, expires: Date), Error> { [weak self] in
            guard let token = self?.auth?.token else { throw APIError(message: "Dinlemek için giriş yap.", status: 401) }
            let response: DownloadLinkResponse = try await APIClient.shared.send("stream", query: ["video_id": videoID], token: token)
            guard let url = URL(string: response.url) else { throw APIError(message: "Geçersiz bağlantı.", status: 0) }
            return (url, response.videoUrl.flatMap(URL.init(string:)), Date(timeIntervalSince1970: TimeInterval(response.expiresAt - 300)))
        }
        linkTasks[videoID] = task
        defer { linkTasks[videoID] = nil }
        let value = try await task.value
        links[videoID] = value
        return value
    }

    /// Anında çalma bağlantısı (VDS /stream). Şarkı inerken çalmaya başlar.
    func liveURL(_ result: SearchResult) async throws -> URL {
        try await link(for: result.id).url
    }

    /// Video olarak izlemek için bağlantı.
    func videoURL(_ videoID: String) async throws -> URL {
        let value = try await link(for: videoID)
        guard let video = value.video else { throw APIError(message: "Video şu an açılamıyor.", status: 0) }
        return video
    }

    /// Sıradaki şarkının bağlantısını önceden al ve VDS'de hazırlat (dokununca anında başlasın).
    func prepareLink(_ result: SearchResult) {
        warm([result])
    }

    /// Listedeki ilk şarkıları VDS'de önceden hazırlatır (yt-dlp gecikmesi dokunmadan önce biter).
    func warm(_ results: [SearchResult], limit: Int = 6) {
        let now = Date()
        let targets = results.filter { !isCached($0.id) && (warmed[$0.id].map { now.timeIntervalSince($0) > 4 * 3600 } ?? true) }.prefix(limit)
        for result in targets {
            warmed[result.id] = now
            Task {
                guard let value = try? await link(for: result.id),
                      var components = URLComponents(url: value.url, resolvingAgainstBaseURL: false) else { return }
                components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "warm", value: "1")]
                guard let warmURL = components.url else { return }
                var request = URLRequest(url: warmURL)
                request.timeoutInterval = 60
                _ = try? await URLSession.shared.data(for: request)
            }
        }
    }

    /// Sıradaki şarkıyı arka planda hazırlar.
    func prefetch(_ result: SearchResult) {
        guard !isCached(result.id), tasks[result.id] == nil else { return }
        Task { _ = try? await resolve(result) }
    }

    var totalSize: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clear() {
        try? FileManager.default.removeItem(at: Self.folder)
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        objectWillChange.send()
    }

    /// Önbellek sınırı aşılırsa en eski dinlenenleri siler.
    private func trim() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard var files = try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: keys) else { return }
        var total = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: Set(keys)).fileSize) ?? 0) }
        guard total > maxBytes else { return }
        files.sort {
            let a = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return a < b
        }
        for file in files where total > maxBytes * 8 / 10 {
            let size = Int64((try? file.resourceValues(forKeys: Set(keys)).fileSize) ?? 0)
            try? FileManager.default.removeItem(at: file)
            total -= size
        }
    }
}

extension Notification.Name {
    /// Bir dosyanın kapağı yeni hazırlandı (object: dosya URL'si).
    static let boxArtworkReady = Notification.Name("box.artworkReady")
}
