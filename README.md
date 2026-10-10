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
| `data/system.def` | Telas em `localcoord = 1280,960`, ocupando a tela 4:3 inteira; posições absolutas descem 120 unidades e a estrada do título encosta na base |
| `data/fight.def` | Anúncios (Round, Fight, KO) centralizados na tela 4:3 |
| `data/common1.cns` | HUD de luta (barras de power, estoques, ícones, banner VS, texto LEVEL) reposicionado para a tela 4:3; fundo do MODE SELECT estendido até a base |
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
- **Menus:** com um motif 16:9 o MUGEN 1.1 centraliza as telas e recorta os fundos na faixa 16:9, deixando
  barras pretas. O `system.def` passa a declarar `localcoord = 1280,960`: os fundos vão até a borda da tela e o
  layout original fica centralizado (posições absolutas +120). A estrada animada do título é ancorada na base.

## Versão Ikemen GO

`kof-ikemen.ps1` cria uma **cópia do jogo rodando no [Ikemen GO](https://github.com/ikemen-engine/Ikemen-GO)
v1.0.0** já em 4:3, para Windows e Linux (por exemplo, um gabinete com CRT). A pasta original do jogo não é
alterada.

1. Com a pasta `Patch 4x3` dentro da pasta do jogo, execute **`Converter para Ikemen.bat`**.
2. O script baixa o Ikemen GO do GitHub (Windows e Linux, ~150 MB, conferidos por SHA256) para
   `Patch 4x3/downloads/`, copia personagens, cenários, telas, fontes e sons (~2,1 GB) e aplica o patch 4:3.
3. O resultado fica em `KOF Final Attack Ikemen`, ao lado da pasta do jogo.

Se o patch 4:3 do MUGEN estiver aplicado no jogo, a cópia parte dos arquivos originais do backup.

```powershell
powershell -ExecutionPolicy Bypass -File kof-ikemen.ps1 [-Out pasta] [-Width 320] [-Platform both|windows|linux] [-Windowed] [-Widescreen]
```

| Opção | Efeito |
|---|---|
| `-Out` | Pasta de destino (precisa estar vazia ou não existir) |
| `-Width` | Largura da saída 4:3 (padrão 320, ou seja 320x240) |
| `-Platform` | `both` (padrão) inclui os executáveis de Windows e Linux; `windows` ou `linux` só um deles |
| `-Windowed` | Começa em janela (o padrão é tela cheia, como no gabinete) |
| `-Widescreen` | Converte para o Ikemen sem aplicar o 4:3 |

Para rodar: `Ikemen_GO.exe` no Windows; no Linux, `chmod +x Ikemen_GO_Linux` e `./Ikemen_GO_Linux` a partir da
pasta do jogo. No FliperOS o teste foi feito com o mesmo Switchres (320x240@60) que o `fliperos-x11-run` usa;
de um terminal (TTY), `cd` para a pasta e `fliperos-x11-run ./Ikemen_GO_Linux` deve abrir o jogo do mesmo
jeito (esse atalho em si não foi testado).

O 4:3 da pasta Ikemen também pode ser desfeito e refeito com o mesmo `kof-4x3.ps1`:

```powershell
powershell -ExecutionPolicy Bypass -File kof-4x3.ps1 -Action restore -GameDir "..\..\KOF Final Attack Ikemen"
powershell -ExecutionPolicy Bypass -File kof-4x3.ps1 -Action apply -GameDir "..\..\KOF Final Attack Ikemen"
```

Nesse caso o backup fica em `backup-widescreen/` dentro da pasta Ikemen.

### Diferenças em relação ao MUGEN

O zoom dos cenários e o reposicionamento do HUD são os mesmos. O que muda:

| Arquivo | Alteração no Ikemen |
|---|---|
| `save/config.ini` | `GameWidth/GameHeight` = renderização (960x720), `WindowWidth/WindowHeight` = saída (320x240), `FightAspect` = resolução (4:3). Na restauração só essas chaves voltam |
| `data/common1.cns`, `chars/*` | Explods ancorados na tela usam `screenwidth/screenheight`, gatilhos do Ikemen que dão o tamanho da tela sem zoom (no Ikemen `gamewidth/gameheight` não seguem a regra do MUGEN) |
| `data/fight.def` | Recebe `[Info] localcoord = 1280,720`, que antes vinha implícito do `system.def` |
| `data/story.def`, `data/ending.def` | Storyboards 1080x720 eram vistos pela moldura 16:9 (o texto começa fora da área 1080). Viram `localcoord = 1280,960` com as cenas deslocadas, mostrando a mesma área do widescreen |
| `data/common1.cns.zss` | Removido da cópia: o Ikemen daria preferência a ele, e o HUD do jogo está no `common1.cns` |

## Observações

- Em 4:3 a tela mostra menos largura de arena; os personagens podem ficar no máximo cerca de 25% mais próximos
  do que no widescreen, como nos KOF clássicos.
- O cenário `kof94blacknoah2` não carrega nem na versão original do jogo (problema pré-existente).
- Testado em janela; em tela cheia o modo 320x240 depende do suporte do driver/monitor.
- Ikemen GO testado no Windows (janela) e num gabinete FliperOS (Ubuntu 24.04, Radeon R7 240, CRT 15 kHz) a
  320x240@60 via Switchres: abertura, título, seleção, storyboard do arcade, VS, anúncios, luta e HUD. A
  primeira execução no Linux é lenta enquanto os 2 GB do jogo entram no cache do disco.

## Histórico

- **1.0** — Primeira versão: zoom de câmera 4:3 nos cenários, HUD, anúncios e efeitos de super ajustados,
  saída padrão 320x240 para CRT com renderização interna em 960x720, backup e restauração.
- **1.1** — Conversão para Ikemen GO v1.0.0 (`kof-ikemen.ps1`) em 4:3, Windows e Linux; `kof-4x3.ps1` aceita
  `-GameDir` e reconhece pastas do Ikemen.
