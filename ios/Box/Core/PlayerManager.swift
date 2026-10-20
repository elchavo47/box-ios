import AVFoundation
import Combine
import MediaPlayer
import UIKit

enum RepeatMode {
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

@MainActor
final class PlayerManager: ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isShuffled = false
    @Published var repeatMode: RepeatMode = .off
    @Published var showFullPlayer = false
    @Published private(set) var currentArtwork: UIImage?

    private let player = AVPlayer()
    private var originalQueue: [Track] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var isSeeking = false

    var current: Track? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    var upNext: [Track] {
        guard let currentIndex else { return [] }
        return Array(queue.dropFirst(currentIndex + 1))
    }

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        configureAudioSession()
        configureRemoteCommands()
        observeTime()
        observeInterruptions()
    }

    // MARK: - Oynatma

    func play(_ tracks: [Track], startAt index: Int = 0, shuffled: Bool = false) {
        guard !tracks.isEmpty else { return }

        let safeIndex = min(max(index, 0), tracks.count - 1)
        originalQueue = tracks

        if shuffled {
            var rest = tracks
            let first = rest.remove(at: shuffled && index == 0 ? Int.random(in: 0..<tracks.count) : safeIndex)
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
        guard let currentIndex else {
            play([track])
            return
        }
        queue.insert(track, at: currentIndex + 1)
        originalQueue.append(track)
    }

    func addToQueue(_ track: Track) {
        guard currentIndex != nil else {
            play([track])
            return
        }
        queue.append(track)
        originalQueue.append(track)
    }

    func jump(to index: Int) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        loadCurrent(autoplay: true)
    }

    func removeFromQueue(at offsets: IndexSet) {
        guard let currentIndex else { return }
        // Sıradakiler listesindeki konumları gerçek kuyruk konumlarına çevir.
        let absolute = offsets.map { $0 + currentIndex + 1 }.filter { queue.indices.contains($0) }
        for index in absolute.sorted(by: >) {
            let removed = queue.remove(at: index)
            if let originalIndex = originalQueue.firstIndex(of: removed) {
                originalQueue.remove(at: originalIndex)
            }
        }
    }

    func moveInQueue(from source: IndexSet, to destination: Int) {
        guard let currentIndex else { return }
        var upcoming = Array(queue.dropFirst(currentIndex + 1))
        upcoming.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue.prefix(currentIndex + 1)) + upcoming
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func resume() {
        guard current != nil else { return }
        if player.currentItem == nil {
            loadCurrent(autoplay: true)
            return
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func next() {
        advance(userInitiated: true)
    }

    func previous() {
        guard let currentIndex else { return }

        if currentTime > 3 || currentIndex == 0 {
            seek(to: 0)
            return
        }

        self.currentIndex = currentIndex - 1
        loadCurrent(autoplay: true)
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        isSeeking = true
        currentTime = max(0, seconds)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.isSeeking = false
                self?.updateNowPlaying()
            }
        }
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
    }

    func cycleRepeat() {
        repeatMode = repeatMode.next
    }

    /// Dosya silindiğinde ya da taşındığında kuyruğu temizler.
    func handleLibraryChange(validPaths: Set<String>) {
        guard !queue.isEmpty else { return }
        let currentPath = current?.relativePath

        if let currentPath, !validPaths.contains(currentPath) {
            stop()
            return
        }

        queue.removeAll { !validPaths.contains($0.relativePath) }
        originalQueue.removeAll { !validPaths.contains($0.relativePath) }
        if let currentPath {
            currentIndex = queue.firstIndex { $0.relativePath == currentPath }
        }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = []
        originalQueue = []
        currentIndex = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        currentArtwork = nil
        showFullPlayer = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - İç işleyiş

    private func advance(userInitiated: Bool) {
        guard let currentIndex else { return }

        if !userInitiated, repeatMode == .one {
            seek(to: 0)
            player.play()
            return
        }

        if currentIndex + 1 < queue.count {
            self.currentIndex = currentIndex + 1
            loadCurrent(autoplay: true)
        } else if repeatMode == .all || userInitiated {
            self.currentIndex = 0
            loadCurrent(autoplay: repeatMode == .all || userInitiated)
        } else {
            pause()
            seek(to: 0)
        }
    }

    private func loadCurrent(autoplay: Bool) {
        guard let track = current else { return }

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }

        let item = AVPlayerItem(url: track.url)
        player.replaceCurrentItem(with: item)
        currentTime = 0
        duration = track.duration
        currentArtwork = nil

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.advance(userInitiated: false)
            }
        }

        if autoplay {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            isPlaying = true
        } else {
            isPlaying = false
        }

        updateNowPlaying()

        let url = track.url
        Task { @MainActor [weak self] in
            let image = await ArtworkCache.shared.image(for: url)
            guard let self, self.current?.url == url else { return }
            self.currentArtwork = image
            self.updateNowPlaying()
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
    }

    private func observeTime() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                guard let self, !self.isSeeking else { return }
                if seconds.isFinite {
                    self.currentTime = seconds
                }
                if let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0,
                   abs(itemDuration - self.duration) > 0.5 {
                    self.duration = itemDuration
                    self.updateNowPlaying()
                }
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
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
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
