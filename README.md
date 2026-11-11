# Editor IA 0.7 — Cortes mais precisos e fala preservada

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
- Monta MP4 H.264/AAC, com 4K 3840x2160 como padrao e opcoes 1080p e 720p; saida em 30 quadros/s e 2 threads de codificacao.\n- Substitui faixas pretas (barras laterais/superiores) por fundo desfocado do proprio video, preservando a imagem central sem cortes ou distorcao. O fundo e preparado em baixa resolucao para reduzir o custo da desfocagem.\n- Exportacao 4K usa o material original, mas recodifica e pode demorar bastante em CPUs antigas; preservar resolucao nao significa qualidade idêntica bit a bit. Videos menores podem ser ampliados ao escolher 4K.
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

## Musica automatica (versao 0.3)

1. Baixe musicas que tenham licenca adequada para seu uso em videos; as faixas **nao estao inclusas** no projeto.
2. Guarde os arquivos MP3/WAV/M4A/FLAC/OGG na pasta `Musicas` ao lado do `EditorIA.ps1`, ou selecione outra pasta na interface.
3. Para facilitar a selecao automatica, use prefixos no nome do arquivo, como `calma-`, `animada-`, `viagem-`, `neutra-`.
4. Ao montar o vlog, o Editor IA seleciona uma faixa por heuristica (volume do audio e palavras nos nomes), repete ate o final do video, e reduz a musica em momentos de audio original forte para manter as falas audiveis.
5. Se a biblioteca estiver vazia, o video sai sem musica.

Fontes para encontrar trilhas licenciadas: [Mixkit](https://mixkit.co/free-stock-music/) e [Pixabay Music](https://pixabay.com/music/). Confira as condicoes de cada faixa, as plataformas permitidas e eventuais creditos; **royalty-free nao significa dominio publico nem garantia contra reivindicacoes**. Musicas nao devem ser redistribuidas separadamente em nosso projeto.

A escolha de trilha nao e uma analise semantica de imagens e nao garante combinacao perfeita. A exportacao desta versao ainda depende de validacao no Windows 10.

## Visao de IA apenas dos cortes escolhidos (0.4)

- Depois de escolher os trechos, o programa extrai **duas imagens pequenas (448 px de largura)** por trecho, em aproximadamente 25% e 70% da duracao de cada corte.
- Analisa **no maximo 8 trechos / 16 imagens** por montagem. Nao envia o video inteiro.
- Quando ativada a caixa **Analisar imagens dos trechos selecionados**, envia essas imagens para a **OpenAI API**, que interpreta o ambiente e retorna uma categoria simples: `calma`, `animada`, `viagem` ou `neutra`.
- Escolhe uma musica licenciada da biblioteca para cada trecho conforme o prefixo do arquivo (`calma-`, `animada-`, `viagem-`, `neutra-`) e reduz o volume sob o audio original. Se nao houver faixa compativel, pode ficar sem musica.
- Sem a caixa ativada, o editor usa a selecao musical local anterior. **Nao faz upload de imagens sem permissao.**
- Exige **internet, chave OpenAI API com credito e o ambiente `OPENAI_API_KEY` configurado no Windows**. A assinatura do ChatGPT nao inclui uso gratuito de API. **Nunca publique a chave no GitHub nem a envie por mensagem.**
- Se o sistema de visao falhar, a classificacao reverte para `neutra`; o aplicativo guarda apenas logs de diagnostico em pasta temporaria.
- Visao e uma classificacao aproximada com poucos quadros, nao interpreta o video quadro a quadro. Cenas podem ser classificadas erroneamente.
- **Os videos originais ficam no computador. Somente as imagens amostradas sao enviadas ao servico de IA.** Evite ativar se houver material sensivel ou pessoas sem consentimento apropriado.

Para configurar a chave, crie-a no portal OpenAI Platform usando o fluxo de seguranca. Salve em uma variavel de ambiente de usuario `OPENAI_API_KEY` do Windows e **abra uma nova janela do PowerShell** antes de executar o editor. A chave nao e inclusa no repositorio. A alteracao foi publicada, mas **a versao 0.4 ainda precisa ser testada no Windows**.

## Acompanhar a edicao na tela (0.5)

- A janela passou a ter uma area de **pre-visualizacao de cenas** na lateral direita, sem alterar a resolucao de exportacao escolhida.
- Durante a montagem, o programa extrai **um quadro JPEG leve** (640 x 360) de cada trecho escolhido e o mostra na interface. A imagem muda quando o programa inicia outra cena; **nao e reproducao continua nem exibicao de todos os quadros em tempo real**.
- O botao **Reproduzir trecho concluido** abre no reprodutor padrao do Windows o ultimo corte que terminou de ser processado. O sistema espera a conclusao do corte antes de disponibiliza-lo.
- Ao finalizar a exportacao, o botao passa a **Abrir video final**.
- O programa ainda exporta 4K quando selecionado e conserva ordem cronologica, fundo desfocado e musica opcional.
- A interface deve ser testada em um monitor de 1366 x 768; caso a janela nao caiba totalmente, mova-a ou ajuste a escala de exibicao no Windows. Nao inicie dois processos de exportacao ao mesmo tempo.

**Esta versao foi publicada, mas ainda nao foi executada/testada no computador do usuario.**

## Melhorias de audio (versao 0.6)

- A caixa **Reduzir vento e priorizar voz** vem ativada. Aplica um filtro de graves (`highpass`), limita frequencias agudas, reduz ruido constante com `afftdn` e usa compressao e limitacao para tornar a voz mais consistente.
- Ruido de vento **forte e sobreposto a voz nao pode ser eliminado perfeitamente**; o filtro pode afetar timbre e sons ambientes. Desative a caixa para comparar.
- Quando houver musicas licenciadas na pasta indicada, o editor coloca musica discreta em volume de 9% (nivel linear) com transicao suave e limitador para evitar saturacao. A voz original permanece como trilha principal.
- Em modo de visao por IA, escolhe musica para cada cena selecionada; fora desse modo, usa uma trilha para toda a montagem.
- Se a biblioteca estiver vazia, o programa mostra quantas musicas encontrou e pergunta se deseja exportar mesmo assim. **O editor nao baixa musicas automaticamente**; adicione arquivos MP3/WAV/M4A/FLAC/OGG licenciados.
- Antes de publicar qualquer video, escute o resultado com fones. A atualizacao foi publicada, mas ainda precisa ser testada no Windows 10 do usuario.


## Cortes sem interromper falas (0.7)

- Retirado o corte fixo de 40 segundos, que interrompia frases no meio.
- As escolhas passam a considerar blocos entre pausas longas do audio, conservando uma margem aproximada de 0,45 segundo antes e depois.
- Se o programa nao detectar pausas confiaveis, prefere manter o trecho inteiro em vez de cortar arbitrariamente a pessoa falando.
- A duracao automatica passa a ser **alvo flexivel**, podendo ultrapassar o limite de 10 minutos para respeitar falas inteiras. Um bloco muito longo pode deixar o resultado extenso.
- Mantem ordem cronologica; tenta um trecho completo por video, e um segundo apenas se couber sem sobreposicao.
- **Limite tecnico:** detectar silêncios nao equivale a reconhecer frases completas. Ventos, musica, barulho ou pausas no meio de uma frase podem confundir o detector. Para maior precisao sem perder nenhuma fala, a proxima evolucao e usar transcricao com timestamps e revisar os limites antes da exportacao.
- Antes de editar material importante, teste com dois videos curtos e escute a uniao entre os cortes.

A versao 0.7 esta publicada, mas ainda nao foi validada no computador Windows do usuario.
