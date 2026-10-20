# 0006 — NDI via carregamento dinâmico do SDK

**Status:** aceita (Fase 3) — validação com SDK real pendente

## Contexto
A especificação exige o SDK oficial da NDI, respeitando a licença (§4.5, §13), e proíbe
simular integração (§16.6). O SDK não estava disponível no ambiente de desenvolvimento,
é instalado manualmente pelo usuário e não deve ser redistribuído no repositório.

## Decisão
- Um alvo C (`CNDI`) declara, **escritas à mão**, as poucas estruturas e funções da API C
  pública do NDI que o app usa, e carrega `libndi` com `dlopen`/`dlsym` em tempo de
  execução. O build não depende do SDK.
- `NDIService` define protocolos; `DynamicNDIRuntime` é a implementação real. Testes usam
  dublês marcados como falsos; o app nunca usa dublês.
- Sem a biblioteca, o app mostra “SDK NDI não instalado” e as camadas NDI não recebem vídeo.
- Recepção pede `BGRX_BGRA` com banda máxima; BGRX é tratado como opaco.
- Saída: `clock_video = false` (o motor já cadencia); timecode `INT64_MAX` (pedido ao SDK
  para sintetizar).

## Riscos e o que conferir com o SDK instalado
1. **Layout das estruturas** em `Sources/CNDI/include/cndi.h` (ordem e tipos dos campos de
   `NDIlib_video_frame_v2_t`, `NDIlib_recv_create_v3_t`, `NDIlib_find_create_t`,
   `NDIlib_send_create_t`, `NDIlib_source_t`). Um erro aqui pode travar o app ao receber.
2. **Valores de enums** (`color_format`, `bandwidth`, `frame_type`, `frame_format_type`).
3. **Nomes dos símbolos** exportados (`NDIlib_*`). Se algum faltar, o carregamento falha
   com mensagem clara, sem travar.
4. **Caminho padrão** da biblioteca no macOS.
5. Se houver divergência, preferir o mecanismo oficial de carregamento dinâmico do SDK
   (tabela de funções) ou compilar contra os headers instalados.

## Consequências
- O app pode ser compilado e testado em CI sem o SDK.
- Até a validação acima, a Fase 3 está **implementada, mas não verificada** com NDI real.
- Áudio NDI fora do escopo desta fase (o áudio do culto vem do Logic — Fase 4).
