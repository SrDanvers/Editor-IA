# Editor IA 1.0 Beta — Vlogs automáticos no Windows 10

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
| Música | Lê arquivos licenciados da pasta `Musicas`; trilha discreta e alternativa por cena quando a visão está ativa |
| Limpeza de voz | Filtro passa-altas + redução de ruído constante + compressão. Não garante eliminar vento muito forte |
| Fundo desfocado | Preenche laterais de vídeo vertical com imagem desfocada do próprio vídeo |
| Prévia | Miniaturas da cena em processamento e botão para abrir trecho finalizado, sem vídeo 4K em tempo real |
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
