# Plano de implementação

## Fase 0 — Auditoria (relatório)

**Estado encontrado:** repositório vazio (sem commits, sem código, sem configuração de
build). Nada foi apagado ou reescrito.

**Ambiente usado nesta entrega:** container Linux na nuvem (Ubuntu 24.04, x86_64) com
Swift 6.0.3. Não havia acesso a um Mac nesta sessão. Consequências:

- O núcleo (`Diagnostics`, `PresentationCore`, `Persistence`) foi compilado e testado
  localmente (Linux).
- O app SwiftUI/AppKit (`LivePresentationApp`) **não pôde ser compilado aqui**; ele é
  compilado pelo job `macos` do CI (`.github/workflows/ci.yml`, runner `macos-15`).
- Versões de Xcode/macOS efetivamente validadas devem ser registradas a partir do log do
  CI e do primeiro build no Mac mini M4.

## Arquitetura

Swift Package com módulos separados; dependências apontam sempre “para dentro”:

```
LivePresentationApp (macOS: SwiftUI/AppKit)
   ├── CompositionEngine (macOS: Metal/AVFoundation)
   │      └── CompositionCore, MediaLibrary
   ├── Persistence ── PresentationCore, MediaLibrary, CompositionCore
   └── Diagnostics (todos)
```

Módulos da Fase 2 já criados: `MediaLibrary`, `CompositionCore`, `CompositionEngine`.
Módulos previstos na especificação e ainda não criados (cada um entra na sua fase, atrás
de um protocolo para permitir testes sem SDK real):

| Módulo | Fase | Responsabilidade |
|---|---|---|
| `NDIService` | 3 | descoberta, recepção, publicação; SDK isolado |
| `AudioRouting` | 4 | seleção explícita de dispositivo, medidor de nível, compensação A/V |
| `StreamingEngine` | 4 | VideoToolbox H.264, RTMP(S), métricas, reconexão com limite |
| `YouTubeService` | 4 | OAuth 2.0 (Keychain), Live Streaming API |

## Fases

### Fase 1 — Apresentação essencial ✅ (esta entrega)

Critérios (spec §11/§17) e como foram atendidos:

- [x] Projeto macOS executável — `swift run LivePresentation` / Xcode.
- [x] Criar, salvar, reabrir e navegar uma apresentação de texto — `LibraryStore`,
      `ShowController`; testes `LibraryStoreTests.testSaveReopenAndLoadPresentation`,
      `ShowControllerTests.*`.
- [x] Saída sem controles de interface — `OutputWindowController` + `OutputRootView`.
- [x] Biblioteca básica e persistência local — SQLite com migrações.
- [x] Testes de navegação, persistência e recuperação.
- [x] Logs básicos — `AppLogger` + painel de diagnóstico.
- [ ] Validar no Mac mini M4 (build limpo seguindo só o README) — **pendente, depende do
      usuário**.

### Fase 2 — Mídia e composição ✅ (código) / ⏳ (medição)

- [x] `MediaAsset` + migração v2 (`media_assets`, `scenes`); importação de arquivos e pastas.
- [x] Miniaturas assíncronas com limite (3) e cache LRU limitado (~96 MB), canceláveis.
- [x] Disponibilidade (`available`/`missing`/`unsupported`), bookmark do macOS, relink
      manual e por pasta (sem escolher entre candidatos ambíguos).
- [x] `CompositionCore` (cenas, camadas, geometria pura testada) e `CompositionEngine`
      (Metal): textura de composição na resolução do perfil, relógio próprio, triplo
      buffer, descarte de quadro quando a GPU atrasa.
- [x] Saída limpa independente da UI: janela de saída e monitor “No ar” exibem a textura.
- [x] Vídeo sem cópia (CVMetalTextureCache); vídeos fora do ar não são decodificados.
- [x] Descarte de caches sob `DispatchSource.makeMemoryPressureSource`.
- [ ] **Medir** memória/CPU/GPU no Mac mini M4 (Instruments + painel de diagnóstico) com
      cenas de teste — roteiro em `docs/MEDICOES.md`. Pendente: depende do hardware-alvo.

### Fase 3 — NDI

Pré-requisito: o usuário baixa e instala o NDI SDK for Apple e aceita a licença (não é
redistribuível no repositório). Integração por um target de sistema/binário isolado,
atrás de `protocol NDISourceDiscovery`, `NDIReceiver`, `NDISender`. Testes com doubles
**explicitamente marcados** como tal; validação real exige rede cabeada.

### Fase 4 — Áudio e transmissão

- Seleção explícita de dispositivo de entrada Core Audio (sem captura do sistema por
  padrão; nada é alterado no Logic).
- Encoder H.264 VideoToolbox + AAC; RTMP(S) — a escolha da implementação RTMP (própria ou
  biblioteca) exige decisão registrada (licença/tamanho/manutenção).
- OAuth Google com `ASWebAuthenticationSession`, tokens no Keychain; YouTube Live
  Streaming API para listar/vincular transmissões. Requer projeto Google Cloud do usuário
  com a API habilitada e verificação de quota/elegibilidade da conta.

### Fase 5 — Robustez

Testes de carga 1080p30 → 4K30 com Logic Pro X aberto, sessões de 2 h, pressão de
memória induzida, checklist pré-evento.

## Riscos e dependências externas

| Item | Risco | Ação |
|---|---|---|
| Ambiente sem Mac nesta sessão | UI não compilada localmente | CI macOS; validação no M4 |
| NDI SDK | licença, instalação manual | Fase 3 só começa com SDK instalado |
| YouTube API | quota, elegibilidade, OAuth verificado | validar com a conta real antes de prometer recursos |
| RTMP | sem framework Apple nativo para publicar RTMP | decisão técnica dedicada |
| 4K30 | orçamento de 16 GB com Logic | só marcar como suportado após teste documentado |

## Decisões pendentes (spec §15)

Mantidas abertas, com hipótese adotada:

- Nº de fontes NDI simultâneas — hipótese: configurável, começar validando 1.
- Mais de uma saída NDI — hipótese: arquitetura permite, v1 publica uma.
- Resoluções/FPS por destino — hipótese: 1080p30 como único perfil “operacional”.
- Rota de áudio do Logic — sem hipótese; o app vai apenas listar dispositivos.
- YouTube cria eventos ou só vincula — hipótese: v1 vincula a transmissão já criada.
- Versões da Bíblia e licenças — ver `decisions/0004`.
- Formato de exportação/backup — hipótese: cópia do arquivo SQLite (com WAL checkpoint).
- Distribuição — pendente (interno vs. download direto vs. Mac App Store).
