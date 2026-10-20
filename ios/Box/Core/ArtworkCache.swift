import AVFoundation
import UIKit

/// Şarkı kapaklarını dosyanın içinden okuyup bellekte tutar.
actor ArtworkCache {
    static let shared = ArtworkCache()

    private let cache = NSCache<NSString, UIImage>()
    private var missing = Set<String>()

    init() {
        cache.countLimit = 300
    }

    func image(for url: URL) async -> UIImage? {
        let key = url.path as NSString

        if let cached = cache.object(forKey: key) {
            return cached
        }

        if missing.contains(url.path) {
            return nil
        }

        let asset = AVURLAsset(url: url)
        var image: UIImage?

        if let items = try? await asset.load(.commonMetadata) {
            for item in items where item.commonKey == .commonKeyArtwork {
                if let data = try? await item.load(.dataValue), let decoded = UIImage(data: data) {
                    image = Self.downscale(decoded, maxSide: 800)
                    break
                }
            }
        }

        if let image {
            cache.setObject(image, forKey: key)
        } else {
            missing.insert(url.path)
        }

        return image
    }

    func invalidate(_ url: URL) {
        cache.removeObject(forKey: url.path as NSString)
        missing.remove(url.path)
    }

    private static func downscale(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return image }

        let scale = maxSide / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1

        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
