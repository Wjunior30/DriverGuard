# Publica uma versão nova no GitHub. Os apps instalados encontram a atualização sozinhos.
# Uso: .\release.ps1 -Notes "O que mudou nesta versão"
# Antes: aumente $AppVersion no HollowDrivers.ps1 e faça commit.
param([Parameter(Mandatory)][string]$Notes)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$repo = 'Wjunior30/DriverGuard'

$ver = ([regex]::Match((Get-Content "$root\HollowDrivers.ps1" -Raw), "\`$AppVersion = '([\d\.]+)'")).Groups[1].Value
if (-not $ver) { throw 'Não achei $AppVersion no HollowDrivers.ps1' }
if (git -C $root status --porcelain) { throw 'Há alterações sem commit. Faça o commit antes de publicar.' }
if (git -C $root tag --list "v$ver") { throw "A versão $ver já foi publicada. Aumente `$AppVersion no HollowDrivers.ps1." }

& "$root\build.ps1"

# assina o instalador com a chave privada (fora do repositório); os apps instalados recusam versão sem esta assinatura
$keyFile = Join-Path $env:USERPROFILE '.HollowDrivers\release-key.xml'
if (-not (Test-Path $keyFile)) { throw "Chave de assinatura não encontrada em $keyFile. Sem ela não dá para publicar (veja tools\new-release-key.ps1)." }
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
$rsa.PersistKeyInCsp = $false
$rsa.FromXmlString([IO.File]::ReadAllText($keyFile))
$sig = $rsa.SignData([IO.File]::ReadAllBytes("$root\dist\HollowDrivers-Setup.exe"), 'SHA256')
[IO.File]::WriteAllText("$root\dist\HollowDrivers-Setup.exe.sig", [Convert]::ToBase64String($sig))
$source = [IO.File]::ReadAllText("$root\HollowDrivers.ps1")
$publicXml = [regex]::Match($source, "(?m)^\`$UpdatePubKey = '([^']+)'$").Groups[1].Value
if (-not $publicXml) { throw 'Chave publica nao encontrada no aplicativo.' }
$verify = New-Object Security.Cryptography.RSACryptoServiceProvider
$verify.PersistKeyInCsp = $false
$verify.FromXmlString($publicXml)
if (-not $verify.VerifyData([IO.File]::ReadAllBytes("$root\dist\HollowDrivers-Setup.exe"), 'SHA256', $sig)) {
    throw 'A assinatura da release nao corresponde a chave publica do aplicativo.'
}
# git e gh escrevem progresso no canal de erro; no PowerShell 5 isso não pode derrubar o script
$ErrorActionPreference = 'Continue'
git -C $root tag "v$ver"
git -C $root push origin main "v$ver" 2>&1 | Out-Host
if ($LASTEXITCODE) { throw 'Falha no git push' }
# .sha256 continua publicado para as versões antigas (1.1.x) conseguirem atualizar até esta
gh release create "v$ver" "$root\dist\HollowDrivers-Setup.exe" "$root\dist\HollowDrivers-Setup.exe.sig" "$root\dist\HollowDrivers-Setup.exe.sha256" "$root\dist\DriverGuard-Setup.exe" "$root\dist\DriverGuard-Setup.exe.sha256" `
    --repo $repo --title "HollowDrivers $ver" --notes $Notes 2>&1 | Out-Host
if ($LASTEXITCODE) { throw 'Falha ao criar a release no GitHub' }
"Publicado: HollowDrivers $ver"
