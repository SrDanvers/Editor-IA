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
     $raw= & $j.ffprobe -v error -show_entries 'format=duration:stream=codec_type' -of json $path | Out-String
     if($LASTEXITCODE -ne 0){throw "Nao foi possivel analisar $path"}
     $p=$raw | ConvertFrom-Json
     $duration=[double]::Parse([string]$p.format.duration,[Globalization.CultureInfo]::InvariantCulture)
     if($duration -le 0){continue}
     $hasAudio=(@($p.streams | Where-Object codec_type -eq 'audio').Count -gt 0)
     $info+=@{path=$path;duration=$duration;audio=$hasAudio}
     $sum+=$duration
   }
   if($sum -le 0){throw 'Nao existem videos validos'}
   $goal=[Math]::Min($sum,[Math]::Min(240,[Math]::Max(12,$sum*0.35)))
   $clips=New-Object System.Collections.ArrayList
   $index=0
   foreach($v in $info){
     $index++
     Report ([int](5+20*$index/$info.Count)) ("Detectando pausas em "+[IO.Path]::GetFileName($v.path))
     $regions=New-Object System.Collections.ArrayList
     if($v.audio){
       $prior=$ErrorActionPreference; $ErrorActionPreference='Continue'
       try { $report= & $j.ffmpeg -hide_banner -nostdin -i $v.path -vn -af 'silencedetect=noise=-34dB:d=0.65' -f null NUL 2>&1 | Out-String } finally { $ErrorActionPreference=$prior }
       $begin=0.0
       $silenceStart=$null
       foreach($line in ($report -split '\r?\n')){
         if($line -match 'silence_start:\s*([0-9.]+)'){$silenceStart=[double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture)}
         if($line -match 'silence_end:\s*([0-9.]+)' -and $null -ne $silenceStart){
           if($silenceStart-$begin -ge 2){[void]$regions.Add(@{start=$begin;length=$silenceStart-$begin})}
           $begin=[double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture)
           $silenceStart=$null
         }
       }
       if($null -ne $silenceStart){
         if($silenceStart-$begin -ge 2){[void]$regions.Add(@{start=$begin;length=$silenceStart-$begin})}
       } elseif($v.duration-$begin -ge 2){[void]$regions.Add(@{start=$begin;length=$v.duration-$begin})}
     }
     if($regions.Count -eq 0){[void]$regions.Add(@{start=0.0;length=$v.duration})}
     $candidate=New-Object System.Collections.ArrayList
     foreach($r in $regions){
       $s=[double]$r.start
       $remaining=[double]$r.length
       while($remaining -ge 1.5){
         $len=[Math]::Min(16,$remaining)
         [void]$candidate.Add(@{start=$s;length=$len})
         $s+=$len
         $remaining-=$len
       }
     }
     $portion=$goal*$v.duration/$sum
     $used=0.0
     foreach($c in @($candidate | Sort-Object -Property length -Descending)){
       if($used -ge $portion){break}
       $length=[Math]::Min([double]$c.length,$portion-$used)
       if($length -ge 1.5){
         [void]$clips.Add(@{path=$v.path;start=$c.start;length=$length;audio=$v.audio;order=$index})
         $used+=$length
       }
     }
   }
   if($clips.Count -eq 0){throw 'Nenhum trecho encontrado'}
   $list=Join-Path $temporary 'concat.txt'
   $records=New-Object System.Collections.Generic.List[string]
   $i=0
   foreach($c in @($clips | Sort-Object order,start)){
     CheckCancel
     $i++
     $piece=Join-Path $temporary ('clip_{0:D4}.mp4' -f $i)
     $params=@('-hide_banner','-nostdin','-y','-ss',(Fmt $c.start),'-i',[string]$c.path)
     if(-not $c.audio){$params+=@('-f','lavfi','-i','anullsrc=channel_layout=stereo:sample_rate=44100')}
     $params+=@('-t',(Fmt $c.length),'-map','0:v:0')
     if($c.audio){$params+=@('-map','0:a:0')}else{$params+=@('-map','1:a:0')}
     $params+=@('-vf','fps=24,scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p','-c:v','libx264','-preset','veryfast','-crf','27','-threads','2','-c:a','aac','-b:a','96k','-ar','44100','-ac','2','-shortest',$piece)
     [void](Execute -ffArgs $params)
     $records.Add("file '"+$piece.Replace("'","'\''")+"'")
     Report ([int](25+69*$i/$clips.Count)) ("Processando corte $i de "+$clips.Count)
   }
   [IO.File]::WriteAllLines($list,$records,[Text.UTF8Encoding]::new($false))
   Execute -ffArgs @('-hide_banner','-nostdin','-y','-f','concat','-safe','0','-i',$list,'-c','copy','-movflags','+faststart',[string]$j.output) | Out-Null
   Report 100 ("Concluido. Video salvo em "+$j.output) 'success'
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
$f.Text='Editor IA 0.2 - Vlogs Automaticos'
$f.Size=New-Object Drawing.Size(800,610)
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
$t=Label 'EDITOR IA 0.2' 20 12
$t.Font=New-Object Drawing.Font('Segoe UI',18,[Drawing.FontStyle]::Bold)
$t.ForeColor=[Drawing.Color]::Gold
[void](Label 'Vlogs: selecao automatica por pausas no audio e montagem em 720p' 20 52)
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
[void](Label '3. Caminho do ffmpeg.exe' 20 350)
$ff=Field 20 380 580
$browse=Button 'Localizar' 614 378 145
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
$run=Button 'CRIAR VLOG AUTOMATICAMENTE' 20 432 385
$run.BackColor=[Drawing.Color]::Gold;$run.ForeColor='Black'
$stop=Button 'CANCELAR' 418 432 145;$stop.Enabled=$false
$folder=Button 'Abrir pasta' 576 432 183
$bar=New-Object Windows.Forms.ProgressBar;$bar.Location=New-Object Drawing.Point(20,481)
$bar.Size=New-Object Drawing.Size(739,19);$f.Controls.Add($bar)
$status=Label 'Pronto.' 20 514
$script:work=$null;$script:proc=$null;$script:active=$false
$timer=New-Object Windows.Forms.Timer;$timer.Interval=800
$timer.Add_Tick({
 if(-not $script:active){return}
 $s=Join-Path $script:work 'status.json'
 if(Test-Path $s){
   try{
     $v=Get-Content -LiteralPath $s -Raw -Encoding UTF8 | ConvertFrom-Json
     $bar.Value=[Math]::Max(0,[Math]::Min(100,[int]$v.pct))
     $status.Text=$v.message
     if($v.state -in @('success','error','cancel')){
       $script:active=$false;$timer.Stop();$run.Enabled=$true;$stop.Enabled=$false
       if($v.state -eq 'success'){[Windows.Forms.MessageBox]::Show('Video exportado.','Editor IA') | Out-Null}
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
   $script:work=Join-Path $env:TEMP ('EditorIA_'+[guid]::NewGuid().ToString('N'))
   New-Item -ItemType Directory -Path $script:work | Out-Null
   $jobfile=Join-Path $script:work 'job.json'
   @{ffmpeg=$engine;ffprobe=$probe;inputs=$inputs;output=$out.Text.Trim()} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $jobfile -Encoding UTF8
   $args='-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Worker -JobPath "'+$jobfile+'"'
   $script:proc=Start-Process powershell.exe -ArgumentList $args -PassThru -WindowStyle Hidden
   $script:active=$true;$run.Enabled=$false;$stop.Enabled=$true;$bar.Value=0;$status.Text='Processando...'
   $timer.Start()
 }catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Editor IA') | Out-Null}
})
$stop.Add_Click({if($script:active){New-Item -ItemType File -Path (Join-Path $script:work 'cancel.flag') -Force | Out-Null;$status.Text='Cancelando...'}})
$folder.Add_Click({$p=Split-Path $out.Text;if($p -and (Test-Path $p)){Start-Process explorer.exe -ArgumentList ('"'+$p+'"')}})
[void]$f.ShowDialog()
