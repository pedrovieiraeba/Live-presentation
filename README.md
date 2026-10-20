# Live Presentation

Aplicativo macOS de apresentação ao vivo para igrejas e eventos — letras, Escritura,
avisos e (nas próximas fases) mídia, composição de cenas, NDI e transmissão para o
YouTube. A prioridade é **confiabilidade em culto ao vivo**: o que está no ar só muda
por ação explícita do operador.

> Especificação de produto: documento “Especificação do produto — aplicativo de
> apresentação, composição audiovisual e transmissão”. Plano e estado de cada fase:
> [`docs/PLANO.md`](docs/PLANO.md). Decisões técnicas: [`docs/decisions/`](docs/decisions/).

## Estado atual — Fase 2 (mídia e composição)

| Recurso | Estado |
|---|---|
| Biblioteca local (SQLite) com criar, renomear, duplicar, apagar, buscar | ✅ Fase 1 |
| Itens: letra, texto, Escritura, aviso; editor de texto → slides (`[Rótulo]`, linhas em branco) | ✅ Fase 1 |
| Prévia × No ar separados; Enviar ao ar, Próximo/Anterior, Ocultar texto, Tela preta, Limpar | ✅ Fase 1 |
| Temas, aviso de área segura, salvamento automático, recuperação sem ir ao ar | ✅ Fase 1 |
| Biblioteca de mídia: importar arquivos/pastas, miniaturas assíncronas, metadados reais | ✅ Fase 2 |
| Mídia ausente/movida: detecção, bookmark do macOS, relink manual e por pasta | ✅ Fase 2 |
| Cenas com camadas: cor, imagem, vídeo, apresentação; posição, escala, recorte, opacidade | ✅ Fase 2 |
| Motor de composição Metal: resolução própria (1080p30; 4K30 experimental), saída limpa | ✅ Fase 2 |
| Painel de diagnóstico: quadros/s, descartes, tempo de GPU, memória estimada | ✅ Fase 2 |
| Medição real de memória/CPU/GPU no Mac mini M4 com o Logic aberto | ⏳ **pendente — precisa ser feita no seu Mac** |
| Playlists | ⚠️ persistência pronta; interface ainda não |
| NDI (entrada/saída) | ⏳ Fase 3 — **não implementado** |
| Áudio (Logic Pro X) e transmissão YouTube | ⏳ Fase 4 — **não implementado** |

A barra de estado mostra NDI, Áudio e YouTube como “não implementado”: nenhuma dessas
integrações é simulada.

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

Regras de segurança da operação (cobertas por testes em `ShowControllerTests` e
`SceneControllerTests`):

- A prévia nunca vai ao ar sozinha.
- O que está no ar é uma *cópia* do slide e da cena: editar ou apagar não muda a saída;
  o painel avisa e oferece **Atualizar no ar**.
- Trocar de apresentação no painel não muda a saída.
- Após falha/encerramento, a sessão é restaurada **sem** slide no ar (a cena de fundo,
  que não contém texto, é restaurada).
- A saída em tela cheia não pode ocupar a tela principal (a dos controles). Se o monitor
  de saída for desconectado, a saída passa para uma janela e o operador é avisado.
- Mídia ausente nunca derruba a saída: a camada some e o painel mostra o motivo.
- Vídeos em camadas começam **sem som** (o áudio do culto vem do Logic).

### Cenas e mídia

1. Aba **Mídia** → **Importar…** (arquivos ou pastas). Os arquivos ficam onde estão.
2. Aba **Cenas** → **Nova cena** cria “fundo + apresentação”. Adicione camadas pelo
   menu **Adicionar** ou com duplo clique numa mídia.
3. **Enviar cena ao ar**. A cena padrão (“Apresentação”) reproduz o comportamento da Fase 1.
4. **Tela preta** escurece a composição inteira; **Limpar** tira só o slide (o fundo
   continua).

## Estrutura

```
Sources/
  Diagnostics/          logs (os.Logger), buffer local, redação de segredos
  PresentationCore/     modelos, temas, parser de letras, ShowController (prévia/ar)
  MediaLibrary/         mídia, importação, relink, cache LRU, limitador de concorrência
  CompositionCore/      cenas, camadas, geometria, SceneController, perfis
  Persistence/          SQLite, migrações versionadas, LibraryStore (actor)
  CSQLite/              módulo do SQLite do sistema (somente Linux/CI)
  CompositionEngine/    motor Metal + exibição (somente macOS)
  LivePresentationApp/  app macOS (SwiftUI + AppKit) — compilado só no macOS
Tests/                  XCTest para os módulos do núcleo
docs/                   plano, decisões, checklist
```

O núcleo não depende de UI e compila também em Linux, o que permite testar a lógica
de operação ao vivo e a persistência em CI.

## Permissões do macOS

As fases 1 e 2 não pedem permissões especiais (sem câmera, microfone, rede ou gravação de
tela). Arquivos de mídia são lidos com as permissões normais do usuário; se estiverem em
pastas protegidas (Mesa, Documentos, Downloads), o macOS pode pedir autorização. Permissões de rede local (NDI) e de áudio serão documentadas nas fases 3 e 4.

## Privacidade e segurança

- Processamento 100% local; nenhuma telemetria ou envio de dados.
- Logs passam por `Redactor` (tokens OAuth, `Bearer`, chaves RTMP etc.).
- Nenhum segredo no repositório (`.gitignore` cobre `client_secret*.json`, `.env`, `*.p12`).
  Credenciais futuras (YouTube) irão para o Keychain.

## Limitações conhecidas

- Vídeos gravados em retrato (rotação nos metadados) aparecem sem a rotação aplicada.
- A prévia da aba Cenas é aproximada (miniaturas, sem decodificar vídeo); a imagem exata
  é a do monitor **No ar**.
- Mistura alfa assume texturas pré-multiplicadas; PNGs com transparência podem ter bordas
  levemente diferentes do Finder/Preview.
- Áudio de vídeos, se ativado, sai pelo dispositivo padrão do sistema (roteamento é Fase 4).
- A medição de área segura usa o motor de texto do AppKit; a renderização usa SwiftUI.
- Atalhos ainda não são configuráveis pela interface; sem saída de palco nesta fase.
- Os trechos bíblicos do exemplo são apenas demonstração — ver `docs/decisions/0004`.

## Dependências e licenças

Nenhuma dependência externa. Frameworks Apple (SwiftUI, AppKit, Foundation, os) e SQLite
(domínio público). O SDK NDI, quando integrado, terá licença própria — ver Fase 3.
