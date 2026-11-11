# Editor IA 0.2 — Vlogs automaticos

Editor local para Windows 10 (64 bits), PowerShell 5.1 e FFmpeg. Interface escura, importacao de multiplos videos e criacao automatica de montagem de vlog.

## Baixar pelo GitHub

1. Abra este repositorio.
2. Clique em **Code > Download ZIP**.
3. Extraia o arquivo ZIP.
4. Execute **Iniciar_EditorIA.ps1** usando PowerShell (ou no terminal: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Iniciar_EditorIA.ps1`).

**Nao e necessario instalar o Git.** O ZIP do GitHub contem os scripts do programa. O FFmpeg nao esta incluido: use o ffmpeg.exe e ffprobe.exe ja extraidos no seu computador.

## Como usar

1. Copie a pasta de videos do celular para o computador (no Explorador do Windows, copie a pasta DCIM ou DennyCamera inteira e cole em Documentos).\n2. Clique em **Adicionar pasta** para importar de uma vez todos os videos da pasta e das subpastas. Ou use **Adicionar arquivos** com Ctrl+A para selecionar todos os arquivos da pasta.
3. Clique em **Salvar em...** e escolha um novo arquivo .mp4.
4. Escolha **4K (3840x2160)** para manter a resolucao das gravacoes; tambem ha 1080p e 720p.\n5. Confira o caminho do **ffmpeg.exe**. O **ffprobe.exe** deve estar na mesma pasta.
6. Clique em **CRIAR VLOG AUTOMATICAMENTE**.
7. Aguarde a conclusao e abra a pasta de saida.

## O que esta versao faz

- Detecta pausas usando `silencedetect` do FFmpeg.
- Prioriza cenas mais longas (geralmente 25 a 40 segundos), juntando pausas curtas para preservar frases.\n- Organiza os arquivos pela data e hora da gravacao: primeiro interpreta nomes como VID_20261105_093700_180.mp4, depois a data interna do video, e por ultimo a data de modificacao do arquivo.\n- Mantem a sequencia cronologica no video final, inclusive quando ha mais de um trecho da mesma gravacao.\n- Tenta usar uma cena diferente de cada video antes de repetir a origem. Com ate 6 arquivos, pode adicionar uma segunda cena separada por pelo menos 8 segundos, sem sobreposicao.\n- Evita importar o mesmo caminho de arquivo duas vezes. Nao detecta se dois arquivos diferentes contem imagens identicas.
- Define a duracao automaticamente conforme a quantidade de arquivos e o material aproveitavel, com limite superior de 10 minutos. Nao ha garantia de utilizar todos os arquivos se o tempo disponivel for insuficiente.
- Monta MP4 H.264/AAC, com 4K 3840x2160 como padrao e opcoes 1080p e 720p; saida em 30 quadros/s e 2 threads de codificacao.\n- Exportacao 4K usa o material original, mas recodifica e pode demorar bastante em CPUs antigas; preservar resolucao nao significa qualidade idêntica bit a bit. Videos menores podem ser ampliados ao escolher 4K.
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
