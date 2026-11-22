import AppKit
import ImageIO
import SwiftUI

// Миниатюры картинок: уменьшаем при загрузке (CGImageSource), держим в кэше.
final class ThumbCache: @unchecked Sendable {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, NSImage>()

    func cached(_ path: String, _ px: Int) -> NSImage? { cache.object(forKey: "\(px)|\(path)" as NSString) }

    func load(_ path: String, maxPixel px: Int) async -> NSImage? {
        if let c = cached(path, px) { return c }
        let img: NSImage? = await Task.detached(priority: .userInitiated) {
            let url = URL(fileURLWithPath: path) as CFURL
            guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: px,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let img { cache.setObject(img, forKey: "\(px)|\(path)" as NSString) }
        return img
    }
}

struct Thumb: View {
    let path: String
    var maxPixel = 480
    var height: CGFloat = 120
    var maxWidth: CGFloat = 220
    var corner: CGFloat = 10
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                let ar = image.size.height > 0 ? image.size.width / image.size.height : 1
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: min(maxWidth, max(height * 0.6, height * ar)), height: height)
                    .clipped()
            } else {
                Rectangle().fill(Color.primary.opacity(0.06))
                    .frame(width: height * 1.4, height: height)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .task(id: path) {
            if image == nil { image = ThumbCache.shared.cached(path, maxPixel) }
            if image == nil { image = await ThumbCache.shared.load(path, maxPixel: maxPixel) }
        }
    }
}

struct ZoomedImage: View {
    let path: String
    var onClose: () -> Void
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.35))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 20, y: 6)
                    .padding(24)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onClose() }
        .task(id: path) { image = await ThumbCache.shared.load(path, maxPixel: 2400) }
    }
}
