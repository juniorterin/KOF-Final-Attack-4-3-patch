# KOF Final Attack - Patch 4:3

Converte o **The King of Fighters: Final Attack** (MUGEN 1.1) de widescreen 16:9 para **4:3**, pensado para
rodar em monitor **CRT 320x240**, mantendo a interface fiel ao original. O patch é reversível: o widescreen
original pode ser restaurado a qualquer momento.

## Instalação

1. Copie a pasta `Patch 4x3` para dentro da pasta do jogo (onde fica `Final Attack.exe`).
2. Feche o jogo.
3. Execute **`Aplicar 4x3.bat`**.

Para voltar ao original, execute **`Restaurar Widescreen.bat`**.

### Outras resoluções

A saída padrão é 320x240. Para outra resolução 4:3, passe a largura (múltipla de 4) pela linha de comando:

```bat
"Aplicar 4x3.bat" -Width 640
```

Ou diretamente pelo PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File kof-4x3.ps1 -Action apply -Width 640
powershell -ExecutionPolicy Bypass -File kof-4x3.ps1 -Action restore
powershell -ExecutionPolicy Bypass -File kof-4x3.ps1 -Action status
```

### Tela cheia no CRT

O patch não altera o modo janela/tela cheia. No CRT, use `Alt+Enter` no jogo ou `FullScreen = 1` em
`data/mugen.cfg`.

## O que o patch altera

| Arquivo | Alteração |
|---|---|
| `data/mugen.cfg` | `GameWidth/GameHeight` = resolução de renderização; `[Video] Width/Height` = resolução de saída |
| `data/fight.def` | Anúncios (Round, Fight, KO) centralizados na tela 4:3 |
| `data/common1.cns` | HUD de luta (barras de power, estoques, ícones, banner VS) reposicionado para a tela 4:3 |
| `stages/*.def` | Zoom fixo de câmera 4:3 e ajuste de enquadramento |
| `chars/*` (14 arquivos) | Efeitos de tela dos supers centralizados corretamente sob o zoom |

Os arquivos originais são copiados para `Patch 4x3/backup-widescreen/` antes de qualquer alteração, junto com
`estado.txt` (resolução original e lista de arquivos). Se ocorrer erro durante a aplicação, o que já foi
escrito é revertido. Na restauração, o `mugen.cfg` volta apenas nas linhas de resolução, preservando opções
salvas pelo jogo nesse meio tempo (volume, controles etc.).

## Como funciona

O MUGEN 1.1 sempre monta a luta como se a tela fosse 16:9; em 4:3 isso deixa uma faixa preta embaixo. O patch
transforma a imagem em um **recorte 4:3 fiel** do widescreen:

- **Zoom de câmera** `zoomin = zoomout = 1.333333` (16:9 ÷ 4:3) em cada cenário: cenário e personagens escalam
  juntos, mantendo proporção e paralaxe.
- **Enquadramento vertical:** o zoom do MUGEN pivota na linha do chão, então em cenários 1.x com chão fixo o chão
  (`zoffset`) e as camadas de fundo (`start` y, `window`) descem `zoffset/3`. Cenários antigos (sem `localcoord`)
  e com chão ligado a um elemento (`zoffsetlink`) já ficam corretos só com o zoom.
- **Limites de câmera** (`boundleft/boundright`) ampliados em `localcoord/8`, para que as bordas do cenário
  continuem alcançáveis. `zoomdelta` das camadas é fixado em 1 para o recorte ser uniforme.
- **HUD:** sob zoom, `gamewidth/gameheight` encolhem pelo fator de zoom, mas explods ancorados na tela
  (`postype = left/right`) não. Nesses explods o patch usa `(gamewidth*4/3)` e `(gameheight*4/3)`. Elementos da
  base da tela 16:9 recebem `+ (altura 4:3 - altura 16:9)`.
- **Renderização:** o MUGEN 1.1 desloca storyboards 4:3 (abertura e intro) em larguras baixas. Por isso,
  resoluções de saída abaixo de 960 px são renderizadas em 960x720 e reduzidas pelo próprio engine
  (`[Video] Width/Height`), o que também deixa a imagem mais limpa em 320x240.
- **Menus** (título, seleção) continuam com o layout original, centralizados (letterbox).

## Observações

- Em 4:3 a tela mostra menos largura de arena; os personagens podem ficar no máximo cerca de 25% mais próximos
  do que no widescreen, como nos KOF clássicos.
- O cenário `kof94blacknoah2` não carrega nem na versão original do jogo (problema pré-existente).
- Testado em janela; em tela cheia o modo 320x240 depende do suporte do driver/monitor.

## Histórico

- **1.0** — Primeira versão: zoom de câmera 4:3 nos cenários, HUD, anúncios e efeitos de super ajustados,
  saída padrão 320x240 para CRT com renderização interna em 960x720, backup e restauração.
