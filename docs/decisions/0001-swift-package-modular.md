# 0001 — Swift Package modular, sem dependências externas

**Status:** aceita (Fase 1)

## Contexto
Repositório vazio; a especificação pede módulos separados, testes automatizados, build
reproduzível a partir de um clone limpo e preferência por frameworks Apple.

## Decisão
- Um único `Package.swift` com targets `Diagnostics`, `PresentationCore`, `Persistence`
  (multiplataforma) e `LivePresentationApp` (executável macOS, SwiftUI + AppKit).
- O target do app só é declarado quando o host é macOS (`#if os(macOS)` no manifesto),
  permitindo testar o núcleo em Linux/CI.
- Nenhuma dependência de terceiros.

## Consequências
- `swift build`/`swift test` e abertura direta no Xcode, sem gerador de projeto.
- O app via SwiftPM não tem bundle `.app`; empacotamento e assinatura ficam para quando a
  forma de distribuição for decidida (pode exigir um projeto Xcode ou script de bundle).
