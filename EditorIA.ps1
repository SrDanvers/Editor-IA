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
     foreach($r in $merged){
       $span=[double]$r.end-[double]$r.start
       if($span -lt 8){continue}
       # 25 a 40 segundos, mantendo varios segundos de folga entre trechos.
       $cursor=[double]$r.start
       while($cursor -lt [double]$r.end){
         $available=[double]$r.end-$cursor
         if($available -lt 12){break}
         $length=[Math]::Min(40,$available)
         [void]$options.Add(@{start=$cursor;length=$length})
         $cursor+=$length+10
       }
     }
     if($options.Count -eq 0){
       # Se nao houver fala longa, usar um trecho mais continuo do arquivo.
       [void]$options.Add(@{start=0.0;length=[Math]::Min(40,[double]$v.duration)})
     }
     # Preferir uma cena da metade do arquivo, evitando selecionar sempre o inicio.
     $first=@($options | Sort-Object @{Expression={[Math]::Abs(($_.start+$_.length/2)-([double]$v.duration/2))}})[0]
     [void]$candidates.Add(@{path=$v.path;duration=$v.duration;audio=$v.audio;order=$index;options=@($options);first=$first})
   }
   # Primeiro: distribuicao equilibrada, uma cena por video, sem repeticoes.
   $remaining=$goal
   $firstQuota=[Math]::Min(40,[Math]::Max(12,[Math]::Floor($goal/[Math]::Max(1,$candidates.Count))))
   foreach($entry in $candidates){
     if($remaining -lt 2){break}
     $take=[Math]::Min([double]$entry.first.length,[Math]::Min($firstQuota,$remaining))
     if($take -ge 2){
       [void]$clips.Add(@{path=$entry.path;start=$entry.first.start;length=$take;audio=$entry.audio;order=$entry.order;pass=1})
       $remaining-=$take
     }
   }
   # Segunda passagem somente quando o total de arquivos e pequeno,
   # escolhendo um intervalo realmente separado do primeiro.
   if($candidates.Count -le 6 -and $remaining -ge 12){
     foreach($entry in $candidates){
       if($remaining -lt 12){break}
       $chosen=$null
       foreach($opt in @($entry.options | Sort-Object start)){
         $a=[double]$opt.start;$b=$a+[double]$opt.length
         $f=[double]$entry.first.start;$g=$f+[double]$entry.first.length
         if(($b -le ($f-8)) -or ($a -ge ($g+8))){$chosen=$opt;break}
       }
       if($null -ne $chosen){
         $take=[Math]::Min([double]$chosen.length,[Math]::Min(40,$remaining))
         if($take -ge 12){
           [void]$clips.Add(@{path=$entry.path;start=$chosen.start;length=$take;audio=$entry.audio;order=$entry.order;pass=2})
           $remaining-=$take
         }
       }
     }
   }
   if($clips.Count -eq 0){throw 'Nenhum trecho valido encontrado'}
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
   $list=Join-Path $temporary 'concat.txt'
   $records=New-Object System.Collections.Generic.List[string]
   $i=0
   foreach($c in @($clips | Sort-Object order,start)){
     CheckCancel
     $i++
     $piece=Join-Path $temporary ('clip_{0:D4}.mp4' -f $i)
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
     $params+=@('-filter_complex',$filter,'-map','[v]')
     if($c.audio){$params+=@('-map','0:a:0')}else{$params+=@('-map','1:a:0')}
     if([bool]$j.cleanVoice){
       # Reduz vento (frequencias graves), ruido constante e equilibra a voz.
       # Nao elimina vento forte por completo.
       $voiceFilter='highpass=f=150,lowpass=f=7500,afftdn=nf=-25,acompressor=threshold=0.10:ratio=2.7:attack=20:release=220:makeup=1.5,alimiter=limit=0.95'
       $params+=@('-af',$voiceFilter)
     }
     $params+=@('-c:v','libx264','-preset',$preset,'-crf',$crf,'-threads','2','-c:a','aac','-b:a','192k','-ar','44100','-ac','2','-shortest',$piece)
     [void](Execute -ffArgs $params)
     if($visionOn -and $songs.Count -gt 0){
       $cat=VisualCategory $c
       $matched=@($songs | Where-Object { $_.BaseName.ToLowerInvariant() -match ('^'+$cat+'[-_ ]') })
       if($matched.Count -eq 0){$matched=@($songs | Where-Object { $_.BaseName.ToLowerInvariant() -match '^neutra[-_ ]' })}
       if($matched.Count -eq 0){$matched=$songs}
       if($matched.Count -gt 0){
         $track=$matched[(($i-1) % $matched.Count)].FullName
         $mix=Join-Path $temporary ('mix_{0:D4}.mp4' -f $i)
         # Musica selecionada so para este trecho, com diminuicao conforme o audio original.
         # Voz sempre principal, musica a 9% em nivel linear.
         $fx='[1:a]volume=0.09,afade=t=in:st=0:d=1[m];[0:a][m]amix=inputs=2:duration=first:normalize=0,alimiter=limit=0.94[a]'
         Execute -ffArgs @('-hide_banner','-nostdin','-y','-i',$piece,'-stream_loop','-1','-i',$track,'-filter_complex',$fx,'-map','0:v:0','-map','[a]','-c:v','copy','-c:a','aac','-b:a','192k','-shortest',$mix) | Out-Null
         Move-Item -LiteralPath $mix -Destination $piece -Force
         Report ([int](25+69*$i/$clips.Count)) ("Cena $i - "+$cat+": "+[IO.Path]::GetFileName($track))
       }
     }
     if(Test-Path -LiteralPath $piece -PathType Leaf){
       Set-Content -LiteralPath (Join-Path (Split-Path $JobPath) 'completed_clip.txt') -Value $piece -Encoding UTF8
     }
     $records.Add("file '"+$piece.Replace("'","'\''")+"'")
     Report ([int](25+69*$i/$clips.Count)) ("Processando corte $i de "+$clips.Count)
   }
   [IO.File]::WriteAllLines($list,$records,[Text.UTF8Encoding]::new($false))
   # Unir cortes antes de aplicar musica. Nao recodificar o video nesta etapa.
   $selectedMusic=$null
   if($j.musicFolder -and (Test-Path -LiteralPath ([string]$j.musicFolder) -PathType Container)){
     $songs=@(Get-ChildItem -LiteralPath ([string]$j.musicFolder) -File -Recurse |
       Where-Object { @('.mp3','.wav','.m4a','.flac','.ogg') -contains $_.Extension.ToLowerInvariant() } |
       Sort-Object FullName)
     if($songs.Count -gt 0){
       # Heuristica leve: volume medio dos primeiros 15 segundos de ate 4 fontes.
       # Nao identifica sentimentos nem interpreta visualmente o video.
       $samples=New-Object System.Collections.ArrayList
       foreach($v in @($info | Where-Object audio | Select-Object -First 4)){
         $prior=$ErrorActionPreference;$ErrorActionPreference='Continue'
         try{$scan= & $j.ffmpeg -hide_banner -nostdin -t 15 -i ([string]$v.path) -vn -af volumedetect -f null NUL 2>&1 | Out-String}finally{$ErrorActionPreference=$prior}
         if($scan -match 'mean_volume:\s*(-?[0-9.]+)\s*dB'){
           [void]$samples.Add([double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture))
         }
       }
       $mood='neutra'
       if($samples.Count -gt 0){
         $avg=($samples | Measure-Object -Average).Average
         if($avg -ge -21){$mood='animada'}
         elseif($avg -le -35){$mood='calma'}
       }
       $names=(@($info | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension([string]$_.path) }) -join ' ').ToLowerInvariant()
       if($names -match 'praia|mar|piscina|viagem|ferias|natureza|travel'){ $mood='viagem' }
       $matched=@($songs | Where-Object { $_.BaseName.ToLowerInvariant() -match ('^'+$mood+'[-_ ]') })
       if($matched.Count -eq 0){$matched=@($songs | Where-Object { $_.BaseName.ToLowerInvariant() -match '^neutra[-_ ]' })}
       if($matched.Count -eq 0){$matched=$songs}
       # Selecionar de modo estavel, alternando as faixas conforme a quantidade de cortes.
       $selectedMusic=$matched[($clips.Count % $matched.Count)].FullName
       Report 94 ("Trilha escolhida ("+$mood+"): "+[IO.Path]::GetFileName($selectedMusic))
     }
   }
   $joined=Join-Path $temporary 'video_montado.mp4'
   Execute -ffArgs @('-hide_banner','-nostdin','-y','-f','concat','-safe','0','-i',$list,'-c','copy','-movflags','+faststart',$joined) | Out-Null
   if($selectedMusic -and -not $visionOn){
     # Compressao lateral reduz a musica quando o audio original fica forte.
     # Mantem as falas originais e copia o video sem nova codificacao 4K.
     $audioFx='[1:a]volume=0.09,afade=t=in:st=0:d=1.5[m];[0:a][m]amix=inputs=2:duration=first:normalize=0,alimiter=limit=0.94[a]'
     Execute -ffArgs @('-hide_banner','-nostdin','-y','-i',$joined,'-stream_loop','-1','-i',$selectedMusic,'-filter_complex',$audioFx,'-map','0:v:0','-map','[a]','-c:v','copy','-c:a','aac','-b:a','192k','-movflags','+faststart','-shortest',[string]$j.output) | Out-Null
   } else {
     Move-Item -LiteralPath $joined -Destination ([string]$j.output) -ErrorAction Stop
   }
   if(-not(Test-Path -LiteralPath ([string]$j.output) -PathType Leaf)){throw 'Arquivo final nao foi encontrado'}
   Report 100 ("Concluido. "+$(if($selectedMusic){"Musica: "+[IO.Path]::GetFileName($selectedMusic)+'. '}else{'Sem biblioteca musical. '})+"Video: "+$j.output) 'success'
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
$f.Text='Editor IA 0.6 - Voz Limpa e Musica'
$f.Size=New-Object Drawing.Size(1170,748)
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
$t=Label 'EDITOR IA 0.6' 20 12
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
$previewInfo=Label 'Aguardando a primeira cena...' 786 359 345
$previewInfo.AutoEllipsis=$true
$previewInfo.Size=New-Object Drawing.Size(345,48)
$previewHelp=Label 'Imagem do trecho atual, nao video ao vivo. Clique abaixo para reproduzir um corte processado.' 786 411 350
$previewHelp.Size=New-Object Drawing.Size(345,70)
$cleanVoice=New-Object Windows.Forms.CheckBox
$cleanVoice.Text='Reduzir vento e priorizar voz'
$cleanVoice.Location=New-Object Drawing.Point(786,535)
$cleanVoice.Size=New-Object Drawing.Size(345,30)
$cleanVoice.ForeColor=[Drawing.Color]::White
$cleanVoice.Checked=$true
$f.Controls.Add($cleanVoice)
$musicState=Label 'Musicas: escolha uma pasta com MP3s licenciados.' 786 575 345
$musicState.Size=New-Object Drawing.Size(345,55)
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
 UpdatePreview
 $s=Join-Path $script:work 'status.json'
 if(Test-Path $s){
   try{
     $v=Get-Content -LiteralPath $s -Raw -Encoding UTF8 | ConvertFrom-Json
     $bar.Value=[Math]::Max(0,[Math]::Min(100,[int]$v.pct))
     $status.Text=$v.message
     $previewInfo.Text=$v.message
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
   if($musicFiles.Count -eq 0){
     $choice=[Windows.Forms.MessageBox]::Show('Nenhuma musica encontrada. O vlog sera exportado sem trilha musical. Continuar?','Editor IA',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Information)
     if($choice -ne [Windows.Forms.DialogResult]::Yes){return}
   }
   $script:work=Join-Path $env:TEMP ('EditorIA_'+[guid]::NewGuid().ToString('N'))
   New-Item -ItemType Directory -Path $script:work | Out-Null
   $jobfile=Join-Path $script:work 'job.json'
   @{ffmpeg=$engine;ffprobe=$probe;inputs=$inputs;output=$out.Text.Trim();quality=@('4K','1080p','720p')[$quality.SelectedIndex];musicFolder=$music.Text.Trim();visual=$visual.Checked;cleanVoice=$cleanVoice.Checked} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $jobfile -Encoding UTF8
   $args='-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Worker -JobPath "'+$jobfile+'"'
   $script:proc=Start-Process powershell.exe -ArgumentList $args -PassThru -WindowStyle Hidden
   $script:active=$true;$run.Enabled=$false;$stop.Enabled=$true;$bar.Value=0;$status.Text='Processando...'
   $script:previewStamp=[datetime]::MinValue
   $script:lastClip=$null;$playClip.Text='Reproduzir trecho concluido';$playClip.Enabled=$false;$previewInfo.Text='Aguardando a primeira cena...'
   if($preview.Image){$preview.Image.Dispose();$preview.Image=$null}
   $timer.Start()
 }catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Editor IA') | Out-Null}
})
$stop.Add_Click({if($script:active){New-Item -ItemType File -Path (Join-Path $script:work 'cancel.flag') -Force | Out-Null;$status.Text='Cancelando...'}})
$folder.Add_Click({$p=Split-Path $out.Text;if($p -and (Test-Path $p)){Start-Process explorer.exe -ArgumentList ('"'+$p+'"')}})
[void]$f.ShowDialog()
