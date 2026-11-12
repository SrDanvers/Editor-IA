param(
 [switch]$Worker,
 [string]$JobPath
)
$ErrorActionPreference='Stop'
if($Worker){
 $j=Get-Content -LiteralPath $JobPath -Raw -Encoding UTF8 | ConvertFrom-Json
 $progress=Join-Path (Split-Path $JobPath) 'status.json'
 $cancel=Join-Path (Split-Path $JobPath) 'cancel.flag'
 $temporary=Join-Path (Split-Path $JobPath) 'parts'
 New-Item -ItemType Directory -Force -Path $temporary | Out-Null
 function Report($pct,$msg,$state='working'){
   @{pct=$pct;message=$msg;state=$state} | ConvertTo-Json -Compress | Set-Content -LiteralPath $progress -Encoding UTF8
 }
 function CheckCancel {if(Test-Path $cancel){throw 'Cancelado pelo usuario'}}
 function Fmt($n){([double]$n).ToString('0.###',[Globalization.CultureInfo]::InvariantCulture)}
 function CaptureDate([string]$path,$probeData){
   $name=[IO.Path]::GetFileNameWithoutExtension($path)
   # Nomes de camera, por exemplo VID_20261105_093700_180.mp4
   if($name -match '(?<!\d)(20\d{2})(0[1-9]|1[0-2])([0-2]\d|3[01])[_ -]?([01]\d|2[0-3])([0-5]\d)([0-5]\d)(?!\d)'){
     $stamp=$Matches[1]+$Matches[2]+$Matches[3]+$Matches[4]+$Matches[5]+$Matches[6]
     $date=[DateTime]::MinValue
     if([DateTime]::TryParseExact($stamp,'yyyyMMddHHmmss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date)){return $date}
   }
   try{
     $created=$probeData.format.tags.creation_time
     if($created){return [DateTimeOffset]::Parse([string]$created,[Globalization.CultureInfo]::InvariantCulture).LocalDateTime}
   }catch{}
   return [IO.File]::GetLastWriteTime($path)
 }
 function TranscriptRegions($v){
   # Opcional e pago. Somente audio mono comprimido e enviado a API.
   $answer=New-Object System.Collections.ArrayList
   if(-not [bool]$j.transcribe -or -not $v.audio -or -not $env:OPENAI_API_KEY){return $answer}
   Add-Type -AssemblyName System.Net.Http
   [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
   $limit=[Math]::Min([double]$v.duration,600.0)
   $count=[int][Math]::Ceiling($limit/90.0)
   $transcriptLog=Join-Path (Split-Path $JobPath) 'transcricoes.txt'
   for($part=0;$part -lt $count;$part++){
     CheckCancel
     $offset=$part*90.0
     $length=[Math]::Min(90.0,$limit-$offset)
     $audio=Join-Path $temporary ("fala_"+$index+"_"+$part+".mp3")
     $prior=$ErrorActionPreference;$ErrorActionPreference='Continue'
     try { $capture= & $j.ffmpeg -hide_banner -loglevel error -nostdin -y -ss (Fmt $offset) -i ([string]$v.path) -t (Fmt $length) -vn -ac 1 -ar 16000 -b:a 48k $audio 2>&1 | Out-String; $code=$LASTEXITCODE } finally {$ErrorActionPreference=$prior}
     if($code -ne 0 -or -not(Test-Path -LiteralPath $audio)){continue}
     $client=$null;$form=$null;$stream=$null
     try{
       $client=[Net.Http.HttpClient]::new()
       $client.Timeout=[TimeSpan]::FromSeconds(120)
       $client.DefaultRequestHeaders.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$env:OPENAI_API_KEY)
       $form=[Net.Http.MultipartFormDataContent]::new()
       $stream=[IO.File]::OpenRead($audio)
       $fileContent=[Net.Http.StreamContent]::new($stream)
       $fileContent.Headers.ContentType=[Net.Http.Headers.MediaTypeHeaderValue]::new('audio/mpeg')
       $form.Add($fileContent,'file',[IO.Path]::GetFileName($audio))
       $form.Add([Net.Http.StringContent]::new('whisper-1'),'model')
       $form.Add([Net.Http.StringContent]::new('verbose_json'),'response_format')
       $form.Add([Net.Http.StringContent]::new('segment'),'timestamp_granularities[]')
       $form.Add([Net.Http.StringContent]::new('pt'),'language')
       $res=$client.PostAsync('https://api.openai.com/v1/audio/transcriptions',$form).GetAwaiter().GetResult()
       $raw=$res.Content.ReadAsStringAsync().GetAwaiter().GetResult()
       if(-not $res.IsSuccessStatusCode){throw "API HTTP $([int]$res.StatusCode)"}
       $data=$raw | ConvertFrom-Json
       foreach($seg in @($data.segments)){
         $start=[double]$seg.start+$offset
         $end=[double]$seg.end+$offset
         if($end -le $start){continue}
         [void]$answer.Add(@{start=$start;end=$end;text=([string]$seg.text).Trim()})
         Add-Content -LiteralPath $transcriptLog -Encoding UTF8 -Value ("$([IO.Path]::GetFileName($v.path)) [$([Math]::Round($start,2))-$([Math]::Round($end,2))]: "+([string]$seg.text).Trim())
       }
     }catch{
       Add-Content -LiteralPath (Join-Path (Split-Path $JobPath) 'transcricao_erros.txt') -Encoding UTF8 -Value ("$([IO.Path]::GetFileName($v.path)): "+$_.Exception.Message)
     }finally{
       if($form){$form.Dispose()}
       if($stream){$stream.Dispose()}
       if($client){$client.Dispose()}
       Remove-Item -LiteralPath $audio -Force -ErrorAction SilentlyContinue
     }
   }
   return $answer
 }
 function Execute([string[]]$ffArgs){
   CheckCancel
   $log=Join-Path (Split-Path $JobPath) 'ffmpeg.log'
   $prior=$ErrorActionPreference; $ErrorActionPreference='Continue'
   try { $lines= & $j.ffmpeg @ffArgs 2>&1 | Out-String } finally { $ErrorActionPreference=$prior }
   $exit=$LASTEXITCODE
   Add-Content -LiteralPath $log -Value $lines -Encoding UTF8
   if($exit -ne 0){
     $last=($lines -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -Last 4) -join ' | '
     throw ("FFmpeg erro "+$exit+": "+$last+" [Log: "+$log+"]")
   }
   return $lines
 }
 try{
   Report 1 'Analisando arquivos...'
   $info=@()
   $sum=0.0
   foreach($path in $j.inputs){
     CheckCancel
     $raw= & $j.ffprobe -v error -show_entries 'format=duration:format_tags=creation_time:stream=codec_type' -of json $path | Out-String
     if($LASTEXITCODE -ne 0){throw "Nao foi possivel analisar $path"}
     $p=$raw | ConvertFrom-Json
     $duration=[double]::Parse([string]$p.format.duration,[Globalization.CultureInfo]::InvariantCulture)
     if($duration -le 0){continue}
     $hasAudio=(@($p.streams | Where-Object codec_type -eq 'audio').Count -gt 0)
     $info+=@{path=$path;duration=$duration;audio=$hasAudio;capture=(CaptureDate $path $p)}
     $sum+=$duration
   }
   if($sum -le 0){throw 'Nao existem videos validos'}
   # A montagem prioriza diversidade: primeiro um trecho longo por arquivo,
   # depois (apenas se houver espaco) uma segunda passagem por arquivos extensos.
   $uniqueInfo=New-Object System.Collections.ArrayList
   $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
   foreach($v in $info){
     if($seen.Add([IO.Path]::GetFullPath([string]$v.path))){[void]$uniqueInfo.Add($v)}
   }
   $info=@($uniqueInfo | Sort-Object capture,path)
   $sum=0.0;foreach($v in $info){$sum+=[double]$v.duration}
   $goal=[Math]::Min($sum,[Math]::Min(600,[Math]::Max(240,14*$info.Count)))
   $clips=New-Object System.Collections.ArrayList
   $candidates=New-Object System.Collections.ArrayList
   $index=0
   foreach($v in $info){
     CheckCancel
     $index++
     Report ([int](5+20*$index/$info.Count)) ("Analisando pausas de "+[IO.Path]::GetFileName($v.path))
     $regions=New-Object System.Collections.ArrayList
     if($v.audio){
       $prior=$ErrorActionPreference;$ErrorActionPreference='Continue'
       try { $report= & $j.ffmpeg -hide_banner -nostdin -i $v.path -vn -af 'silencedetect=noise=-34dB:d=1.5' -f null NUL 2>&1 | Out-String } finally { $ErrorActionPreference=$prior }
       $beginSpeech=0.0;$silenceStart=$null
       foreach($line in ($report -split '\r?\n')){
         if($line -match 'silence_start:\s*([0-9.]+)'){
           $silenceStart=[double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture)
         }
         if($line -match 'silence_end:\s*([0-9.]+)' -and $null -ne $silenceStart){
           $endSpeech=[Math]::Min([double]$v.duration,$silenceStart)
           if($endSpeech-$beginSpeech -gt 0){[void]$regions.Add(@{start=$beginSpeech;end=$endSpeech})}
           $beginSpeech=[double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture)
           $silenceStart=$null
         }
       }
       if($null -ne $silenceStart){$endSpeech=[Math]::Min([double]$v.duration,$silenceStart)}
       else{$endSpeech=[double]$v.duration}
       if($endSpeech-$beginSpeech -gt 0){[void]$regions.Add(@{start=$beginSpeech;end=$endSpeech})}
     }
     if($regions.Count -eq 0){[void]$regions.Add(@{start=0.0;end=[double]$v.duration})}
     # Juntar pausas curtas para nao interromper frases.
     $merged=New-Object System.Collections.ArrayList
     foreach($r in @($regions | Sort-Object start)){
       if($merged.Count -gt 0 -and ([double]$r.start-[double]$merged[$merged.Count-1].end) -le 3.0){
         $merged[$merged.Count-1].end=[Math]::Max([double]$merged[$merged.Count-1].end,[double]$r.end)
       }else{[void]$merged.Add(@{start=[double]$r.start;end=[double]$r.end})}
     }
     $options=New-Object System.Collections.ArrayList
     # Preferir blocos inteiros identificados por transcricao. Nao dividir segmentos.
     $speech=@()
     if([bool]$j.transcribe -and $v.audio){
       Report ([int](5+20*$index/$info.Count)) ("Transcrevendo fala do video "+$index+" de "+$info.Count)
       $speech=@(TranscriptRegions $v)
     }
     if($speech.Count -gt 0){
       $groupStart=$null;$groupEnd=0.0
       foreach($seg in @($speech | Sort-Object start)){
         $ss=[double]$seg.start;$ee=[double]$seg.end
         if($null -eq $groupStart){$groupStart=$ss;$groupEnd=$ee;continue}
         # Pausa acima de 2,5s: concluir bloco antes de iniciar outro.
         if(($ss-$groupEnd) -gt 2.5){
           $left=[Math]::Max(0,$groupStart-0.6)
           $right=[Math]::Min([double]$v.duration,$groupEnd+0.8)
           if(($right-$left) -gt 2){[void]$options.Add(@{start=$left;length=($right-$left)})}
           $groupStart=$ss;$groupEnd=$ee
         }else{$groupEnd=[Math]::Max($groupEnd,$ee)}
       }
       if($null -ne $groupStart){
         $left=[Math]::Max(0,$groupStart-0.6)
         $right=[Math]::Min([double]$v.duration,$groupEnd+0.8)
         if(($right-$left) -gt 2){[void]$options.Add(@{start=$left;length=($right-$left)})}
       }
     }
     # Apenas cortes em pausas detectadas. Margem de 0,45s antes/depois da fala.
     # NAO dividir falas por limite arbitrario de 40 segundos.
     if($options.Count -eq 0){foreach($r in $merged){
       $rawStart=[double]$r.start
       $rawEnd=[double]$r.end
       $start=[Math]::Max(0,$rawStart-0.45)
       $end=[Math]::Min([double]$v.duration,$rawEnd+0.45)
       if(($end-$start) -ge 4){
         [void]$options.Add(@{start=$start;length=($end-$start)})
       }
     }}
     if($options.Count -eq 0){
       # Sem pausas confiaveis: conservar o video inteiro, sem cortar frases.
       [void]$options.Add(@{start=0.0;length=[double]$v.duration})
     }
     # Dar preferencia a um bloco completo da metade do video.
     $first=@($options | Sort-Object @{Expression={[Math]::Abs(($_.start+$_.length/2)-([double]$v.duration/2))}})[0]
     [void]$candidates.Add(@{path=$v.path;duration=$v.duration;audio=$v.audio;order=$index;options=@($options);first=$first})
   }
   # Preservar ao menos um bloco COMPLETO de cada video na ordem cronologica.
   # A duracao desejada e um alvo flexivel, nunca um ponto de corte dentro da fala.
   $usedSeconds=0.0
   foreach($entry in $candidates){
     $opt=$entry.first
     if([double]$opt.length -ge 2){
       [void]$clips.Add(@{path=$entry.path;start=$opt.start;length=$opt.length;audio=$entry.audio;order=$entry.order;pass=1})
       $usedSeconds += [double]$opt.length
     }
   }
   # Se ainda couber, adicionar outra fala completa, sem sobrepor a primeira.
   if($usedSeconds -lt $goal -and $candidates.Count -le 6){
     foreach($entry in $candidates){
       if($usedSeconds -ge $goal){break}
       $firstStart=[double]$entry.first.start
       $firstEnd=$firstStart+[double]$entry.first.length
       $other=@($entry.options | Sort-Object start | Where-Object {
         $start=[double]$_.start
         $end=$start+[double]$_.length
         ($end -le ($firstStart-1)) -or ($start -ge ($firstEnd+1))
       } | Select-Object -First 1)
       if($other.Count -gt 0){
         $opt=$other[0]
         # Nao adicionar bloco que ultrapasse muito a duracao-alvo.
         if(($usedSeconds+[double]$opt.length) -le ($goal+30)){
           [void]$clips.Add(@{path=$entry.path;start=$opt.start;length=$opt.length;audio=$entry.audio;order=$entry.order;pass=2})
           $usedSeconds += [double]$opt.length
         }
       }
     }
   }
   if($clips.Count -eq 0){throw 'Nenhum trecho valido encontrado'}
   # Revisao e auditoria: plano cronologico antes da exportacao.
   $cutRows=@()
   $number=0
   foreach($cut in @($clips | Sort-Object order,start)){
     $number++
     $cutRows+= [pscustomobject]@{
       numero=$number
       arquivo=[IO.Path]::GetFileName([string]$cut.path)
       inicio_segundos=[Math]::Round([double]$cut.start,2)
       fim_segundos=[Math]::Round(([double]$cut.start+[double]$cut.length),2)
       duracao_segundos=[Math]::Round([double]$cut.length,2)
     }
   }
   $cutRows | Export-Csv -LiteralPath (Join-Path (Split-Path $JobPath) 'plano_cortes.csv') -Delimiter ';' -NoTypeInformation -Encoding UTF8

   # Analise visual opcional: apenas dois quadros de alguns cortes escolhidos.
   $visionOn=([bool]$j.visual) -and (-not [string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY))
   $songs=@()
   if($j.musicFolder -and (Test-Path -LiteralPath ([string]$j.musicFolder) -PathType Container)){
     $songs=@(Get-ChildItem -LiteralPath ([string]$j.musicFolder) -File -Recurse |
       Where-Object { @('.mp3','.wav','.m4a','.flac','.ogg') -contains $_.Extension.ToLowerInvariant() } | Sort-Object FullName)
   }
   if($songs.Count -eq 0){
     Report 24 'Sem musicas na biblioteca: exportacao tera somente voz/audio original.'
   }else{
     Report 24 ("Biblioteca encontrada: "+$songs.Count+" musica(s) disponivel(is).")
   }
   if([bool]$j.visual -and -not $visionOn){ Report 26 'Sem OPENAI_API_KEY: trilhas seguem a escolha local.' }
   $script:visionUsed=0
   $visionMemo=@{}
   function VisualCategory($cut){
     if(-not $visionOn -or $script:visionUsed -ge 8){return 'neutra'}
     $frameContent=New-Object System.Collections.ArrayList
     foreach($fraction in @(0.25,0.70)){
       $position=[double]$cut.start+([double]$cut.length*$fraction)
       $img=Join-Path $temporary ('quadro_'+$script:visionUsed+'_'+$fraction.ToString('0.00',[Globalization.CultureInfo]::InvariantCulture)+'.jpg')
       $prior=$ErrorActionPreference;$ErrorActionPreference='Continue'
       try{$null= & $j.ffmpeg -hide_banner -loglevel error -nostdin -y -ss (Fmt $position) -i ([string]$cut.path) -frames:v 1 -vf 'scale=448:-2' -q:v 5 $img 2>&1 | Out-String}finally{$ErrorActionPreference=$prior}
       if(Test-Path -LiteralPath $img){
         $base64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($img))
         [void]$frameContent.Add(@{type='input_image';image_url=('data:image/jpeg;base64,'+$base64);detail='low'})
         Remove-Item -LiteralPath $img -Force -ErrorAction SilentlyContinue
       }
     }
     if($frameContent.Count -eq 0){return 'neutra'}
     $script:visionUsed++
     $payload=@{
       model='gpt-4.1-mini'
       max_output_tokens=24
       input=@(@{role='user';content=@(@{type='input_text';text='Analise somente estas imagens do mesmo trecho de vlog. Escolha UMA categoria de trilha instrumental apropriada: calma, animada, viagem, neutra. Responda apenas com uma dessas quatro palavras, sem explicacao. Nao identifique pessoas.'})+@($frameContent)})
     } | ConvertTo-Json -Depth 12 -Compress
     try {
       $response=Invoke-RestMethod -Uri 'https://api.openai.com/v1/responses' -Method Post -Headers @{Authorization=('Bearer '+$env:OPENAI_API_KEY)} -Body ([Text.Encoding]::UTF8.GetBytes($payload)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 90
       $raw=(@($response.output | ForEach-Object {$_.content} | Where-Object type -eq 'output_text' | ForEach-Object text) -join ' ').Trim().ToLowerInvariant()
       if($raw -match '\b(calma|animada|viagem|neutra)\b'){return $Matches[1]}
     }catch{
       Add-Content -LiteralPath (Join-Path (Split-Path $JobPath) 'visao_erros.txt') -Value ("Analise visual nao concluida: "+$_.Exception.Message) -Encoding UTF8
     }
     return 'neutra'
   }
   $previewFile=Join-Path (Split-Path $JobPath) 'preview.jpg'
   # IA visual gratuita opcional: Moondream instalado localmente com Ollama.
   $script:localVisionCount=0
   function LocalVisionCategory($cut){
     if(-not [bool]$j.localVision -or $script:localVisionCount -ge 8){return 'neutra'}
     $shot=Join-Path $temporary ('visao_local_'+$script:localVisionCount+'.jpg')
     $at=[double]$cut.start+[double]$cut.length*0.5
     $prior=$ErrorActionPreference;$ErrorActionPreference='Continue'
     try{$null= & $j.ffmpeg -hide_banner -loglevel error -nostdin -y -ss (Fmt $at) -i ([string]$cut.path) -frames:v 1 -vf 'scale=384:-2' -q:v 6 $shot 2>&1 | Out-String}finally{$ErrorActionPreference=$prior}
     if(-not(Test-Path -LiteralPath $shot)){return 'neutra'}
     $script:localVisionCount++
     try{
       $b64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($shot))
       $body=@{
         model='moondream';stream=$false;keep_alive='0'
         prompt='Choose exactly one instrumental background music category that fits this video frame: calma, animada, viagem, neutra. Return only that single word.'
         images=@($b64);options=@{num_predict=30;num_ctx=512}
       } | ConvertTo-Json -Depth 8 -Compress
       $resp=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 240
       $ans=([string]$resp.response).ToLowerInvariant()
       if($ans -match '\b(calma|animada|viagem|neutra)\b'){return $Matches[1]}
     }catch{
       Add-Content -LiteralPath (Join-Path (Split-Path $JobPath) 'visao_local_erros.txt') -Encoding UTF8 -Value $_.Exception.Message
     }finally{Remove-Item -LiteralPath $shot -Force -ErrorAction SilentlyContinue}
     return 'neutra'
   }
   function PickMusic($cut,$slot,$category){
     if($songs.Count -eq 0){return $null}
     $matched=@($songs | Where-Object {$_.BaseName.ToLowerInvariant() -match ('^'+$category+'[-_ ]')})
     # Alternar de verdade quando ha mais de uma musica licenciada.
     if($matched.Count -lt 2){$matched=$songs}
     $index=($slot % $matched.Count)
     return $matched[$index].FullName
   }
   function CreateMusicBed($cut,$clipNumber,$category){
     if($songs.Count -eq 0){return $null}
     $bedDir=Join-Path $temporary ('trilha_'+$clipNumber)
     New-Item -ItemType Directory -Force -Path $bedDir | Out-Null
     $listPath=Join-Path $bedDir 'musicas.txt'
     $parts=New-Object 'System.Collections.Generic.List[string]'
     $remaining=[double]$cut.length
     $partIndex=0
     while($remaining -gt 0.05 -and $partIndex -lt 180){
       CheckCancel
       $duration=[Math]::Min(40.0,$remaining)
       $song=PickMusic $cut (($clipNumber-1)+$partIndex) $category
       $path=Join-Path $bedDir ('audio_{0:D3}.m4a' -f $partIndex)
       $fadeOut=[Math]::Max(0,$duration-[Math]::Min(1.2,$duration/4))
       $af='aresample=44100,volume=0.13,afade=t=in:st=0:d=0.8,afade=t=out:st='+(Fmt $fadeOut)+':d=1.2'
       # Encurtar a trilha em blocos de ate 40s. Musicass sao editadas, nao baixadas.
       Execute -ffArgs @('-hide_banner','-loglevel','error','-nostdin','-y','-stream_loop','-1','-i',$song,'-t',(Fmt $duration),'-vn','-af',$af,'-ar','44100','-ac','2','-c:a','aac','-b:a','128k',$path) | Out-Null
       $parts.Add("file '"+$path.Replace("'","'\''")+"'")
       $remaining-=$duration
       $partIndex++
       Add-Content -LiteralPath (Join-Path (Split-Path $JobPath) 'trilhas_escolhidas.txt') -Encoding UTF8 -Value ("Cena "+$clipNumber+" / Parte "+$partIndex+": "+[IO.Path]::GetFileName($song)+" ("+$category+")")
     }
     if($parts.Count -eq 0){return $null}
     [IO.File]::WriteAllLines($listPath,$parts,[Text.UTF8Encoding]::new($false))
     $bed=Join-Path $bedDir 'trilha_completa.m4a'
     Execute -ffArgs @('-hide_banner','-loglevel','error','-nostdin','-y','-f','concat','-safe','0','-i',$listPath,'-c','copy',$bed) | Out-Null
     return $bed
   }
   $list=Join-Path $temporary 'concat.txt'
   $records=New-Object System.Collections.Generic.List[string]
   $i=0
   foreach($c in @($clips | Sort-Object order,start)){
     CheckCancel
     $i++
     $piece=Join-Path $temporary ('clip_{0:D4}.mp4' -f $i)
     # Previa EM MOVIMENTO a 360p e 15fps: reproduz enquanto o 4K e renderizado.
     # Pode levar alguns segundos para ficar pronta; nao e imagem fixa.
     if([bool]$j.livePreview){
       $proxy=Join-Path $temporary ('previsualizacao_{0:D4}.mp4' -f $i)
       $proxyFx='fps=15,scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:(ow-iw)/2:(oh-ih)/2'
       if(([bool]$j.autoZoom) -and ($i % 3 -eq 2) -and ([double]$c.length -ge 7)){
         $proxyFx+=",zoompan=z='1+0.20*sin(PI*min(on\,75)/75)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=640x360:fps=15"
       }
       $prior=$ErrorActionPreference;$ErrorActionPreference='Continue'
       try {
         $null= & $j.ffmpeg -hide_banner -loglevel error -nostdin -y -ss (Fmt ([double]$c.start)) -i ([string]$c.path) -t (Fmt ([double]$c.length)) -an -vf $proxyFx -c:v libx264 -preset ultrafast -crf 29 -threads 2 -movflags +faststart $proxy 2>&1 | Out-String
       } finally {$ErrorActionPreference=$prior}
       if(Test-Path -LiteralPath $proxy){
         Set-Content -LiteralPath (Join-Path (Split-Path $JobPath) 'preview_video.txt') -Value $proxy -Encoding UTF8
       }
     }
     # Uma miniatura por cena selecionada: leve e visivel durante a exportacao.
     $thumb=Join-Path (Split-Path $JobPath) ('preview_{0:D4}.jpg' -f $i)
     $at=[Math]::Max(0,[double]$c.start+[double]$c.length*0.5)
     $prior=$ErrorActionPreference;$ErrorActionPreference='Continue'
     try {
       $null= & $j.ffmpeg -hide_banner -loglevel error -nostdin -y -ss (Fmt $at) -i ([string]$c.path) -frames:v 1 -vf 'scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:(ow-iw)/2:(oh-ih)/2' -q:v 5 $thumb 2>&1 | Out-String
     } finally {$ErrorActionPreference=$prior}
     if(Test-Path -LiteralPath $thumb){
       # Troca atomica para evitar que a interface leia JPEG incompleto.
       Copy-Item -LiteralPath $thumb -Destination ($previewFile+'.new') -Force
       Move-Item -LiteralPath ($previewFile+'.new') -Destination $previewFile -Force
     }
     Report ([int](25+69*($i-1)/$clips.Count)) ("Cena $i de "+$clips.Count+" - "+[IO.Path]::GetFileName([string]$c.path))
     $params=@('-hide_banner','-nostdin','-y','-ss',(Fmt $c.start),'-i',[string]$c.path)
     if(-not $c.audio){$params+=@('-f','lavfi','-i','anullsrc=channel_layout=stereo:sample_rate=44100')}
     $params+=@('-t',(Fmt $c.length))
     $profile=([string]$j.quality)
     switch($profile){
       '1080p' {$w=1920;$h=1080;$crf='20';$preset='veryfast'}
       '720p'  {$w=1280;$h=720;$crf='23';$preset='veryfast'}
       default {$w=3840;$h=2160;$crf='18';$preset='ultrafast'}
     }
     # Fundo borrado de baixa resolucao para reduzir o custo de CPU.
     # A camada principal conserva o enquadramento, sem barras pretas.
     $filter="[0:v]split=2[bgsrc][fgsrc];[bgsrc]scale=320:180:force_original_aspect_ratio=increase,crop=320:180,boxblur=12:1,scale=$($w):$($h),setsar=1[bg];[fgsrc]scale=$($w):$($h):force_original_aspect_ratio=decrease,setsar=1[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2:shortest=1,format=yuv420p,fps=30[v]"
     # Zoom cinematografico limitado a uma cena a cada tres, evitando movimentos repetitivos.
     # A curva sobe e desce suavemente durante os primeiros 5 segundos do corte.
     $enableZoom=([bool]$j.autoZoom) -and ($i % 3 -eq 2) -and ([double]$c.length -ge 7)
     if($enableZoom){
       $zoomAmount=0.20
       $zoomFx="zoompan=z='1+$zoomAmount*sin(PI*min(on\,150)/150)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=$($w)x$($h):fps=30"
       $filter+=';[v]'+$zoomFx+'[outv]'
       $params+=@('-filter_complex',$filter,'-map','[outv]')
     }else{
       $params+=@('-filter_complex',$filter,'-map','[v]')
     }
     if($c.audio){$params+=@('-map','0:a:0')}else{$params+=@('-map','1:a:0')}
     if([bool]$j.cleanVoice){
       # Reduz vento (frequencias graves), ruido constante e equilibra a voz.
       # Nao elimina vento forte por completo.
       $voiceFilter='highpass=f=150,lowpass=f=7500,afftdn=nf=-25,acompressor=threshold=0.10:ratio=2.7:attack=20:release=220:makeup=1.5,alimiter=limit=0.95'
       $params+=@('-af',$voiceFilter)
     }
     $params+=@('-c:v','libx264','-preset',$preset,'-crf',$crf,'-threads','2','-c:a','aac','-b:a','192k','-ar','44100','-ac','2','-shortest',$piece)
     [void](Execute -ffArgs $params)
     # Trilha automatica por cena: funciona SEM API e troca a musica a cada 40s.
     if($songs.Count -gt 0){
       $category='neutra'
       if($visionOn){$category=VisualCategory $c}
       elseif([bool]$j.localVision){$category=LocalVisionCategory $c}
       else {
         $filename=[IO.Path]::GetFileNameWithoutExtension([string]$c.path).ToLowerInvariant()
         if($filename -match 'praia|viagem|ferias|natureza|montanha|travel|passeio'){$category='viagem'}
         elseif($filename -match 'festa|esporte|piscina|corrida|danca|aventura'){$category='animada'}
         elseif($filename -match 'pordosol|por.do.sol|descanso|dormir|calm'){$category='calma'}
       }
       $bed=CreateMusicBed $c $i $category
       if($bed){
         $mixed=Join-Path $temporary ('mix_{0:D4}.mp4' -f $i)
         # Voz do clipe prioritária; trilha gravada a nivel baixo e limitada.
         $fx='[0:a][1:a]amix=inputs=2:duration=first:normalize=0,alimiter=limit=0.94[a]'
         Execute -ffArgs @('-hide_banner','-loglevel','error','-nostdin','-y','-i',$piece,'-i',$bed,'-filter_complex',$fx,'-map','0:v:0','-map','[a]','-c:v','copy','-c:a','aac','-ar','44100','-ac','2','-b:a','192k','-shortest',$mixed) | Out-Null
         Move-Item -LiteralPath $mixed -Destination $piece -Force
         Report ([int](25+69*$i/$clips.Count)) ("Cena $i mixada com musicas variadas ("+$category+")")
       }
     }
     if(Test-Path -LiteralPath $piece -PathType Leaf){
       Set-Content -LiteralPath (Join-Path (Split-Path $JobPath) 'completed_clip.txt') -Value $piece -Encoding UTF8
     }
     $records.Add("file '"+$piece.Replace("'","'\''")+"'")
     Report ([int](25+69*$i/$clips.Count)) ("Processando corte $i de "+$clips.Count)
   }
   # Tela final opcional: imagem PNG/JPG do usuario transformada em cena MP4.
   if($j.outroImage){
     $outroPath=[string]$j.outroImage
     if(-not(Test-Path -LiteralPath $outroPath -PathType Leaf)){throw ("Imagem da tela final nao encontrada: "+$outroPath)}
     $outroSeconds=[double]$j.outroSeconds
     if($outroSeconds -lt 3 -or $outroSeconds -gt 30){$outroSeconds=8}
     $outroClip=Join-Path $temporary 'tela_final.mp4'
     $outroFilter="scale=$($w):$($h):force_original_aspect_ratio=decrease,pad=$($w):$($h):(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p"
     Report 94 ("Criando tela final de "+(Fmt $outroSeconds)+" segundos...")
     # Mesmos codecs, resolucao e fps dos cortes; audio silencioso para manter sincronismo.
     Execute -ffArgs @('-hide_banner','-loglevel','error','-nostdin','-y','-loop','1','-framerate','30','-i',$outroPath,
       '-f','lavfi','-i','anullsrc=r=44100:cl=stereo',
       '-t',(Fmt $outroSeconds),'-vf',$outroFilter,'-r','30',
       '-map','0:v:0','-map','1:a:0','-c:v','libx264','-preset',$preset,'-crf',$crf,'-threads','2','-pix_fmt','yuv420p',
       '-c:a','aac','-b:a','192k','-ar','44100','-ac','2','-shortest',$outroClip) | Out-Null
     $records.Add("file '"+$outroClip.Replace("'","'\''")+"'")
   }
   [IO.File]::WriteAllLines($list,$records,[Text.UTF8Encoding]::new($false))
   # Cada corte ja recebeu sua trilha: nao colocar uma unica musica no vlog inteiro.
   $joined=Join-Path $temporary 'video_montado.mp4'
   Execute -ffArgs @('-hide_banner','-nostdin','-y','-f','concat','-safe','0','-i',$list,'-c','copy','-movflags','+faststart',$joined) | Out-Null
   Move-Item -LiteralPath $joined -Destination ([string]$j.output) -ErrorAction Stop
   if(-not(Test-Path -LiteralPath ([string]$j.output) -PathType Leaf)){throw 'Arquivo final nao foi encontrado'}
   Report 100 ("Concluido. "+$(if($songs.Count -gt 0){"Trilhas por cena. "}else{"Sem biblioteca musical. "})+"Video: "+$j.output) 'success'
 } catch {
   if($_.Exception.Message -match 'Cancelado'){Report 0 'Processamento cancelado' 'cancel'}
   else{Report 0 $_.Exception.Message 'error'}
 } finally {
   if((Test-Path $progress) -and ((Get-Content -LiteralPath $progress -Raw | ConvertFrom-Json).state -eq 'success')){ Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue }
 }
 return
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$f=New-Object Windows.Forms.Form
$f.Text='Editor IA 1.2.1 Beta - Zoom e Tela Final'
$f.Size=New-Object Drawing.Size(1170,870)
$f.AutoScroll=$true
$f.StartPosition='CenterScreen'
$f.BackColor=[Drawing.Color]::FromArgb(25,25,28)
$f.ForeColor='White'
$f.Font=New-Object Drawing.Font('Segoe UI',10)
function Label($text,$x,$y,$w=730){
 $t=New-Object Windows.Forms.Label;$t.Text=$text;$t.Location=New-Object Drawing.Point($x,$y)
 $t.Size=New-Object Drawing.Size($w,26);$f.Controls.Add($t);return $t
}
function Button($text,$x,$y,$w){
 $b=New-Object Windows.Forms.Button;$b.Text=$text;$b.Location=New-Object Drawing.Point($x,$y)
 $b.Size=New-Object Drawing.Size($w,32);$b.BackColor=[Drawing.Color]::FromArgb(65,65,70)
 $b.ForeColor='White';$b.FlatStyle='Flat';$f.Controls.Add($b);return $b
}
function Field($x,$y,$w){
 $t=New-Object Windows.Forms.TextBox;$t.Location=New-Object Drawing.Point($x,$y);$t.Size=New-Object Drawing.Size($w,26)
 $f.Controls.Add($t);return $t
}
$t=Label 'EDITOR IA 1.2.1 BETA' 20 12
$t.Font=New-Object Drawing.Font('Segoe UI',18,[Drawing.FontStyle]::Bold)
$t.ForeColor=[Drawing.Color]::Gold
[void](Label 'Vlogs: ordem cronologica, cenas longas, fundo desfocado e musica automatica' 20 52)
[void](Label '1. Videos para analisar' 20 90)
$files=New-Object Windows.Forms.ListBox
$files.Location=New-Object Drawing.Point(20,118);$files.Size=New-Object Drawing.Size(580,150)
$files.SelectionMode='MultiExtended';$f.Controls.Add($files)
$add=Button 'Adicionar arquivos' 614 118 145
$addFolder=Button 'Adicionar pasta' 614 154 145
$remove=Button 'Remover' 614 190 145
$clear=Button 'Limpar' 614 226 145
$add.Add_Click({
 $d=New-Object Windows.Forms.OpenFileDialog;$d.Filter='Videos|*.mp4;*.mov;*.mkv;*.avi;*.webm|Todos|*.*'
 $d.Multiselect=$true
 if($d.ShowDialog() -eq 'OK'){foreach($p in $d.FileNames){if(-not $files.Items.Contains($p)){[void]$files.Items.Add($p)}}}
})
$addFolder.Add_Click({
 $d=New-Object Windows.Forms.FolderBrowserDialog
 $d.Description='Selecione a pasta que contem os videos copiados para o PC'
 if($d.ShowDialog() -eq 'OK'){
   $extensions=@('.mp4','.mov','.mkv','.avi','.webm','.m4v')
   $paths=@(Get-ChildItem -LiteralPath $d.SelectedPath -File -Recurse -ErrorAction SilentlyContinue |
     Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } |
     Sort-Object FullName)
   foreach($file in $paths){
     if(-not $files.Items.Contains($file.FullName)){[void]$files.Items.Add($file.FullName)}
   }
   [Windows.Forms.MessageBox]::Show(("Encontrados "+$paths.Count+" videos na pasta e subpastas."),'Editor IA') | Out-Null
 }
})
$remove.Add_Click({for($i=$files.SelectedIndices.Count-1;$i -ge 0;$i--){$files.Items.RemoveAt($files.SelectedIndices[$i])}})
$clear.Add_Click({$files.Items.Clear()})
[void](Label '2. Arquivo final MP4' 20 282)
$out=Field 20 309 580
$save=Button 'Salvar em...' 614 307 145
$save.Add_Click({
 $d=New-Object Windows.Forms.SaveFileDialog;$d.Filter='MP4|*.mp4';$d.FileName='vlog_automatico.mp4'
 if($d.ShowDialog() -eq 'OK'){$out.Text=$d.FileName}
})
[void](Label '3. Qualidade de exportacao' 20 347 270)
$quality=New-Object Windows.Forms.ComboBox
$quality.DropDownStyle='DropDownList';$quality.Location=New-Object Drawing.Point(312,347)
$quality.Size=New-Object Drawing.Size(290,30)
$quality.BackColor=[Drawing.Color]::White
$quality.ForeColor=[Drawing.Color]::Black
$quality.FlatStyle='Standard'
$quality.Visible=$true
[void]$quality.Items.Add('4K (3840x2160) - melhor resolucao')
[void]$quality.Items.Add('1080p (1920x1080)')
[void]$quality.Items.Add('720p (1280x720)')
$quality.SelectedIndex=0;$f.Controls.Add($quality)
$quality.BringToFront()
[void](Label '4. Caminho do ffmpeg.exe' 20 387)
$ff=Field 20 417 580
$browse=Button 'Localizar' 614 415 145
$browse.Add_Click({
 $d=New-Object Windows.Forms.OpenFileDialog;$d.Filter='ffmpeg.exe|ffmpeg.exe'
 if($d.ShowDialog() -eq 'OK'){$ff.Text=$d.FileName}
})
$paths=@(
 (Join-Path $env:USERPROFILE 'Downloads\ffmpeg-master-latest-win64-gpl\ffmpeg-master-latest-win64-gpl\bin\ffmpeg.exe'),
 'C:\ffmpeg\bin\ffmpeg.exe'
)
foreach($p in $paths){if(Test-Path -LiteralPath $p){$ff.Text=$p;break}}
if(-not $ff.Text){$c=Get-Command ffmpeg.exe -ErrorAction SilentlyContinue;if($c){$ff.Text=$c.Source}}
[void](Label '5. Biblioteca musical (pasta com faixas licenciadas)' 20 465 550)
$music=Field 20 493 580
$musicBrowse=Button 'Escolher pasta' 614 491 145
$musicBrowse.Add_Click({
  $d=New-Object Windows.Forms.FolderBrowserDialog
  $d.Description='Selecione a pasta de musicas com licenca de uso em videos'
  if($d.ShowDialog() -eq 'OK'){$music.Text=$d.SelectedPath}
})
$musicDefault=Join-Path $PSScriptRoot 'Musicas'
if(Test-Path -LiteralPath $musicDefault -PathType Container){$music.Text=$musicDefault}
$autoZoom=New-Object Windows.Forms.CheckBox
$autoZoom.Text='Zoom cinematografico automatico (1.2x, em algumas cenas)'
$autoZoom.Location=New-Object Drawing.Point(20,559)
$autoZoom.Size=New-Object Drawing.Size(730,24)
$autoZoom.ForeColor=[Drawing.Color]::White
$autoZoom.Checked=$true
$f.Controls.Add($autoZoom)
$visual=New-Object Windows.Forms.CheckBox
$visual.Text='Analisar imagens dos trechos selecionados (IA online - envia ate 16 quadros)'
$visual.Location=New-Object Drawing.Point(20,531)
$visual.Size=New-Object Drawing.Size(720,24)
$visual.ForeColor=[Drawing.Color]::White
$visual.Checked=$false
$f.Controls.Add($visual)
$run=Button 'CRIAR VLOG AUTOMATICAMENTE' 20 583 385
$run.BackColor=[Drawing.Color]::Gold;$run.ForeColor='Black'
$stop=Button 'CANCELAR' 418 583 145;$stop.Enabled=$false
$folder=Button 'Abrir pasta' 576 583 183
$bar=New-Object Windows.Forms.ProgressBar;$bar.Location=New-Object Drawing.Point(20,633)
$bar.Size=New-Object Drawing.Size(739,19);$f.Controls.Add($bar)
[void](Label '6. Tela final do video (opcional, PNG/JPG)' 20 701 530)
$outroImage=Field 20 733 480
$outroBrowse=Button 'Escolher imagem' 510 731 145
$outroBrowse.Add_Click({
 $d=New-Object Windows.Forms.OpenFileDialog
 $d.Filter='Imagens|*.png;*.jpg;*.jpeg;*.bmp|Todos os arquivos|*.*'
 if($d.ShowDialog() -eq 'OK'){$outroImage.Text=$d.FileName}
})
$outroDuration=New-Object Windows.Forms.ComboBox
$outroDuration.DropDownStyle='DropDownList'
$outroDuration.Location=New-Object Drawing.Point(666,733)
$outroDuration.Size=New-Object Drawing.Size(94,28)
$outroDuration.BackColor=[Drawing.Color]::White
$outroDuration.ForeColor=[Drawing.Color]::Black
[void]$outroDuration.Items.Add('5 segundos')
[void]$outroDuration.Items.Add('8 segundos')
[void]$outroDuration.Items.Add('10 segundos')
[void]$outroDuration.Items.Add('15 segundos')
$outroDuration.SelectedIndex=1
$f.Controls.Add($outroDuration)
$outroDuration.BringToFront()
$status=Label 'A pre-visualizacao mostra quadros dos trechos em edicao, sem decodificacao 4K continua.' 20 664
$previewTitle=Label 'PRE-VISUALIZACAO DA MONTAGEM' 787 88 350
$previewTitle.ForeColor=[Drawing.Color]::Gold
$previewTitle.Font=New-Object Drawing.Font('Segoe UI',12,[Drawing.FontStyle]::Bold)
$preview=New-Object Windows.Forms.PictureBox
$preview.Location=New-Object Drawing.Point(786,121)
$preview.Size=New-Object Drawing.Size(345,225)
$preview.BackColor=[Drawing.Color]::Black
$preview.BorderStyle='FixedSingle'
$preview.SizeMode='Zoom'
$f.Controls.Add($preview)
# Hospedar o reprodutor WPF na mesma area. Quando indisponivel, mostrar JPEG.
$script:player=$null
$script:playerHost=$null
try{
 Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,WindowsFormsIntegration -ErrorAction Stop
 $script:player=[System.Windows.Controls.MediaElement]::new()
 $script:player.LoadedBehavior=[System.Windows.Controls.MediaState]::Manual
 $script:player.UnloadedBehavior=[System.Windows.Controls.MediaState]::Stop
 $script:player.Stretch=[System.Windows.Media.Stretch]::Uniform
 $script:player.IsMuted=$true
 $script:playerHost=[System.Windows.Forms.Integration.ElementHost]::new()
 $script:playerHost.Location=New-Object Drawing.Point(786,121)
 $script:playerHost.Size=New-Object Drawing.Size(345,225)
 $script:playerHost.BackColor=[Drawing.Color]::Black
 $script:playerHost.Child=$script:player
 $f.Controls.Add($script:playerHost)
 $script:playerHost.BringToFront()
 $script:player.Add_MediaEnded({try{$script:player.Position=[TimeSpan]::Zero;$script:player.Play()}catch{}})
 $script:player.Add_MediaFailed({
   $script:playerHost.Visible=$false
   $preview.BringToFront()
 })
}catch{$script:player=$null;$script:playerHost=$null}
$script:previewVideoPath=''
function UpdateMotionPreview {
 if(-not $script:work -or -not $script:player){return}
 $note=Join-Path $script:work 'preview_video.txt'
 if(-not(Test-Path -LiteralPath $note -PathType Leaf)){return}
 try{
   $path=(Get-Content -LiteralPath $note -Raw -Encoding UTF8).Trim()
   if(-not $path -or $path -eq $script:previewVideoPath -or -not(Test-Path -LiteralPath $path -PathType Leaf)){return}
   $script:player.Stop()
   $script:player.Source=[Uri]::new($path,[UriKind]::Absolute)
   $script:player.Position=[TimeSpan]::Zero
   $script:playerHost.Visible=$true
   $script:playerHost.BringToFront()
   $script:player.Play()
   $script:previewVideoPath=$path
 }catch{
   if($script:playerHost){$script:playerHost.Visible=$false}
   $preview.BringToFront()
 }
}
$previewInfo=Label 'Aguardando a primeira cena...' 786 359 345
$previewInfo.AutoEllipsis=$true
$previewInfo.Size=New-Object Drawing.Size(345,48)
$previewHelp=Label 'Reproducao real do corte em 360p durante renderizacao 4K. Repete a cena ate a proxima ficar pronta.' 786 411 350
$previewHelp.Size=New-Object Drawing.Size(345,70)
$livePreview=New-Object Windows.Forms.CheckBox
$livePreview.Text='Mostrar cortes em movimento durante a edicao (360p)'
$livePreview.Location=New-Object Drawing.Point(786,523)
$livePreview.Size=New-Object Drawing.Size(355,30)
$livePreview.Checked=$true
$f.Controls.Add($livePreview)
$localVision=New-Object Windows.Forms.CheckBox
$localVision.Text='IA visual GRATIS local (Ollama + Moondream, opcional)'
$localVision.Location=New-Object Drawing.Point(786,553)
$localVision.Size=New-Object Drawing.Size(355,30)
$localVision.Checked=$false
$f.Controls.Add($localVision)
$cleanVoice=New-Object Windows.Forms.CheckBox
$cleanVoice.Text='Reduzir vento e priorizar voz'
$cleanVoice.Location=New-Object Drawing.Point(786,586)
$cleanVoice.Size=New-Object Drawing.Size(345,30)
$cleanVoice.ForeColor=[Drawing.Color]::White
$cleanVoice.Checked=$true
$f.Controls.Add($cleanVoice)
$musicState=Label 'Musicas: escolha uma pasta com MP3s licenciados.' 786 615 345
$musicState.Size=New-Object Drawing.Size(345,55)
$transcribe=New-Object Windows.Forms.CheckBox
$transcribe.Text='Cortes por transcricao de voz (API paga; envia audio)'
$transcribe.Location=New-Object Drawing.Point(786,678)
$transcribe.Size=New-Object Drawing.Size(355,28)
$transcribe.ForeColor=[Drawing.Color]::White
$transcribe.Checked=$false
$f.Controls.Add($transcribe)
$openPlan=Button 'Ver plano dos cortes (CSV)' 786 712 345
$openPlan.Add_Click({
 if(-not $script:work){[Windows.Forms.MessageBox]::Show('Inicie uma montagem primeiro.','Editor IA') | Out-Null;return}
 $plan=Join-Path $script:work 'plano_cortes.csv'
 if(Test-Path -LiteralPath $plan -PathType Leaf){Start-Process -FilePath $plan}
 else{[Windows.Forms.MessageBox]::Show('O plano de cortes ainda esta sendo preparado.','Editor IA') | Out-Null}
})
$playClip=Button 'Reproduzir trecho concluido' 786 486 345
$playClip.Enabled=$false
$script:lastClip=$null
$playClip.Add_Click({
 if($script:lastClip -and (Test-Path -LiteralPath $script:lastClip -PathType Leaf)){
   Start-Process -FilePath $script:lastClip
 }else{
   [Windows.Forms.MessageBox]::Show('O trecho ainda nao esta disponivel.','Editor IA') | Out-Null
 }
})
$script:work=$null;$script:proc=$null;$script:active=$false
$script:previewStamp=[datetime]::MinValue
function UpdatePreview {
 if(-not $script:work){return}
 $path=Join-Path $script:work 'preview.jpg'
 if(-not (Test-Path -LiteralPath $path -PathType Leaf)){return}
 try {
   $stamp=(Get-Item -LiteralPath $path).LastWriteTimeUtc
   if($stamp -le $script:previewStamp){return}
   $bytes=[IO.File]::ReadAllBytes($path)
   $stream=[IO.MemoryStream]::new($bytes)
   try{
     $img=[Drawing.Image]::FromStream($stream)
     try{$copy=[Drawing.Bitmap]::new($img)}finally{$img.Dispose()}
   }finally{$stream.Dispose()}
   $oldImage=$preview.Image
   $preview.Image=$copy
   if($oldImage){$oldImage.Dispose()}
   $script:previewStamp=$stamp
 }catch{}
}
$timer=New-Object Windows.Forms.Timer;$timer.Interval=800
$timer.Add_Tick({
 if(-not $script:active){return}
 UpdateMotionPreview
 UpdatePreview
 $s=Join-Path $script:work 'status.json'
 if(Test-Path $s){
   try{
     $v=Get-Content -LiteralPath $s -Raw -Encoding UTF8 | ConvertFrom-Json
     $bar.Value=[Math]::Max(0,[Math]::Min(100,[int]$v.pct))
     $status.Text=$v.message
     $previewInfo.Text=$v.message
     $trackLog=Join-Path $script:work 'trilhas_escolhidas.txt'
     if(Test-Path -LiteralPath $trackLog){
       $used=@(Get-Content -LiteralPath $trackLog -Encoding UTF8 -ErrorAction SilentlyContinue)
       if($used.Count -gt 0){$musicState.Text=('Trilhas aplicadas: '+$used.Count+' | '+$used[-1])}
     }
     $completed=Join-Path $script:work 'completed_clip.txt'
     if(Test-Path -LiteralPath $completed){
       $last=(Get-Content -LiteralPath $completed -Raw -Encoding UTF8).Trim()
       if($last -and (Test-Path -LiteralPath $last -PathType Leaf)){
         $script:lastClip=$last
         $playClip.Enabled=$true
       }
     }
     if($v.state -in @('success','error','cancel')){
       $script:active=$false;$timer.Stop();$run.Enabled=$true;$stop.Enabled=$false
       if($v.state -eq 'success'){
         $playClip.Text='Abrir video final'
         $script:lastClip=$out.Text.Trim()
         $playClip.Enabled=$true
         [Windows.Forms.MessageBox]::Show('Video exportado.','Editor IA') | Out-Null
       }
     }
   }catch{}
 }
 if($script:active -and $script:proc){
   $script:proc.Refresh()
   if($script:proc.HasExited){$script:active=$false;$timer.Stop();$run.Enabled=$true;$stop.Enabled=$false}
 }
})
$run.Add_Click({
 try{
   if($files.Items.Count -eq 0){throw 'Adicione pelo menos um video.'}
   $engine=$ff.Text.Trim()
   if(-not(Test-Path $engine)){throw 'Localize o ffmpeg.exe'}
   $probe=Join-Path (Split-Path $engine) 'ffprobe.exe'
   if(-not(Test-Path $probe)){throw 'ffprobe.exe nao encontrado ao lado do FFmpeg'}
   if(-not $out.Text.Trim().ToLowerInvariant().EndsWith('.mp4')){throw 'Selecione um arquivo MP4 de saida'}
   if(Test-Path $out.Text){throw 'O arquivo de saida ja existe; escolha outro nome'}
   if(-not(Test-Path (Split-Path $out.Text))){throw 'A pasta de saida nao existe'}
   if($transcribe.Checked -and -not $env:OPENAI_API_KEY){
     throw 'Transcricao requer OPENAI_API_KEY configurada. Desmarque a opcao ou configure a chave sem coloca-la no GitHub.'
   }
   if($localVision.Checked){
     try{
       $resp=Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -Method Get -TimeoutSec 3
       $found=@($resp.models | Where-Object {$_.name -match '^moondream(:|$)'})
       if($found.Count -eq 0){throw 'Modelo moondream nao instalado. No PowerShell: ollama pull moondream'}
     }catch{
       throw ("IA local indisponivel: "+$_.Exception.Message+". Desmarque a opcao para selecao musical gratis por regras.")
     }
   }
   if($visual.Checked -and -not $env:OPENAI_API_KEY){
     throw 'Analise visual requer OPENAI_API_KEY. Desmarque a opcao ou configure a chave.'
   }
   if($outroImage.Text.Trim() -and -not(Test-Path -LiteralPath $outroImage.Text.Trim() -PathType Leaf)){
     throw 'A imagem da tela final nao foi encontrada. Escolha um PNG/JPG valido ou deixe vazio.'
   }
   $inputs=@()
   foreach($v in $files.Items){
     $path=[string]$v
     if($path -match '(?i)\\INetCache\\'){
       throw 'Video selecionado diretamente do celular (arquivo temporario). Copie primeiro os videos para uma pasta local no PC, clique Limpar e adicione-os novamente.'
     }
     if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw ("Arquivo nao encontrado: "+$path)}
     $inputs+=$path
   }
   $musicFiles=@()
   if($music.Text.Trim() -and (Test-Path -LiteralPath $music.Text.Trim() -PathType Container)){
     $musicFiles=@(Get-ChildItem -LiteralPath $music.Text.Trim() -Recurse -File -ErrorAction SilentlyContinue |
       Where-Object { @('.mp3','.wav','.m4a','.flac','.ogg') -contains $_.Extension.ToLowerInvariant() })
   }
   $musicState.Text=("Musicas encontradas: "+$musicFiles.Count)
   if($musicFiles.Count -eq 1){
     [Windows.Forms.MessageBox]::Show('A pasta tem somente UMA musica. Para variar durante o vlog, adicione pelo menos 3 musicas licenciadas diferentes.','Editor IA') | Out-Null
   }
   if($musicFiles.Count -eq 0){
     $choice=[Windows.Forms.MessageBox]::Show('Nenhuma musica encontrada. O vlog sera exportado sem trilha musical. Continuar?','Editor IA',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Information)
     if($choice -ne [Windows.Forms.DialogResult]::Yes){return}
   }
   $script:work=Join-Path $env:TEMP ('EditorIA_'+[guid]::NewGuid().ToString('N'))
   New-Item -ItemType Directory -Path $script:work | Out-Null
   $jobfile=Join-Path $script:work 'job.json'
   @{ffmpeg=$engine;ffprobe=$probe;inputs=$inputs;output=$out.Text.Trim();quality=@('4K','1080p','720p')[$quality.SelectedIndex];musicFolder=$music.Text.Trim();visual=$visual.Checked;cleanVoice=$cleanVoice.Checked;transcribe=$transcribe.Checked;livePreview=$livePreview.Checked;localVision=$localVision.Checked;autoZoom=$autoZoom.Checked;outroImage=$outroImage.Text.Trim();outroSeconds=@(5,8,10,15)[$outroDuration.SelectedIndex]} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $jobfile -Encoding UTF8
   $args='-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Worker -JobPath "'+$jobfile+'"'
   $script:proc=Start-Process powershell.exe -ArgumentList $args -PassThru -WindowStyle Hidden
   $script:active=$true;$run.Enabled=$false;$stop.Enabled=$true;$bar.Value=0;$status.Text='Processando...'
   $script:previewStamp=[datetime]::MinValue
   $script:previewVideoPath=''
   if($script:player){try{$script:player.Stop();$script:player.Source=$null}catch{}}
   $script:lastClip=$null;$playClip.Text='Reproduzir trecho concluido';$playClip.Enabled=$false;$previewInfo.Text='Aguardando a primeira cena...'
   if($preview.Image){$preview.Image.Dispose();$preview.Image=$null}
   $timer.Start()
   if($tabs){$tabs.SelectedTab=$watchTab}
 }catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Editor IA') | Out-Null}
})
$stop.Add_Click({if($script:active){New-Item -ItemType File -Path (Join-Path $script:work 'cancel.flag') -Force | Out-Null;$status.Text='Cancelando...'}})
$folder.Add_Click({$p=Split-Path $out.Text;if($p -and (Test-Path $p)){Start-Process explorer.exe -ArgumentList ('"'+$p+'"')}})

# ===== Editor IA 1.3: interface organizada em tres abas =====
$f.Text='Editor IA 1.3 - Editor de Vlogs'
$f.ClientSize=New-Object Drawing.Size(1130,690)
$f.AutoScroll=$false
$f.MinimumSize=New-Object Drawing.Size(1000,690)
$f.BackColor=[Drawing.Color]::FromArgb(17,18,23)
$t.Text='EDITOR IA   |   STUDIO 1.3'
$t.Location=New-Object Drawing.Point(26,14)
$t.Size=New-Object Drawing.Size(900,37)
$t.Font=New-Object Drawing.Font('Segoe UI',19,[Drawing.FontStyle]::Bold)
$t.ForeColor=[Drawing.Color]::FromArgb(255,204,0)
$intro=@($f.Controls | Where-Object {$_ -is [Windows.Forms.Label] -and $_.Top -eq 52} | Select-Object -First 1)
if($intro.Count -gt 0){
 $intro[0].Text='EDIÇÃO AUTOMÁTICA  /  CORTES  /  MÚSICA  /  ZOOM  /  EXPORTAÇÃO'
 $intro[0].Location=New-Object Drawing.Point(28,54)
 $intro[0].Size=New-Object Drawing.Size(980,22)
 $intro[0].Font=New-Object Drawing.Font('Segoe UI',9)
 $intro[0].ForeColor=[Drawing.Color]::FromArgb(170,175,185)
}
$tabs=New-Object Windows.Forms.TabControl
$tabs.Location=New-Object Drawing.Point(21,88)
$tabs.Size=New-Object Drawing.Size(1086,575)
$tabs.Anchor='Top,Bottom,Left,Right'
$tabs.Font=New-Object Drawing.Font('Segoe UI Semibold',10)
$tabs.Padding=New-Object Drawing.Point(22,10)
$tabs.Appearance='Normal'
$tabs.BackColor=[Drawing.Color]::FromArgb(24,26,33)
$projectTab=New-Object Windows.Forms.TabPage
$projectTab.Text='  01  PROJETO E ARQUIVOS  '
$editTab=New-Object Windows.Forms.TabPage
$editTab.Text='  02  EDIÇÃO AUTOMÁTICA  '
$watchTab=New-Object Windows.Forms.TabPage
$watchTab.Text='  03  ACOMPANHAR CORTES  '
foreach($page in @($projectTab,$editTab,$watchTab)){
 $page.BackColor=[Drawing.Color]::FromArgb(25,27,34)
 $page.ForeColor=[Drawing.Color]::White
 $page.AutoScroll=$true
 [void]$tabs.TabPages.Add($page)
}
[void]$f.Controls.Add($tabs)
function Place($c,$page,$x,$y,$w,$h){
 if(-not $c){return}
 $page.Controls.Add($c)
 $c.Location=New-Object Drawing.Point($x,$y)
 if($w -gt 0 -and $h -gt 0){$c.Size=New-Object Drawing.Size($w,$h)}
 if($c -is [Windows.Forms.Button]){
   $c.FlatStyle=[Windows.Forms.FlatStyle]::Flat
   $c.FlatAppearance.BorderSize=0
   if($c -ne $run){
     $c.BackColor=[Drawing.Color]::FromArgb(49,53,66)
     $c.ForeColor=[Drawing.Color]::White
   }
 }
 if($c -is [Windows.Forms.CheckBox]) {
   $c.ForeColor=[Drawing.Color]::White
   $c.BackColor=[Drawing.Color]::Transparent
 }
 if($c -is [Windows.Forms.TextBox] -or $c -is [Windows.Forms.ListBox]){
   $c.BackColor=[Drawing.Color]::FromArgb(244,246,249)
   $c.ForeColor=[Drawing.Color]::FromArgb(28,30,38)
 }
}
# Posicionar os campos que ja possuem seus eventos, sem duplicar handlers.
Place $files $projectTab 25 67 790 146
Place $add $projectTab 834 67 184 32
Place $addFolder $projectTab 834 104 184 32
Place $remove $projectTab 834 141 184 32
Place $clear $projectTab 834 178 184 32
Place $out $projectTab 25 251 790 30
Place $save $projectTab 834 250 184 32
Place $quality $projectTab 265 300 310 30
Place $ff $projectTab 25 360 790 30
Place $browse $projectTab 834 359 184 32
Place $music $projectTab 25 428 790 30
Place $musicBrowse $projectTab 834 427 184 32
Place $outroImage $projectTab 25 496 635 30
Place $outroBrowse $projectTab 672 495 184 32
Place $outroDuration $projectTab 866 496 152 30
# Os textos antigos eram descartados pelos criadores; mover pelo cabecalho.
$labelMap=@{
 '1. Videos para analisar'=@(25,35,450,26)
 '2. Arquivo final MP4'=@(25,224,500,26)
 '3. Qualidade de exportacao'=@(25,299,230,27)
 '4. Caminho do ffmpeg.exe'=@(25,332,590,26)
 '5. Biblioteca musical (pasta com faixas licenciadas)'=@(25,400,660,26)
 '6. Tela final do video (opcional, PNG/JPG)'=@(25,468,720,26)
}
foreach($label in @($f.Controls | Where-Object {$_ -is [Windows.Forms.Label] -and $labelMap.ContainsKey($_.Text)})){
 $p=$labelMap[$label.Text]
 Place $label $projectTab $p[0] $p[1] $p[2] $p[3]
}
# Opcoes de edição em um painel amplo, sem colisoes entre os controles.
$editHead=New-Object Windows.Forms.Label
$editHead.Text='AUTOMAÇÃO DO VLOG'
$editHead.ForeColor=[Drawing.Color]::FromArgb(255,204,0)
$editHead.Font=New-Object Drawing.Font('Segoe UI Semibold',14)
Place $editHead $editTab 28 24 540 32
Place $visual $editTab 29 82 770 30
Place $autoZoom $editTab 29 122 770 30
Place $livePreview $editTab 29 162 770 30
Place $localVision $editTab 29 202 770 30
Place $cleanVoice $editTab 29 242 770 30
Place $transcribe $editTab 29 282 770 30
Place $musicState $editTab 29 327 970 50
Place $run $editTab 29 408 472 43
Place $stop $editTab 517 408 225 43
Place $folder $editTab 758 408 244 43
Place $bar $editTab 29 475 973 22
Place $status $editTab 29 513 973 65
$run.BackColor=[Drawing.Color]::FromArgb(255,204,0)
$run.ForeColor=[Drawing.Color]::Black
$run.Font=New-Object Drawing.Font('Segoe UI Semibold',11)
$bar.Style='Continuous'
# Acompanhamento: o monitor de video e os controles ficam juntos.
Place $previewTitle $watchTab 28 26 950 32
Place $preview $watchTab 28 72 722 408
if($script:playerHost){
 Place $script:playerHost $watchTab 28 72 722 408
 $script:playerHost.BringToFront()
}
Place $previewInfo $watchTab 28 495 722 55
Place $playClip $watchTab 774 89 245 43
Place $openPlan $watchTab 774 146 245 43
Place $previewHelp $watchTab 774 222 246 165
$previewTitle.Font=New-Object Drawing.Font('Segoe UI Semibold',13)
$previewTitle.ForeColor=[Drawing.Color]::FromArgb(255,204,0)
$watchHint=New-Object Windows.Forms.Label
$watchHint.Text='CENA ATUAL: versão leve em movimento. O vídeo final continua sendo exportado na qualidade escolhida.'
$watchHint.ForeColor=[Drawing.Color]::FromArgb(180,185,195)
Place $watchHint $watchTab 28 555 980 26
$tabs.SelectedIndex=0
# Nao oculta o progresso: ao iniciar a exportacao mudar para a aba de acompanhamento.


[void]$f.ShowDialog()
