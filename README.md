# Editor IA 1.2 Beta — Zoom cinematográfico, cortes em movimento e músicas variadas

Editor de vlogs em PowerShell 5.1 e FFmpeg, feito para computador de 8 GB de RAM com gráficos Intel HD 3000. Tema escuro/amarelo.

**Estado:** beta publicado para testes. A execução completa ainda não foi validada no PC do usuário. Não considere este programa uma edição profissional autônoma sem revisar o vídeo final.

## Instalação

1. Clique em **Code → Download ZIP** neste repositório e extraia tudo.
2. Execute `Iniciar_EditorIA.ps1` com PowerShell.
3. Em **Localizar**, escolha o `ffmpeg.exe` já instalado (e `ffprobe.exe` na mesma pasta).
4. Copie os vídeos do celular para uma pasta **local do computador** antes de importar. O editor não lê bem caminhos MTP/INetCache.
5. Clique **Adicionar pasta** para importar todos os vídeos e subpastas.
6. Escolha o destino MP4, qualidade 4K/1080p/720p e, se desejar, uma biblioteca de músicas licenciadas.
7. Clique **CRIAR VLOG AUTOMATICAMENTE**.
8. Acompanhe a miniatura da cena, clique em **Ver plano dos cortes (CSV)** após o planejamento, ou reproduza um trecho concluído.

O arquivo final fica na pasta escolhida em **Salvar em...**. Os arquivos de origem não são alterados.

## Recursos reunidos

| Recurso | Como funciona |
|---|---|
| Importar lote | Pasta e subpastas, sem carregar um arquivo por vez |
| Ordenar | Nome com data/hora da câmera; depois metadados; depois modificação do arquivo |
| Cortes sem interromper frases | Sem cortes por tempo fixo; prioriza blocos entre pausas, com margem |
| Cortes por transcrição (opcional) | Envia somente áudio comprimido para transcrição com timestamps e agrupa frases nos limites |
| Plano de cortes | Gera `plano_cortes.csv` na pasta de trabalho temporária; pode abrir pelo botão |
| Visão por cenas (opcional) | Extrai até 16 imagens pequenas de até oito trechos, enviadas à API apenas com a opção ativada |
| Música | Lê faixas licenciadas da pasta `Musicas` e alterna automaticamente entre as disponíveis a cada cena e até cada 40 segundos, inclusive sem API |
| Limpeza de voz | Filtro passa-altas + redução de ruído constante + compressão. Não garante eliminar vento muito forte |
| Fundo desfocado | Preenche laterais de vídeo vertical com imagem desfocada do próprio vídeo |
| Prévia em movimento | Gera um vídeo-proxy de 360p/15 fps da cena selecionada para reproduzir na interface enquanto o corte 4K é renderizado; pode repetir a cena até o próximo corte |
| Exportação | MP4 H.264/AAC 4K (padrão), 1080p ou 720p, via CPU. 4K pode demorar bastante |

## IA e privacidade

- O modo normal processa os vídeos **localmente** com FFmpeg, sem enviar arquivos à nuvem.
- **Cortes por transcrição (opcional)** envia até 10 minutos de áudio por vídeo para a OpenAI API, em blocos de até 90 segundos. Usa temporariamente o modelo de transcrição `whisper-1` com timestamps, **anunciado para descontinuação em 26 de fevereiro de 2027**. É preciso migrar a um modelo novo de timestamps antes dessa data.
- **Analisar imagens (opcional)** envia pequenas imagens dos cortes para a API. Não envia vídeos completos.
- Os dois modos são pagos separadamente da assinatura ChatGPT e exigem `OPENAI_API_KEY` configurada como variável de ambiente do Windows. **Não cole a chave no chat e nunca a publique no GitHub.**
- Se a transcrição falhar, o editor volta à análise por pausas. Erros são registrados na pasta temporária.

Documentação da transcrição: https://developers.openai.com/api/docs/guides/speech-to-text

## Músicas e licenças

Coloque seus arquivos MP3/WAV/M4A/FLAC/OGG na pasta `Musicas` ou selecione outra pasta. Nomeie com prefixos: `calma-`, `animada-`, `viagem-`, `neutra-`.

Você pode procurar trilhas em https://mixkit.co/free-stock-music/ e https://pixabay.com/music/; confira a licença de cada obra e os usos permitidos. Royalty-free **não significa domínio público** e não impede reivindicações automáticas. Nenhuma música é incluída no repositório.

## Limitações que ainda exigem revisão humana

- Uma pausa no meio de uma frase ou vento intenso pode gerar cortes ruins mesmo com os filtros.
- A transcrição com timestamp melhora a escolha de limites, mas não garante uma narrativa perfeita.
- Uma cena longa pode fazer o vlog ultrapassar a duração desejada.
- A seleção visual só classifica temas simples com poucos quadros; não entende toda a ação da cena.
- Não há linha do tempo de edição manual completa nem reprodução contínua da exportação dentro da interface.
- O formato original 4K preserva a **resolução**, mas é recodificado e pode perder qualidade. Em computador antigo, use 720p para primeiro teste.
- O teste automático do GitHub verifica **sintaxe PowerShell**, não substitui um teste funcional completo com vídeos reais.

## Resolução de problemas

Se houver erro, consulte os registros `%TEMP%\EditorIA_*\ffmpeg.log`, `status.json` ou `transcricao_erros.txt`. Não execute várias exportações simultâneas. Antes de uma edição longa, teste com dois vídeos curtos e ouça as falas perto das transições.

### Licença
Consulte os arquivos do repositório antes de redistribuir o software. O conteúdo dos seus vídeos e a licença das músicas são responsabilidades separadas.

## Novo na versão 1.1 Beta: cortes em movimento e músicas distintas

**Ver os cortes se movimentando:** marque `Mostrar cortes em movimento durante a edicao (360p)` (ativado por padrão). O FFmpeg prepara um proxy de baixa resolução do corte selecionado e o Windows Media Element reproduz esse vídeo dentro do editor enquanto a versão final é renderizada. O vídeo muda quando o corte seguinte começa; até lá pode repetir o mesmo trecho. A prévia **não é um monitor de saída 4K em tempo real** e a preparação de cada proxy acrescenta processamento. Se o reprodutor Windows não suportar o arquivo, a miniatura continua disponível.

**Música variada, sem custo de API:** a montagem alterna entre arquivos da sua biblioteca local `Musicas`, em cada cena e em trechos de **até 40 segundos**. A voz fica prioritária. A seleção básica usa categorias nos nomes dos arquivos e das músicas, não análise visual com IA. Com uma única música na pasta, ela inevitavelmente será repetida; adicione pelo menos três faixas diferentes com licença de uso em vídeo.

**IA visual gratuita (opcional):** é possível usar **Ollama + modelo Moondream** no computador. O editor envia somente imagens ao serviço local em `http://127.0.0.1:11434`; não exige chave nem pagamento de API. A opção **IA visual GRATIS local** vem desativada por padrão porque o i5 antigo com 8 GB de RAM pode ficar muito lento. O modelo é aproximadamente 1,7 GB e a inferência no processador pode demorar.
1. Instale o Ollama para Windows de https://ollama.com/download
2. Com o Ollama aberto, execute `ollama pull moondream` no PowerShell.
3. No editor, selecione músicas licenciadas e marque `IA visual GRATIS local`. Não marque simultaneamente a opção de visão na nuvem.
4. Se não quiser instalar nada, **desmarque IA visual local**: a rotação gratuita das músicas já funciona normalmente.

**Importante:** nem a rotação musical por regras nem a IA visual local garantem identificar corretamente a emoção ou o contexto do vídeo. A análise local limita-se a até oito cenas por montagem; as demais usam a categoria neutra. Até o momento o código foi publicado, mas **a interface com reprodução e o modelo local ainda precisam ser testados no seu Windows**.

## Novo: Zoom cinematografico automatico (1.2 Beta)

- O zoom vem ativado por padrao, mas pode ser desativado pela caixa **Zoom cinematografico automatico (1.2x, em algumas cenas)**.
- Aproximacao maxima de 1,2x, centralizada, com curva gradual de entrada e saida durante os primeiros 5 segundos de cenas selecionadas.
- Para evitar zoom em todas as cenas, o programa aplica o efeito em aproximadamente **uma a cada tres cenas**, desde que a cena tenha ao menos 7 segundos. Os cortes continuam ordenados pela data/hora da gravacao.
- A previa em movimento 360p tenta mostrar o mesmo efeito aplicado ao arquivo de exportacao. O processamento 4K do zoom pode exigir muito da CPU i5 antiga.
- O zoom e seletivo, **mas nao rastreia rostos nem identifica automaticamente o objeto mais importante**. Essa seria uma evolucao posterior; o efeito atual e centralizado.
- Em 4K a imagem pode perder alguma nitidez devido a ampliacao digital e nova codificacao.

Teste sugerido: escolha 3 a 5 videos curtos, deixe zoom e previa ativados, exporte inicialmente a 720p, confira os movimentos e depois teste 1080p ou 4K. A integracao ao Windows ainda requer teste no computador do usuario.

## Correcao de inicializacao (12/11/2026)

O arquivo `Iniciar_EditorIA.ps1` agora executa a interface na mesma sessao, mostra uma caixa de erro se a abertura falhar e salva os detalhes em `EditorIA_erro_ao_abrir.txt` na pasta do projeto. Se o programa nao abrir, inicie pelo PowerShell com:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\Iniciar_EditorIA.ps1
```

Execute esse comando dentro da pasta extraida do ZIP. Se surgir erro, copie o conteudo do arquivo de diagnostico, **sem senhas, chaves de API ou dados privados**. Essa melhoria de diagnostico nao garante por si so que todo erro de inicializacao esteja corrigido.
