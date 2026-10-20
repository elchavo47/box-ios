import AVFoundation
import CoreImage
import UIKit

/// Şarkı kapaklarını dosyanın içinden okur, siyah bantları kırpar, kare yapar ve
/// iki boyutta (liste için küçük, oynatıcı için büyük) bellekte tutar.
actor ArtworkCache {
    static let shared = ArtworkCache()

    private let large = NSCache<NSString, UIImage>()
    private let small = NSCache<NSString, UIImage>()
    private let colors = NSCache<NSString, UIColor>()
    private var missing = Set<String>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    init() {
        large.countLimit = 40
        small.countLimit = 600
    }

    /// `maxSide` 200'ün altındaysa küçük önbellekten verir.
    func image(for url: URL, maxSide: CGFloat = 900) async -> UIImage? {
        let key = url.path as NSString
        let wantsSmall = maxSide <= 200

        if wantsSmall, let cached = small.object(forKey: key) { return cached }
        if !wantsSmall, let cached = large.object(forKey: key) { return cached }
        if missing.contains(url.path) { return nil }

        guard let full = await loadFull(url) else { return nil }

        if wantsSmall {
            let thumb = Self.downscale(full, maxSide: 200)
            small.setObject(thumb, forKey: key)
            return thumb
        }
        return full
    }

    /// Kapaktan oynatıcı arka planı için baskın renk.
    func dominantColor(for url: URL) async -> UIColor? {
        let key = url.path as NSString
        if let cached = colors.object(forKey: key) { return cached }
        guard let image = await image(for: url, maxSide: 200), let cg = image.cgImage else { return nil }

        let input = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input,
            kCIInputExtentKey: CIVector(cgRect: input.extent),
        ]), let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)

        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
            .getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        // Okunaklı kalması için koyu ve doygun tut.
        let color = UIColor(hue: hue, saturation: min(max(sat, 0.25) * 1.15, 0.85), brightness: min(max(bri, 0.28), 0.48), alpha: 1)
        colors.setObject(color, forKey: key)
        return color
    }

    func invalidate(_ url: URL) {
        let key = url.path as NSString
        large.removeObject(forKey: key)
        small.removeObject(forKey: key)
        colors.removeObject(forKey: key)
        missing.remove(url.path)
    }

    private func loadFull(_ url: URL) async -> UIImage? {
        let key = url.path
        if let cached = large.object(forKey: key as NSString) { return cached }
        if let task = inFlight[key] { return await task.value }

        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            let asset = AVURLAsset(url: url)
            guard let items = try? await asset.load(.commonMetadata) else { return nil }
            for item in items where item.commonKey == .commonKeyArtwork {
                if let data = try? await item.load(.dataValue), let decoded = UIImage(data: data) {
                    return Self.prepare(decoded)
                }
            }
            return nil
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil

        if let image {
            large.setObject(image, forKey: key as NSString)
        } else {
            missing.insert(key)
        }
        return image
    }

    // MARK: - Görsel işleme

    /// Siyah bantları kırpar, ortadan kare keser, 900 px'e küçültür.
    nonisolated static func prepare(_ image: UIImage) -> UIImage {
        let trimmed = trimLetterbox(image)
        return downscale(squareCrop(trimmed), maxSide: 900)
    }

    /// YouTube küçük resimlerindeki üst/alt (ve yan) siyah bantları bulup kırpar.
    nonisolated static func trimLetterbox(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let width = cg.width, height = cg.height
        guard width > 20, height > 20 else { return image }

        // Hızlı analiz için küçük bir kopya üzerinde çalış.
        let sampleW = 96
        let sampleH = max(1, Int(Double(height) / Double(width) * Double(sampleW)))
        var pixels = [UInt8](repeating: 0, count: sampleW * sampleH * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: sampleW, height: sampleH, bitsPerComponent: 8, bytesPerRow: sampleW * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))
            return true
        }
        guard drawn else { return image }

        func luminance(_ x: Int, _ y: Int) -> Int {
            let i = (y * sampleW + x) * 4
            return (Int(pixels[i]) * 3 + Int(pixels[i + 1]) * 6 + Int(pixels[i + 2])) / 10
        }
        func rowDark(_ y: Int) -> Bool {
            var total = 0, maxValue = 0
            for x in 0..<sampleW { let l = luminance(x, y); total += l; maxValue = max(maxValue, l) }
            return total / sampleW < 18 && maxValue < 60
        }
        func colDark(_ x: Int, _ y0: Int, _ y1: Int) -> Bool {
            guard y1 > y0 else { return false }
            var total = 0, maxValue = 0
            for y in y0..<y1 { let l = luminance(x, y); total += l; maxValue = max(maxValue, l) }
            return total / (y1 - y0) < 18 && maxValue < 60
        }

        // Bellekteki ilk satır görüntünün üstüdür.
        var top = 0
        while top < sampleH / 3 && rowDark(top) { top += 1 }
        var bottom = sampleH - 1
        while bottom > sampleH * 2 / 3 && rowDark(bottom) { bottom -= 1 }
        var left = 0
        while left < sampleW / 3 && colDark(left, top, bottom) { left += 1 }
        var right = sampleW - 1
        while right > sampleW * 2 / 3 && colDark(right, top, bottom) { right -= 1 }

        guard top > 1 || left > 1 || bottom < sampleH - 2 || right < sampleW - 2 else { return image }

        let sx = Double(width) / Double(sampleW), sy = Double(height) / Double(sampleH)
        let rect = CGRect(
            x: Double(left) * sx,
            y: Double(top) * sy,
            width: Double(right - left + 1) * sx,
            height: Double(bottom - top + 1) * sy
        ).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))

        guard rect.width > 40, rect.height > 40, let cropped = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    nonisolated static func squareCrop(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let side = min(cg.width, cg.height)
        guard cg.width != cg.height else { return image }
        let rect = CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)
        guard let cropped = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    nonisolated static func downscale(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return image }

        let scale = maxSide / longest
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
