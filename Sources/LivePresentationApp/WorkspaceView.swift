import PresentationCore
import SwiftUI

/// Área de trabalho: cabeçalho da apresentação, lista de itens, grade de slides
/// e editor do item selecionado.
struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let presentation = model.show?.presentation {
            VStack(spacing: 0) {
                PresentationHeader(presentation: presentation)
                Divider()
                HSplitView {
                    ItemList(presentation: presentation)
                        .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
                    VSplitView {
                        SlideGrid(presentation: presentation)
                            .frame(minHeight: 220)
                        ItemEditor(presentation: presentation)
                            .frame(minHeight: 200, idealHeight: 260)
                    }
                }
            }
        } else {
            ContentUnavailableView("Nenhuma apresentação aberta", systemImage: "rectangle.on.rectangle",
                                   description: Text("Escolha ou crie uma apresentação na biblioteca."))
        }
    }
}

private struct PresentationHeader: View {
    @EnvironmentObject private var model: AppModel
    let presentation: Presentation
    @State private var editingTheme: Theme?

    var body: some View {
        HStack(spacing: 12) {
            TextField("Nome", text: Binding(
                get: { presentation.name },
                set: { newName in model.edit { $0.name = newName } }
            ))
            .textFieldStyle(.plain)
            .font(.title2.weight(.semibold))

            Picker("Tema padrão", selection: Binding(
                get: { presentation.defaultThemeID },
                set: { id in model.edit { $0.defaultThemeID = id } }
            )) {
                ForEach(model.themes) { Text($0.name).tag($0.id) }
            }
            .frame(maxWidth: 240)

            Button {
                editingTheme = model.theme(id: presentation.defaultThemeID)
            } label: {
                Label("Editar tema", systemImage: "paintpalette")
            }
            .help("Editar tipografia, cores e margens do tema")

            Menu {
                ForEach(ItemKind.allCases, id: \.self) { kind in
                    Button(kind.displayName) { model.addItem(kind: kind) }
                }
            } label: {
                Label("Adicionar item", systemImage: "plus.rectangle.on.rectangle")
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .sheet(item: $editingTheme) { theme in
            ThemeEditorView(original: theme)
                .environmentObject(model)
        }
    }
}

// MARK: Itens

private struct ItemList: View {
    @EnvironmentObject private var model: AppModel
    let presentation: Presentation
    @State private var pendingDeletion: PresentationItem?

    var body: some View {
        List(selection: $model.selectedItemID) {
            ForEach(presentation.items) { item in
                HStack {
                    Image(systemName: icon(for: item.kind)).foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(item.title.isEmpty ? item.kind.displayName : item.title).lineLimit(1)
                        Text("\(item.slides.count) slides").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(item.id)
                .contextMenu {
                    Button("Apagar item…", role: .destructive) { pendingDeletion = item }
                }
            }
            .onMove { source, destination in
                model.edit { $0.items.move(fromOffsets: source, toOffset: destination) }
            }
        }
        .confirmationDialog(
            "Apagar o item \"\(pendingDeletion?.title ?? "")\"?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Apagar", role: .destructive) {
                if let item = pendingDeletion { model.edit { $0.removeItem(id: item.id) } }
                pendingDeletion = nil
            }
        }
    }

    private func icon(for kind: ItemKind) -> String {
        switch kind {
        case .lyrics: return "music.note.list"
        case .text: return "text.alignleft"
        case .scripture: return "book.closed"
        case .announcement: return "megaphone"
        }
    }
}

// MARK: Grade de slides

private struct SlideGrid: View {
    @EnvironmentObject private var model: AppModel
    let presentation: Presentation
    @FocusState private var focused: Bool

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 12)]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                    ForEach(presentation.items) { item in
                        Section {
                            ForEach(item.slides) { slide in
                                let address = SlideAddress(itemID: item.id, slideID: slide.id)
                                SlideThumbnail(
                                    slide: slide,
                                    theme: model.theme(id: presentation.themeID(for: address)),
                                    number: (presentation.position(of: address) ?? 0) + 1,
                                    isPreview: model.showState?.preview == address,
                                    isLive: model.showState?.live?.address == address,
                                    overflows: model.fitReport(for: address)?.overflows ?? false
                                )
                                .id(address)
                                .onTapGesture(count: 2) {
                                    focused = true
                                    model.goLive(address)
                                }
                                .onTapGesture {
                                    focused = true
                                    model.selectPreview(address)
                                    model.selectedItemID = item.id
                                }
                                .contextMenu {
                                    Button("Enviar ao ar") { model.goLive(address) }
                                    Button("Duplicar slide") { model.edit { _ = $0.duplicateSlide(at: address) } }
                                }
                            }
                        } header: {
                            Text(item.title.isEmpty ? item.kind.displayName : item.title)
                                .font(.headline)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.background)
                        }
                    }
                }
                .padding(12)
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            // Atalhos de operação quando a grade tem foco (clicadores enviam
            // setas ou Page Up/Down).
            .onKeyPress(.rightArrow) { model.next(); return .handled }
            .onKeyPress(.downArrow) { model.next(); return .handled }
            .onKeyPress(.space) { model.next(); return .handled }
            .onKeyPress(.leftArrow) { model.previous(); return .handled }
            .onKeyPress(.upArrow) { model.previous(); return .handled }
            .onKeyPress(.return) { model.take(); return .handled }
            .onChange(of: model.showState?.live?.address) { _, address in
                guard let address else { return }
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(address) }
            }
        }
    }
}

private struct SlideThumbnail: View {
    let slide: Slide
    let theme: Theme
    let number: Int
    let isPreview: Bool
    let isLive: Bool
    let overflows: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SlideCanvasView(text: slide.text, theme: theme)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(borderColor, lineWidth: isLive || isPreview ? 3 : 1)
                )
            HStack(spacing: 6) {
                Text("\(number)").monospacedDigit().foregroundStyle(.secondary)
                if !slide.label.isEmpty { Text(slide.label).lineLimit(1) }
                Spacer(minLength: 0)
                if overflows {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("O texto excede a área segura do tema")
                        .accessibilityLabel("Excede a área segura")
                }
                if isLive {
                    badge("NO AR", color: .red)
                } else if isPreview {
                    badge("PRÉVIA", color: .blue)
                }
            }
            .font(.caption)
        }
        .contentShape(Rectangle())
    }

    private var borderColor: Color {
        if isLive { return .red }
        if isPreview { return .blue }
        return Color.secondary.opacity(0.4)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color, in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.white)
    }
}

// MARK: Editor do item

private struct ItemEditor: View {
    @EnvironmentObject private var model: AppModel
    let presentation: Presentation

    @State private var source = ""
    @State private var loadedItemID: UUID?
    @State private var maxLines = 0

    var body: some View {
        if let itemID = model.selectedItemID, let item = presentation.item(id: itemID) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Título", text: Binding(
                        get: { item.title },
                        set: { title in model.edit { $0.updateItem(id: itemID) { $0.title = title } } }
                    ))
                    .frame(maxWidth: 260)

                    Picker("Tipo", selection: Binding(
                        get: { item.kind },
                        set: { kind in model.edit { $0.updateItem(id: itemID) { $0.kind = kind } } }
                    )) {
                        ForEach(ItemKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .frame(maxWidth: 180)

                    Picker("Tema", selection: Binding<UUID?>(
                        get: { item.themeID },
                        set: { id in model.edit { $0.updateItem(id: itemID) { $0.themeID = id } } }
                    )) {
                        Text("Padrão da apresentação").tag(UUID?.none)
                        ForEach(model.themes) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .frame(maxWidth: 260)

                    Stepper(maxLines == 0 ? "Linhas/slide: livre" : "Linhas/slide: \(maxLines)",
                            value: $maxLines, in: 0...12)
                        .onChange(of: maxLines) { _, _ in apply(itemID: itemID) }
                }
                Text("Linhas em branco separam slides. Use [Rótulo] numa linha para nomear a estrofe.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $source)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onChange(of: source) { _, _ in apply(itemID: itemID) }
            }
            .padding(12)
            .onAppear { load(item) }
            .onChange(of: itemID) { _, _ in load(item) }
        } else {
            ContentUnavailableView("Selecione um item", systemImage: "text.cursor",
                                   description: Text("O texto do item aparece aqui para edição."))
        }
    }

    private func load(_ item: PresentationItem) {
        guard loadedItemID != item.id else { return }
        loadedItemID = item.id
        source = LyricsParser.source(from: item.slides)
    }

    private func apply(itemID: UUID) {
        guard loadedItemID == itemID else { return }
        model.updateItemSource(itemID: itemID, source: source, maxLinesPerSlide: maxLines == 0 ? nil : maxLines)
    }
}
