import UIKit
import WidgetKit

/// Çalan şarkıyı ve son dinlenenleri ana ekran widget'ına yazar (App Group yoksa hiçbir şey yapmaz).
@MainActor
final class WidgetBridge {
    static let shared = WidgetBridge()

    weak var library: LibraryStore?
    private var lastNowKey = ""
    private var lastRecentKey = ""
    private var snapshot = WidgetSnapshot.empty
    private var started = false

    private func jpeg(_ image: UIImage, side: CGFloat) -> Data? {
        ArtworkCache.downscale(ArtworkCache.squareCrop(image), maxSide: side).jpegData(compressionQuality: 0.8)
    }

    /// Çalan şarkı ya da çalma durumu değişince çağrılır.
    func update(track: Track?, playing: Bool, artwork: UIImage?) {
        guard BoxShared.container != nil else { return }
        let key = "\(track?.id ?? "-")|\(playing)|\(artwork != nil)"
        guard key != lastNowKey else { return }
        lastNowKey = key

        if !started { snapshot = WidgetSnapshot.load(); started = true }
        if let track {
            var art: String?
            if let artwork, let data = jpeg(artwork, side: 400), let url = BoxShared.imageURL("now.jpg") {
                try? data.write(to: url, options: .atomic)
                art = "now.jpg"
            }
            snapshot.now = WidgetTrack(title: track.title, artist: track.displayArtist, art: art ?? snapshot.now?.art)
        } else {
            snapshot.now = nil
        }
        snapshot.playing = playing
        refreshRecent()
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Son dinlenen 3 şarkının küçük kapaklarını hazırlar.
    private func refreshRecent() {
        guard let library else { return }
        let recent = Array(library.recentlyPlayed.prefix(3))
        let key = recent.map(\.id).joined(separator: ",")
        guard key != lastRecentKey else { return }
        lastRecentKey = key
        snapshot.recent = recent.enumerated().map { WidgetTrack(title: $1.title, artist: $1.displayArtist, art: "r\($0).jpg") }
        snapshot.save()
        Task { [weak self] in
            for (index, track) in recent.enumerated() {
                let image: UIImage?
                if let remote = track.remote {
                    image = await ArtworkCache.shared.remoteArtwork(for: remote.id, preferred: track.artworkFallback)
                } else {
                    image = await ArtworkCache.shared.image(for: track.url, maxSide: 300)
                }
                if let image, let data = self?.jpeg(image, side: 240), let url = BoxShared.imageURL("r\(index).jpg") {
                    try? data.write(to: url, options: .atomic)
                }
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
