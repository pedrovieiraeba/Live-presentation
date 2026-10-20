# 0005 — Motor de composição em Metal

**Status:** aceita (Fase 2)

## Decisão
- A composição é renderizada numa textura própria (`bgra8Unorm`, privada) na resolução
  do perfil, por um `DispatchSourceTimer` numa fila dedicada — independente da taxa de
  atualização da interface.
- Triplo buffer de texturas; no máximo 2 quadros em voo; se a GPU atrasar, o quadro é
  descartado e contado (não acumula fila).
- Janela de saída e monitor “No ar” são `MTKView`s que apenas exibem a última textura,
  usando a mesma `MTLCommandQueue` (a GPU ordena leitura/escrita).
- Shaders compilados em tempo de execução a partir de código-fonte, para não depender do
  suporte do SwiftPM a `.metal`.
- Vídeo: `AVPlayer` + `AVPlayerItemVideoOutput` (BGRA, compatível com Metal) +
  `CVMetalTextureCache` — sem cópia de quadro. Só camadas da cena no ar têm player.
- Imagens: reduzidas com ImageIO ao maior lado do perfil antes de virar textura.
- Slide: renderizado com `ImageRenderer` (SwiftUI) no tamanho da composição, só quando
  muda; o fundo do tema é desenhado pelo motor.
- Sem Metal, o app usa a saída SwiftUI da Fase 1 (sem camadas).

## Consequências
- A mesma textura servirá para a saída NDI (Fase 3) e o encoder (Fase 4); isso exigirá
  leitura de volta ou `IOSurface` — decisão na Fase 3.
- Mistura alfa pré-multiplicada; pequenas diferenças em PNGs com transparência.
