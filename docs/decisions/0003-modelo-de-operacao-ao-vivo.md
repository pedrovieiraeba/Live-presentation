# 0003 — Modelo de operação ao vivo (prévia × no ar)

**Status:** aceita (Fase 1)

## Decisão
`ShowController` é uma máquina de estados pura (struct, sem UI, sem relógio):

- `preview`: endereço estável (`itemID` + `slideID`) do slide em preparação.
- `live`: **snapshot** (texto, rótulo, tema) do que foi enviado ao ar.
- `textHidden` e `blackout` como camadas independentes.
- Endereços por identificador, não por índice: edições não fazem a prévia “pular”.

Regras:
1. Nada vai ao ar sem ação explícita (`take`, `goLive`, `next`, `previous`).
2. Editar/apagar o slide no ar não altera a saída; o app sinaliza (`liveIsStale`) e
   oferece reenvio.
3. Trocar de apresentação não altera a saída; `next/previous` ficam bloqueados enquanto
   o slide no ar não pertencer à apresentação aberta.
4. Recuperação após falha restaura a prévia e **nunca** o ar.
5. Nos limites da apresentação, a saída permanece estável (`atBoundary`).

## Consequências
Comportamento verificável por testes unitários; a UI só traduz eventos em chamadas.
