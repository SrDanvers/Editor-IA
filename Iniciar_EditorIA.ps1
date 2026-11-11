# Iniciador do Editor IA 0.2 (Windows 10)
$ErrorActionPreference='Stop'
$script=Join-Path $PSScriptRoot 'EditorIA.ps1'
if(-not(Test-Path -LiteralPath $script -PathType Leaf)){throw 'EditorIA.ps1 nao encontrado na mesma pasta'}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File $script
