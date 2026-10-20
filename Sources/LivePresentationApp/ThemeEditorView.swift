import AppKit
import PresentationCore
import SwiftUI

/// Editor de tema com prévia ao vivo. Salvar grava o tema; "Salvar como novo"
/// cria uma cópia com novo identificador.
struct ThemeEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let original: Theme
    @State private var theme: Theme
    @State private var sampleText = "Grande é o Senhor\ne mui digno de louvor"

    private static let fontFamilies = NSFontManager.shared.availableFontFamilies

    init(original: Theme) {
        self.original = original
        _theme = State(initialValue: original)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Form {
                TextField("Nome", text: $theme.name)

                Section("Tipografia") {
                    Picker("Fonte", selection: $theme.fontFamily) {
                        Text("Sistema").tag("")
                        ForEach(Self.fontFamilies, id: \.self) { Text($0).tag($0) }
                    }
                    HStack {
                        Slider(value: $theme.fontSize, in: 24...160, step: 1) { Text("Tamanho") }
                        Text("\(Int(theme.fontSize)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                    Picker("Peso", selection: $theme.fontWeight) {
                        ForEach(FontWeightOption.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    HStack {
                        Slider(value: $theme.lineSpacing, in: 0...60, step: 1) { Text("Entrelinha") }
                        Text("\(Int(theme.lineSpacing))").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                    Toggle("Caixa alta", isOn: $theme.uppercase)
                    Toggle("Sombra no texto", isOn: $theme.textShadow)
                }

                Section("Cores") {
                    ColorPicker("Texto", selection: colorBinding(\.textColor))
                    ColorPicker("Fundo", selection: colorBinding(\.backgroundColor))
                }

                Section("Posição") {
                    Picker("Horizontal", selection: $theme.horizontalAlignment) {
                        Text("Esquerda").tag(HorizontalTextAlignment.leading)
                        Text("Centro").tag(HorizontalTextAlignment.center)
                        Text("Direita").tag(HorizontalTextAlignment.trailing)
                    }
                    Picker("Vertical", selection: $theme.verticalAlignment) {
                        Text("Topo").tag(VerticalTextAlignment.top)
                        Text("Centro").tag(VerticalTextAlignment.center)
                        Text("Base").tag(VerticalTextAlignment.bottom)
                    }
                    marginSlider("Margem superior", \.margins.top)
                    marginSlider("Margem inferior", \.margins.bottom)
                    marginSlider("Margens laterais", \.margins.leading, mirror: \.margins.trailing)
                }
            }
            .formStyle(.grouped)
            .frame(width: 380)

            VStack(alignment: .leading, spacing: 10) {
                SlideCanvasView(text: sampleText, theme: theme, showsSafeArea: true)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(width: 480)
                let fit = model.fitMeasurer.measure(sampleText, theme: theme, canvas: Theme.referenceCanvas)
                if fit.overflows {
                    Label("O texto de exemplo excede a área segura", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                TextEditor(text: $sampleText)
                    .font(.body)
                    .frame(width: 480, height: 90)
                    .border(Color.secondary.opacity(0.3))
                Spacer()
                HStack {
                    Button("Cancelar", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Salvar como novo") {
                        var copy = theme
                        copy.id = UUID()
                        if copy.name == original.name { copy.name += " (cópia)" }
                        Task { await model.saveTheme(copy); dismiss() }
                    }
                    Button("Salvar") {
                        Task { await model.saveTheme(theme); dismiss() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(minHeight: 560)
    }

    private func colorBinding(_ keyPath: WritableKeyPath<Theme, RGBAColor>) -> Binding<Color> {
        Binding(get: { theme[keyPath: keyPath].swiftUIColor },
                set: { theme[keyPath: keyPath] = RGBAColor($0) })
    }

    private func marginSlider(_ title: String, _ keyPath: WritableKeyPath<Theme, Double>,
                              mirror: WritableKeyPath<Theme, Double>? = nil) -> some View {
        HStack {
            Slider(value: Binding(get: { theme[keyPath: keyPath] },
                                  set: { value in
                                      theme[keyPath: keyPath] = value
                                      if let mirror { theme[keyPath: mirror] = value }
                                  }),
                   in: 0...0.3) { Text(title) }
            Text("\(Int(theme[keyPath: keyPath] * 100))%").monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }
}
