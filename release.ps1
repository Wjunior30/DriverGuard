# Publica uma versão nova no GitHub. Os apps instalados encontram a atualização sozinhos.
# Uso: .\release.ps1 -Notes "O que mudou nesta versão"
# Antes: aumente $AppVersion no DriverGuard.ps1 e faça commit.
param([Parameter(Mandatory)][string]$Notes)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$repo = 'Wjunior30/DriverGuard'

$ver = ([regex]::Match((Get-Content "$root\DriverGuard.ps1" -Raw), "\`$AppVersion = '([\d\.]+)'")).Groups[1].Value
if (-not $ver) { throw 'Não achei $AppVersion no DriverGuard.ps1' }
if (git -C $root status --porcelain) { throw 'Há alterações sem commit. Faça o commit antes de publicar.' }
if (git -C $root tag --list "v$ver") { throw "A versão $ver já foi publicada. Aumente `$AppVersion no DriverGuard.ps1." }

& "$root\build.ps1"
# git e gh escrevem progresso no canal de erro; no PowerShell 5 isso não pode derrubar o script
$ErrorActionPreference = 'Continue'
git -C $root tag "v$ver"
git -C $root push origin main "v$ver" 2>&1 | Out-Host
if ($LASTEXITCODE) { throw 'Falha no git push' }
gh release create "v$ver" "$root\dist\DriverGuard-Setup.exe" "$root\dist\DriverGuard-Setup.exe.sha256" `
    --repo $repo --title "DriverGuard $ver" --notes $Notes 2>&1 | Out-Host
if ($LASTEXITCODE) { throw 'Falha ao criar a release no GitHub' }
"Publicado: DriverGuard $ver"
