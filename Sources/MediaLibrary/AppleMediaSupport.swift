#if canImport(AVFoundation) && canImport(ImageIO)
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Probe real de mídia com ImageIO (imagens) e AVFoundation (vídeos).
public struct AppleMediaProbe: MediaProbing {
    public init() {}

    public func probe(_ url: URL, kind: MediaKind) async throws -> MediaProbeResult {
        switch kind {
        case .image: return try probeImage(url)
        case .video: return try await probeVideo(url)
        }
    }

    private func probeImage(_ url: URL) throws -> MediaProbeResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { throw MediaProbeError.unreadable("imagem não decodificável") }
        var width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        var height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        // Orientações 5–8 (EXIF) giram a imagem em 90°.
        if let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(orientation) {
            swap(&width, &height)
        }
        let type = CGImageSourceGetType(source).map { $0 as String }
        return MediaProbeResult(pixelWidth: width, pixelHeight: height, codec: type)
    }

    private func probeVideo(_ url: URL) async throws -> MediaProbeResult {
        let asset = AVURLAsset(url: url)
        let (duration, playable) = try await asset.load(.duration, .isPlayable)
        guard playable else { throw MediaProbeError.notPlayable }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaProbeError.noVideoTrack
        }
        let (size, transform, formats) = try await track.load(.naturalSize, .preferredTransform, .formatDescriptions)
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        let codec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) }
        return MediaProbeResult(duration: duration.seconds.isFinite ? duration.seconds : nil,
                                pixelWidth: Int(abs(rect.width).rounded()),
                                pixelHeight: Int(abs(rect.height).rounded()),
                                codec: codec)
    }

    private func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let text = String(bytes: bytes, encoding: .macOSRoman) ?? "\(code)"
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// Bookmarks do sistema: reencontram arquivos movidos no mesmo volume.
public struct AppleBookmarks: BookmarkResolving {
    public init() {}

    public func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public func resolve(_ bookmark: Data) -> (url: URL, refreshed: Data?)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale ? makeBookmark(for: url) : nil)
    }
}

/// Gera miniaturas sem carregar a mídia inteira na memória.
public enum ThumbnailGenerator {
    public static func thumbnail(for asset: MediaAsset, maxPixelSize: Int) async throws -> CGImage {
        switch asset.kind {
        case .image:
            return try downsampledImage(at: asset.url, maxPixelSize: maxPixelSize)
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: asset.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
            let seconds = min(1.0, (asset.duration ?? 0) / 2)
            let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            return image
        }
    }

    /// Decodifica a imagem já reduzida (ImageIO), respeitando a orientação EXIF.
    public static func downsampledImage(at url: URL, maxPixelSize: Int) throws -> CGImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            throw MediaProbeError.unreadable("imagem não encontrada")
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw MediaProbeError.unreadable("imagem não decodificável")
        }
        return image
    }
}
#endif
