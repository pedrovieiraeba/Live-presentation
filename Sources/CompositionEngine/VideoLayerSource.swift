import AVFoundation
import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Decodifica um vídeo (VideoToolbox via AVPlayer) e entrega o quadro atual
/// como textura Metal, sem cópia: o CVPixelBuffer é mapeado pelo
/// CVMetalTextureCache.
final class VideoLayerSource {
    struct Config: Equatable {
        var url: URL
        var loop: Bool
        var muted: Bool
    }

    let config: Config
    private let player: AVPlayer
    private let item: AVPlayerItem
    private let output: AVPlayerItemVideoOutput
    private let textureCache: CVMetalTextureCache
    private var current: CVMetalTexture?
    private var endObserver: NSObjectProtocol?

    init?(config: Config, device: MTLDevice) {
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        textureCache = cache
        self.config = config

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        let item = AVPlayerItem(url: config.url)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        self.output = output
        self.item = item
        self.player = player
        // Áudio de vídeos é silenciado por padrão: o áudio do culto vem do Logic.
        player.isMuted = config.muted
        player.actionAtItemEnd = config.loop ? .none : .pause
        if config.loop {
            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            }
        }
        player.play()
    }

    deinit { stop() }

    /// Mensagem de erro se o item falhou ao carregar/decodificar.
    var failure: String? {
        item.status == .failed ? (item.error?.localizedDescription ?? "falha de decodificação") : nil
    }

    /// Textura do quadro correspondente ao instante atual (ou a última válida).
    /// O `CVMetalTexture` retornado deve ser retido até o fim do uso na GPU.
    func currentTexture() -> (texture: MTLTexture, owner: CVMetalTexture)? {
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: itemTime),
           let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
            var cvTexture: CVMetalTexture?
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, buffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
            if status == kCVReturnSuccess, let cvTexture { current = cvTexture }
        }
        guard let current, let texture = CVMetalTextureGetTexture(current) else { return nil }
        return (texture, current)
    }

    func stop() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
        CVMetalTextureCacheFlush(textureCache, 0)
    }
}
