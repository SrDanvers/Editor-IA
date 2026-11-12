# Editor IA 1.2 - inicializador com diagnostico de erros
$ErrorActionPreference='Stop'
$main=Join-Path $PSScriptRoot 'EditorIA.ps1'
$log=Join-Path $PSScriptRoot 'EditorIA_erro_ao_abrir.txt'
try {
  if(-not(Test-Path -LiteralPath $main -PathType Leaf)){throw 'EditorIA.ps1 nao encontrado. Extraia o ZIP inteiro na mesma pasta.'}
  Add-Type -AssemblyName System.Windows.Forms
  # Executar na mesma sessao: erros do script nao somem quando a janela fecha.
  & $main
} catch {
  $detail=($_ | Out-String)
  $message="O Editor IA nao conseguiu abrir.`r`n`r`n"+$_.Exception.Message+"`r`n`r`nLog: "+$log
  try {
    [IO.File]::WriteAllText($log,("[{0}]`r`n{1}" -f (Get-Date),$detail),[Text.Encoding]::UTF8)
  } catch {}
  try {[Windows.Forms.MessageBox]::Show($message,'Editor IA - erro ao iniciar','OK','Error') | Out-Null}
  catch {Write-Host $message -ForegroundColor Red}
  Write-Host $detail -ForegroundColor Red
  Read-Host 'Pressione Enter para sair' | Out-Null
}
