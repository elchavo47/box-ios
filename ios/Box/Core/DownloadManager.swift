import AVFoundation
import Combine
import UIKit

enum DownloadState: Equatable {
    case preparing
    case downloading(Double)
    case processing
    case done(String)
    case failed(String)

    var isActive: Bool {
        switch self {
        case .preparing, .downloading, .processing: return true
        default: return false
        }
    }
}

struct DownloadItem: Identifiable, Equatable {
    let id: String
    let title: String
    let channel: String
    let thumbnail: URL?
    var state: DownloadState
    let startedAt: Date
}

@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var items: [String: DownloadItem] = [:]

    private weak var library: LibraryStore?
    private weak var auth: AuthStore?

    var activeCount: Int {
        items.values.filter { $0.state.isActive }.count
    }

    var sortedItems: [DownloadItem] {
        items.values.sorted { $0.startedAt > $1.startedAt }
    }

    func attach(library: LibraryStore, auth: AuthStore) {
        self.library = library
        self.auth = auth
    }

    func state(for id: String) -> DownloadState? {
        items[id]?.state
    }

    func clearFinished() {
        items = items.filter { $0.value.state.isActive }
    }

    /// Wi‑Fi'da indir ayarı açıkken mobil veride bekleyen indirme var.
    @Published private(set) var waitingForWifi = false
    private var networkWatch: AnyCancellable?
    weak var network: NetworkMonitor? {
        didSet {
            networkWatch = network?.$isExpensive.removeDuplicates().sink { [weak self] _ in
                Task { @MainActor in self?.pump() }
            }
        }
    }

    private var pending: [SearchResult] = []
    private var running = 0
    private let maxConcurrent = 2
    /// İndirme bitince çağrılır (ör. içe aktarılan listeye eklemek için).
    var onFinished: ((SearchResult, String) -> Void)?

    /// İndirme bu hesapta açık mı (premium ve panelden açık olmalı); kapalıysa onBlocked çağrılır.
    var isAllowed: () -> Bool = { true }
    var onBlocked: (() -> Void)?

    func download(_ result: SearchResult) {
        guard isAllowed() else { onBlocked?(); return }
        if let existing = items[result.id], existing.state.isActive { return }
        if library?.downloadedPath(for: result.id) != nil { return }

        items[result.id] = DownloadItem(
            id: result.id,
            title: result.title,
            channel: result.channel,
            thumbnail: result.thumbnailURL,
            state: .preparing,
            startedAt: Date()
        )
        pending.append(result)
        pump()
    }

    func download(all results: [SearchResult]) {
        guard isAllowed() else { onBlocked?(); return }
        for result in results { download(result) }
    }

    /// Premium kapanınca ya da çıkış yapılınca: bekleyenleri ve sürenleri iptal et.
    /// Süren indirme bitse bile kitaplığa kaydedilmez.
    func cancelAll() {
        pending.removeAll()
        for (id, item) in items where item.state.isActive { retryable[id] = false }
        items = items.filter { !$0.value.state.isActive }
        waitingForWifi = false
    }

    /// Çıkışta indirme geçmişini de temizle (başka hesap görmesin).
    func reset() {
        cancelAll()
        items.removeAll()
    }

    private func pump() {
        if AppSettings.shared.wifiOnlyDownloads, network?.isExpensive == true, !pending.isEmpty {
            waitingForWifi = true
            return
        }
        waitingForWifi = false
        while running < maxConcurrent, !pending.isEmpty {
            let next = pending.removeFirst()
            running += 1
            Task {
                // Dinlemek için önbelleğe alınmışsa sunucuya gitmeden kopyala.
                if !(await copyFromStreamCache(next)) {
                    await run(next)
                }
                running -= 1
                pump()
            }
        }
    }

    /// Önbellekteki (dinlenmiş) şarkıyı kitaplığa kaydeder.
    @discardableResult
    func copyFromStreamCache(_ result: SearchResult) async -> Bool {
        guard let library else { return false }
        let cached = StreamCache.fileURL(for: result.id)
        guard FileManager.default.fileExists(atPath: cached.path) else { return false }
        if items[result.id] == nil {
            items[result.id] = DownloadItem(id: result.id, title: result.title, channel: result.channel, thumbnail: result.thumbnailURL, state: .processing, startedAt: Date())
        }
        update(result.id, .processing)
        let folder = library.documents.appendingPathComponent(AppConfig.downloadsFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = FileService.uniqueURL(for: FileService.sanitize(result.title) + ".m4a", in: folder)
        // Önbellekteki dosyaya başlık, sanatçı ve kapak yazarak kopyala.
        let artwork = await Self.fetchArtwork(result)
        let tagged = await Self.writeMetadata(source: cached, destination: destination, title: result.title, artist: result.channel, artwork: artwork)
        if !tagged {
            do {
                try FileManager.default.copyItem(at: cached, to: destination)
            } catch {
                return false
            }
        }
        await library.addFile(destination)
        let path = library.relativePath(for: destination)
        library.setDownloadedPath(path, for: result.id)
        update(result.id, .done(path))
        onFinished?(result, path)
        if pending.isEmpty && running <= 1 { Haptics.success() }
        return true
    }

    private func update(_ id: String, _ state: DownloadState) {
        items[id]?.state = state
    }

    /// Başarısız olursa bekleyip yeniden dener (ağ kopması, yoğunluk, sunucu hatası).
    private func run(_ result: SearchResult) async {
        let delays: [UInt64] = [3, 10, 25]
        for attempt in 0...delays.count {
            if await attemptDownload(result) { return }
            guard attempt < delays.count, case .failed(let message)? = items[result.id]?.state,
                  retryable[result.id] == true else { return }
            update(result.id, .preparing)
            let lower = message.lowercased()
            let wait = lower.contains("çok fazla") || lower.contains("yoğun") ? max(delays[attempt], 30) : delays[attempt]
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
        }
    }

    private var retryable: [String: Bool] = [:]

    /// Başarısız olanların hepsini yeniden kuyruğa al.
    func retryFailed() {
        let failed = items.values.filter { if case .failed = $0.state { return true } else { return false } }
        for item in failed {
            let result = SearchResult(id: item.id, title: item.title, channel: item.channel, thumbnail: item.thumbnail?.absoluteString, duration: 0)
            items[item.id] = nil
            download(result)
        }
    }

    var failedCount: Int {
        items.values.filter { if case .failed = $0.state { return true } else { return false } }.count
    }

    private func attemptDownload(_ result: SearchResult) async -> Bool {
        guard let token = auth?.token, let library else {
            retryable[result.id] = false
            update(result.id, .failed(L("Oturum bulunamadı.")))
            return false
        }

        do {
            let link: DownloadLinkResponse = try await APIClient.shared.send(
                "download",
                query: ["video_id": result.id, "title": result.title],
                token: token
            )

            guard let url = URL(string: link.url) else {
                throw APIError(message: L("Geçersiz indirme bağlantısı."), status: 0)
            }

            let id = result.id
            let tempFile = try await FileDownloader.download(from: url) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.items[id]?.state.isActive == true else { return }
                    self.update(id, .downloading(progress))
                }
            }

            // İndirme bu arada iptal edildiyse (premium kapandı, çıkış yapıldı) kaydetme.
            guard items[id]?.state.isActive == true else {
                try? FileManager.default.removeItem(at: tempFile)
                return false
            }
            update(id, .processing)

            let folder = library.documents.appendingPathComponent(AppConfig.downloadsFolderName, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let baseName = FileService.sanitize(result.title)
            let destination = FileService.uniqueURL(for: baseName + ".m4a", in: folder)

            let artwork = await Self.fetchArtwork(result)
            let tagged = await Self.writeMetadata(
                source: tempFile,
                destination: destination,
                title: result.title,
                artist: result.channel,
                artwork: artwork
            )

            if !tagged {
                try FileManager.default.moveItem(at: tempFile, to: destination)
            } else {
                try? FileManager.default.removeItem(at: tempFile)
            }

            await library.addFile(destination)
            let path = library.relativePath(for: destination)
            library.setDownloadedPath(path, for: id)
            update(id, .done(path))
            onFinished?(result, path)
            if pending.isEmpty && running <= 1 { Haptics.success() }
            return true
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? L("İndirme başarısız oldu.")
            let status = (error as? APIError)?.status ?? 0
            // Kota bitti / yetki yok / geçersiz video: tekrar denemenin anlamı yok.
            retryable[result.id] = !(status == 400 || status == 401 || status == 403 || status == 404 || message.contains("Bugünlük"))
            update(result.id, .failed(message))
            return false
        }
    }

    // MARK: - Kapak ve etiket

    static func fetchArtwork(_ result: SearchResult) async -> Data? {
        // Önce bantsız yüksek çözünürlüklü kapak, olmazsa arama küçük resmi.
        for url in [result.maxResURL, result.thumbnailURL].compactMap({ $0 }) {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data), image.size.width > 200 else { continue }
            return ArtworkCache.prepare(image).jpegData(compressionQuality: 0.88)
        }
        return nil
    }

    /// İndirilen m4a dosyasına başlık, sanatçı ve kapak yazar (yeniden kodlama yapmadan).
    static func writeMetadata(source: URL, destination: URL, title: String, artist: String, artwork: Data?) async -> Bool {
        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            return false
        }

        var metadata: [AVMetadataItem] = []

        let titleItem = AVMutableMetadataItem()
        titleItem.identifier = .commonIdentifierTitle
        titleItem.value = title as NSString
        titleItem.extendedLanguageTag = "und"
        metadata.append(titleItem)

        let artistItem = AVMutableMetadataItem()
        artistItem.identifier = .commonIdentifierArtist
        artistItem.value = artist as NSString
        artistItem.extendedLanguageTag = "und"
        metadata.append(artistItem)

        if let artwork {
            let artworkItem = AVMutableMetadataItem()
            artworkItem.identifier = .commonIdentifierArtwork
            artworkItem.value = artwork as NSData
            artworkItem.dataType = kCMMetadataBaseDataType_JPEG as String
            artworkItem.extendedLanguageTag = "und"
            metadata.append(artworkItem)
        }

        exporter.outputURL = destination
        exporter.outputFileType = .m4a
        exporter.metadata = metadata

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously {
                continuation.resume()
            }
        }

        if exporter.status == .completed {
            return true
        }

        try? FileManager.default.removeItem(at: destination)
        return false
    }
}

/// URLSession indirmesini ilerleme bildirimiyle async hale getirir.
final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var finished = false

    private init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    static func download(from url: URL, onProgress: @escaping (Double) -> Void) async throws -> URL {
        let downloader = FileDownloader(onProgress: onProgress)

        let configuration = URLSessionConfiguration.default
        // Sunucu yt-dlp ile dosyayı hazırlarken bir süre veri gelmeyebilir.
        configuration.timeoutIntervalForRequest = 330
        configuration.timeoutIntervalForResource = 900

        let session = URLSession(configuration: configuration, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            downloader.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    /// Son bildirilen yüzde. URLSession saniyede onlarca kez haber verir; her birini
    /// arayüze iletmek listeleri sürekli yeniden çizdirip kasmaya yol açıyordu.
    private var lastPercent = -1
    private var lastReport = Date.distantPast

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else {
            if lastPercent < 0 { lastPercent = 0; onProgress(0) }
            return
        }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let percent = Int(fraction * 100)
        let now = Date()
        guard percent != lastPercent, percent >= 100 || now.timeIntervalSince(lastReport) >= 0.25 else { return }
        lastPercent = percent
        lastReport = now
        onProgress(fraction)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0

        guard status == 200 else {
            var message = L("İndirme sunucusu hata verdi ({0}).", status)
            if let data = try? Data(contentsOf: location),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = json["detail"] as? String {
                message = detail
            }
            resume(with: .failure(APIError(message: message, status: status)))
            return
        }

        // Geçici dosya bu metot bitince silinir; hemen kendi konumumuza taşı.
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        do {
            try FileManager.default.moveItem(at: location, to: target)
            resume(with: .success(target))
        } catch {
            resume(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let message: String
            if (error as? URLError)?.code == .timedOut {
                message = L("İndirme zaman aşımına uğradı.")
            } else {
                message = L("Bağlantı koptu, tekrar dene.")
            }
            resume(with: .failure(APIError(message: message, status: 0)))
        }
    }

    private func resume(with result: Result<URL, Error>) {
        guard !finished, let continuation else { return }
        finished = true
        self.continuation = nil
        continuation.resume(with: result)
    }
}
