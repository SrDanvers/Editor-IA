# Editor IA 0.2 — Vlogs automaticos

Editor local para Windows 10 (64 bits), PowerShell 5.1 e FFmpeg. Interface escura, importacao de multiplos videos e criacao automatica de montagem de vlog.

## Baixar pelo GitHub

1. Abra este repositorio.
2. Clique em **Code > Download ZIP**.
3. Extraia o arquivo ZIP.
4. Execute **Iniciar_EditorIA.ps1** usando PowerShell (ou no terminal: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Iniciar_EditorIA.ps1`).

**Nao e necessario instalar o Git.** O ZIP do GitHub contem os scripts do programa. O FFmpeg nao esta incluido: use o ffmpeg.exe e ffprobe.exe ja extraidos no seu computador.

## Como usar

1. Clique em **Adicionar** e selecione varios videos de vlog.
2. Clique em **Salvar em...** e escolha um novo arquivo .mp4.
3. Confira o caminho do **ffmpeg.exe**. O **ffprobe.exe** deve estar na mesma pasta.
4. Clique em **CRIAR VLOG AUTOMATICAMENTE**.
5. Aguarde a conclusao e abra a pasta de saida.

## O que esta versao faz

- Detecta pausas usando `silencedetect` do FFmpeg.
- Prioriza trechos com audio ativo, divididos em segmentos de ate 16 segundos.
- Seleciona uma duracao aproximada de 35% do material, com limite maximo de 4 minutos.
- Monta MP4 H.264/AAC em 1280x720, 24 quadros/s e 2 threads de codificacao.
- Processa localmente, sem API paga nem upload de videos.

**Limitacao:** este sistema usa regras de audio para escolher trechos. Nao compreende o significado das falas nem identifica automaticamente os momentos mais interessantes como uma IA multimodal. A exportacao no seu Windows ainda precisa ser testada. A reproducao de alguns formatos de origem pode falhar dependendo dos codecs.

## Requisitos

- Windows 10 de 64 bits.
- PowerShell 5.1 e .NET/Windows Forms.
- FFmpeg e FFprobe na mesma pasta.
- Recomendado pelo menos 8 GB de RAM e espaco livre no disco.

## Solucao de problemas

- Se o programa nao abrir, execute `Iniciar_EditorIA.ps1` em uma janela PowerShell para visualizar as mensagens.
- Se a montagem falhar, consulte `ffmpeg.log` dentro da pasta temporaria `%TEMP%\EditorIA_...`.
- Para evitar sobrescrever arquivos, escolha um nome de saida novo.

Este repositorio contem uma versao compacta, de um unico script, publicada para facilitar o download via GitHub. A versao anterior 0.1 permanece separada.
