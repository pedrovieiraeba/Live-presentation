import PresentationCore
import SwiftUI

/// Janela do operador: biblioteca | área de trabalho | prévia e ar.
struct OperatorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                LibrarySidebar()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            } content: {
                ContentArea()
                    .navigationSplitViewColumnWidth(min: 520, ideal: 700)
            } detail: {
                ControlPanel()
                    .frame(minWidth: 360)
            }
            Divider()
            StatusBar()
        }
        .alert("Atenção", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

// MARK: Abas de conteúdo

enum ContentTab: String, CaseIterable, Identifiable {
    case presentation = "Apresentação"
    case media = "Mídia"
    case scenes = "Cenas"
    var id: String { rawValue }
}

struct ContentArea: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("contentTab") private var tab: ContentTab = .presentation

    var body: some View {
        VStack(spacing: 0) {
            Picker("Área", selection: $tab) {
                ForEach(ContentTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            .padding(8)
            Divider()
            switch tab {
            case .presentation: WorkspaceView()
            case .media: MediaLibraryView(media: model.media, scenes: model.scenes)
            case .scenes: ScenesView(scenes: model.scenes, media: model.media)
            }
        }
    }
}

// MARK: Biblioteca

struct LibrarySidebar: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingDeletion: PresentationSummary?
    @State private var filter = ""

    var body: some View {
        List(selection: Binding(
            get: { model.openPresentationID },
            set: { id in if let id { Task { await model.openPresentation(id: id) } } }
        )) {
            Section("Biblioteca") {
                ForEach(filtered) { summary in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.name).lineLimit(1)
                        Text("\(summary.slideCount) slides · \(summary.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(summary.id)
                    .contextMenu {
                        Button("Duplicar") { Task { await model.duplicatePresentation(id: summary.id) } }
                        Divider()
                        Button("Apagar…", role: .destructive) { pendingDeletion = summary }
                    }
                }
            }
        }
        .searchable(text: $filter, placement: .sidebar, prompt: "Buscar")
        .toolbar {
            ToolbarItem {
                Button { Task { await model.createPresentation() } } label: {
                    Label("Nova apresentação", systemImage: "plus")
                }
                .help("Nova apresentação (⇧⌘N)")
            }
        }
        .confirmationDialog(
            "Apagar \"\(pendingDeletion?.name ?? "")\"?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Apagar", role: .destructive) {
                if let target = pendingDeletion { Task { await model.deletePresentation(id: target.id) } }
                pendingDeletion = nil
            }
        } message: {
            Text("A apresentação será removida da biblioteca. Esta ação não pode ser desfeita.")
        }
    }

    private var filtered: [PresentationSummary] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.summaries }
        return model.summaries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

// MARK: Barra de estado

struct StatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // O controlador de saída é observado diretamente para refletir
        // mudanças de tela sem depender de republicação do AppModel.
        StatusBarContent(output: model.output)
    }
}

private struct StatusBarContent: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var output: OutputWindowController

    var body: some View {
        HStack(spacing: 18) {
            indicator(icon: output.isOpen ? "display" : "display.trianglebadge.exclamationmark",
                      title: "Saída", value: output.target?.displayName ?? "fechada",
                      state: output.isOpen ? .ok : .warning)
            indicator(icon: "square.3.layers.3d", title: "Composição",
                      value: model.engine == nil
                        ? "sem Metal — saída simplificada"
                        : "\(model.profile.name) · cena \(model.scenes.program?.name ?? "-")",
                      state: model.engine == nil ? .warning : (model.profile.status == .experimental ? .warning : .ok))
            indicator(icon: "dot.radiowaves.left.and.right", title: "NDI", value: "não implementado (fase 3)",
                      state: .unavailable)
            indicator(icon: "waveform", title: "Áudio", value: "não implementado (fase 4)", state: .unavailable)
            indicator(icon: "antenna.radiowaves.left.and.right", title: "YouTube",
                      value: "não implementado (fase 4)", state: .unavailable)
            Spacer()
            saveIndicator
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private enum IndicatorState { case ok, warning, error, unavailable }

    private func indicator(icon: String, title: String, value: String, state: IndicatorState) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(color(for: state))
            Text("\(title):").bold()
            Text(value).foregroundStyle(state == .unavailable ? .secondary : .primary)
        }
        .accessibilityElement(children: .combine)
    }

    private func color(for state: IndicatorState) -> Color {
        switch state {
        case .ok: return .green
        case .warning: return .orange
        case .error: return .red
        case .unavailable: return .secondary
        }
    }

    @ViewBuilder
    private var saveIndicator: some View {
        switch model.saveStatus {
        case .saved:
            Label("Salvo", systemImage: "checkmark.circle")
        case .pending:
            Label("Salvando…", systemImage: "clock")
        case .failed(let message):
            Label("Erro ao salvar", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(message)
        case .volatile:
            Label("Biblioteca temporária — nada é salvo", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
