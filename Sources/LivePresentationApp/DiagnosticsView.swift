import Darwin
import Diagnostics
import SwiftUI

/// Painel local de diagnóstico: logs recentes (já redigidos) e uso de memória.
/// Nada é enviado para fora da máquina.
struct DiagnosticsView: View {
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
