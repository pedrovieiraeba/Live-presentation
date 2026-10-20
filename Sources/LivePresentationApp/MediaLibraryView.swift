import AppKit
import CompositionCore
import MediaLibrary
import SwiftUI
import UniformTypeIdentifiers

/// Biblioteca de mídia: importação, miniaturas, estado dos arquivos e relink.
struct MediaLibraryView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var media: MediaModel
    @ObservedObject var scenes: SceneModel
    @State private var filter = ""
    @State private var kindFilter: MediaKind?
    @State private var pendingRemoval: MediaAsset?

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if media.assets.isEmpty {
                ContentUnavailableView {
                    Label("Nenhuma mídia", systemImage: "photo.on.rectangle")
                } description: {
                    Text("Importe imagens e vídeos. Os arquivos ficam onde estão; a biblioteca só guarda a referência.")
                } actions: {
                    Button("Importar…") { chooseImport() }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(filtered) { asset in
                            MediaTile(asset: asset, image: media.thumbnail(for: asset),
                                      version: media.thumbnailsVersion)
                                .contextMenu { contextMenu(for: asset) }
                                .onTapGesture(count: 2) { addToSelectedScene(asset) }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .confirmationDialog(
            "Remover \"\(pendingRemoval?.name ?? "")\" da biblioteca?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remover", role: .destructive) {
                if let asset = pendingRemoval { Task { await media.remove(asset) } }
                pendingRemoval = nil
            }
        } message: {
            Text("O arquivo no disco não é apagado. Camadas que usam esta mídia ficarão sem conteúdo.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { chooseImport() } label: { Label("Importar…", systemImage: "square.and.arrow.down") }
                .disabled(media.isImporting)
            Button { Task { await media.refreshAvailability() } } label: {
                Label("Verificar arquivos", systemImage: "arrow.clockwise")
            }
            if missingCount > 0 {
                Button { chooseRelinkFolder() } label: {
                    Label("Procurar \(missingCount) ausente(s)…", systemImage: "magnifyingglass")
                }
                .help("Escolha uma pasta: arquivos com o mesmo nome (e tamanho) serão reencontrados")
            }
            Spacer()
            Picker("Tipo", selection: $kindFilter) {
                Text("Todos").tag(MediaKind?.none)
                ForEach(MediaKind.allCases, id: \.self) { Text($0.displayName).tag(MediaKind?.some($0)) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            TextField("Buscar", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
        }
        .padding(10)
        .overlay(alignment: .bottomLeading) { importStatus }
    }

    @ViewBuilder
    private var importStatus: some View {
        if let progress = media.importProgress {
            HStack {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                    .frame(width: 160)
                Text("Importando \(progress.completed)/\(progress.total)").font(.caption)
                Button("Cancelar") { media.cancelImport() }.controlSize(.small)
            }
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .offset(x: 10, y: 34)
        } else if let summary = media.lastImportSummary {
            Text(summary).font(.caption).foregroundStyle(.secondary).padding(.leading, 12).offset(y: 18)
        }
    }

    @ViewBuilder
    private func contextMenu(for asset: MediaAsset) -> some View {
        Button("Adicionar à cena selecionada") { addToSelectedScene(asset) }
            .disabled(asset.availability != .available || scenes.selectedScene == nil)
        if asset.availability != .available {
            Button("Localizar arquivo…") { chooseRelink(asset) }
        }
        Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([asset.url]) }
            .disabled(asset.availability == .missing)
        Divider()
        Button("Remover da biblioteca…", role: .destructive) { pendingRemoval = asset }
    }

    private var filtered: [MediaAsset] {
        media.assets.filter { asset in
            (kindFilter == nil || asset.kind == kindFilter)
                && (filter.isEmpty || asset.name.localizedCaseInsensitiveContains(filter))
        }
    }

    private var missingCount: Int { media.assets.filter { $0.availability == .missing }.count }

    private func addToSelectedScene(_ asset: MediaAsset) {
        guard asset.availability == .available else { return }
        let content: LayerContent = asset.kind == .video
            ? .video(assetID: asset.id, loop: true, muted: true)
            : .image(assetID: asset.id)
        scenes.addLayer(content, name: asset.name)
    }

    // MARK: Painéis de arquivo

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.title = "Importar mídia"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .movie]
        guard panel.runModal() == .OK else { return }
        media.importItems(panel.urls)
    }

    private func chooseRelink(_ asset: MediaAsset) {
        let panel = NSOpenPanel()
        panel.title = "Localizar \(asset.name)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = asset.kind == .video ? [.movie] : [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await media.relink(asset, to: url) }
    }

    private func chooseRelinkFolder() {
        let panel = NSOpenPanel()
        panel.title = "Procurar mídia ausente em…"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await media.relinkMissing(in: url) }
    }
}

struct MediaTile: View {
    let asset: MediaAsset
    let image: CGImage?
    /// Força redesenho quando novas miniaturas chegam.
    let version: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: asset.kind == .video ? "film" : "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
                if asset.availability != .available {
                    Color.black.opacity(0.55)
                    Label(asset.availability == .missing ? "AUSENTE" : "INCOMPATÍVEL",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(asset.name).lineLimit(1).font(.callout)
            Text(asset.summary).lineLimit(1).font(.caption).foregroundStyle(.secondary)
        }
        .help(asset.lastError ?? asset.path)
    }
}
