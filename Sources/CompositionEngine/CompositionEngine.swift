import CompositionCore
import CoreGraphics
import Diagnostics
import Foundation
import MediaLibrary
import Metal
import MetalKit
import NDIService
import PresentationCore
import QuartzCore

/// Métricas locais do motor, para o painel de diagnóstico.
public struct CompositionStats: Equatable, Sendable {
    public var profileName = ""
    public var targetFPS = 0
    public var measuredFPS = 0.0
    public var renderedFrames = 0
    public var droppedFrames = 0
    public var averageGPUTimeMs = 0.0
    public var activeVideoLayers = 0
    public var loadedImages = 0
    /// Estimativa (largura × altura × 4 bytes) das texturas mantidas pelo motor.
    public var estimatedTextureMemoryBytes = 0
    public var issues: [String] = []
    public var ndiSources: [NDILayerStats] = []
    public var ndiOutput: NDIOutputSender.Stats?
}

public struct NDILayerStats: Equatable, Sendable, Identifiable {
    public var layerID: UUID
    public var layerName: String
    public var receiver: NDIReceiverStats
    public var id: UUID { layerID }
}

/// Anel de texturas para os quadros de uma fonte NDI (escrita pela CPU sem
/// conflito com leituras da GPU ainda em voo).
private final class NDITextureRing {
    var textures: [MTLTexture] = []
    var next = 0
    var lastGeneration: UInt64 = .max
    var current: MTLTexture?
    var ignoresAlpha = false
}

/// Motor de composição: renderiza a cena no ar numa textura própria, na
/// resolução do perfil, num relógio independente da interface. Janelas de saída
/// e monitores apenas exibem a última textura pronta.
///
/// Concorrência: a API pública é chamada na main thread; a renderização roda
/// numa fila serial própria; o estado compartilhado é protegido por `lock`.
public final class CompositionEngine: @unchecked Sendable {
    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let renderer: QuadRenderer
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    private let renderQueue = DispatchQueue(label: "app.livepresentation.composition", qos: .userInteractive)
    private let textureLoader: MTKTextureLoader
    private let log = AppLogger(category: "composition")
    private var timer: DispatchSourceTimer?

    private let lock = NSLock()
    // Estado protegido por `lock`:
    private var profile: CompositionProfile
    private var program: CompositionScene?
    private var blackout = false
    private var slideTexture: MTLTexture?
    private var slideBackground: RGBAColor?
    private var imageTextures: [UUID: MTLTexture] = [:]
    private var videoSources: [UUID: VideoLayerSource] = [:]
    private var mediaIssues: [UUID: String] = [:]
    private var targets: [MTLTexture] = []
    private var nextTarget = 0
    private var latest: MTLTexture?
    private var inFlight = 0
    private var stats = CompositionStats()
    private var gpuTimes: [Double] = []
    private var frameTimestamps: [CFTimeInterval] = []
    private var ndiRuntime: NDIRuntime?
    private var ndiWorkers: [UUID: NDIReceiverWorker] = [:]
    private var ndiOutput: NDIOutputSender?
    private var stagingBuffers: [MTLBuffer] = []
    private var stagingBusy: [Bool] = []
    private var nextStaging = 0
    /// Limite configurável de fontes NDI recebidas ao mesmo tempo (spec §4.5).
    private var maxActiveNDISources = 2

    // Somente na fila de render:
    private var ndiTextures: [UUID: NDITextureRing] = [:]

    // Somente main thread:
    private var slideGeneration = 0
    private var imageLoadsInProgress: Set<UUID> = []

    public static func make(profile: CompositionProfile) -> CompositionEngine? {
        do {
            return try CompositionEngine(profile: profile)
        } catch {
            AppLogger(category: "composition").error("Motor de composição indisponível: \(error)",
                                                     code: "E-COMPOSITION-INIT")
            return nil
        }
    }

    init(profile: CompositionProfile) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw CompositionEngineError.noMetalDevice }
        guard let queue = device.makeCommandQueue() else { throw CompositionEngineError.setupFailed("fila de comandos") }
        self.device = device
        self.commandQueue = queue
        self.renderer = try QuadRenderer(device: device, pixelFormat: Self.pixelFormat)
        self.textureLoader = MTKTextureLoader(device: device)
        self.profile = profile
        try makeTargets(for: profile)
        log.info("Motor de composição pronto: \(device.name), \(profile.name)")
    }

    deinit { stop() }

    // MARK: Ciclo de vida

    public func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        let fps = currentProfile.framesPerSecond
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / max(fps, 1)), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.renderFrame() }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        lock.lock()
        let sources = videoSources
        videoSources.removeAll()
        let workers = ndiWorkers
        ndiWorkers.removeAll()
        let output = ndiOutput
        ndiOutput = nil
        lock.unlock()
        for source in sources.values { source.stop() }
        for worker in workers.values { worker.stop() }
        output?.drain()
    }

    // MARK: NDI

    /// Runtime NDI carregado (ou `nil` se o SDK não estiver instalado).
    public func setNDIRuntime(_ runtime: NDIRuntime?, maxActiveSources: Int) {
        lock.lock()
        ndiRuntime = runtime
        maxActiveNDISources = max(maxActiveSources, 0)
        lock.unlock()
    }

    public func setMaxActiveNDISources(_ value: Int, assets: [UUID: MediaAsset]) {
        lock.lock(); maxActiveNDISources = max(value, 0); lock.unlock()
        setProgram(lockedProgram, assets: assets)
    }

    /// Publica (ou para de publicar) a composição como saída NDI.
    public func setNDIOutput(_ sender: NDIOutputSender?) {
        lock.lock()
        let previous = ndiOutput
        ndiOutput = sender
        lock.unlock()
        if previous !== sender { previous?.drain() }
    }

    private func reconcileNDI(scene: CompositionScene?) -> [UUID: String] {
        var issues: [UUID: String] = [:]
        lock.lock()
        let runtime = ndiRuntime
        let limit = maxActiveNDISources
        let existing = ndiWorkers
        lock.unlock()

        var wanted: [(layer: Layer, source: String)] = []
        for layer in scene?.layers ?? [] {
            guard let source = layer.content.ndiSourceName else { continue }
            if runtime == nil {
                issues[layer.id] = "\(layer.name): SDK NDI não instalado"
            } else if source.isEmpty {
                issues[layer.id] = "\(layer.name): nenhuma fonte NDI escolhida"
            } else if wanted.count >= limit {
                issues[layer.id] = "\(layer.name): limite de \(limit) fonte(s) NDI ativa(s) atingido"
            } else {
                wanted.append((layer, source))
            }
        }

        var workers: [UUID: NDIReceiverWorker] = [:]
        for (layer, source) in wanted {
            if let worker = existing[layer.id], worker.sourceName == source {
                workers[layer.id] = worker
            } else if let runtime {
                let worker = NDIReceiverWorker(runtime: runtime, sourceName: source)
                worker.start()
                workers[layer.id] = worker
            }
        }
        let removed = existing.filter { workers[$0.key] !== $0.value }.map(\.value)
        lock.lock(); ndiWorkers = workers; lock.unlock()
        // Encerrar um receptor pode levar até um timeout de captura: fora da main thread.
        if !removed.isEmpty {
            DispatchQueue.global(qos: .utility).async { removed.forEach { $0.stop() } }
        }
        return issues
    }

    /// Copia o quadro NDI mais novo para uma textura do anel (fila de render).
    private func ndiTexture(for layerID: UUID, worker: NDIReceiverWorker) -> (MTLTexture, Bool)? {
        let ring = ndiTextures[layerID] ?? NDITextureRing()
        ndiTextures[layerID] = ring
        if let newest = worker.latestFrame(), newest.generation != ring.lastGeneration {
            let frame = newest.frame
            let generation = newest.generation
            if ring.textures.first.map({ $0.width != frame.width || $0.height != frame.height }) ?? true {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: frame.width, height: frame.height, mipmapped: false)
                descriptor.usage = .shaderRead
                descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
                ring.textures = (0..<3).compactMap { _ in device.makeTexture(descriptor: descriptor) }
                ring.next = 0
            }
            if ring.textures.count == 3 {
                let texture = ring.textures[ring.next]
                ring.next = (ring.next + 1) % 3
                texture.replace(region: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0,
                                withBytes: frame.data, bytesPerRow: frame.bytesPerRow)
                ring.current = texture
                ring.ignoresAlpha = frame.ignoresAlpha
                ring.lastGeneration = generation
            }
        }
        return ring.current.map { ($0, ring.ignoresAlpha) }
    }

    /// Copia a textura composta para um buffer compartilhado e entrega ao emissor NDI.
    private func encodeNDIReadback(_ commandBuffer: MTLCommandBuffer, target: MTLTexture,
                                   sender: NDIOutputSender, fps: Int) {
        let width = target.width, height = target.height
        let bytesPerRow = width * 4
        lock.lock()
        if stagingBuffers.first.map({ $0.length != bytesPerRow * height }) ?? true {
            stagingBuffers = (0..<3).compactMap { _ in
                device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared)
            }
            stagingBusy = Array(repeating: false, count: stagingBuffers.count)
            nextStaging = 0
        }
        guard stagingBuffers.count == 3, !stagingBusy[nextStaging] else {
            lock.unlock()
            return
        }
        let index = nextStaging
        nextStaging = (nextStaging + 1) % 3
        stagingBusy[index] = true
        let buffer = stagingBuffers[index]
        lock.unlock()

        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            lock.lock(); stagingBusy[index] = false; lock.unlock()
            return
        }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()

        commandBuffer.addCompletedHandler { [weak self] completed in
            guard completed.status == .completed else {
                self?.releaseStaging(index)
                return
            }
            sender.submit(buffer.contents(), width: width, height: height, bytesPerRow: bytesPerRow,
                          framesPerSecond: fps) { [weak self] in self?.releaseStaging(index) }
        }
    }

    private func releaseStaging(_ index: Int) {
        lock.lock()
        if stagingBusy.indices.contains(index) { stagingBusy[index] = false }
        lock.unlock()
    }

    // MARK: Entrada de estado (main thread)

    public var currentProfile: CompositionProfile {
        lock.lock(); defer { lock.unlock() }
        return profile
    }

    /// Troca a resolução de composição. Imagens são recarregadas no novo tamanho;
    /// o app deve reenviar o slide renderizado.
    public func setProfile(_ newProfile: CompositionProfile, assets: [UUID: MediaAsset]) {
        guard newProfile != currentProfile else { return }
        let wasRunning = timer != nil
        if wasRunning { timer?.cancel(); timer = nil }
        renderQueue.sync {
            lock.lock()
            profile = newProfile
            imageTextures.removeAll()
            slideTexture = nil
            latest = nil
            stagingBuffers.removeAll()
            stagingBusy.removeAll()
            lock.unlock()
            do { try makeTargets(for: newProfile) } catch {
                log.error("Falha ao alocar texturas de \(newProfile.name): \(error)", code: "E-COMPOSITION-TARGETS")
            }
        }
        log.notice("Perfil de composição: \(newProfile.name)")
        let scene = lockedProgram
        setProgram(scene, assets: assets)
        if wasRunning { start() }
    }

    private var lockedProgram: CompositionScene? {
        lock.lock(); defer { lock.unlock() }
        return program
    }

    /// Define a cena no ar e prepara somente as fontes que ela usa: vídeos fora
    /// do ar não são decodificados; imagens fora do ar são liberadas.
    public func setProgram(_ scene: CompositionScene?, assets: [UUID: MediaAsset]) {
        var neededImages: Set<UUID> = []
        var neededVideos: [UUID: VideoLayerSource.Config] = [:]
        var issues: [UUID: String] = [:]

        for layer in scene?.layers ?? [] {
            guard let assetID = layer.content.mediaAssetID else { continue }
            guard let asset = assets[assetID] else {
                issues[layer.id] = "\(layer.name): mídia removida da biblioteca"
                continue
            }
            guard asset.availability == .available else {
                issues[layer.id] = "\(layer.name): \(asset.name) está \(asset.availability == .missing ? "ausente" : "incompatível")"
                continue
            }
            switch layer.content {
            case .image:
                neededImages.insert(assetID)
            case let .video(_, loop, muted):
                neededVideos[layer.id] = .init(url: asset.url, loop: loop, muted: muted)
            case .solid, .presentation, .ndi:
                break
            }
        }
        issues.merge(reconcileNDI(scene: scene)) { first, _ in first }

        lock.lock()
        program = scene
        let existingVideos = videoSources
        imageTextures = imageTextures.filter { neededImages.contains($0.key) }
        let loadedImages = Set(imageTextures.keys)
        mediaIssues = issues
        lock.unlock()

        // Vídeos: mantém os que não mudaram, cria os novos, encerra os demais.
        var videos: [UUID: VideoLayerSource] = [:]
        for (layerID, config) in neededVideos {
            if let existing = existingVideos[layerID], existing.config == config {
                videos[layerID] = existing
            } else if let source = VideoLayerSource(config: config, device: device) {
                videos[layerID] = source
            } else {
                issues[layerID] = "Vídeo não pôde ser preparado"
            }
        }
        for (layerID, source) in existingVideos where videos[layerID] !== source { source.stop() }

        lock.lock()
        videoSources = videos
        mediaIssues = issues
        lock.unlock()

        for assetID in neededImages.subtracting(loadedImages) {
            if let asset = assets[assetID] { loadImage(asset) }
        }
    }

    public func setBlackout(_ on: Bool) {
        lock.lock(); blackout = on; lock.unlock()
    }

    /// Slide renderizado (já no tamanho do perfil, fundo transparente) e cor de
    /// fundo do tema. `nil` em ambos = nada no ar.
    public func setSlide(image: CGImage?, background: RGBAColor?) {
        slideGeneration += 1
        let generation = slideGeneration
        guard let image else {
            lock.lock(); slideTexture = nil; slideBackground = background; lock.unlock()
            return
        }
        let loader = textureLoader
        let options = Self.textureOptions
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let texture = try? loader.newTexture(cgImage: image, options: options)
            DispatchQueue.main.async {
                guard let self, generation == self.slideGeneration else { return }
                self.lock.lock()
                self.slideTexture = texture
                self.slideBackground = background
                self.lock.unlock()
            }
        }
    }

    /// Libera o que pode ser recarregado (pressão de memória). Não toca no que
    /// está no ar neste instante além de imagens, que são recarregadas.
    public func purgeCaches(assets: [UUID: MediaAsset]) {
        let scene = lockedProgram
        lock.lock(); imageTextures.removeAll(); lock.unlock()
        setProgram(scene, assets: assets)
    }

    // MARK: Saída

    /// Última composição completa. Leitores devem usar `commandQueue` para que a
    /// GPU ordene leitura e escrita.
    public var latestTexture: MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    public func currentStats() -> CompositionStats {
        lock.lock(); defer { lock.unlock() }
        var s = stats
        s.profileName = profile.name
        s.targetFPS = profile.framesPerSecond
        s.activeVideoLayers = videoSources.count
        s.loadedImages = imageTextures.count
        let targetBytes = targets.reduce(0) { $0 + $1.width * $1.height * 4 }
        let imageBytes = imageTextures.values.reduce(0) { $0 + $1.width * $1.height * 4 }
        let slideBytes = slideTexture.map { $0.width * $0.height * 4 } ?? 0
        s.estimatedTextureMemoryBytes = targetBytes + imageBytes + slideBytes
        var issues = Array(mediaIssues.values)
        for (layerID, source) in videoSources {
            if let failure = source.failure {
                let name = program?.layer(id: layerID)?.name ?? "Vídeo"
                issues.append("\(name): \(failure)")
            }
        }
        for (layerID, worker) in ndiWorkers {
            let name = program?.layer(id: layerID)?.name ?? "Fonte NDI"
            let receiver = worker.currentStats
            s.ndiSources.append(NDILayerStats(layerID: layerID, layerName: name, receiver: receiver))
            if receiver.unsupportedFrames > 0, receiver.framesReceived == receiver.unsupportedFrames {
                issues.append("\(name): formato de vídeo NDI não suportado (\(receiver.fourCC))")
            }
        }
        s.ndiSources.sort { $0.layerName < $1.layerName }
        s.ndiOutput = ndiOutput?.currentStats
        s.issues = issues.sorted()
        return s
    }

    // MARK: Internos

    private static let textureOptions: [MTKTextureLoader.Option: Any] = [
        .SRGB: false,
        .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
        .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
    ]

    private func makeTargets(for profile: CompositionProfile) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat, width: profile.width, height: profile.height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        var made: [MTLTexture] = []
        for _ in 0..<3 {
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw CompositionEngineError.setupFailed("textura \(profile.width)×\(profile.height)")
            }
            made.append(texture)
        }
        lock.lock()
        targets = made
        nextTarget = 0
        lock.unlock()
    }

    private func loadImage(_ asset: MediaAsset) {
        guard !imageLoadsInProgress.contains(asset.id) else { return }
        imageLoadsInProgress.insert(asset.id)
        let maxPixel = max(currentProfile.width, currentProfile.height)
        let loader = textureLoader
        let options = Self.textureOptions
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<MTLTexture, Error> = Result {
                let image = try ThumbnailGenerator.downsampledImage(at: asset.url, maxPixelSize: maxPixel)
                return try loader.newTexture(cgImage: image, options: options)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.imageLoadsInProgress.remove(asset.id)
                self.lock.lock()
                let stillNeeded = self.program?.layers.contains { $0.content.mediaAssetID == asset.id } ?? false
                switch result {
                case .success(let texture) where stillNeeded:
                    self.imageTextures[asset.id] = texture
                case .failure(let error):
                    self.log.error("Imagem \(asset.name) não carregou: \(error)", code: "E-COMPOSITION-IMAGE")
                    for layer in self.program?.layers ?? [] where layer.content.mediaAssetID == asset.id {
                        self.mediaIssues[layer.id] = "\(layer.name): imagem não pôde ser lida"
                    }
                default:
                    break
                }
                self.lock.unlock()
            }
        }
    }

    /// Executado na `renderQueue` a cada tique do relógio de composição.
    private func renderFrame() {
        lock.lock()
        guard !targets.isEmpty else { lock.unlock(); return }
        // GPU atrasada: descarta este quadro em vez de acumular fila.
        if inFlight >= 2 {
            stats.droppedFrames += 1
            lock.unlock()
            return
        }
        inFlight += 1
        let target = targets[nextTarget]
        nextTarget = (nextTarget + 1) % targets.count
        let scene = program
        let isBlackout = blackout
        let slide = slideTexture
        let slideBG = slideBackground
        let images = imageTextures
        let videos = videoSources
        let ndi = ndiWorkers
        let output = ndiOutput
        let fps = profile.framesPerSecond
        let canvas = profile.canvas
        lock.unlock()
        // Descarta anéis de textura de fontes que saíram do ar.
        for key in ndiTextures.keys where ndi[key] == nil { ndiTextures[key] = nil }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { finishFrame(nil, target: nil); return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            finishFrame(nil, target: nil); return
        }

        var retained: [AnyObject] = []
        if !isBlackout, let scene {
            for layer in scene.layers where layer.isVisible && layer.opacity > 0 {
                switch layer.content {
                case .solid(let color):
                    if let quad = LayerLayout.quad(for: layer, sourceSize: canvas, canvas: canvas) {
                        renderer.draw(encoder, texture: renderer.whiteTexture, quad: quad, canvas: canvas,
                                      tint: QuadRenderer.tint(color, opacity: layer.opacity))
                    }
                case .image(let assetID):
                    if let texture = images[assetID] {
                        draw(texture, layer: layer, encoder: encoder, canvas: canvas)
                    }
                case .video:
                    if let frame = videos[layer.id]?.currentTexture() {
                        retained.append(frame.owner)
                        draw(frame.texture, layer: layer, encoder: encoder, canvas: canvas)
                    }
                case .presentation(let drawsBackground):
                    if drawsBackground, let slideBG {
                        var bgLayer = layer
                        bgLayer.fitMode = .stretch
                        bgLayer.crop = .none
                        if let quad = LayerLayout.quad(for: bgLayer, sourceSize: canvas, canvas: canvas) {
                            renderer.draw(encoder, texture: renderer.whiteTexture, quad: quad, canvas: canvas,
                                          tint: QuadRenderer.tint(slideBG, opacity: layer.opacity))
                        }
                    }
                    if let slide {
                        draw(slide, layer: layer, encoder: encoder, canvas: canvas)
                    }
                case .ndi:
                    if let worker = ndi[layer.id], let source = ndiTexture(for: layer.id, worker: worker) {
                        draw(source.0, layer: layer, encoder: encoder, canvas: canvas, ignoresAlpha: source.1)
                    }
                }
            }
        }
        encoder.endEncoding()
        if let output {
            encodeNDIReadback(commandBuffer, target: target, sender: output, fps: fps)
        }

        // Mantém os quadros de vídeo vivos até a GPU terminar de lê-los.
        let retainedFrames = retained
        commandBuffer.addCompletedHandler { [weak self] buffer in
            _ = retainedFrames
            let gpu = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            self?.finishFrame(buffer.status == .completed ? gpu : nil, target: buffer.status == .completed ? target : nil)
        }
        commandBuffer.commit()
    }

    private func draw(_ texture: MTLTexture, layer: Layer, encoder: MTLRenderCommandEncoder, canvas: CanvasSize,
                      ignoresAlpha: Bool = false) {
        let size = CanvasSize(width: Double(texture.width), height: Double(texture.height))
        guard let quad = LayerLayout.quad(for: layer, sourceSize: size, canvas: canvas) else { return }
        renderer.draw(encoder, texture: texture, quad: quad, canvas: canvas,
                      tint: QuadRenderer.tint(opacity: layer.opacity), ignoresAlpha: ignoresAlpha)
    }

    private func finishFrame(_ gpuMs: Double?, target: MTLTexture?) {
        let now = CACurrentMediaTime()
        lock.lock()
        inFlight -= 1
        if let target {
            latest = target
            stats.renderedFrames += 1
            frameTimestamps.append(now)
            frameTimestamps.removeAll { now - $0 > 1 }
            stats.measuredFPS = Double(frameTimestamps.count)
        }
        if let gpuMs, gpuMs.isFinite, gpuMs >= 0 {
            gpuTimes.append(gpuMs)
            if gpuTimes.count > 60 { gpuTimes.removeFirst(gpuTimes.count - 60) }
            stats.averageGPUTimeMs = gpuTimes.reduce(0, +) / Double(gpuTimes.count)
        }
        lock.unlock()
    }
}
