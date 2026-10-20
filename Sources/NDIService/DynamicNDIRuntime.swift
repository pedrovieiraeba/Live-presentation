import CNDI
import Diagnostics
import Foundation

/// Runtime NDI real: carrega a biblioteca do SDK instalado pelo usuário.
public final class DynamicNDIRuntime: NDIRuntime, @unchecked Sendable {
    private var lib: cndi_lib
    public let version: String
    public let libraryPath: String
    private static let log = AppLogger(category: "ndi")

    /// Caminhos procurados, em ordem. `LIVEPRESENTATION_NDI_LIB` tem prioridade.
    /// Os caminhos padrão do SDK são a melhor informação disponível e devem ser
    /// conferidos com a instalação real (ver docs/decisions/0006).
    public static var defaultSearchPaths: [String] {
        var paths: [String] = []
        let env = ProcessInfo.processInfo.environment
        if let custom = env["LIVEPRESENTATION_NDI_LIB"] { paths.append(custom) }
        for key in ["NDI_RUNTIME_DIR_V6", "NDI_RUNTIME_DIR_V5"] {
            if let dir = env[key] {
                #if os(macOS)
                paths.append((dir as NSString).appendingPathComponent("libndi.dylib"))
                #else
                paths.append((dir as NSString).appendingPathComponent("libndi.so"))
                #endif
            }
        }
        #if os(macOS)
        paths += [
            "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
            "/usr/local/lib/libndi.dylib",
        ]
        #else
        paths += ["libndi.so.6", "libndi.so.5", "/usr/lib/libndi.so", "/usr/local/lib/libndi.so"]
        #endif
        return paths
    }

    /// Procura e carrega a biblioteca. Nunca lança por ausência do SDK de forma
    /// silenciosa: o erro descreve onde foi procurado.
    public static func load(searchPaths: [String] = defaultSearchPaths) -> Result<DynamicNDIRuntime, NDIError> {
        var lastError: String?
        for path in searchPaths {
            // Caminho absoluto inexistente: pula sem tentar dlopen.
            if path.hasPrefix("/"), !FileManager.default.fileExists(atPath: path) { continue }
            var lib = cndi_lib()
            var buffer = [CChar](repeating: 0, count: 512)
            let rc = cndi_load(path, &lib, &buffer, buffer.count)
            if rc != 0 {
                lastError = String(cString: buffer)
                continue
            }
            guard lib.initialize!() else {
                cndi_unload(&lib)
                return .failure(.unsupportedCPU)
            }
            let version = lib.version!().map { String(cString: $0) } ?? "desconhecida"
            log.notice("NDI carregado de \(path) — versão \(version)")
            return .success(DynamicNDIRuntime(lib: lib, version: version, path: path))
        }
        if let lastError { return .failure(.libraryLoadFailed(lastError)) }
        return .failure(.libraryNotFound(searched: searchPaths))
    }

    private init(lib: cndi_lib, version: String, path: String) {
        self.lib = lib
        self.version = version
        self.libraryPath = path
    }

    deinit {
        lib.destroy!()
        cndi_unload(&lib)
    }

    public func makeFinder() throws -> NDIFinder {
        var settings = cndi_find_create_t(show_local_sources: true, p_groups: nil, p_extra_ips: nil)
        guard let instance = lib.find_create_v2!(&settings) else { throw NDIError.creationFailed("buscador") }
        return Finder(runtime: self, instance: instance)
    }

    public func makeReceiver(sourceName: String, receiverName: String) throws -> NDIReceiver {
        let instance: UnsafeMutableRawPointer? = sourceName.withCString { namePtr in
            receiverName.withCString { recvPtr in
                var settings = cndi_recv_create_v3_t(
                    source_to_connect_to: cndi_source_t(p_ndi_name: namePtr, p_url_address: nil),
                    color_format: Int32(CNDI_RECV_COLOR_FORMAT_BGRX_BGRA),
                    bandwidth: Int32(CNDI_RECV_BANDWIDTH_HIGHEST),
                    allow_video_fields: false,
                    p_ndi_recv_name: recvPtr)
                return lib.recv_create_v3!(&settings)
            }
        }
        guard let instance else { throw NDIError.creationFailed("receptor") }
        return Receiver(runtime: self, instance: instance)
    }

    public func makeSender(name: String) throws -> NDISender {
        let instance: UnsafeMutableRawPointer? = name.withCString { namePtr in
            var settings = cndi_send_create_t(p_ndi_name: namePtr, p_groups: nil,
                                              clock_video: false, clock_audio: false)
            return lib.send_create!(&settings)
        }
        guard let instance else { throw NDIError.creationFailed("emissor") }
        return Sender(runtime: self, instance: instance)
    }

    // MARK: Instâncias

    private final class Finder: NDIFinder {
        let runtime: DynamicNDIRuntime
        let instance: UnsafeMutableRawPointer

        init(runtime: DynamicNDIRuntime, instance: UnsafeMutableRawPointer) {
            self.runtime = runtime
            self.instance = instance
        }

        deinit { runtime.lib.find_destroy!(instance) }

        func currentSources() -> [NDISourceInfo] {
            var count: UInt32 = 0
            guard let list = runtime.lib.find_get_current_sources!(instance, &count), count > 0 else { return [] }
            return (0..<Int(count)).compactMap { index in
                let source = list[index]
                guard let name = source.p_ndi_name else { return nil }
                return NDISourceInfo(name: String(cString: name),
                                     address: source.p_url_address.map { String(cString: $0) })
            }
        }
    }

    private final class Receiver: NDIReceiver {
        let runtime: DynamicNDIRuntime
        let instance: UnsafeMutableRawPointer

        init(runtime: DynamicNDIRuntime, instance: UnsafeMutableRawPointer) {
            self.runtime = runtime
            self.instance = instance
        }

        deinit { runtime.lib.recv_destroy!(instance) }

        func capture(timeoutMs: UInt32) -> NDICaptureEvent {
            var frame = cndi_video_frame_v2_t()
            let type = runtime.lib.recv_capture_v2!(instance, &frame, nil, nil, timeoutMs)
            switch type {
            case Int32(CNDI_FRAME_TYPE_VIDEO):
                guard let data = frame.p_data else {
                    runtime.lib.recv_free_video_v2!(instance, &frame)
                    return .error
                }
                let rate = frame.frame_rate_D > 0 ? Double(frame.frame_rate_N) / Double(frame.frame_rate_D) : nil
                let copy = frame
                // O quadro mantém o receptor vivo até ser devolvido ao SDK.
                return .video(NDIVideoFrame(
                    width: Int(frame.xres), height: Int(frame.yres),
                    bytesPerRow: Int(frame.line_stride_in_bytes), fourCC: frame.four_cc,
                    frameRate: rate, data: UnsafeRawPointer(data),
                    release: { [self] in
                        var toFree = copy
                        runtime.lib.recv_free_video_v2!(instance, &toFree)
                    }))
            case Int32(CNDI_FRAME_TYPE_STATUS_CHANGE):
                return .statusChange
            case Int32(CNDI_FRAME_TYPE_ERROR):
                return .error
            default:
                return .nothing
            }
        }
    }

    private final class Sender: NDISender {
        let runtime: DynamicNDIRuntime
        let instance: UnsafeMutableRawPointer

        init(runtime: DynamicNDIRuntime, instance: UnsafeMutableRawPointer) {
            self.runtime = runtime
            self.instance = instance
        }

        deinit { runtime.lib.send_destroy!(instance) }

        func sendBGRA(_ data: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
                      frameRateN: Int32, frameRateD: Int32) {
            var frame = cndi_video_frame_v2_t()
            frame.xres = Int32(width)
            frame.yres = Int32(height)
            frame.four_cc = NDIFourCC.bgra
            frame.frame_rate_N = frameRateN
            frame.frame_rate_D = frameRateD
            frame.picture_aspect_ratio = Float(width) / Float(max(height, 1))
            frame.frame_format_type = Int32(CNDI_FRAME_FORMAT_PROGRESSIVE)
            // INT64_MAX pede ao SDK que gere o timecode (NDIlib_send_timecode_synthesize).
            frame.timecode = Int64.max
            frame.p_data = UnsafeMutablePointer(mutating: data.assumingMemoryBound(to: UInt8.self))
            frame.line_stride_in_bytes = Int32(bytesPerRow)
            runtime.lib.send_send_video_v2!(instance, &frame)
        }

        func connectionCount() -> Int {
            Int(runtime.lib.send_get_no_connections!(instance, 0))
        }
    }
}
