# TrackSplit

App nativo de macOS (SwiftUI, Apple Silicon) que prepara os stems de um pendrive
rekordbox para o Pioneer XDJ-RX3 com o mod rx3-toolkit (commit 7d243f8, botões
VOCAL / DRUMS / BASS / INST).

## Como usar

1. Abra o TrackSplit e conecte o pendrive. Ele é detectado sozinho quando tem
   `PIONEER/` e `Contents/`.
2. Veja quantas músicas faltam, o tempo estimado e o espaço necessário. Escolha
   todas as músicas ou só algumas playlists. As que já têm stems contam como prontas.
3. **Iniciar**. Dá para cancelar a qualquer momento; as faixas concluídas ficam.
4. No fim, a tela mostra quantas deram certo e, para cada erro, o motivo.

## O que é gravado no pendrive

Só dentro de `RX3_STEMS/` na raiz do pendrive:

- `<nome>.rx3stem` (vocal), `<nome>.rx3drums`, `<nome>.rx3bass`: PCM s16
  estéreo 44,1 kHz com o cabeçalho de 64 bytes `RX3STM1`. O deck monta o INST
  como mix menos stems.
- `rx3-stems-manifest.json`, no mesmo formato (versão 2) do toolkit.

`<nome>` é o nome do arquivo de música **exatamente** como está no pendrive, até
o último ponto, do mesmo jeito que `stem_path_for_track` faz no deck. Espaços
antes da extensão são mantidos (o `safe_stem` do toolkit removia esses espaços).
Cada arquivo é gravado como `.partial` e só depois renomeado, então um pendrive
tirado no meio da gravação nunca fica com stem cortado. Os arquivos `._` que o
macOS cria em FAT/exFAT são apagados.

## Motor de separação

- Modelo Demucs `htdemucs_ft.yaml` via `audio-separator`, no Metal (mps), com
  normalização 1.0. Gera vocal, bateria e baixo de uma vez.
- O alinhamento ao decodificador do deck (atraso do encoder MP3/AAC) e o
  formato do container vêm do `app/stems/stem.py` do toolkit, copiado sem
  alterações em `TrackSplit/Engine/rx3_stem.py`.
- Runtime próprio em `~/Library/Application Support/TrackSplit/`: um venv
  Python com audio-separator, PyTorch e FFmpeg estático (imageio-ffmpeg), mais o
  modelo (~330 MB). Na primeira abertura o app monta isso sozinho usando um
  Python 3.10–3.13 do Mac (Homebrew ou python.org) e mostra o progresso no rodapé.
  São ~1,5 GB e alguns minutos, só uma vez. Não depende de nenhuma outra pasta.

## Compilar

```bash
cd ~/Documents/TrackSplit
xcodegen generate
xcodebuild -project TrackSplit.xcodeproj -scheme TrackSplit -configuration Release -derivedDataPath build build
open build/Build/Products/Release/TrackSplit.app
```

O ícone e o logo são gerados de `tracksplit-logo.jpg` com
`swift Tools/make_icons.swift tracksplit-logo.jpg TrackSplit/Assets.xcassets`.
