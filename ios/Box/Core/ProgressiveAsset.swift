import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Bir şarkıyı (ya da videoyu) uygulamanın kendisi indirirken oynatıcıya parça parça verir.
/// AVPlayer'ın HTTP tarafındaki hassasiyetlerine takılmadan ilk baytlar gelir gelmez çalmaya başlar;
/// iniş bitince dosya önbelleğe taşınır.
final class ProgressiveAsset: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    enum Kind { case audio, video }

    let asset: AVURLAsset
    let kind: Kind

    /// İniş tamamlanınca (ana iş parçacığında): geçici dosyanın yolu.
    var onComplete: ((URL) -> Void)?
    /// İniş başarısız olunca (ana iş parçacığında).
    var onError: ((String) -> Void)?

    private let remoteURL: URL
    private let queue = DispatchQueue(label: "box.progressive")
    private let tempURL: URL
    private var writer: FileHandle?
    private var reader: FileHandle?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var contentLength: Int64 = 0
    private var downloaded: Int64 = 0
    private var finished = false
    private var failed = false
    private var pending: [AVAssetResourceLoadingRequest] = []

    private static let scheme = "boxstream"

    init(remoteURL: URL, kind: Kind) {
        self.remoteURL = remoteURL
        self.kind = kind
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("box-progressive-\(UUID().uuidString)")
            .appendingPathExtension(kind == .video ? "mp4" : "m4a")

        var components = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false)!
        components.scheme = Self.scheme
        asset = AVURLAsset(url: components.url!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    deinit {
        task?.cancel()
        session?.invalidateAndCancel()
        try? writer?.close()
        try? reader?.close()
        if !finished { try? FileManager.default.removeItem(at: tempURL) }
    }

    func cancel() {
        queue.async {
            self.task?.cancel()
            self.session?.invalidateAndCancel()
            self.session = nil
            for request in self.pending where !request.isFinished { request.finishLoading(with: URLError(.cancelled)) }
            self.pending.removeAll()
        }
    }

    // MARK: - İndirme

    private func startIfNeeded() {
        guard session == nil, !finished, !failed else { return }
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        writer = try? FileHandle(forWritingTo: tempURL)
        reader = try? FileHandle(forReadingFrom: tempURL)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 1800
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        task = session?.dataTask(with: remoteURL)
        task?.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            completionHandler(.cancel)
            fail("Akış sunucusu \(status) döndü.")
            return
        }
        contentLength = max(response.expectedContentLength, 0)
        completionHandler(.allow)
        processPending()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let writer else { return }
        writer.seekToEndOfFile()
        writer.write(data)
        downloaded += Int64(data.count)
        processPending()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as? URLError)?.code == .cancelled { return }
            fail("Bağlantı koptu: \(error.localizedDescription)")
            return
        }
        try? writer?.synchronizeFile()
        finished = true
        if contentLength == 0 { contentLength = downloaded }
        processPending()
        let url = tempURL
        DispatchQueue.main.async { [weak self] in self?.onComplete?(url) }
        session.finishTasksAndInvalidate()
        self.session = nil
    }

    private func fail(_ message: String) {
        guard !failed else { return }
        failed = true
        for request in pending where !request.isFinished {
            request.finishLoading(with: NSError(domain: "Box", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
        }
        pending.removeAll()
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }

    // MARK: - Oynatıcıya veri verme

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !failed else { return false }
        pending.append(loadingRequest)
        startIfNeeded()
        processPending()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pending.removeAll { $0 === loadingRequest }
    }

    private func processPending() {
        guard contentLength > 0 || finished else { return }
        pending.removeAll { request in
            if request.isFinished || request.isCancelled { return true }
            if let info = request.contentInformationRequest {
                info.contentType = kind == .video ? UTType.mpeg4Movie.identifier : UTType.mpeg4Audio.identifier
                info.contentLength = contentLength
                info.isByteRangeAccessSupported = true
            }
            guard let dataRequest = request.dataRequest else {
                request.finishLoading()
                return true
            }
            if respond(to: dataRequest) {
                request.finishLoading()
                return true
            }
            return false
        }
    }

    /// Mevcut baytlardan isteneni verir; istek tamamlandıysa true.
    private func respond(to dataRequest: AVAssetResourceLoadingDataRequest) -> Bool {
        let start = dataRequest.currentOffset
        let requestedEnd: Int64 = dataRequest.requestsAllDataToEndOfResource
            ? contentLength
            : dataRequest.requestedOffset + Int64(dataRequest.requestedLength)
        let available = downloaded
        guard start < available else {
            return finished && start >= available
        }
        let end = min(requestedEnd, available)
        if end > start, let reader {
            var offset = start
            // Büyük istekleri parça parça ver (bellek şişmesin).
            while offset < end {
                let length = Int(min(end - offset, 512 * 1024))
                reader.seek(toFileOffset: UInt64(offset))
                let chunk = reader.readData(ofLength: length)
                if chunk.isEmpty { break }
                dataRequest.respond(with: chunk)
                offset += Int64(chunk.count)
            }
        }
        return dataRequest.currentOffset >= requestedEnd
    }
}
