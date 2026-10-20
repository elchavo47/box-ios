import ImageIO
import SwiftUI
import UIKit

/// İnternetten gelen küçük resimler (YouTube kapakları, profil fotoğrafları) için bellek önbelleği.
/// Resmi arka planda gereken boyuta küçültür; listeler kaydırılırken ana iş parçacığı yorulmaz
/// ve aynı resim ekrana her girişinde yeniden indirilmez.
@MainActor
final class RemoteImageCache {
    static let shared = RemoteImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [NSString: Task<UIImage?, Never>] = [:]

    init() {
        memory.countLimit = 500
        memory.totalCostLimit = 96 * 1024 * 1024
    }

    /// Önbellekte varsa hemen döner (ilk çizimde boş kare görünmesin diye).
    func cached(_ url: URL, maxSide: CGFloat) -> UIImage? {
        memory.object(forKey: Self.key(url, maxSide))
    }

    func image(_ url: URL, maxSide: CGFloat) async -> UIImage? {
        let key = Self.key(url, maxSide)
        if let hit = memory.object(forKey: key) { return hit }
        if let running = inFlight[key] { return await running.value }

        let pixels = Self.bucket(maxSide)
        let task: Task<UIImage?, Never> = Task.detached(priority: .utility) {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400 else { return nil }
            return ImageDownsampler.image(from: data, maxPixel: pixels)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            memory.setObject(image, forKey: key, cost: cost)
        }
        return image
    }

    func remove(_ url: URL) {
        for side in stride(from: 64, through: 1024, by: 64) {
            memory.removeObject(forKey: Self.key(url, CGFloat(side)))
        }
    }

    /// Boyutları 64 piksellik basamaklara yuvarla (aynı resim için az sayıda kopya).
    nonisolated private static func bucket(_ maxSide: CGFloat) -> CGFloat {
        let clamped = min(max(maxSide, 64), 1024)
        return (clamped / 64).rounded(.up) * 64
    }

    nonisolated private static func key(_ url: URL, _ maxSide: CGFloat) -> NSString {
        "\(Int(bucket(maxSide)))|\(url.absoluteString)" as NSString
    }
}

/// Büyük fotoğrafları belleğe tamamını açmadan küçültür (48 MP fotoğraf bile hafif kalır).
enum ImageDownsampler {
    /// `maxPixel`: uzun kenarın piksel cinsinden üst sınırı. Fotoğrafın yönü (EXIF) düzeltilir.
    static func image(from data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixel)),
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// İnternetteki bir resmi önbellekli gösterir (AsyncImage gibi, ama her seferinde indirmez).
struct CachedRemoteImage<Placeholder: View>: View {
    let url: URL?
    var maxSide: CGFloat = 400
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var loadedURL: URL?

    var body: some View {
        ZStack {
            if let shown = currentImage {
                Image(uiImage: shown)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { image = nil; loadedURL = nil; return }
            if let hit = RemoteImageCache.shared.cached(url, maxSide: maxSide) {
                image = hit
                loadedURL = url
                return
            }
            let loaded = await RemoteImageCache.shared.image(url, maxSide: maxSide)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                image = loaded
                loadedURL = url
            }
        }
    }

    @MainActor
    private var currentImage: UIImage? {
        guard let url else { return nil }
        if let hit = RemoteImageCache.shared.cached(url, maxSide: maxSide) { return hit }
        return loadedURL == url ? image : nil
    }
}
