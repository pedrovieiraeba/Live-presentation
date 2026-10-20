import CompositionCore
import MediaLibrary
import PresentationCore
import SwiftUI

/// Cenas e camadas: lista de cenas, prévia aproximada, camadas e inspetor.
struct ScenesView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var scenes: SceneModel
    @ObservedObject var media: MediaModel
    @State private var pendingDeletion: CompositionScene?

    var body: some View {
        HSplitView {
            sceneList
                .frame(minWidth: 170, idealWidth: 200, maxWidth: 260)
            if let scene = scenes.selectedScene {
                VStack(alignment: .leading, spacing: 10) {
                    header(scene)
                    ScenePreviewView(scene: scene, media: media)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxHeight: 300)
                    HSplitView {
                        LayerList(scene: scene, scenes: scenes, media: media)
                            .frame(minWidth: 220, idealWidth: 260)
                        LayerInspector(scene: scene, scenes: scenes, media: media)
                            .frame(minWidth: 260)
                    }
                }
                .padding(12)
            } else {
                ContentUnavailableView("Selecione uma cena", systemImage: "square.3.layers.3d")
            }
        }
        .confirmationDialog(
            "Apagar a cena \"\(pendingDeletion?.name ?? "")\"?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Apagar", role: .destructive) {
                if let scene = pendingDeletion { scenes.remove(sceneID: scene.id) }
                pendingDeletion = nil
            }
        } message: {
            Text("Se esta cena estiver no ar, a saída continua até você enviar outra cena.")
        }
    }

    private var sceneList: some View {
        List(selection: Binding(get: { scenes.controller.selectedSceneID },
                                set: { scenes.select(sceneID: $0) })) {
            ForEach(scenes.scenes) { scene in
                HStack {
                    Text(scene.name).lineLimit(1)
                    Spacer()
                    if scenes.program?.id == scene.id {
                        Text("NO AR")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 4)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.white)
                    }
                }
                .tag(scene.id)
                .contextMenu {
                    Button("Enviar ao ar") { scenes.take(sceneID: scene.id) }
                    Button("Duplicar") { scenes.duplicate(sceneID: scene.id) }
                    Divider()
                    Button("Apagar…", role: .destructive) { pendingDeletion = scene }
                        .disabled(scenes.scenes.count <= 1)
                }
            }
            .onMove { scenes.moveScenes(fromOffsets: $0, toOffset: $1) }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { scenes.addScene() } label: { Label("Nova cena", systemImage: "plus") }
                Spacer()
            }
            .padding(8)
        }
    }

    private func header(_ scene: CompositionScene) -> some View {
        HStack(spacing: 10) {
            TextField("Nome da cena", text: Binding(
                get: { scene.name },
                set: { name in scenes.edit(sceneID: scene.id) { $0.name = name } }))
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
            Spacer()
            if scenes.program?.id == scene.id {
                if scenes.controller.programIsStale {
                    Label("Editada — o público vê a versão anterior", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Atualizar no ar") { scenes.refreshProgram() }
                } else {
                    Label("No ar", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.red)
                }
            } else {
                Button { scenes.take(sceneID: scene.id) } label: {
                    Label("Enviar cena ao ar", systemImage: "play.rectangle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
    }
}

// MARK: Prévia

/// Prévia leve da cena com miniaturas (vídeos não são decodificados aqui). A
/// imagem exata do que vai ao ar é a do monitor "No ar".
struct ScenePreviewView: View {
    @EnvironmentObject private var model: AppModel
    let scene: CompositionScene
    @ObservedObject var media: MediaModel

    var body: some View {
        GeometryReader { geo in
            let canvas = CanvasSize(width: geo.size.width, height: geo.size.height)
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(scene.layers) { layer in
                    layerView(layer, canvas: canvas)
                }
            }
            .clipped()
        }
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.secondary.opacity(0.5)))
    }

    @ViewBuilder
    private func layerView(_ layer: Layer, canvas: CanvasSize) -> some View {
        switch layer.content {
        case .solid(let color):
            placed(layer, source: canvas, canvas: canvas) { color.swiftUIColor }
        case .image(let id), .video(let id, _, _):
            if let asset = media.assetsByID[id] {
                let source = CanvasSize(width: Double(asset.pixelWidth ?? 1920), height: Double(asset.pixelHeight ?? 1080))
                placed(layer, source: source, canvas: canvas) {
                    if let image = media.thumbnail(for: asset) {
                        Image(decorative: image, scale: 1).resizable()
                    } else {
                        Color.gray.opacity(0.3)
                            .overlay(Image(systemName: asset.kind == .video ? "film" : "photo").foregroundStyle(.secondary))
                    }
                }
            }
        case .presentation(let drawsBackground):
            let text = previewSlideText
            placed(layer, source: canvas, canvas: canvas) {
                SlideContentView(text: text ?? "Texto do slide", theme: previewTheme,
                                 drawsBackground: drawsBackground)
                    .scaleEffect(canvas.width / Theme.referenceCanvas.width, anchor: .topLeading)
                    .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
                    .opacity(text == nil ? 0.5 : 1)
            }
        }
    }

    /// Posiciona `content` segundo a geometria da camada (a mesma do motor).
    @ViewBuilder
    private func placed<Content: View>(_ layer: Layer, source: CanvasSize, canvas: CanvasSize,
                                       @ViewBuilder content: () -> Content) -> some View {
        if let quad = LayerLayout.quad(for: layer, sourceSize: source, canvas: canvas) {
            let fullW = quad.destination.width / quad.source.width
            let fullH = quad.destination.height / quad.source.height
            content()
                .frame(width: fullW, height: fullH)
                .offset(x: -quad.source.x * fullW, y: -quad.source.y * fullH)
                .frame(width: quad.destination.width, height: quad.destination.height, alignment: .topLeading)
                .clipped()
                .opacity(quad.opacity)
                .offset(x: quad.destination.x, y: quad.destination.y)
        }
    }

    private var previewSlideText: String? {
        guard let show = model.show else { return nil }
        if case let .slide(text, _) = show.output { return text }
        if let preview = show.state.preview { return show.presentation.slide(at: preview)?.text }
        return nil
    }

    private var previewTheme: Theme {
        guard let show = model.show else { return .standardLyrics }
        if case let .slide(_, id) = show.output { return model.theme(id: id) }
        if let preview = show.state.preview { return model.theme(id: show.presentation.themeID(for: preview)) }
        return model.theme(id: show.presentation.defaultThemeID)
    }
}

// MARK: Camadas

private struct LayerList: View {
    let scene: CompositionScene
    @ObservedObject var scenes: SceneModel
    @ObservedObject var media: MediaModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Camadas").font(.headline)
                Spacer()
                Menu {
                    Button("Cor sólida") { scenes.addLayer(.solid(.black)) }
                    Button("Apresentação (slide)") { scenes.addLayer(.presentation(drawsThemeBackground: false)) }
                    Menu("Imagem") {
                        ForEach(media.assets.filter { $0.kind == .image && $0.availability == .available }) { asset in
                            Button(asset.name) { scenes.addLayer(.image(assetID: asset.id), name: asset.name) }
                        }
                    }
                    Menu("Vídeo") {
                        ForEach(media.assets.filter { $0.kind == .video && $0.availability == .available }) { asset in
                            Button(asset.name) {
                                scenes.addLayer(.video(assetID: asset.id, loop: true, muted: true), name: asset.name)
                            }
                        }
                    }
                } label: {
                    Label("Adicionar", systemImage: "plus")
                }
                .fixedSize()
            }
            // Exibida de cima (frente) para baixo (fundo), como em editores gráficos.
            List(selection: $scenes.selectedLayerID) {
                ForEach(Array(scene.layers.reversed())) { layer in
                    HStack {
                        Button {
                            scenes.editLayer(layer.id) { $0.isVisible.toggle() }
                        } label: {
                            Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                        }
                        .buttonStyle(.borderless)
                        .help(layer.isVisible ? "Ocultar camada" : "Mostrar camada")
                        Text(layer.name).lineLimit(1).foregroundStyle(layer.isVisible ? .primary : .secondary)
                        Spacer()
                        if let id = layer.content.mediaAssetID, media.assetsByID[id]?.availability != .available {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("Mídia ausente ou removida")
                        }
                    }
                    .tag(layer.id)
                    .contextMenu {
                        Button("Trazer para frente") { scenes.moveLayer(layer.id, by: 1) }
                        Button("Enviar para trás") { scenes.moveLayer(layer.id, by: -1) }
                        Divider()
                        Button("Remover camada", role: .destructive) { scenes.removeLayer(layer.id) }
                    }
                }
            }
        }
    }
}

private struct LayerInspector: View {
    let scene: CompositionScene
    @ObservedObject var scenes: SceneModel
    @ObservedObject var media: MediaModel

    var body: some View {
        if let id = scenes.selectedLayerID, let layer = scene.layer(id: id) {
            Form {
                TextField("Nome", text: bind(layer, \.name))
                LabeledContent("Tipo", value: layer.content.displayName)
                contentControls(layer)
                Section("Aparência") {
                    slider("Opacidade", bind(layer, \.opacity), 0...1, percent: true)
                    Picker("Ajuste", selection: bind(layer, \.fitMode)) {
                        ForEach(FitMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                Section("Posição e escala") {
                    slider("Centro X", bind(layer, \.transform.centerX), 0...1, percent: true)
                    slider("Centro Y", bind(layer, \.transform.centerY), 0...1, percent: true)
                    slider("Escala", bind(layer, \.transform.scale), 0.05...3, percent: true)
                    Button("Redefinir posição") { scenes.editLayer(id) { $0.transform = .identity } }
                }
                Section("Recorte") {
                    slider("Superior", bind(layer, \.crop.top), 0...0.45, percent: true)
                    slider("Inferior", bind(layer, \.crop.bottom), 0...0.45, percent: true)
                    slider("Esquerda", bind(layer, \.crop.left), 0...0.45, percent: true)
                    slider("Direita", bind(layer, \.crop.right), 0...0.45, percent: true)
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Selecione uma camada", systemImage: "slider.horizontal.3")
        }
    }

    @ViewBuilder
    private func contentControls(_ layer: Layer) -> some View {
        switch layer.content {
        case .solid(let color):
            ColorPicker("Cor", selection: Binding(
                get: { color.swiftUIColor },
                set: { new in scenes.editLayer(layer.id) { $0.content = .solid(RGBAColor(new)) } }))
        case let .video(assetID, loop, muted):
            Toggle("Repetir (loop)", isOn: Binding(
                get: { loop },
                set: { new in scenes.editLayer(layer.id) { $0.content = .video(assetID: assetID, loop: new, muted: muted) } }))
            Toggle("Sem som", isOn: Binding(
                get: { muted },
                set: { new in scenes.editLayer(layer.id) { $0.content = .video(assetID: assetID, loop: loop, muted: new) } }))
            if !muted {
                Text("O áudio do vídeo sai pelo dispositivo padrão do sistema, não pelo Logic. Use com cuidado.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            assetInfo(assetID)
        case .image(let assetID):
            assetInfo(assetID)
        case .presentation(let drawsBackground):
            Toggle("Desenhar fundo do tema", isOn: Binding(
                get: { drawsBackground },
                set: { new in scenes.editLayer(layer.id) { $0.content = .presentation(drawsThemeBackground: new) } }))
        }
    }

    @ViewBuilder
    private func assetInfo(_ assetID: UUID) -> some View {
        if let asset = media.assetsByID[assetID] {
            LabeledContent("Arquivo", value: asset.name)
            LabeledContent("Detalhes", value: asset.summary)
            if asset.availability != .available {
                Label("Arquivo \(asset.availability == .missing ? "ausente" : "incompatível") — a camada não aparece na saída",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } else {
            Label("Mídia removida da biblioteca", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func bind<T>(_ layer: Layer, _ keyPath: WritableKeyPath<Layer, T>) -> Binding<T> {
        Binding(get: { layer[keyPath: keyPath] },
                set: { value in scenes.editLayer(layer.id) { $0[keyPath: keyPath] = value } })
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        percent: Bool) -> some View {
        HStack {
            Slider(value: value, in: range) { Text(title) }
            Text(percent ? "\(Int((value.wrappedValue * 100).rounded()))%" : String(format: "%.2f", value.wrappedValue))
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
    }
}
