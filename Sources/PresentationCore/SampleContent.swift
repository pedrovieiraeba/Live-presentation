import Foundation

/// Conteúdo de exemplo para a primeira execução.
///
/// Os trechos bíblicos seguem a tradição Almeida (Revista e Corrigida) e servem
/// só para demonstração. Antes de distribuir o app, conferir a redação exata e o
/// status de licença da edição usada (ver docs/decisions/0004).
public enum SampleContent {
    public static func welcomePresentation(now: Date = Date()) -> Presentation {
        var presentation = Presentation(name: "Exemplo — Culto", createdAt: now)

        presentation.appendItem(PresentationItem(
            kind: .announcement,
            title: "Boas-vindas",
            slides: [Slide(text: "Seja bem-vindo"), Slide(text: "O culto começa em instantes")]
        ))

        presentation.appendItem(PresentationItem(
            kind: .scripture,
            title: "Salmo 119.105",
            slides: [Slide(label: "Sl 119.105",
                           text: "Lâmpada para os meus pés é tua palavra,\ne luz para o meu caminho.")],
            themeID: Theme.scripture.id
        ))

        presentation.appendItem(PresentationItem(
            kind: .scripture,
            title: "João 1.1–5",
            slides: LyricsParser.slides(from: """
                [Jo 1.1–2]
                No princípio era o Verbo, e o Verbo estava com Deus,
                e o Verbo era Deus.
                Ele estava no princípio com Deus.

                [Jo 1.3–5]
                Todas as coisas foram feitas por ele,
                e sem ele nada do que foi feito se fez.
                Nele estava a vida, e a vida era a luz dos homens.
                E a luz resplandece nas trevas,
                e as trevas não a compreenderam.
                """),
            themeID: Theme.scripture.id
        ))

        return presentation
    }
}
