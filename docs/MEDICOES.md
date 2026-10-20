# Roteiro de medição — Fase 2

Objetivo (spec §5 e §10, Fase 2): medir consumo real em vez de presumir. Nada aqui foi
medido ainda; preencha a tabela no Mac mini M4.

## Preparação
1. Build de release: `swift build -c release` e execute `.build/release/LivePresentation`.
2. Feche apps não essenciais. Anote a versão do macOS e do Xcode.
3. Abra **Diagnóstico** (⌥⌘D): quadros/s, descartes, GPU, texturas, miniaturas, memória.

## Cenas de teste
| ID | Cena | Perfil |
|---|---|---|
| A | Padrão (só slide) | 1080p30 |
| B | Vídeo 1080p em loop + slide | 1080p30 |
| C | Vídeo 4K em loop + imagem + slide | 1080p30 |
| D | Igual a C | 4K30 (experimental) |
| E | Igual a B, com o Logic Pro X aberto e um projeto realista tocando | 1080p30 |

Para cada cena: 10 min rodando, depois anote. Em Instruments use os templates
**Allocations**/**VM Tracker** (memória), **Metal System Trace** (GPU) e **Time Profiler** (CPU).

## Resultados
| Cena | Memória residente | Texturas (diag.) | CPU % | GPU ms/quadro | Quadros/s | Descartes | Observações |
|---|---|---|---|---|---|---|---|
| A | | | | | | | |
| B | | | | | | | |
| C | | | | | | | |
| D | | | | | | | |
| E | | | | | | | |

## Critérios
- 1080p30: 30 quadros/s estáveis, descartes ≈ 0, sem estalos no Logic (cena E).
- 4K30 só passa a “operacional” com a cena D/E aprovada e registrada aqui (spec §11).
- Pressão de memória: no Terminal, a ferramenta `memory_pressure` do macOS pode simular
  pressão (confira as opções em `man memory_pressure`; não verifiquei a sintaxe exata). Confirme
  no Diagnóstico que as miniaturas foram descartadas e a saída não parou.
