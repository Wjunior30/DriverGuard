# Gera dist\HollowDrivers.exe e dist\HollowDrivers-Setup.exe (usa o compilador C# que já vem no Windows).
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dist = Join-Path $root 'dist'
$csc = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
New-Item -ItemType Directory -Force -Path $dist | Out-Null

# ícone com vários tamanhos (PNG dentro do .ico)
Add-Type -AssemblyName System.Drawing
$fam = @('Segoe Fluent Icons', 'Segoe MDL2 Assets') |
    Where-Object { (New-Object Drawing.Text.InstalledFontCollection).Families.Name -contains $_ } | Select-Object -First 1
$pngs = foreach ($s in 16, 24, 32, 48, 64, 128, 256) {
    $bmp = New-Object Drawing.Bitmap($s, $s)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'; $g.Clear([Drawing.Color]::Transparent)
    $pad = [Math]::Max(1, [int]($s / 32))
    $rect = New-Object Drawing.Rectangle($pad, $pad, ($s - 2 * $pad), ($s - 2 * $pad))
    $br = New-Object Drawing.Drawing2D.LinearGradientBrush($rect, [Drawing.Color]::FromArgb(255, 90, 69), [Drawing.Color]::FromArgb(212, 20, 90), 45)
    $g.FillEllipse($br, $rect)
    $font = New-Object Drawing.Font($fam, [single]($s * 0.46), [Drawing.GraphicsUnit]::Pixel)
    $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $g.DrawString([string][char]0xEA18, $font, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF(0, ($s * 0.03), $s, $s)), $sf)
    $g.Dispose()
    $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    , @($s, $ms.ToArray())
}
$ico = Join-Path $root 'HollowDrivers.ico'
$bw = New-Object IO.BinaryWriter([IO.File]::Create($ico))
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$pngs.Count)
$offset = 6 + 16 * $pngs.Count
foreach ($p in $pngs) {
    $sz = $p[0]; $data = $p[1]
    $bw.Write([byte]($sz % 256)); $bw.Write([byte]($sz % 256)); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$data.Length); $bw.Write([uint32]$offset)
    $offset += $data.Length
}
foreach ($p in $pngs) { $bw.Write([byte[]]$p[1]) }
$bw.Close()

$app = Join-Path $root 'HollowDrivers.ps1'   # PowerShell 5.1 precisa de BOM para ler acentos
[IO.File]::WriteAllText($app, [IO.File]::ReadAllText($app, [Text.Encoding]::UTF8), (New-Object Text.UTF8Encoding $true))

# versão única: vem do $AppVersion do HollowDrivers.ps1
$ver = ([regex]::Match([IO.File]::ReadAllText($app), "\`$AppVersion = '([\d\.]+)'")).Groups[1].Value
if (-not $ver) { throw 'Não achei $AppVersion no HollowDrivers.ps1' }
$verCs = "$root\src\Version.g.cs"
[IO.File]::WriteAllText($verCs, @"
[assembly: System.Reflection.AssemblyVersion("$ver.0")]
[assembly: System.Reflection.AssemblyFileVersion("$ver.0")]
namespace DG { static class Ver { public const string V = "$ver"; } }
"@)

$refs = '/codepage:65001', '/reference:System.Windows.Forms.dll', '/reference:System.Management.dll'
& $csc /nologo /target:winexe /optimize+ "/win32icon:$ico" "/out:$dist\HollowDrivers.exe" @refs "$root\src\Launcher.cs" $verCs
if ($LASTEXITCODE) { throw 'Falha ao compilar HollowDrivers.exe' }

Copy-Item "$root\HollowDrivers.ps1" $dist -Force
Copy-Item $ico $dist -Force
Copy-Item "$dist\HollowDrivers.exe" $root -Force   # para a pasta de desenvolvimento também abrir sem console

& $csc /nologo /target:winexe /optimize+ "/win32icon:$ico" "/out:$dist\HollowDrivers-Setup.exe" @refs `
    "/resource:$dist\HollowDrivers.ps1,HollowDrivers.ps1" "/resource:$dist\HollowDrivers.exe,HollowDrivers.exe" "/resource:$ico,HollowDrivers.ico" `
    "$root\src\Setup.cs" $verCs
if ($LASTEXITCODE) { throw 'Falha ao compilar HollowDrivers-Setup.exe' }

# hash para o app conferir o download da atualização
$hash = (Get-FileHash "$dist\HollowDrivers-Setup.exe" -Algorithm SHA256).Hash.ToLower()
[IO.File]::WriteAllText("$dist\HollowDrivers-Setup.exe.sha256", "$hash  HollowDrivers-Setup.exe")
# Os apps DriverGuard 1.1.x procuram estes nomes na release para migrar.
Copy-Item "$dist\HollowDrivers-Setup.exe" "$dist\DriverGuard-Setup.exe" -Force
[IO.File]::WriteAllText("$dist\DriverGuard-Setup.exe.sha256", "$hash  DriverGuard-Setup.exe")
"HollowDrivers $ver"

Get-ChildItem $dist | Select-Object Name, @{ n = 'KB'; e = { [math]::Round($_.Length / 1KB) } } | Format-Table -AutoSize
