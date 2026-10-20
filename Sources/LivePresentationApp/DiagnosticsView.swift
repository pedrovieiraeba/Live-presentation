import CompositionEngine
import Darwin
import Diagnostics
import SwiftUI

/// Painel local de diagnóstico: logs recentes (já redigidos) e uso de memória.
/// Nada é enviado para fora da máquina.
struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var minimumLevel: LogLevel = .info

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 20) {
                    Label("Sessão \(DiagnosticsSession.id)", systemImage: "number")
                    Label("Memória residente: \(Self.residentMemoryDescription())", systemImage: "memorychip")
                        .help("Aproximação via task_info; para medições precisas use Instruments.")
                    Spacer()
                    Picker("Nível mínimo", selection: $minimumLevel) {
                        ForEach(LogLevel.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .frame(width: 200)
                    Button("Limpar") { LogBuffer.shared.clear() }
                }
                compositionStats
                Table(Array(LogBuffer.shared.entries(minimumLevel: minimumLevel).reversed())) {
                    TableColumn("Hora") { entry in
                        Text(entry.date.formatted(date: .omitted, time: .standard)).monospacedDigit()
                    }
                    .width(80)
                    TableColumn("Nível") { entry in Text(entry.level.label) }
                        .width(60)
                    TableColumn("Categoria") { entry in Text(entry.category) }
                        .width(90)
                    TableColumn("Código") { entry in Text(entry.code ?? "") }
                        .width(140)
                    TableColumn("Mensagem") { entry in Text(entry.message).textSelection(.enabled) }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var compositionStats: some View {
        if let engine = model.engine {
            let stats = engine.currentStats()
            HStack(spacing: 18) {
                Label("\(stats.profileName)", systemImage: "square.3.layers.3d")
                Text("Quadros/s: \(String(format: "%.0f", stats.measuredFPS))/\(stats.targetFPS)")
                Text("Descartados: \(stats.droppedFrames)")
                Text("GPU: \(String(format: "%.2f", stats.averageGPUTimeMs)) ms")
                Text("Vídeos ativos: \(stats.activeVideoLayers)")
                Text("Texturas ≈ \(ByteCountFormatter.string(fromByteCount: Int64(stats.estimatedTextureMemoryBytes), countStyle: .memory))")
                Text("Miniaturas ≈ \(ByteCountFormatter.string(fromByteCount: Int64(model.media.thumbnailCacheBytes), countStyle: .memory))")
            }
            .font(.caption.monospacedDigit())
            ForEach(stats.ndiSources) { source in
                let r = source.receiver
                Text("NDI ← \(source.layerName) [\(r.sourceName)]: \(r.status.label) · \(r.width)×\(r.height) \(r.fourCC) · "
                     + String(format: "%.0f/%.0f q/s", r.measuredFrameRate, r.nominalFrameRate ?? 0)
                     + " · \(r.framesReceived) quadros · \(r.receiverCreations) receptor(es)")
                    .font(.caption.monospacedDigit())
            }
            if let output = stats.ndiOutput {
                Text("NDI → \(output.name): \(output.connections) conexão(ões) · \(output.framesSent) enviados · \(output.framesDropped) descartados")
                    .font(.caption.monospacedDigit())
            }
        } else {
            Label("Motor de composição indisponível (sem Metal)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    static func residentMemoryDescription() -> String {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "indisponível" }
        return ByteCountFormatter.string(fromByteCount: Int64(info.resident_size), countStyle: .memory)
    }
}
