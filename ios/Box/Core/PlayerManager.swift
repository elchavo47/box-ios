import AVFoundation
import Combine
import MediaPlayer
import UIKit

enum RepeatMode: String, Codable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    var symbol: String {
        self == .one ? "repeat.1" : "repeat"
    }
}

enum SleepTimer: Equatable {
    case off
    case at(Date)
    case endOfTrack

    var isActive: Bool { self != .off }
}

/// Saniyede birkaç kez değişen süre bilgisi ayrı tutulur; böylece yalnızca
/// ilerleme çubuğu gibi küçük görünümler yeniden çizilir.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    var progress: Double {
        duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
    }
}

@MainActor
final class PlayerManager: ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var isShuffled = false
    @Published var repeatMode: RepeatMode = .off { didSet { saveState() } }
    @Published var showFullPlayer = false
    @Published private(set) var currentArtwork: UIImage?
    @Published private(set) var artworkColor: UIColor?
    /// Akan arka plan için kapaktan üç renk.
    @Published private(set) var artworkPalette: [UIColor] = []
    @Published private(set) var sleepTimer: SleepTimer = .off
    @Published private(set) var playbackRate: Float = 1
    /// İnternetten dinlenen şarkı hazırlanıyor.
    @Published private(set) var isBuffering = false
    @Published var errorMessage: String?
    /// Şarkının videosu oynatılıyor (YouTube Music'teki Şarkı / Video anahtarı).
    @Published private(set) var videoMode = false
    @Published private(set) var videoLoading = false

    let clock = PlaybackClock()

    /// Yeni bir şarkı çalmaya başladığında (geçmiş için).
    var onTrackStart: ((Track) -> Void)?
    /// İndirilmemiş şarkının dosyasını hazırlar.
    var resolveRemote: ((SearchResult) async throws -> URL)?
    /// Anında çalma bağlantısı (parça parça iner).
    var liveRemote: ((SearchResult) async throws -> URL)?
    var prefetchRemote: ((SearchResult) -> Void)?
    var videoURLFor: ((String) async throws -> URL)?
    /// Yerel (indirilmiş) şarkının YouTube kimliği; videosu varsa izlenebilir.
    var videoIDFor: ((Track) -> String?)?
    /// Akışla çalınan şarkı tamamen inince önbelleğe almak için.
    var onStreamCached: ((SearchResult, URL) -> Void)?
    /// İnternet şarkısını hatırlamak için (geçmiş, beğeni, sıra).
    var onRemoteSeen: ((SearchResult) -> Void)?
    /// Sıra bitince benzer şarkılarla devam etmek için (otomatik radyo).
    var radioProvider: ((Track, [String]) async -> [Track])?
    var autoRadioEnabled: () -> Bool = { false }
    /// Dinleme süresi (istatistik / Box Özeti için).
    var onListen: ((Track, Double) -> Void)?
    /// Çevrimdışıyken çalınamayacak şarkıları atlamak için.
    var isPlayable: ((Track) -> Bool)?
    /// Şarkılar arası yumuşak geçiş (saniye) ve ses efektleri.
    var crossfade: () -> Double = { 0 }
    var effects: () -> (EQPreset, Bool) = { (.flat, false) }
    var visualizer: () -> Bool = { false }
    /// Görselleştirici seviyeleri (bant başına 0...1).
    private(set) var meter: TapContext?
    private var fadeInStarted: Date?
    @Published private(set) var radioLoading = false

    /// Son akış hatası (teşhis için Hesap ekranında görünür).
    @Published private(set) var lastStreamError: String?

    /// Video katmanı için (sessiz; ses ana oynatıcıdan gelir).
    let videoPlayer = AVPlayer()
    var avPlayer: AVPlayer { videoPlayer }
    private var progressive: ProgressiveAsset?
    private var videoProgressive: ProgressiveAsset?
    private var videoObservers: Set<AnyCancellable> = []

    var currentVideoID: String? {
        guard let current else { return nil }
        return current.remote?.id ?? videoIDFor?(current)
    }
    private var itemObservers: Set<AnyCancellable> = []
    private var loadToken = 0

    private let player = AVPlayer()
    private var originalQueue: [Track] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var isSeeking = false
    private var lastStateSave = Date.distantPast
    private var restored = false
    private let stateKey = "box.playerState"

    var current: Track? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    var currentTime: Double { clock.currentTime }
    var duration: Double { clock.duration }

    var upNext: [Track] {
        guard let currentIndex else { return [] }
        return Array(queue.dropFirst(currentIndex + 1))
    }

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        videoPlayer.isMuted = true
        videoPlayer.automaticallyWaitsToMinimizeStalling = false
        configureAudioSession()
        configureRemoteCommands()
        observeTime()
        observeInterruptions()

        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.saveState(force: true)
                // Arka planda görüntü durur, ses ana oynatıcıdan kesintisiz devam eder.
                if self.videoMode { self.videoPlayer.pause() }
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.syncVideo(force: true) }
        }
    }

    // MARK: - Oynatma

    func play(_ tracks: [Track], startAt index: Int = 0, shuffled: Bool = false) {
        var tracks = tracks
        var index = index
        if !allowsRemote() {
            // Premium yoksa indirilmemiş internet şarkıları çalınmaz.
            let chosen = tracks.indices.contains(index) ? tracks[index] : nil
            tracks = tracks.filter { !$0.isRemote }
            index = chosen.flatMap { c in tracks.firstIndex { $0.id == c.id } } ?? 0
        }
        guard !tracks.isEmpty else { return }

        let safeIndex = min(max(index, 0), tracks.count - 1)
        originalQueue = tracks

        if shuffled {
            var rest = tracks
            let first = rest.remove(at: index == 0 ? Int.random(in: 0..<tracks.count) : safeIndex)
            rest.shuffle()
            queue = [first] + rest
            currentIndex = 0
            isShuffled = true
        } else {
            queue = tracks
            currentIndex = safeIndex
            isShuffled = false
        }

        loadCurrent(autoplay: true)
    }

    func playNext(_ track: Track) {
        if track.isRemote && !allowsRemote() { return }
        guard let currentIndex else {
            play([track])
            return
        }
        queue.insert(track, at: currentIndex + 1)
        originalQueue.append(track)
        Haptics.success()
        saveState(force: true)
    }

    func addToQueue(_ track: Track) {
        if track.isRemote && !allowsRemote() { return }
        guard currentIndex != nil else {
            play([track])
            return
        }
        queue.append(track)
        originalQueue.append(track)
        Haptics.success()
        saveState(force: true)
    }

    /// Bir şarkıdan radyo başlat: önce o şarkı, sonra benzerleri.
    func startRadio(from track: Track) {
        guard let radioProvider, allowsRemote() else { return }
        radioLoading = true
        Task { @MainActor in
            let more = await radioProvider(track, [track.remote?.id].compactMap { $0 })
            self.radioLoading = false
            if self.current?.id == track.id {
                if let index = self.currentIndex {
                    self.queue = Array(self.queue.prefix(index + 1)) + more
                    self.originalQueue = self.queue
                    self.isShuffled = false
                }
            } else {
                self.play([track] + more)
            }
            Haptics.success()
        }
    }

    func jump(to index: Int) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        loadCurrent(autoplay: true)
    }

    func removeFromQueue(at offsets: IndexSet) {
        guard let currentIndex else { return }
        let absolute = offsets.map { $0 + currentIndex + 1 }.filter { queue.indices.contains($0) }
        for index in absolute.sorted(by: >) {
            let removed = queue.remove(at: index)
            if let originalIndex = originalQueue.firstIndex(of: removed) {
                originalQueue.remove(at: originalIndex)
            }
        }
        saveState(force: true)
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        guard let currentIndex else { return }
        var upcoming = Array(queue.dropFirst(currentIndex + 1))
        upcoming.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue.prefix(currentIndex + 1)) + upcoming
        saveState(force: true)
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func resume() {
        guard current != nil else { return }
        if isBuffering && player.currentItem == nil { isPlaying = true; return }
        if player.currentItem == nil {
            loadCurrent(autoplay: true)
            return
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.volume = 1
        player.playImmediately(atRate: playbackRate)
        isPlaying = true
        updateNowPlaying()
        syncVideo(force: true)
    }

    func pause() {
        if isBuffering && player.currentItem == nil { isPlaying = false; return }
        player.pause()
        isPlaying = false
        updateNowPlaying()
        saveState(force: true)
        videoPlayer.pause()
    }

    func next() {
        advance(userInitiated: true)
    }

    func previous() {
        guard let currentIndex else { return }

        if clock.currentTime > 3 || currentIndex == 0 {
            seek(to: 0)
            return
        }

        self.currentIndex = currentIndex - 1
        loadCurrent(autoplay: true)
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, clock.duration > 0 ? clock.duration - 0.25 : seconds))
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        isSeeking = true
        clock.currentTime = clamped
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.isSeeking = false
                self?.updateNowPlaying()
                self?.syncVideo(force: true)
            }
        }
    }

    func skip(by seconds: Double) {
        seek(to: clock.currentTime + seconds)
    }

    func toggleShuffle() {
        guard let current else {
            isShuffled.toggle()
            return
        }

        if isShuffled {
            queue = originalQueue
            currentIndex = queue.firstIndex(of: current) ?? 0
            isShuffled = false
        } else {
            var rest = queue
            if let index = rest.firstIndex(of: current) {
                rest.remove(at: index)
            }
            rest.shuffle()
            queue = [current] + rest
            currentIndex = 0
            isShuffled = true
        }
        saveState(force: true)
    }

    func cycleRepeat() {
        repeatMode = repeatMode.next
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        player.defaultRate = rate
        if isPlaying { player.rate = rate }
        updateNowPlaying()
        syncVideo(force: true)
    }

    // MARK: - Uyku zamanlayıcısı

    func setSleepTimer(minutes: Int) {
        sleepTimer = .at(Date().addingTimeInterval(TimeInterval(minutes * 60)))
        player.volume = 1
        Haptics.success()
    }

    func setSleepAtEndOfTrack() {
        sleepTimer = .endOfTrack
        player.volume = 1
        Haptics.success()
    }

    func cancelSleepTimer() {
        sleepTimer = .off
        player.volume = 1
    }

    /// Kalan süre (saniye); bitiş zamanı yoksa nil.
    var sleepRemaining: TimeInterval? {
        switch sleepTimer {
        case .at(let date): return max(0, date.timeIntervalSinceNow)
        case .endOfTrack: return max(0, clock.duration - clock.currentTime)
        case .off: return nil
        }
    }

    private func checkSleepTimer() {
        guard case .at(let date) = sleepTimer else { return }
        let remaining = date.timeIntervalSinceNow
        if remaining <= 0 {
            sleepTimer = .off
            pause()
            player.volume = 1
        }
    }

    /// Ses seviyesi: uyku zamanlayıcısı, şarkı sonu ve başı yumuşak geçişleri birlikte.
    private func updateVolume() {
        var volume: Double = 1
        if case .at(let date) = sleepTimer {
            let remaining = date.timeIntervalSinceNow
            if remaining < 10 { volume = min(volume, max(0.05, remaining / 10)) }
        }
        let fade = crossfade()
        if fade > 0, clock.duration > fade * 2 {
            let left = clock.duration - clock.currentTime
            if left < fade { volume = min(volume, max(0, left / fade)) }
            if let started = fadeInStarted {
                let elapsed = Date().timeIntervalSince(started)
                if elapsed < fade { volume = min(volume, max(0.05, elapsed / fade)) } else { fadeInStarted = nil }
            }
        }
        if abs(Double(player.volume) - volume) > 0.01 { player.volume = Float(volume) }
    }

    /// Yumuşak geçiş açıksa şarkı bitmeden biraz önce sonrakine geç.
    private func checkCrossfadeAdvance() {
        let fade = crossfade()
        guard fade > 0, isPlaying, repeatMode != .one, clock.duration > fade * 2, !isSeeking else { return }
        if clock.duration - clock.currentTime <= 0.35, sleepTimer != .endOfTrack {
            advance(userInitiated: false)
        }
    }

    // MARK: - Premium

    /// Premium açık mı (internet şarkıları, video, radyo için).
    var allowsRemote: () -> Bool = { true }

    /// Premium kapanınca: internet şarkılarını sıradan çıkar, video modunu kapat.
    /// Çalan şarkı internet şarkısıysa oynatma durur.
    func dropRemoteTracks() {
        if videoMode {
            videoMode = false
            stopVideo()
        }
        guard queue.contains(where: \.isRemote) else { return }
        if current?.isRemote == true {
            stop()
            return
        }
        let currentPath = current?.relativePath
        queue.removeAll { $0.isRemote }
        originalQueue.removeAll { $0.isRemote }
        currentIndex = currentPath.flatMap { path in queue.firstIndex { $0.relativePath == path } }
        if currentIndex == nil { stop() } else { saveState(force: true) }
    }

    // MARK: - Kitaplık değişikliği

    /// Dosya silindiğinde ya da taşındığında kuyruğu temizler.
    func handleLibraryChange(validPaths: Set<String>) {
        guard !queue.isEmpty else { return }
        let currentPath = current?.relativePath

        if let currentPath, current?.isRemote != true, !validPaths.contains(currentPath) {
            stop()
            return
        }

        queue.removeAll { !$0.isRemote && !validPaths.contains($0.relativePath) }
        originalQueue.removeAll { !$0.isRemote && !validPaths.contains($0.relativePath) }
        if let currentPath {
            currentIndex = queue.firstIndex { $0.relativePath == currentPath }
        }
    }

    func stop() {
        loadToken += 1
        isBuffering = false
        stopVideo()
        progressive?.cancel()
        progressive = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = []
        originalQueue = []
        currentIndex = nil
        isPlaying = false
        clock.currentTime = 0
        clock.duration = 0
        currentArtwork = nil
        artworkColor = nil
        showFullPlayer = false
        sleepTimer = .off
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        UserDefaults.standard.removeObject(forKey: stateKey)
    }

    // MARK: - Kaldığı yerden devam

    private struct SavedState: Codable {
        var paths: [String]
        var original: [String]
        var index: Int
        var time: Double
        var shuffled: Bool
        var repeatMode: RepeatMode
        var remotes: [SearchResult]? = nil
    }

    private func saveState(force: Bool = false) {
        guard restored || force else { return }
        guard let currentIndex, !queue.isEmpty else { return }
        if !force, Date().timeIntervalSince(lastStateSave) < 5 { return }
        lastStateSave = Date()
        let state = SavedState(
            paths: queue.map(\.relativePath),
            original: originalQueue.map(\.relativePath),
            index: currentIndex,
            time: clock.currentTime,
            shuffled: isShuffled,
            repeatMode: repeatMode,
            remotes: Array(Set(queue.compactMap(\.remote) + originalQueue.compactMap(\.remote)))
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: stateKey)
        }
    }

    /// Uygulama açılırken son çalınan kuyruğu duraklatılmış olarak geri yükler.
    func restoreIfNeeded(tracks: [Track]) {
        guard !restored else { return }
        restored = true
        guard current == nil,
              let data = UserDefaults.standard.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }

        var index = Dictionary(tracks.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
        for remote in state.remotes ?? [] where index["yt:" + remote.id] == nil {
            index["yt:" + remote.id] = .remote(remote)
        }
        let restoredQueue = state.paths.compactMap { index[$0] }
        guard state.paths.indices.contains(state.index),
              let currentTrack = index[state.paths[state.index]],
              let newIndex = restoredQueue.firstIndex(of: currentTrack) else { return }

        queue = restoredQueue
        originalQueue = state.original.compactMap { index[$0] }
        if originalQueue.isEmpty { originalQueue = restoredQueue }
        isShuffled = state.shuffled
        repeatMode = state.repeatMode
        currentIndex = newIndex
        loadCurrent(autoplay: false, startAt: state.time, record: false)
    }

    // MARK: - İç işleyiş

    private func advance(userInitiated: Bool) {
        guard let currentIndex else { return }

        if !userInitiated, sleepTimer == .endOfTrack {
            sleepTimer = .off
            pause()
            seek(to: 0)
            return
        }

        if !userInitiated, repeatMode == .one {
            seek(to: 0)
            player.playImmediately(atRate: playbackRate)
            return
        }

        // Çevrimdışıysa indirilmemiş şarkıları atla.
        var nextIndex = currentIndex + 1
        if let isPlayable {
            while nextIndex < queue.count, !isPlayable(queue[nextIndex]) { nextIndex += 1 }
        }

        if nextIndex < queue.count {
            self.currentIndex = nextIndex
            loadCurrent(autoplay: true)
        } else if repeatMode == .off, autoRadioEnabled(), let radioProvider, let last = current {
            // Sıra bitti: benzer şarkılarla devam et.
            radioLoading = true
            let known = queue.compactMap { $0.remote?.id }
            Task { @MainActor in
                let more = await radioProvider(last, known)
                self.radioLoading = false
                if more.isEmpty {
                    if userInitiated { self.currentIndex = 0; self.loadCurrent(autoplay: true) } else { self.pause(); self.seek(to: 0) }
                    return
                }
                self.queue.append(contentsOf: more)
                self.originalQueue.append(contentsOf: more)
                self.currentIndex = currentIndex + 1
                self.loadCurrent(autoplay: true)
            }
        } else if repeatMode == .all || userInitiated {
            self.currentIndex = 0
            loadCurrent(autoplay: true)
        } else {
            pause()
            seek(to: 0)
        }
    }

    // MARK: - Video

    /// Şarkı ile Video arasında geçiş. Ses hiç durmaz; görüntü sesin saniyesine kilitlenir.
    func setVideoMode(_ on: Bool) async {
        if on {
            guard allowsRemote() else { return }
            guard !videoMode || videoProgressive == nil else { return }
            videoMode = true
            await loadVideoForCurrent()
        } else {
            videoMode = false
            stopVideo()
        }
    }

    private func loadVideoForCurrent() async {
        guard videoMode, let track = current else { return }
        guard let id = currentVideoID, let resolver = videoURLFor else {
            stopVideo()
            videoMode = false
            return
        }
        stopVideo()
        videoLoading = true
        do {
            let url = try await resolver(id)
            guard videoMode, current?.id == track.id else { videoLoading = false; return }
            let loader = ProgressiveAsset(remoteURL: url, kind: .video)
            videoProgressive = loader
            let item = AVPlayerItem(asset: loader.asset)
            item.preferredForwardBufferDuration = 4
            videoPlayer.replaceCurrentItem(with: item)
            item.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status in
                    guard let self, self.videoProgressive === loader else { return }
                    if status == .readyToPlay {
                        self.videoLoading = false
                        self.syncVideo(force: true)
                    } else if status == .failed {
                        self.videoLoading = false
                        self.videoMode = false
                        self.stopVideo()
                        self.errorMessage = "Bu şarkının videosu açılamadı."
                    }
                }
                .store(in: &videoObservers)
            loader.onError = { [weak self] message in
                guard let self, self.videoProgressive === loader else { return }
                self.lastStreamError = "Video: " + message
            }
            syncVideo(force: true)
        } catch {
            videoLoading = false
            videoMode = false
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Video açılamadı."
        }
    }

    private func stopVideo() {
        videoObservers.removeAll()
        videoPlayer.pause()
        videoPlayer.replaceCurrentItem(with: nil)
        videoProgressive?.cancel()
        videoProgressive = nil
        videoLoading = false
    }

    /// Görüntüyü sesin konumuna ve hızına eşitler.
    private func syncVideo(force: Bool = false) {
        guard videoMode, let item = videoPlayer.currentItem, item.status == .readyToPlay else { return }
        guard UIApplication.shared.applicationState != .background else { return }
        let audioTime = player.currentTime().seconds
        guard audioTime.isFinite else { return }
        let videoTime = videoPlayer.currentTime().seconds
        if force || !videoTime.isFinite || abs(videoTime - audioTime) > 0.3 {
            videoPlayer.seek(to: CMTime(seconds: audioTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if isPlaying && !isBuffering {
            if videoPlayer.rate != playbackRate { videoPlayer.playImmediately(atRate: playbackRate) }
        } else if videoPlayer.rate != 0 {
            videoPlayer.pause()
        }
    }

    private func loadCurrent(autoplay: Bool, startAt: Double = 0, record: Bool = true) {
        guard let track = current else { return }
        loadToken += 1
        progressive?.cancel()
        progressive = nil
        if let remote = track.remote { onRemoteSeen?(remote) }
        let token = loadToken

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        clock.currentTime = startAt
        clock.duration = track.duration
        player.volume = crossfade() > 0 && record ? 0.05 : 1
        currentArtwork = nil

        if let remote = track.remote, !FileManager.default.fileExists(atPath: track.url.path) {
            // İndirilmemiş şarkı: akış bağlantısıyla hemen çal, olmazsa dosyayı indirip çal.
            player.pause()
            player.replaceCurrentItem(with: nil)
            isBuffering = true
            isPlaying = autoplay
            updateNowPlaying()
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    guard let live = self.liveRemote else { throw APIError(message: "Akış ayarlı değil.", status: 0) }
                    let url = try await live(remote)
                    guard token == self.loadToken else { return }
                    // Uygulama şarkıyı kendisi indirir, ilk baytlar gelir gelmez oynatıcıya verir.
                    let loader = ProgressiveAsset(remoteURL: url, kind: .audio)
                    self.progressive = loader
                    loader.onComplete = { [weak self] temp in
                        self?.onStreamCached?(remote, temp)
                    }
                    loader.onError = { [weak self] message in
                        guard let self else { return }
                        self.lastStreamError = message
                        // Hiç çalmaya başlayamadıysa dosyayı indirip çal.
                        if token == self.loadToken, self.clock.currentTime < 1 {
                            Task { await self.fallbackToFile(track: track, remote: remote, token: token, startAt: startAt, record: false) }
                        }
                    }
                    self.startItem(track: track, item: AVPlayerItem(asset: loader.asset), autoplay: self.isPlaying, startAt: startAt, record: record, streaming: true)
                } catch {
                    guard token == self.loadToken else { return }
                    self.lastStreamError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    await self.fallbackToFile(track: track, remote: remote, token: token, startAt: startAt, record: record)
                }
            }
            return
        }

        isBuffering = false
        startItem(track: track, url: track.url, autoplay: autoplay, startAt: startAt, record: record)
    }

    /// Akış başarısız olursa şarkıyı tam indirip çalar.
    private func fallbackToFile(track: Track, remote: SearchResult, token: Int, startAt: Double, record: Bool) async {
        guard let resolve = resolveRemote else { return }
        isBuffering = true
        do {
            let url = try await resolve(remote)
            guard token == loadToken else { return }
            startItem(track: track, url: url, autoplay: isPlaying, startAt: startAt, record: record)
        } catch {
            guard token == loadToken else { return }
            isBuffering = false
            isPlaying = false
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Şarkı açılamadı."
            updateNowPlaying()
        }
    }

    private func startItem(track: Track, url: URL, autoplay: Bool, startAt: Double, record: Bool) {
        startItem(track: track, item: AVPlayerItem(url: url), autoplay: autoplay, startAt: startAt, record: record, artworkURL: url)
    }

    private func startItem(track: Track, item: AVPlayerItem, autoplay: Bool, startAt: Double, record: Bool, streaming: Bool = false, artworkURL: URL? = nil) {
        item.audioTimePitchAlgorithm = .timeDomain
        item.preferredForwardBufferDuration = streaming ? 4 : 0
        player.replaceCurrentItem(with: item)
        isBuffering = streaming
        let (preset, normalize) = effects()
        let wantsMeter = visualizer()
        meter = nil
        if preset != .flat || normalize || wantsMeter {
            Task { @MainActor in
                guard let (mix, context) = await AudioEffects.audioMix(for: item, preset: preset, normalize: normalize, meter: wantsMeter) else { return }
                if self.player.currentItem === item {
                    item.audioMix = mix
                    self.meter = wantsMeter ? context : nil
                }
            }
        }
        fadeInStarted = crossfade() > 0 && record ? Date() : nil
        if streaming, let remote = track.remote {
            // 8 saniyede çalmaya başlayamazsa dosyayı indirip çal.
            let token = loadToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, token == self.loadToken, self.player.currentItem === item,
                      self.isBuffering, self.clock.currentTime < 0.5 else { return }
                self.lastStreamError = "Akış 8 saniyede başlamadı; şarkı indirilerek çalınıyor."
                self.progressive?.cancel()
                Task { await self.fallbackToFile(track: track, remote: remote, token: token, startAt: 0, record: false) }
            }
        }

        itemObservers.removeAll()
        let token = loadToken
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self, token == self.loadToken else { return }
                if status == .readyToPlay {
                    self.syncVideo(force: true)
                } else if status == .failed {
                    if streaming { self.lastStreamError = item.error?.localizedDescription ?? "Oynatıcı akışı açamadı." }
                    if streaming, let remote = track.remote {
                        self.itemObservers.removeAll()
                        Task { await self.fallbackToFile(track: track, remote: remote, token: token, startAt: self.clock.currentTime, record: false) }
                    } else {
                        self.isBuffering = false
                        self.isPlaying = false
                        self.errorMessage = "Bu dosya çalınamıyor."
                    }
                }
            }
            .store(in: &itemObservers)
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self, token == self.loadToken else { return }
                // Aynı değeri tekrar yazmak bile ekranları yeniden çizdirir; yalnızca değişince yaz.
                let buffering = status == .waitingToPlayAtSpecifiedRate && streaming
                if self.isBuffering != buffering { self.isBuffering = buffering }
                self.syncVideo()
            }
            .store(in: &itemObservers)

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.advance(userInitiated: false)
            }
        }

        if startAt > 1 {
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }

        if autoplay {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.playImmediately(atRate: playbackRate)
            isPlaying = true
            if record { onTrackStart?(track) }
        } else {
            isPlaying = false
        }

        updateNowPlaying()
        saveState(force: true)

        // Sıradaki internet şarkısını şimdiden hazırla.
        if let index = currentIndex, queue.indices.contains(index + 1), let next = queue[index + 1].remote {
            prefetchRemote?(next)
        }
        if !autoplay { isBuffering = false }

        // Sonraki şarkıya geçildiyse video modu açık kalır: yeni şarkının videosunu getir.
        if videoMode, record {
            Task { await self.loadVideoForCurrent() }
        }

        Task { @MainActor [weak self] in
            var image: UIImage?
            var color: UIColor?
            if let artworkURL {
                image = await ArtworkCache.shared.image(for: artworkURL)
                color = await ArtworkCache.shared.dominantColor(for: artworkURL)
            }
            // İnternet şarkısı: dosyada kapak yok, YouTube küçük resmini kullan (kilit ekranı için de).
            if image == nil, let remote = track.remote {
                image = await ArtworkCache.shared.remoteArtwork(for: remote.id, preferred: remote.squareCover(size: 1080))
                if let image { color = await ArtworkCache.shared.dominantColor(of: image, key: "yt:" + remote.id) }
            }
            var colors: [UIColor] = []
            if let image { colors = await ArtworkCache.shared.palette(of: image) }
            guard let self, self.current?.id == track.id else { return }
            self.currentArtwork = image
            self.artworkColor = color
            self.artworkPalette = colors
            self.updateNowPlaying()
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
    }

    private func observeTime() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                guard let self else { return }
                self.checkSleepTimer()
                self.updateVolume()
                self.checkCrossfadeAdvance()
                guard !self.isSeeking else { return }
                if seconds.isFinite, abs(seconds - self.clock.currentTime) >= 0.2 {
                    self.clock.currentTime = seconds
                }
                if let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0,
                   abs(itemDuration - self.clock.duration) > 0.5 {
                    self.clock.duration = itemDuration
                    self.updateNowPlaying()
                }
                if self.isPlaying { self.saveState() }
                if self.videoMode { self.syncVideo() }
                if self.isPlaying, !self.isBuffering, let track = self.current { self.onListen?(track, 0.25) }
            }
        }
    }

    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt

            Task { @MainActor in
                guard let self, let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

                switch type {
                case .began:
                    self.isPlaying = false
                    self.updateNowPlaying()
                case .ended:
                    let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions ?? 0)
                    if options.contains(.shouldResume) {
                        self.resume()
                    }
                @unknown default:
                    break
                }
            }
        }

        // Kulaklık çıkarılınca durdur.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                guard let self, let rawReason,
                      AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable else { return }
                self.pause()
            }
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }

        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }

        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }

        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }

        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.displayArtist,
            MPMediaItemPropertyPlaybackDuration: clock.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: clock.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(playbackRate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(playbackRate),
        ]

        if !track.album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = track.album
        }

        if let image = currentArtwork ?? UIImage(named: "BoxLogo") {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
