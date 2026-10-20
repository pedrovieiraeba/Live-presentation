import CompositionCore
import CompositionEngine
import PresentationCore
import SwiftUI

/// Prévia (em preparação) e Programa (no ar), controles de transporte e
/// escolha da saída.
struct ControlPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                monitor(title: "PRÉVIA", tint: .blue, text: previewText, theme: previewTheme,
                        caption: previewCaption, showsSafeArea: true)

                transport

                if let engine = model.engine {
                    programMonitor(engine: engine)
                } else {
                    monitor(title: "NO AR", tint: .red, text: liveText, theme: liveTheme,
                            caption: liveCaption, showsSafeArea: false)
                }

                liveWarnings

                if let notes = liveNotes, !notes.isEmpty {
                    GroupBox("Notas do slide no ar") {
                        Text(notes).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                CompositionControls(scenes: model.scenes)

                OutputTargetPicker(output: model.output)
            }
            .padding(14)
        }
    }

    // MARK: Monitores

    private func monitor(title: String, tint: Color, text: String?, theme: Theme?, caption: String,
                         showsSafeArea: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.heavy))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tint, in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white)
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            SlideCanvasView(text: text, theme: theme, showsSafeArea: showsSafeArea)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(tint, lineWidth: 2))
        }
    }

    /// Monitor de programa: a textura real do motor, idêntica à saída.
    private func programMonitor(engine: CompositionEngine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("NO AR")
                    .font(.caption.weight(.heavy))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white)
                Text(liveCaption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            MetalOutputView(engine: engine, framesPerSecond: 15)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.red, lineWidth: 2))
        }
    }

    private var transport: some View {
        VStack(spacing: 8) {
            Button {
                model.take()
            } label: {
                Label("Enviar ao ar", systemImage: "play.rectangle.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(model.showState?.preview == nil)
            .help("Envia a prévia ao ar (⌘↩ ou ↩ na grade)")

            HStack {
                Button { model.previous() } label: {
                    Label("Anterior", systemImage: "backward.fill").frame(maxWidth: .infinity)
                }
                .help("Slide anterior (Page Up, ← na grade)")
                Button { model.next() } label: {
                    Label("Próximo", systemImage: "forward.fill").frame(maxWidth: .infinity)
                }
                .help("Próximo slide (Page Down, → ou espaço na grade)")
            }
            .controlSize(.large)

            HStack {
                Toggle(isOn: Binding(get: { model.showState?.textHidden ?? false },
                                     set: { _ in model.toggleTextHidden() })) {
                    Label("Ocultar texto", systemImage: "textformat.size.smaller")
                }
                .toggleStyle(.button)
                .help("Mantém o fundo e oculta o texto (⇧⌘T)")

                Toggle(isOn: Binding(get: { model.showState?.blackout ?? false },
                                     set: { _ in model.toggleBlackout() })) {
                    Label("Tela preta", systemImage: "rectangle.fill")
                }
                .toggleStyle(.button)
                .help("Saída totalmente preta (⇧⌘B)")

                Spacer()

                Button(role: .destructive) { model.clearAll() } label: {
                    Label("Limpar", systemImage: "xmark.rectangle")
                }
                .help("Tira tudo do ar (⇧⌘L)")
            }
        }
    }

    @ViewBuilder
    private var liveWarnings: some View {
        if let show = model.show, show.state.live != nil {
            if !show.liveBelongsToOpenPresentation {
                warning("O slide no ar é de outra apresentação ou foi removido. Próximo/Anterior estão bloqueados até você enviar um slide desta apresentação.")
            } else if show.liveIsStale {
                HStack {
                    warning("O slide no ar foi editado. O público ainda vê a versão anterior.")
                    Button("Atualizar no ar") { model.refreshLive() }
                }
            }
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Dados

    private var previewText: String? {
        guard let show = model.show, let address = show.state.preview else { return nil }
        return show.presentation.slide(at: address)?.text
    }

    private var previewTheme: Theme? {
        guard let show = model.show, let address = show.state.preview else { return nil }
        return model.theme(id: show.presentation.themeID(for: address))
    }

    private var previewCaption: String {
        guard let show = model.show, let position = show.previewPosition else { return "nada selecionado" }
        return "slide \(position + 1) de \(show.presentation.slideCount)"
    }

    private var liveText: String? {
        if case let .slide(text, _) = model.show?.output { return text }
        return nil
    }

    private var liveTheme: Theme? {
        switch model.show?.output {
        case let .slide(_, id), let .background(id): return model.theme(id: id)
        default: return nil
        }
    }

    private var liveCaption: String {
        guard let state = model.showState else { return "" }
        if state.blackout { return "tela preta" }
        guard let live = state.live else { return "nada no ar" }
        var parts: [String] = []
        if let position = model.show?.livePosition { parts.append("slide \(position + 1)") }
        if !live.label.isEmpty { parts.append(live.label) }
        if state.textHidden { parts.append("texto oculto") }
        return parts.joined(separator: " · ")
    }

    private var liveNotes: String? {
        guard let show = model.show, let live = show.state.live else { return nil }
        return show.presentation.slide(at: live.address)?.notes
    }
}

private struct OutputTargetPicker: View {
    @ObservedObject var output: OutputWindowController

    var body: some View {
        GroupBox("Saída de apresentação") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Destino:")
                    Text(output.target?.displayName ?? "fechada").bold()
                    Spacer()
                    if output.isOpen {
                        Button("Fechar saída") { output.close() }
                    }
                }
                Button("Abrir em janela") { output.show(.window) }
                ForEach(output.screens) { screen in
                    Button {
                        output.show(.screen(screen))
                    } label: {
                        Text("Tela cheia em \(screen.name) (\(screen.resolutionLabel))")
                    }
                    .disabled(screen.isPrimary)
                    .help(screen.isPrimary
                          ? "A tela principal é reservada aos controles do operador."
                          : "Saída sem bordas nesta tela")
                }
                if output.screens.count < 2 {
                    Text("Conecte um segundo monitor ou projetor para saída em tela cheia.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Cena no ar e resolução da composição.
private struct CompositionControls: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var scenes: SceneModel

    var body: some View {
        GroupBox("Composição") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Cena no ar", selection: Binding(
                    get: { scenes.program?.id },
                    set: { id in if let id { scenes.take(sceneID: id) } })) {
                    ForEach(scenes.scenes) { Text($0.name).tag(UUID?.some($0.id)) }
                    if let program = scenes.program, scenes.controller.scene(id: program.id) == nil {
                        Text("\(program.name) (apagada)").tag(UUID?.some(program.id))
                    }
                }
                if scenes.controller.programIsStale {
                    HStack {
                        Label("A cena no ar foi editada.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Atualizar no ar") { scenes.refreshProgram() }
                    }
                }
                Picker("Resolução", selection: Binding(
                    get: { model.profile },
                    set: { model.setProfile($0) })) {
                    ForEach(CompositionProfile.builtIn) { Text($0.name).tag($0) }
                }
                .disabled(model.engine == nil)
                if model.profile.status == .experimental {
                    Text("4K ainda não foi validado no Mac mini M4 com o Logic aberto. Use em ensaio, não em culto.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let engine = model.engine {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let issues = engine.currentStats().issues
                        if !issues.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(issues, id: \.self) { issue in
                                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
