# Live Presentation

Aplicativo macOS de apresentação ao vivo para igrejas e eventos — letras, Escritura,
avisos e (nas próximas fases) mídia, composição de cenas, NDI e transmissão para o
YouTube. A prioridade é **confiabilidade em culto ao vivo**: o que está no ar só muda
por ação explícita do operador.

> Especificação de produto: documento “Especificação do produto — aplicativo de
> apresentação, composição audiovisual e transmissão”. Plano e estado de cada fase:
> [`docs/PLANO.md`](docs/PLANO.md). Decisões técnicas: [`docs/decisions/`](docs/decisions/).

## Estado atual — Fase 1 (vertical slice)

| Recurso | Estado |
|---|---|
| Biblioteca local (SQLite) com criar, renomear, duplicar, apagar, buscar | ✅ implementado |
| Itens: letra, texto, Escritura, aviso; editor de texto → slides (`[Rótulo]`, linhas em branco) | ✅ |
| Prévia × No ar separados; Enviar ao ar, Próximo/Anterior, Ocultar texto, Tela preta, Limpar | ✅ |
| Saída limpa em janela ou tela cheia num monitor secundário | ✅ |
| Temas (fonte, tamanho, peso, cores, alinhamento, margens, sombra, caixa alta) | ✅ |
| Aviso quando o texto excede a área segura | ✅ |
| Salvamento automático e recuperação da sessão (nunca volta ao ar sozinho) | ✅ |
| Logs com código de erro, sessão e redação de segredos; painel de diagnóstico | ✅ |
| Playlists | ⚠️ persistência pronta e testada; interface ainda não |
| Imagens, vídeos, cenas/camadas, Metal | ⏳ Fase 2 |
| NDI (entrada/saída) | ⏳ Fase 3 — **não implementado** |
| Áudio (Logic Pro X) e transmissão YouTube | ⏳ Fase 4 — **não implementado** |

A barra de estado do app mostra NDI, Áudio e YouTube como “não implementado”: nenhuma
dessas integrações é simulada.

## Requisitos

- macOS 14 Sonoma ou superior (alvo: Mac mini M4, 16 GB).
- Xcode 16 ou superior (Swift 5.9+; o CI usa o Xcode padrão do runner `macos-15`).
- Nenhuma dependência de terceiros. SQLite vem do próprio macOS.

## Build e execução

```bash
git clone https://github.com/pedrovieiraeba/Live-presentation.git
cd Live-presentation
swift build            # compila núcleo + app
swift run LivePresentation
swift test             # testes automatizados
```

Ou, no Xcode: **File ▸ Open…** → selecione a pasta (o `Package.swift`), escolha o
esquema **LivePresentation** e **Run** (⌘R).

> Executado via SwiftPM, o app roda sem bundle `.app` (sem ícone/Info.plist). Isso é
> suficiente para desenvolvimento e ensaio; o empacotamento para distribuição (assinatura,
> notarização) é decisão pendente — ver `docs/PLANO.md`.

A biblioteca fica em `~/Library/Application Support/LivePresentation/library.sqlite`.
Na primeira execução é criada uma apresentação de exemplo.

## Operação

| Ação | Atalho |
|---|---|
| Selecionar slide para a prévia | clique |
| Enviar slide direto ao ar | duplo clique |
| Enviar prévia ao ar | ⌘↩ (ou ↩ com a grade em foco) |
| Próximo / anterior | Page Down / Page Up (clicadores), ou → ↓ espaço / ← ↑ com a grade em foco |
| Ocultar texto (mantém o fundo) | ⇧⌘T |
| Tela preta | ⇧⌘B |
| Limpar tudo | ⇧⌘L |
| Fechar saída | ⇧⌘O |
| Nova apresentação | ⇧⌘N |
| Diagnóstico | ⌥⌘D |

Regras de segurança da operação (cobertas por testes em `ShowControllerTests`):

- A prévia nunca vai ao ar sozinha.
- O que está no ar é uma *cópia* do slide: editar ou apagar o slide não muda a saída;
  o painel avisa e oferece **Atualizar no ar**.
- Trocar de apresentação no painel não muda a saída.
- Após falha/encerramento, a sessão é restaurada **sem** conteúdo no ar.
- A saída em tela cheia não pode ocupar a tela principal (a dos controles). Se o monitor
  de saída for desconectado, a saída passa para uma janela e o operador é avisado.

## Estrutura

```
Sources/
  Diagnostics/          logs (os.Logger), buffer local, redação de segredos
  PresentationCore/     modelos, temas, parser de letras, ShowController (prévia/ar)
  Persistence/          SQLite, migrações versionadas, LibraryStore (actor)
  CSQLite/              módulo do SQLite do sistema (somente Linux/CI)
  LivePresentationApp/  app macOS (SwiftUI + AppKit) — compilado só no macOS
Tests/                  XCTest para os três módulos do núcleo
docs/                   plano, decisões, checklist
```

O núcleo não depende de UI e compila também em Linux, o que permite testar a lógica
de operação ao vivo e a persistência em CI.

## Permissões do macOS

A Fase 1 não pede nenhuma permissão especial (sem câmera, microfone, rede ou gravação de
tela). Permissões de rede local (NDI) e de áudio serão documentadas nas fases 3 e 4.

## Privacidade e segurança

- Processamento 100% local; nenhuma telemetria ou envio de dados.
- Logs passam por `Redactor` (tokens OAuth, `Bearer`, chaves RTMP etc.).
- Nenhum segredo no repositório (`.gitignore` cobre `client_secret*.json`, `.env`, `*.p12`).
  Credenciais futuras (YouTube) irão para o Keychain.

## Limitações conhecidas

- Renderização da saída via SwiftUI; composição em Metal entra na Fase 2.
- A medição de área segura usa o motor de texto do AppKit; a renderização usa SwiftUI.
  Pequenas diferenças de quebra de linha são possíveis.
- Atalhos ainda não são configuráveis pela interface.
- Sem saída de palco (stage display) nesta fase.
- Os trechos bíblicos do exemplo são apenas demonstração — ver `docs/decisions/0004`.

## Dependências e licenças

Nenhuma dependência externa. Frameworks Apple (SwiftUI, AppKit, Foundation, os) e SQLite
(domínio público). O SDK NDI, quando integrado, terá licença própria — ver Fase 3.
