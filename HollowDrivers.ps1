param([switch]$SelfTest, [switch]$Watch, [switch]$Rescue, [switch]$AutoRescue, [switch]$HoldWU)

$AppVersion = '1.3.3'
$UpdateRepo = 'Wjunior30/DriverGuard'   # onde as versões novas são publicadas (GitHub Releases)
# Chave pública das versões. Uma atualização só é aceita se vier assinada pela chave privada correspondente,
# que fica fora do GitHub (%USERPROFILE%\.HollowDrivers). Assim, quem invadir a conta do GitHub não consegue publicar malware.
$UpdatePubKey = '<RSAKeyValue><Modulus>uPHjdxzzM6NPQ+25NkI5EIxWOi7qwZU8E2bNEebugIquc2DEW12CjNUKaeZUoe90KK/yRYaOp5y37vGq2lOpcgRKqcn9egoqik4hi0XhLE1OGiLYKbEKtf2/Uf6JWPEb+B/+eOVyrB93RWnkuGL7x/cTdCviu+oiWuE4gE0/abABq/4WRVf6FZgxiHP7VAsM/6Rk9Yu0tysaFOHMkSZEx0b4Nt4SgGtt70KCOS0mCPdmM9EO19oJqdd4gAWjbc9kUrVNmL3yqydXewqDL7coDwUA+SypHrFR/WXmR2C8+/wBPguJGDX+6swklq2hGAH+eA37rwydt46he2pFjvLoHXMNTVdZctj6Im+NE+hefr+k/0lT4SO43wKEodmCn8RYekJpZ7kEgWfxgHsTCrcbM0gFQCLAHzTyGElNq8jS8u4ZD3Ia+B4+iGl0Kva+CA5dzbpbWEDqTgVMiq3BJUaM38yvAOcP0UPGugxlshOjuc7Yfaf7znEG9Eaknw8TJUat</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>'
$Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$DataDir = Join-Path $env:LOCALAPPDATA 'HollowDrivers'
$LegacyDir = Join-Path $env:LOCALAPPDATA 'DriverGuard'   # nome antigo do app: leva backup e configurações junto
if ((Test-Path $LegacyDir) -and -not (Test-Path $DataDir)) { try { Move-Item $LegacyDir $DataDir -Force -ErrorAction Stop } catch { } }
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
# Mantem os backups feitos pelas versoes DriverGuard durante a troca de nome.
Get-ChildItem $DataDir -Recurse -File -Filter 'driverguard-backup.json' -ErrorAction SilentlyContinue | ForEach-Object {
    $newMeta = Join-Path $_.DirectoryName 'HollowDrivers-backup.json'
    if (-not (Test-Path $newMeta)) { Move-Item -LiteralPath $_.FullName -Destination $newMeta }
}
foreach ($f in 'baseline-video.json', 'watch-state.json') {
    foreach ($old in @((Join-Path $Here $f), (Join-Path $env:USERPROFILE "HollowDrivers\$f"))) {
        if ((Test-Path $old) -and -not (Test-Path (Join-Path $DataDir $f))) { Copy-Item $old (Join-Path $DataDir $f) }
    }
}
$BaselineFile = Join-Path $DataDir 'baseline-video.json'
$WatchState = Join-Path $DataDir 'watch-state.json'
$BackupDir = Join-Path $DataDir 'backup'
$Exe = Join-Path $Here 'HollowDrivers.exe'
$Launcher = Join-Path $Here 'HollowDrivers.vbs'
$IconFile = Join-Path $Here 'HollowDrivers.ico'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Start-Launcher([string]$arg) {
    if (Test-Path $Exe) {
        if ($arg) { Start-Process $Exe -ArgumentList $arg } else { Start-Process $Exe }
    } else {
        $a = '"{0}"' -f $Launcher; if ($arg) { $a += " $arg" }
        Start-Process wscript.exe -ArgumentList $a
    }
}

# ================================================================ coleta (também roda em segundo plano)
$Logic = {
    $CatMap = @{
        DISPLAY = 'Vídeo'; NET = 'Rede'; MEDIA = 'Áudio'; AUDIOENDPOINT = 'Áudio'; SYSTEM = 'Sistema / Chipset'
        USB = 'USB'; HDC = 'Armazenamento'; SCSIADAPTER = 'Armazenamento'; BLUETOOTH = 'Bluetooth'
        HIDCLASS = 'Entrada'; MOUSE = 'Entrada'; KEYBOARD = 'Entrada'; MONITOR = 'Monitor'
        PRINTER = 'Impressora'; CAMERA = 'Câmera'; IMAGE = 'Câmera'; SECURITYDEVICES = 'Segurança'
        SOFTWARECOMPONENT = 'Componente de software'; EXTENSION = 'Extensões do fabricante'; FIRMWARE = 'Firmware'
        BIOMETRIC = 'Biometria'; SMARTCARDREADER = 'Leitor de cartão'; SDHOST = 'Leitor de cartão'; SENSOR = 'Sensores'
        BATTERY = 'Bateria / energia'; PORTS = 'Portas'; PROCESSOR = 'Processador'
    }
    $ProblemText = @{
        1 = 'Mal configurado (código 1)'; 10 = 'Não iniciou (código 10)'; 14 = 'Precisa reiniciar (código 14)'
        22 = 'DESABILITADO (código 22)'
        28 = 'SEM DRIVER (código 28)'; 31 = 'Falha ao carregar (código 31)'; 43 = 'FALHOU (código 43)'
    }
    function Get-ProblemText([int]$code) {
        if ($code -eq 0) { return 'OK' }
        if ($ProblemText.ContainsKey($code)) { return $ProblemText[$code] }
        "Erro (código $code)"
    }

    function Get-WuState {
        $ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
        $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        $au = "$pol\AU"
        $get = { param($p, $n) try { (Get-ItemProperty -Path $p -Name $n -ErrorAction Stop).$n } catch { $null } }
        $ate = $null
        $exp = & $get $ux 'PauseUpdatesExpiryTime'
        if ($exp) { try { $ate = ([datetime]$exp).ToLocalTime() } catch { } }
        $pontos = $null; $ultimo = $null
        try {
            $rp = @(Get-CimInstance -Namespace root/default -ClassName SystemRestore -ErrorAction Stop)
            $pontos = $rp.Count
            if ($pontos) { $ultimo = ($rp | Sort-Object CreationTime -Descending | Select-Object -First 1).CreationTime }
        } catch { }
        [pscustomobject]@{
            PausadoAte = $ate
            Pausado    = [bool]($ate -and $ate -gt (Get-Date))
            SemAuto    = ((& $get $au 'NoAutoUpdate') -eq 1)
            SemDriver  = ((& $get $pol 'ExcludeWUDriversInQualityUpdate') -eq 1)
            SrLigada   = -not ((& $get 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'DisableSR') -eq 1)
            Pontos     = $pontos
            UltimoPonto = $(if ($ultimo) { try { [Management.ManagementDateTimeConverter]::ToDateTime($ultimo) } catch { $null } } else { $null })
        }
    }

    function Get-DriverScan {
        $problems = @{}
        Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction SilentlyContinue |
            Where-Object { $_.ConfigManagerErrorCode -ne 45 } |
            ForEach-Object { $problems[$_.PNPDeviceID] = $_ }
        $now = Get-Date
        $seen = @{}
        $list = @(foreach ($d in Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue) {
            if (-not $d.DeviceName -or -not $d.DriverVersion) { continue }
            $seen[$d.DeviceID] = $true
            $cls = "$($d.DeviceClass)".ToUpper()
            $age = if ($d.DriverDate) { [math]::Round(($now - $d.DriverDate).TotalDays / 365.25, 1) } else { $null }
            if ($problems.ContainsKey($d.DeviceID)) { $status = Get-ProblemText $problems[$d.DeviceID].ConfigManagerErrorCode }
            elseif ($null -ne $age -and $age -ge 4 -and "$($d.DriverProviderName)" -notmatch '^Microsoft') { $status = 'Antigo' }
            else { $status = 'OK' }
            [pscustomobject]@{
                Status      = $status
                Categoria   = $(if ($CatMap.ContainsKey($cls)) { $CatMap[$cls] } else { 'Outros' })
                Dispositivo = $d.DeviceName
                Fabricante  = "$($d.DriverProviderName)"
                Versao      = $d.DriverVersion
                Data        = $d.DriverDate
                Idade       = $age
                INF         = "$($d.InfName)"
                Microsoft   = ("$($d.DriverProviderName)" -match '^Microsoft')
            }
        })
        foreach ($p in $problems.Values) {
            if ($seen.ContainsKey($p.PNPDeviceID)) { continue }
            $list += [pscustomobject]@{
                Status      = Get-ProblemText $p.ConfigManagerErrorCode
                Categoria   = 'Sem driver'
                Dispositivo = $(if ($p.Name) { $p.Name } else { $p.PNPDeviceID })
                Fabricante  = "$($p.Manufacturer)"; Versao = ''; Data = $null; Idade = $null; INF = ''; Microsoft = $false
            }
        }
        $list
    }

    # Notebook com duas placas: prefere a dedicada (NVIDIA, depois AMD) em vez da integrada.
    function Get-GpuInfo {
        $vc = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
            Where-Object { $_.PNPDeviceID -like 'PCI\*' } |
            Sort-Object @{ e = { if ($_.PNPDeviceID -match 'VEN_10DE') { 0 } elseif ($_.PNPDeviceID -match 'VEN_1002') { 1 } else { 2 } } },
                        @{ e = { [int64]$_.AdapterRAM }; Descending = $true } |
            Select-Object -First 1
        if (-not $vc) { return $null }
        $venDev = if ($vc.PNPDeviceID -match '(VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4})') { $matches[1] } else { '' }
        $vendor = switch -regex ($venDev) {
            '^VEN_1002' { 'AMD'; break }
            '^VEN_10DE' { 'NVIDIA'; break }
            '^VEN_8086' { 'Intel'; break }
            default { "$($vc.AdapterCompatibility)" }
        }
        [pscustomobject]@{
            Name = $vc.Name; Version = $vc.DriverVersion; Inf = $vc.InfFilename
            Code = [int]$vc.ConfigManagerErrorCode; VenDev = $venDev; Vendor = $vendor; Pnp = "$($vc.PNPDeviceID)"
        }
    }

    # drivers principais: os que fazem o PC funcionar (vídeo, rede, áudio, chipset, armazenamento, bluetooth)
    $KeyClasses = @{ DISPLAY = 'Vídeo'; NET = 'Rede'; MEDIA = 'Áudio'; SYSTEM = 'Chipset'; HDC = 'Armazenamento'; SCSIADAPTER = 'Armazenamento'; BLUETOOTH = 'Bluetooth' }
    function Get-KeyDrivers {
        # dispositivos diferentes que usam o MESMO driver (ex.: duas pontes AMD PCI) viram uma entrada só
        $porDriver = @{}
        foreach ($k in Get-KeyDriversRaw) {
            $key = '{0}|{1}|{2}' -f $k.Inf, $k.Versao, $k.Nome
            if ($porDriver.ContainsKey($key)) { $porDriver[$key].Qtd++ ; continue }
            $k | Add-Member -NotePropertyName Qtd -NotePropertyValue 1 -Force
            $porDriver[$key] = $k
        }
        @($porDriver.Values)
    }

    function Get-KeyDriversRaw {
        $seen = @{}
        foreach ($d in Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue) {
            $cls = "$($d.DeviceClass)".ToUpper()
            if (-not $KeyClasses.ContainsKey($cls) -or -not $d.DriverVersion) { continue }
            if ($d.DeviceID -notmatch '^(PCI|USB)\\' -or "$($d.DriverProviderName)" -match '^Microsoft') { continue }
            if ($seen.ContainsKey($d.DeviceID)) { continue }
            $seen[$d.DeviceID] = $true
            [pscustomobject]@{
                Id = $d.DeviceID; Nome = $d.DeviceName; Categoria = $KeyClasses[$cls]; Classe = $cls
                ClassGuid = "$($d.ClassGuid)"; Versao = $d.DriverVersion; Data = $d.DriverDate
                Inf = "$($d.InfName)"; Fabricante = "$($d.DriverProviderName)"
                VenDev = $(if ($d.DeviceID -match '((VEN_|VID_)[0-9A-F]{4}&(DEV_|PID_)[0-9A-F]{4})') { $matches[1] } else { '' })
            }
        }
    }

    function Get-SystemInfo {
        $bb = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
        $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
        $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue | Select-Object -First 1
        $ram = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
        # driver de chipset: o mais recente da classe Sistema feito pelo fabricante do processador
        $chip = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
            Where-Object { "$($_.DeviceClass)".ToUpper() -eq 'SYSTEM' -and "$($_.DriverProviderName)" -notmatch '^Microsoft' -and $_.DriverDate } |
            Sort-Object DriverDate -Descending | Select-Object -First 1
        $cv = if ("$($cpu.Manufacturer)" -match 'AMD') { 'AMD' } elseif ("$($cpu.Manufacturer)" -match 'Intel') { 'Intel' } else { "$($cpu.Manufacturer)" }
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        $enc = Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue | Select-Object -First 1
        $laptop = [bool](@($enc.ChassisTypes) | Where-Object { $_ -in 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32 }) -or
                  [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
        [pscustomobject]@{
            BoardMaker = "$($bb.Manufacturer)".Trim(); BoardModel = "$($bb.Product)".Trim()
            Maker = "$($cs.Manufacturer)".Trim(); Model = "$($cs.Model)".Trim(); IsLaptop = $laptop
            Cpu = "$($cpu.Name)".Trim(); CpuVendor = $cv; Cores = [int]$cpu.NumberOfCores; Threads = [int]$cpu.NumberOfLogicalProcessors
            BiosVer = "$($bios.SMBIOSBIOSVersion)".Trim(); BiosDate = $bios.ReleaseDate
            ChipsetName = "$($chip.DeviceName)"; ChipsetVer = "$($chip.DriverVersion)"; ChipsetDate = $chip.DriverDate; ChipsetMaker = "$($chip.DriverProviderName)"
            RamGB = [math]::Round((($ram | Measure-Object Capacity -Sum).Sum) / 1GB); RamSpeed = [int]($ram | Select-Object -First 1).ConfiguredClockSpeed; RamSlots = $ram.Count
        }
    }

    # Acha a pasta do pacote do driver dentro do DriverStore do Windows (leitura, sem admin).
    function Get-DriverPackage([string]$oemInf, [string]$version) {
        $inf = Join-Path $env:windir "INF\$oemInf"
        if (-not $oemInf -or -not (Test-Path $inf)) { return $null }
        $repo = Join-Path $env:windir 'System32\DriverStore\FileRepository'
        $cat = Select-String -Path $inf -Pattern '^\s*CatalogFile\S*\s*=\s*(\S+)' | Select-Object -First 1
        if ($cat) {
            $base = [IO.Path]::GetFileNameWithoutExtension($cat.Matches[0].Groups[1].Value)
            foreach ($d in Get-ChildItem $repo -Directory -Filter "$base.inf_*" -ErrorAction SilentlyContinue) {
                $f = Get-ChildItem $d.FullName -Filter '*.inf' -File | Select-Object -First 1
                if ($f -and (Select-String -Path $f.FullName -Pattern ('DriverVer\s*=.*' + [regex]::Escape($version)) -Quiet)) {
                    return [pscustomobject]@{ Folder = $d.FullName; Inf = $f.Name }
                }
            }
        }
        $len = (Get-Item $inf).Length; $hash = (Get-FileHash $inf).Hash
        foreach ($d in Get-ChildItem $repo -Directory -ErrorAction SilentlyContinue) {
            foreach ($f in Get-ChildItem $d.FullName -Filter '*.inf' -File -ErrorAction SilentlyContinue) {
                if ($f.Length -eq $len -and (Get-FileHash $f.FullName).Hash -eq $hash) { return [pscustomobject]@{ Folder = $d.FullName; Inf = $f.Name } }
            }
        }
        $null
    }

    # Todos os pacotes de driver de terceiros instalados (inclui extensões do fabricante), só a versão mais nova de cada.
    function Get-OemPackages {
        $byName = @{}
        foreach ($f in Get-ChildItem (Join-Path $env:windir 'INF') -Filter 'oem*.inf' -File -ErrorAction SilentlyContinue) {
            $ver = Select-String -Path $f.FullName -Pattern '^\s*DriverVer\s*=\s*[^,]*,\s*([\d\.]+)' | Select-Object -First 1
            if (-not $ver) { continue }
            $v = $ver.Matches[0].Groups[1].Value
            $cls = Select-String -Path $f.FullName -Pattern '^\s*Class\s*=\s*(\w+)' | Select-Object -First 1
            $pkg = Get-DriverPackage $f.Name $v
            if (-not $pkg) { continue }
            $vv = try { [version]$v } catch { [version]'0.0' }
            $key = $pkg.Inf.ToLower()
            if (-not $byName.ContainsKey($key) -or $byName[$key].V -lt $vv) {
                $byName[$key] = [pscustomobject]@{
                    Oem = $f.Name; Inf = $pkg.Inf; Folder = $pkg.Folder; Version = $v; V = $vv
                    Class = $(if ($cls) { $cls.Matches[0].Groups[1].Value.ToUpper() } else { 'OUTROS' })
                }
            }
        }
        @($byName.Values)
    }

    # ---- versão nova do próprio HollowDrivers (GitHub Releases)
    function Get-AppUpdate([string]$repo, [string]$current) {
        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = 'Tls12'
        $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'HollowDrivers' } -TimeoutSec 20
        $v = $null; try { $v = [version](("$($r.tag_name)") -replace '^[vV]', '') } catch { }
        if (-not $v -or $v -le [version]$current) { return }
        $exe = @($r.assets | Where-Object { $_.name -eq 'HollowDrivers-Setup.exe' })[0]
        $sig = @($r.assets | Where-Object { $_.name -eq 'HollowDrivers-Setup.exe.sig' })[0]
        if (-not $exe -or -not $sig) { return }   # versão sem assinatura não é oferecida
        # os links precisam ser exatamente os do GitHub deste repositório
        $ok = '^https://github\.com/' + [regex]::Escape($repo) + '/releases/download/v[\d\.]+/HollowDrivers-Setup\.exe(\.sig)?$'
        if ($exe.browser_download_url -notmatch $ok -or $sig.browser_download_url -notmatch $ok) { return }
        [pscustomobject]@{ Version = "$v"; Url = $exe.browser_download_url; SigUrl = $sig.browser_download_url; Notes = "$($r.body)".Trim(); SizeMB = [math]::Round($exe.size / 1MB, 1) }
    }

    # ---- atualizações pelo Catálogo oficial do Microsoft Update (drivers certificados pela Microsoft)
    function Get-CatalogHwId([string]$id) {
        if ($id -match '^(PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4})') { return $matches[1] }
        if ($id -match '^((USB|HID)\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4})') { return $matches[1] }
        if ($id -match '^(HID\\VEN_[A-Z0-9]+&DEV_[0-9A-F]{4})') { return $matches[1] }
        if ($id -match '^(ACPI\\[A-Z0-9]{4,8})\\') { return $matches[1] }
        $null
    }

    function Search-Catalog([string]$q) {
        $r = Invoke-WebRequest -UseBasicParsing -Uri ('https://www.catalog.update.microsoft.com/Search.aspx?q=' + [uri]::EscapeDataString($q)) -TimeoutSec 60
        foreach ($m in [regex]::Matches($r.Content, '<tr id="([0-9a-f\-]{36})_R\d+"[\s\S]*?</tr>')) {
            $c = @([regex]::Matches($m.Value, '<td[^>]*>([\s\S]*?)</td>') | ForEach-Object { ($_.Groups[1].Value -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim() })
            if ($c.Count -lt 7) { continue }
            [pscustomobject]@{ Id = $m.Groups[1].Value; Title = $c[1]; Products = $c[2]; Class = $c[3]; Date = $c[4]; Version = $c[5]; Size = ([regex]::Match($c[6], '[\d\.,]+ [KMG]B')).Value }
        }
    }

    # Para cada dispositivo com driver de fabricante (ou sem driver), procura versão MAIS NOVA no catálogo.
    # Vídeo e firmware ficam de fora de propósito.
    function Get-DriverUpdates {
        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = 'Tls12'
        $os = if ([Environment]::OSVersion.Version.Build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
        $cands = @{}
        foreach ($d in Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue) {
            if (-not $d.DeviceID -or "$($d.DeviceClass)".ToUpper() -in 'DISPLAY', 'FIRMWARE') { continue }
            if ("$($d.DriverProviderName)" -match '^Microsoft' -or -not $d.DriverVersion) { continue }
            $hw = Get-CatalogHwId $d.DeviceID
            if (-not $hw -or $cands.ContainsKey($hw)) { continue }
            $cands[$hw] = [pscustomobject]@{ Hw = $hw; Name = $d.DeviceName; Class = "$($d.DeviceClass)".ToUpper(); Version = $d.DriverVersion; Date = $d.DriverDate }
        }
        foreach ($p in Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode = 28' -ErrorAction SilentlyContinue) {
            $hw = Get-CatalogHwId $p.PNPDeviceID
            if (-not $hw -or $cands.ContainsKey($hw)) { continue }
            $cands[$hw] = [pscustomobject]@{ Hw = $hw; Name = $(if ($p.Name) { $p.Name } else { $hw }); Class = "$($p.PNPClass)".ToUpper(); Version = ''; Date = $null }
        }
        $i = 0; $n = $cands.Count
        foreach ($c in $cands.Values) {
            $i++
            if ($Prog) { $Prog.Text = "Verificando $i de ${n}: $($c.Name)" }
            $rows = @()
            try { $rows = @(Search-Catalog $c.Hw) } catch { continue }
            $cur = $null; try { $cur = [version]$c.Version } catch { }
            $best = $null; $bestV = $null
            foreach ($r in $rows) {
                if ($r.Products -notmatch [regex]::Escape($os) -or $r.Class -match 'Firmware') { continue }
                $v = $null; try { $v = [version]$r.Version } catch { }
                if (-not $v -or ($cur -and $v -le $cur)) { continue }
                $pub = $null; try { $pub = [datetime]::ParseExact($r.Date, 'M/d/yyyy', [Globalization.CultureInfo]::InvariantCulture) } catch { }
                if ($c.Date -and $pub -and $pub -le $c.Date) { continue }
                if (-not $bestV -or $v -gt $bestV) { $best = $r; $bestV = $v }
            }
            if ($best) {
                [pscustomobject]@{
                    Id = $best.Id; Dispositivo = $c.Name; Classe = $c.Class
                    Atual = $(if ($c.Version) { $c.Version } else { 'sem driver' })
                    Nova = $best.Version; Data = $best.Date; Tamanho = $best.Size; Titulo = $best.Title; Hw = $c.Hw
                }
            }
        }
    }

    function Find-DriverBooster {
        $found = @()
        foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                          'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
                          'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall') {
            foreach ($k in Get-ChildItem $root -ErrorAction SilentlyContinue) {
                $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
                if ("$($p.DisplayName)" -match 'Driver Booster') {
                    $found += [pscustomobject]@{ Path = "$($p.InstallLocation)".TrimEnd('\'); Uninstall = "$($p.UninstallString)" }
                }
            }
        }
        foreach ($d in 'C:\Program Files\Driver Booster', 'C:\Program Files (x86)\IObit\Driver Booster') {
            if ((Test-Path $d) -and -not ($found | Where-Object { $_.Path -eq $d })) { $found += [pscustomobject]@{ Path = $d; Uninstall = '' } }
        }
        @($found)
    }

    function Get-SourceName([string]$cmd, [string]$header) {
        if ($cmd -match 'Driver ?Booster|DpInst') { return 'Driver Booster ⚠' }
        if ($cmd -match 'AMDSoftwareInstaller|AtiSetup|AMDInstallManager') { return 'Instalador oficial AMD' }
        if ($cmd -match 'nvidia') { return 'Instalador oficial NVIDIA' }
        if ($cmd -match '\\Intel\\|igxpin|Installer\.exe.*Intel') { return 'Instalador oficial Intel' }
        if ($header -match 'Hardware initiated') { return 'Windows (detecção automática)' }
        if ($cmd -match 'pnputil') { return 'pnputil (manual / HollowDrivers)' }
        if ($cmd -match 'svchost|wuauclt|TiWorker|MoUsoCoreWorker|drvinst') { return 'Windows / Windows Update' }
        if ($cmd) {
            $exe = if ($cmd -match '^"([^"]+)"') { $matches[1] } else { ($cmd -split '\s+')[0] }
            return [IO.Path]::GetFileName($exe)
        }
        'Desconhecido'
    }

    # Lê o log de instalação do Windows e devolve quem instalou driver na placa de vídeo.
    function Get-InstallHistory([string]$venDev) {
        if (-not $venDev) { return @() }
        $files = Get-ChildItem (Join-Path $env:windir 'INF') -Filter 'setupapi.dev*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime
        $found = New-Object Collections.Generic.List[object]
        foreach ($f in $files) {
            try { $sr = New-Object IO.StreamReader([IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')) } catch { continue }
            $cur = $null
            while ($null -ne ($line = $sr.ReadLine())) {
                if ($line.StartsWith('>>>  [')) {
                    if ($cur -and $cur.Match -and $cur.Start) { $found.Add($cur) }
                    $h = $line.Substring(6).TrimEnd(']')
                    $cur = if ($h -like 'Device Install*') { [pscustomobject]@{ Header = $h; Start = $null; Cmd = ''; Match = ($h -like "*$venDev*") } } else { $null }
                    continue
                }
                if (-not $cur) { continue }
                if (-not $cur.Start -and $line -match 'Section start (\d{4}/\d\d/\d\d \d\d:\d\d:\d\d)') {
                    $cur.Start = [datetime]::ParseExact($matches[1], 'yyyy/MM/dd HH:mm:ss', $null)
                    continue
                }
                if (-not $cur.Cmd -and $line -match '^\s+cmd:\s+(.+)$') {
                    $cur.Cmd = $matches[1]
                    if ($cur.Cmd -like "*$venDev*" -or $cur.Cmd -match 'AMDSoftwareInstaller|AtiSetup|AMDInstallManager') { $cur.Match = $true }
                }
            }
            if ($cur -and $cur.Match -and $cur.Start) { $found.Add($cur) }
            $sr.Close()
        }
        $seen = @{}
        $found | Sort-Object Start -Descending | ForEach-Object {
            $src = Get-SourceName $_.Cmd $_.Header
            $key = $_.Start.ToString('yyyyMMddHHmm') + $src
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                [pscustomobject]@{ Quando = $_.Start; Origem = $src; Detalhe = $_.Header }
            }
        }
    }

    function Get-Health {
        $since = (Get-Date).AddDays(-30)
        $kp = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since } -ErrorAction SilentlyContinue)
        $tdr = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 4101; StartTime = $since } -ErrorAction SilentlyContinue)
        [pscustomobject]@{
            Crashes       = $kp.Count
            LastCrash     = $(if ($kp.Count) { $kp[0].TimeCreated } else { $null })
            Tdr           = $tdr.Count
            DriverBooster = @(Find-DriverBooster)
        }
    }

    # A hora que o Windows REGISTRA a queda é a do boot seguinte. A hora real vem da mensagem do evento 6008.
    function Get-CrashList([int]$days = 90) {
        $since = (Get-Date).AddDays(-$days)
        $log = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $since; Id = 41, 42, 107, 1, 6008 } -ErrorAction SilentlyContinue |
            Where-Object { $_.ProviderName -match 'Kernel-Power|Power-Troubleshooter|EventLog' })
        $sh = @($log | Where-Object { $_.Id -eq 6008 })
        $sleeps = @($log | Where-Object { $_.Id -eq 42 })
        $wakes = @($log | Where-Object { $_.Id -in 107, 1 })
        foreach ($e in @($log | Where-Object { $_.Id -eq 41 })) {
            $h = @{}
            ([xml]$e.ToXml()).Event.EventData.Data | ForEach-Object { $h[$_.Name] = $_.'#text' }
            $bc = [int64]("0$($h['BugcheckCode'])"); $btn = [int64]("0$($h['PowerButtonTimestamp'])"); $sl = [int]("0$($h['SleepInProgress'])")
            $tipo = if ($bc -ne 0) { 'Tela azul (0x{0:X})' -f $bc }
                elseif ($btn -ne 0) { 'Você segurou o botão de ligar' }
                elseif ($sl -ne 0) { 'Travou ao desligar/suspender' }
                else { 'Desligou de repente (sem erro)' }
            # hora real: números da mensagem do 6008 do mesmo boot, na ordem h m s dia mes ano
            $real = $e.TimeCreated
            $m = @($sh | Where-Object { [math]::Abs(($_.TimeCreated - $e.TimeCreated).TotalMinutes) -le 5 }) | Select-Object -First 1
            if ($m) {
                $n = @([regex]::Matches($m.Message, '\d+') | ForEach-Object { [int]$_.Value })
                if ($n.Count -ge 6) { try { $real = Get-Date -Year $n[5] -Month $n[4] -Day $n[3] -Hour $n[0] -Minute $n[1] -Second $n[2] } catch { } }
            }
            $off = ($e.TimeCreated - $real).TotalMinutes
            if ($off -lt 0) { $off = 0 }
            $s = @($sleeps | Where-Object { $_.TimeCreated -le $real }) | Select-Object -Last 1
            $w = @($wakes | Where-Object { $_.TimeCreated -le $real }) | Select-Object -Last 1
            [pscustomobject]@{
                Quando = $real
                Tipo = $tipo
                Estado = $(if ($s -and (-not $w -or $s.TimeCreated -gt $w.TimeCreated)) { 'Suspenso (dormindo)' } else { 'Ligado, em uso' })
                Desligado = $(if ($off -lt 2) { 'voltou na hora' } elseif ($off -lt 60) { '{0:N0} min' -f $off } else { '{0:N1} h' -f ($off / 60) })
                Sozinho = ($off -lt 2)
            }
        }
    }
}
. $Logic

# ================================================================ referência, backup e vigia

function Get-Baseline {
    if (Test-Path $BaselineFile) { try { Get-Content $BaselineFile -Raw | ConvertFrom-Json } catch { $null } }
}
function Save-Baseline($gpu) {
    [pscustomobject]@{ Name = $gpu.Name; Version = $gpu.Version; Inf = $gpu.Inf; Vendor = $gpu.Vendor; Marcado = (Get-Date).ToString('dd/MM/yyyy HH:mm') } |
        ConvertTo-Json | Set-Content $BaselineFile -Encoding UTF8
}

# ---- referência ("guardião") de TODOS os drivers principais, não só o vídeo
$KeyFile = Join-Path $DataDir 'baselines.json'
function Get-KeyBaselines {
    $h = @{}
    if (Test-Path $KeyFile) {
        # o PS 5 devolve a lista inteira como um item só; o ForEach-Object desmonta
        try { foreach ($b in @(Get-Content $KeyFile -Raw | ConvertFrom-Json | ForEach-Object { $_ })) { if ($b.Id) { $h[$b.Id] = $b } } } catch { }
    }
    $h
}
function Save-KeyBaselines($keys) {
    $agora = (Get-Date).ToString('dd/MM/yyyy HH:mm')
    @($keys | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Nome = $_.Nome; Categoria = $_.Categoria; Versao = $_.Versao; Inf = $_.Inf; Marcado = $agora } }) |
        ConvertTo-Json -Depth 4 | Set-Content $KeyFile -Encoding UTF8
}
# devolve os drivers principais que mudaram de versão desde a referência
function Get-KeyChanges($keys) {
    $base = Get-KeyBaselines
    if (-not $base.Count) { return @() }
    @($keys | Where-Object { $base.ContainsKey($_.Id) -and $base[$_.Id].Versao -ne $_.Versao } |
        ForEach-Object { [pscustomobject]@{ Nome = $_.Nome; Categoria = $_.Categoria; Antes = $base[$_.Id].Versao; Agora = $_.Versao; VenDev = $_.VenDev; Id = $_.Id } })
}

# backup por dispositivo (o de vídeo continua no seu lugar de sempre)
function Get-DeviceBackup([string]$id) {
    foreach ($d in Get-ChildItem $BackupDir -Directory -Filter 'dev-*' -ErrorAction SilentlyContinue) {
        $j = Join-Path $d.FullName 'HollowDrivers-backup.json'
        if (-not (Test-Path $j)) { continue }
        try {
            $o = Get-Content $j -Raw | ConvertFrom-Json
            if ($o.DeviceId -eq $id) { $o | Add-Member -NotePropertyName Path -NotePropertyValue $d.FullName -Force; return $o }
        } catch { }
    }
    $null
}

function Get-Backup([string]$version) {
    if ($version -notmatch '^[\d\.]+$') { return $null }   # nunca vira caminho tipo ..\..\
    $d = Join-Path $BackupDir $version
    $j = Join-Path $d 'HollowDrivers-backup.json'
    if (-not (Test-Path $j)) { return $null }
    try { $o = Get-Content $j -Raw | ConvertFrom-Json; $o | Add-Member -NotePropertyName Path -NotePropertyValue $d -Force; $o } catch { $null }
}

function Test-WatchEnabled { $null -ne (Get-ItemProperty $RunKey -Name HollowDrivers -ErrorAction SilentlyContinue) }
function Set-WatchEnabled([bool]$on) {
    if ($on) {
        $cmd = if (Test-Path $Exe) { '"{0}" -Watch' -f $Exe } else { 'wscript.exe "{0}" -Watch' -f $Launcher }
        Set-ItemProperty $RunKey -Name HollowDrivers -Value $cmd
    } else { Remove-ItemProperty $RunKey -Name HollowDrivers -ErrorAction SilentlyContinue }
}
function Stop-Tray {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*HollowDrivers.ps1*-Watch*' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Get-State {
    $s = $null
    if (Test-Path $WatchState) { try { $s = Get-Content $WatchState -Raw | ConvertFrom-Json } catch { } }
    $h = @{ LastCheck = $null; LastUpd = $null; UpdKey = ''; AppKey = '' }
    if ($s) { foreach ($p in $s.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    $h
}
function Save-State($h) { $h | ConvertTo-Json | Set-Content $WatchState -Encoding UTF8 }

function Get-WatchIssues {
    $st = Get-State
    $last = $null
    if ($st.LastCheck) { try { $last = [datetime]$st.LastCheck } catch { } }
    $issues = @()
    $g = Get-GpuInfo; $b = Get-Baseline
    if ($g -and $g.Code -ne 0) { $issues += 'Placa de vídeo com erro ({0}) — jogos não vão abrir.' -f (Get-ProblemText $g.Code) }
    if ($g -and $b -and $b.Version -ne $g.Version) {
        $h = @(Get-InstallHistory $g.VenDev)[0]
        $issues += 'Driver de vídeo trocado: {0} → {1}{2}' -f $b.Version, $g.Version, $(if ($h) { " ($($h.Origem))" } else { '' })
    }
    if ($last) {
        $new = @(Get-CrashList 30 | Where-Object { $_.Quando -gt $last })
        if ($new.Count) { $issues += 'O PC caiu {0}x desde a última verificação (última {1:dd/MM HH:mm}).' -f $new.Count, $new[0].Quando }
    }
    # placa de vídeo quebrada + cópia salva = abre o app em modo socorro (ele restaura sozinho)
    if ($g -and $g.Code -ne 0) {
        $b = Get-Baseline
        if ($b -and (Get-Backup $b.Version)) { Start-Launcher '-Rescue' }
    }
    $ch = @(Get-KeyChanges @(Get-KeyDrivers))
    if ($ch.Count) {
        $issues += $(if ($ch.Count -eq 1) { 'Driver de {0} trocado: {1} → {2}' -f $ch[0].Categoria.ToLower(), $ch[0].Antes, $ch[0].Agora }
            else { '{0} drivers principais trocados ({1})' -f $ch.Count, ((@($ch | Select-Object -First 3 | ForEach-Object { $_.Categoria.ToLower() }) | Sort-Object -Unique) -join ', ') })
    }
    if ((Find-DriverBooster).Count) { $issues += 'Driver Booster instalado.' }
    $st = Get-State; $st.LastCheck = (Get-Date).ToString('o'); Save-State $st
    $issues
}

# modelos de script que rodam com permissão de administrador (só quando o usuário confirma)
# Funções usadas por TODO script que roda como administrador. O script vai direto na linha de comando
# (-EncodedCommand), nunca num arquivo que outro programa poderia trocar antes do "Sim" do UAC.
$ElevLib = @'
$L = New-Object Collections.ArrayList
function W([string]$t) { [void]$L.Add($t) }
# log em arquivo NOVO (CreateNew): nunca sobrescreve nada, nem segue link simbólico plantado antes
function Save-Log {
    try {
        $dir = Split-Path '__LOG__'
        if ((Get-Item -LiteralPath $dir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
        $fs = [IO.File]::Open('__LOG__', 'CreateNew', 'Write')
        $sw = New-Object IO.StreamWriter($fs, (New-Object Text.UTF8Encoding $true))
        foreach ($x in $L) { $sw.WriteLine($x) }
        $sw.Close()
    } catch { }
}
# driver só é aceito com a assinatura oficial de drivers da Microsoft (WHQL)
function Test-WhqlSigned([string]$file) {
    $s = Get-AuthenticodeSignature -LiteralPath $file
    $s.Status -eq 'Valid' -and
        $s.SignerCertificate.Subject -like 'CN=Microsoft Windows Hardware Compatibility Publisher, O=Microsoft Corporation*' -and
        $s.SignerCertificate.Issuer -like '*O=Microsoft Corporation*'
}
# copia o pacote para uma pasta que SÓ administradores podem alterar; tudo é conferido e instalado de lá
function Copy-Protected([string]$src) {
    $dst = Join-Path $env:SystemRoot ('Temp\HollowDrivers-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dst | Out-Null
    icacls $dst /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' | Out-Null
    robocopy $src $dst /E /R:0 /W:0 /XJ /NFL /NDL /NJH /NJS /NP | Out-Null
    $dst
}
function New-RestorePoint([string]$desc) {
    try {
        Checkpoint-Computer -Description $desc -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue -WarningVariable wv
        if ($wv) { W ('PONTO=aviso: ' + $wv[0]) } else { W 'PONTO=ok' }
    } catch { W ('PONTO=falhou: ' + $_.Exception.Message) }
}
'@

$EnableTpl = @'
try {
    $id = '__PNP__'
    if ($id -notmatch '^[A-Za-z0-9\\&_\.\-]+$') { throw 'identificador de dispositivo inválido' }
    $d = Get-PnpDevice -InstanceId $id -ErrorAction Stop
    W ('ANTES=' + $d.Status + '/' + $d.Problem)
    try { Enable-PnpDevice -InstanceId $id -Confirm:$false -ErrorAction Stop } catch { W ('ENABLE=' + $_.Exception.Message) }
    $out = (& pnputil.exe /enable-device $id 2>&1 | Out-String).Trim()
    W ('PNPUTIL=' + ($out -replace '\s*\r?\n\s*', ' | '))
    Start-Sleep -Seconds 2
    $d2 = Get-PnpDevice -InstanceId $id -ErrorAction SilentlyContinue
    W ('DEPOIS=' + $d2.Status + '/' + $d2.Problem)
} catch { W ('ERRO=' + $_.Exception.Message) }
finally { Save-Log }
'@

$RestoreTpl = @'
try {
    $inf = '__INFNAME__'
    if ($inf -notmatch '^[\w\-\.]+\.inf$') { throw 'nome de arquivo INF inválido no backup' }
    $deviceId = '__DEVID__'
    $currentInf = '__CURRENTINF__'
    if (-not $deviceId) { throw 'dispositivo nao identificado com seguranca' }
    if ($currentInf) {
        if ($currentInf -notmatch '^oem\d+\.inf$') { throw 'nome do driver atual invalido' }
        $active = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | Where-Object { $_.InfName -ieq $currentInf })
        if (@($active | Where-Object { $_.DeviceID -eq $deviceId }).Count -ne 1) { throw 'o driver atual do dispositivo mudou; examine o PC novamente' }
        if ($active.Count -ne 1) { throw 'o pacote atual tambem e usado por outro dispositivo; restauracao cancelada' }
    }
    $dst = Copy-Protected '__SRC__'
    try {
        # confere TUDO antes de mexer no driver atual
        $infPath = Join-Path $dst $inf
        if (-not (Test-Path -LiteralPath $infPath)) { throw 'o INF do backup não foi encontrado' }
        $txt = Get-Content -LiteralPath $infPath -Raw
        if ($txt -notmatch '(?im)^\s*ClassGuid\s*=\s*\{?__CLASSGUID__\}?') { throw 'o backup não é do tipo de driver esperado' }
        if ($txt -notmatch ('(?im)^\s*DriverVer\s*=[^\r\n]*' + [regex]::Escape('__VER__'))) { throw 'a versão do backup não confere com a salva' }
        $cats = @(Get-ChildItem -LiteralPath $dst -Recurse -Filter '*.cat')
        if (-not $cats.Count -or @($cats | Where-Object { -not (Test-WhqlSigned $_.FullName) }).Count) { throw 'o backup não tem a assinatura oficial da Microsoft' }
        New-RestorePoint 'HollowDrivers - antes de restaurar driver de video'
        # Registra o backup antes de remover o pacote atual.
        $stage = pnputil /add-driver $infPath 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw ('falha ao preparar backup: ' + $stage.Trim()) }
        if ($currentInf) {
            $o = pnputil /delete-driver $currentInf /uninstall /force 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { throw ('falha ao remover driver atual: ' + $o.Trim()) }
            W ('REMOVIDO=' + $currentInf)
        }
        $o = pnputil /add-driver $infPath /install 2>&1 | Out-String
        W ('INSTALAR=' + $LASTEXITCODE)
        W $o.Trim()
        if ($LASTEXITCODE -ne 0) { throw ('falha ao instalar backup: ' + $o.Trim()) }
        pnputil /scan-devices | Out-Null
    } finally { Remove-Item -LiteralPath $dst -Recurse -Force -ErrorAction SilentlyContinue }
} catch { W ('ERRO=' + $_.Exception.Message) }
finally { Save-Log }
'@

$PointTpl = @'
try { New-RestorePoint 'HollowDrivers - ponto manual' } finally { Save-Log }
'@

$WuTpl = @'
try {
    $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $au = "$pol\AU"
    $ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $inicio = 'PauseUpdatesStartTime', 'PauseFeatureUpdatesStartTime', 'PauseQualityUpdatesStartTime'
    $fim = 'PauseUpdatesExpiryTime', 'PauseFeatureUpdatesEndTime', 'PauseQualityUpdatesEndTime'
    if ('__HOLD__' -eq '1') {
        New-Item $au -Force | Out-Null
        New-Item $ux -Force | Out-Null
        Set-ItemProperty $au -Name NoAutoUpdate -Value 1 -Type DWord
        Set-ItemProperty $au -Name AUOptions -Value 2 -Type DWord
        $ini = (Get-Date).ToUniversalTime()
        foreach ($n in $inicio) { Set-ItemProperty $ux -Name $n -Value $ini.ToString('yyyy-MM-ddTHH:mm:ssZ') -Type String }
        foreach ($n in $fim) { Set-ItemProperty $ux -Name $n -Value $ini.AddDays(35).ToString('yyyy-MM-ddTHH:mm:ssZ') -Type String }
        W 'HOLD=1'
    } elseif ('__HOLD__' -eq '0') {
        Remove-ItemProperty $au -Name NoAutoUpdate, AUOptions -ErrorAction SilentlyContinue
        foreach ($n in ($inicio + $fim)) { Remove-ItemProperty $ux -Name $n -ErrorAction SilentlyContinue }
        W 'HOLD=0'
    }
    if ('__DRV__' -eq '1') {
        New-Item $pol -Force | Out-Null
        Set-ItemProperty $pol -Name ExcludeWUDriversInQualityUpdate -Value 1 -Type DWord
        W 'DRV=1'
    } elseif ('__DRV__' -eq '0') {
        Remove-ItemProperty $pol -Name ExcludeWUDriversInQualityUpdate -ErrorAction SilentlyContinue
        W 'DRV=0'
    }
    if ('__SR__' -eq '1') {
        try { Enable-ComputerRestore -Drive 'C:\' -ErrorAction Stop; W 'SR=1' } catch { W ('SR=falhou: ' + $_.Exception.Message) }
        try { vssadmin resize shadowstorage /for=C: /on=C: /maxsize=10% 2>&1 | Out-Null } catch { }
        New-RestorePoint '__DESC__'
    }
} catch { W ('ERRO=' + $_.Exception.Message) }
finally { Save-Log }
'@

$KeyAllTpl = @'
$itens = @(ConvertFrom-Json '__JSON__' | ForEach-Object { $_ })
$ok = 0
foreach ($i in $itens) {
    if ($Prog) { $Prog.Text = "Copiando: $($i.Nome)" }
    New-Item -ItemType Directory -Force -Path $i.Dst | Out-Null
    robocopy $i.Src $i.Dst /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -lt 8) {
        $size = (Get-ChildItem $i.Dst -Recurse -File | Measure-Object Length -Sum).Sum
        [pscustomobject]@{ Version = $i.Ver; Name = $i.Nome; Inf = $i.Inf; Vendor = $i.Vendor; DeviceId = $i.Id; ClassGuid = $i.ClassGuid; Categoria = $i.Cat
            Date = (Get-Date).ToString('dd/MM/yyyy HH:mm'); SizeMB = [math]::Round($size / 1MB) } |
            ConvertTo-Json | Set-Content (Join-Path $i.Dst 'HollowDrivers-backup.json') -Encoding UTF8
        $ok++
    }
}
[pscustomobject]@{ Ok = $ok; Total = $itens.Count }
'@

$BackupTpl = @'
robocopy '__SRC__' '__DST__' /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
$rc = $LASTEXITCODE
if ($rc -lt 8) {
    $size = (Get-ChildItem '__DST__' -Recurse -File | Measure-Object Length -Sum).Sum
    [pscustomobject]@{ Version = '__VER__'; Name = '__NAME__'; Inf = '__INF__'; Vendor = '__VENDOR__'; DeviceId = '__DEVID__'; ClassGuid = '__CLASSGUID__'; Categoria = '__CAT__'; Date = (Get-Date).ToString('dd/MM/yyyy HH:mm'); SizeMB = [math]::Round($size / 1MB) } |
        ConvertTo-Json | Set-Content (Join-Path '__DST__' 'HollowDrivers-backup.json') -Encoding UTF8
}
$rc
'@

$DlTpl = @'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
$items = @(ConvertFrom-Json '__JSON__' | ForEach-Object { $_ })   # PS 5 devolve a lista inteira como um item só
function Test-WhqlSigned([string]$file) {
    $s = Get-AuthenticodeSignature -LiteralPath $file
    $s.Status -eq 'Valid' -and
        $s.SignerCertificate.Subject -like 'CN=Microsoft Windows Hardware Compatibility Publisher, O=Microsoft Corporation*' -and
        $s.SignerCertificate.Issuer -like '*O=Microsoft Corporation*'
}
$ok = @(); $fail = @(); $pins = @(); $i = 0
foreach ($u in $items) {
    $i++
    if ($Prog) { $Prog.Text = "Baixando $i de $($items.Count): $($u.Dispositivo)" }
    $dir = Join-Path '__DIR__' $u.Id
    try {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $post = 'updateIDs=' + [uri]::EscapeDataString('[{"size":0,"languages":"","uidInfo":"' + $u.Id + '","updateID":"' + $u.Id + '"}]')
        $d = Invoke-WebRequest -UseBasicParsing -Method Post -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Body $post -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 60
        $urls = @([regex]::Matches($d.Content, "downloadInformation\[\d+\]\.files\[\d+\]\.url\s*=\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -like '*.cab' })
        if (-not $urls.Count) { throw 'link de download não encontrado' }
        $x = Join-Path $dir 'arquivos'
        New-Item -ItemType Directory -Force -Path $x | Out-Null
        foreach ($url in $urls) {
            if ($url -notmatch '^https?://[^/]*\.(windowsupdate|microsoft)\.com/') { throw 'link fora dos servidores da Microsoft' }
            $cab = Join-Path $dir ([IO.Path]::GetFileName(([uri]$url).AbsolutePath))
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $cab -TimeoutSec 900
            if (-not (Test-WhqlSigned $cab)) { throw 'o download não tem a assinatura oficial de drivers da Microsoft' }
            & expand.exe -F:* $cab $x | Out-Null
            Remove-Item $cab -Force
        }
        # "impressão digital" dos arquivos que definem o driver (.inf e .cat): o script de administrador
        # reconfere cada uma antes de instalar, então trocar o pacote depois do download não adianta
        $files = @(Get-ChildItem -LiteralPath $x -Recurse -File | Where-Object { $_.Extension -in '.inf', '.cat' } | ForEach-Object {
            [pscustomobject]@{ P = $_.FullName.Substring($x.Length + 1); H = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
        })
        if (-not ($files | Where-Object { $_.P -like '*.inf' })) { throw 'pacote sem arquivo .inf' }
        foreach ($c in @($files | Where-Object { $_.P -like '*.cat' })) { if (-not (Test-WhqlSigned (Join-Path $x $c.P))) { throw 'catálogo do driver sem assinatura da Microsoft' } }
        if (-not ($files | Where-Object { $_.P -like '*.cat' })) { throw 'pacote sem catálogo assinado' }
        $ok += $u.Id
        $pins += [pscustomobject]@{ Id = $u.Id; Files = $files }
    } catch {
        $fail += ('{0}: {1}' -f $u.Dispositivo, $_.Exception.Message)
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
[pscustomobject]@{ Ok = @($ok); Fail = @($fail); Pins = @($pins) }
'@

$UpdTpl = @'
try {
    New-RestorePoint 'HollowDrivers - antes de atualizar drivers'
    $pins = @(ConvertFrom-Json '__PINS__' | ForEach-Object { $_ })
    foreach ($p in $pins) {
        if ($p.Id -notmatch '^[0-9a-f\-]{36}$') { W ('RECUSADO=' + $p.Id + ' id inválido'); continue }
        $dst = Copy-Protected (Join-Path '__DIR__' ($p.Id + '\arquivos'))
        try {
            $bad = $null
            foreach ($f in @($p.Files)) {
                $fp = Join-Path $dst $f.P
                if (-not (Test-Path -LiteralPath $fp) -or (Get-FileHash -LiteralPath $fp -Algorithm SHA256).Hash -ne $f.H) { $bad = 'arquivo alterado depois do download: ' + $f.P; break }
                if ($f.P -like '*.cat' -and -not (Test-WhqlSigned $fp)) { $bad = 'catálogo sem assinatura da Microsoft: ' + $f.P; break }
            }
            if (-not $bad) {
                $known = @($p.Files | ForEach-Object { $_.P })
                $extra = @(Get-ChildItem -LiteralPath $dst -Recurse -File | Where-Object { $_.Extension -in '.inf', '.cat' -and $known -notcontains $_.FullName.Substring($dst.Length + 1) })
                if ($extra.Count) { $bad = 'arquivo inesperado no pacote: ' + $extra[0].Name }
            }
            if ($bad) { W ('RECUSADO=' + $p.Id + ' ' + $bad); continue }
            $o = pnputil /add-driver (Join-Path $dst '*.inf') /subdirs /install 2>&1 | Out-String
            $rc = $LASTEXITCODE
            W ('PACOTE=' + $p.Id + ' RC=' + $rc)
            if ($rc -eq 259) {
                foreach ($m in [regex]::Matches($o, 'oem\d+\.inf')) { pnputil /delete-driver $m.Value 2>&1 | Out-Null; W ('LIMPO=' + $m.Value) }
            }
        } finally { Remove-Item -LiteralPath $dst -Recurse -Force -ErrorAction SilentlyContinue }
    }
} catch { W ('ERRO=' + $_.Exception.Message) }
finally { Save-Log }
'@

function Expand-Tpl([string]$tpl, [hashtable]$map) {
    foreach ($k in $map.Keys) { $tpl = $tpl.Replace($k, "$($map[$k])".Replace("'", "''")) }
    $tpl
}

# ================================================================ segurar o Windows Update (tarefa agendada)
# Roda no logon e uma vez por dia COM permissão de administrador. Só faz uma coisa: se o usuário pediu
# para manter as atualizações seguradas e alguém (ou o próprio Windows) religou, aplica a pausa de novo.
$WuTask = 'HollowDrivers-Windows'
function Test-WuTask { [bool](Get-ScheduledTask -TaskName $WuTask -ErrorAction SilentlyContinue) }

if ($HoldWU) {
    $st = Get-State
    if (-not $st.WuHold) { return }
    $w = Get-WuState
    if ($w.Pausado -and $w.SemAuto) { return }              # já está segurado: nada a fazer
    $log = Join-Path $DataDir ('windows-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
    $code = (Expand-Tpl $ElevLib @{ '__LOG__' = $log }) + "`n" +
        (Expand-Tpl $WuTpl @{ '__HOLD__' = '1'; '__DRV__' = ''; '__SR__' = ''; '__DESC__' = '' })
    & ([scriptblock]::Create($code))
    return
}

# ================================================================ socorro automático (tarefa agendada)
# Roda no logon COM permissão de administrador, mas só faz uma coisa: se a placa de vídeo estiver
# com erro e existir cópia validada, reinstala essa cópia. Uma tentativa por inicialização.
$RescueTask = 'HollowDrivers-Socorro'
function Test-RescueTask { [bool](Get-ScheduledTask -TaskName $RescueTask -ErrorAction SilentlyContinue) }

if ($AutoRescue) {
    $log = Join-Path $DataDir ('socorro-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
    $st = Get-State
    $boot = ''
    try { $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o') } catch { }
    if ($st.RescueBoot -eq $boot -and $boot) { return }      # já tentou nesta inicialização
    $g = Get-GpuInfo
    if (-not $g -or $g.Code -eq 0) { return }                # vídeo está bem: nada a fazer
    $b = Get-Baseline
    $bk = if ($b) { Get-Backup $b.Version } else { $null }
    if (-not $bk -or "$($bk.Inf)" -notmatch '^[\w\-\.]+\.inf$') { return }
    $st.RescueBoot = $boot; Save-State $st
    $vendorRx = switch ($bk.Vendor) {
        'AMD' { 'Advanced Micro Devices|\bAMD\b|ATI Technologies' }
        'NVIDIA' { 'NVIDIA' }
        'Intel' { '\bIntel\b' }
        default { [regex]::Escape("$($bk.Vendor)") }
    }
    $code = (Expand-Tpl $ElevLib @{ '__LOG__' = $log }) + "`n" +
        (Expand-Tpl $RestoreTpl @{ '__VENDOR__' = $vendorRx; '__SRC__' = $bk.Path; '__INFNAME__' = $bk.Inf
            '__VER__' = $bk.Version; '__CLASSGUID__' = '4d36e968-e325-11ce-bfc1-08002be10318'; '__DEVID__' = $g.Pnp; '__CURRENTINF__' = $g.Inf })
    & ([scriptblock]::Create($code))
    return
}

# ================================================================ vigia: ícone fixo perto do relógio
if ($Watch) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $mtx = New-Object Threading.Mutex($false, 'Local\HollowDriversTray')
    if (-not $mtx.WaitOne(0)) { return }

    function New-TrayIcon([Drawing.Color]$c1, [Drawing.Color]$c2) {
        $bmp = New-Object Drawing.Bitmap(32, 32)
        $gr = [Drawing.Graphics]::FromImage($bmp); $gr.SmoothingMode = 'AntiAlias'; $gr.TextRenderingHint = 'AntiAliasGridFit'
        $r = New-Object Drawing.Rectangle(1, 1, 30, 30)
        $gr.FillEllipse((New-Object Drawing.Drawing2D.LinearGradientBrush($r, $c1, $c2, 45)), $r)
        $f = New-Object Drawing.Font('Segoe MDL2 Assets', 15, [Drawing.GraphicsUnit]::Pixel)
        $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
        $gr.DrawString([string][char]0xEA18, $f, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF(0, 1, 32, 32)), $sf)
        $gr.Dispose()
        [Drawing.Icon]::FromHandle($bmp.GetHicon())
    }
    $icoOk = New-TrayIcon ([Drawing.Color]::FromArgb(52, 211, 153)) ([Drawing.Color]::FromArgb(16, 150, 110))
    $icoBad = New-TrayIcon ([Drawing.Color]::FromArgb(255, 90, 69)) ([Drawing.Color]::FromArgb(212, 20, 90))

    $ni = New-Object Windows.Forms.NotifyIcon
    $ni.Icon = $icoOk; $ni.Text = 'HollowDrivers'; $ni.Visible = $true
    $script:LastIssues = ''

    function Invoke-WatchCheck([bool]$manual) {
        $updLine = ''
        $st = Get-State
        $lastU = $null; if ($st.LastUpd) { try { $lastU = [datetime]$st.LastUpd } catch { } }
        if ($manual -or -not $lastU -or ((Get-Date) - $lastU).TotalHours -ge 24) {
            $online = $true
            try { $null = Invoke-WebRequest -UseBasicParsing -Method Head -Uri 'https://www.catalog.update.microsoft.com/' -TimeoutSec 15 } catch { $online = $false }
            if ($online) {
                $ups = @(); try { $ups = @(Get-DriverUpdates) } catch { }
                $key = @($ups | ForEach-Object Id) -join '|'
                $st = Get-State
                $isNew = $key -and $key -ne $st.UpdKey
                $st.LastUpd = (Get-Date).ToString('o'); $st.UpdKey = $key; Save-State $st
                if ($ups.Count -and ($isNew -or $manual)) {
                    $updLine = $(if ($ups.Count -eq 1) { '1 atualização de driver oficial disponível.' } else { "$($ups.Count) atualizações de driver oficiais disponíveis." })
                }
                $au = $null; try { $au = Get-AppUpdate $UpdateRepo $AppVersion } catch { }
                $st = Get-State
                if ($au -and ($manual -or $st.AppKey -ne $au.Version)) { $updLine = ("HollowDrivers $($au.Version) disponível. " + $updLine).Trim() }
                $st.AppKey = $(if ($au) { $au.Version } else { '' }); Save-State $st
            }
        }
        $issues = @(Get-WatchIssues)
        if ($issues.Count) {
            $ni.Icon = $icoBad
            $ni.Text = $(if ($issues.Count -eq 1) { 'HollowDrivers — 1 alerta' } else { 'HollowDrivers — {0} alertas' -f $issues.Count })
        } else { $ni.Icon = $icoOk; $ni.Text = 'HollowDrivers — tudo certo' }
        $key = $issues -join '|'
        if ($issues.Count -and ($manual -or $key -ne $script:LastIssues)) {
            $txt = (@($issues) + @($updLine | Where-Object { $_ })) -join "`n"
            $ni.ShowBalloonTip(20000, 'HollowDrivers — atenção', $txt.Substring(0, [Math]::Min(250, $txt.Length)), 'Warning')
        } elseif ($updLine) {
            $ni.ShowBalloonTip(15000, 'HollowDrivers', "$updLine Clique para abrir e atualizar.", 'Info')
        } elseif ($manual) {
            $ni.ShowBalloonTip(8000, 'HollowDrivers', 'Tudo certo com seus drivers.', 'Info')
        }
        $script:LastIssues = $key
    }

    $menu = New-Object Windows.Forms.ContextMenuStrip
    [void]$menu.Items.Add('Abrir HollowDrivers', $null, { Start-Launcher '' })
    [void]$menu.Items.Add('Verificar agora', $null, { Invoke-WatchCheck $true })
    [void]$menu.Items.Add('-')
    [void]$menu.Items.Add('Fechar vigia (volta ao reiniciar o PC)', $null, { $ni.Visible = $false; [Windows.Forms.Application]::Exit() })
    $ni.ContextMenuStrip = $menu
    $ni.add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Start-Launcher '' } })
    $ni.add_BalloonTipClicked({ Start-Launcher '' })

    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 3600000
    $timer.add_Tick({ Invoke-WatchCheck $false })
    $timer.Start()
    Invoke-WatchCheck $false
    [Windows.Forms.Application]::Run()
    $ni.Dispose(); $mtx.ReleaseMutex()
    return
}

if ($SelfTest) {
    $g = Get-GpuInfo; $g | Format-List
    Get-SystemInfo | Format-List
    Get-Health | Format-List
    Get-InstallHistory $g.VenDev | Select-Object -First 5 | Format-Table -AutoSize
    Get-CrashList 90 | Group-Object Tipo | Select-Object Count, Name | Format-Table -AutoSize
    'Pacote do driver: ' + (Get-DriverPackage $g.Inf $g.Version | Out-String).Trim()
    "Vigia ligado: $(Test-WatchEnabled)"
    $s = Get-DriverScan
    'Drivers: {0} | problema: {1} | antigos: {2}' -f $s.Count, @($s | Where-Object { $_.Status -notin 'OK', 'Antigo' }).Count, @($s | Where-Object { $_.Status -eq 'Antigo' }).Count
    return
}

# ================================================================ interface (WPF)
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
$dwmOk = $false
# carrega pela memória: LoadFrom travaria o .exe e impediria a atualização automática de substituí-lo
if (Test-Path $Exe) { try { [void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes($Exe)); $dwmOk = [bool]('DG.Dwm' -as [type]) } catch { } }
if (-not $dwmOk) { Add-Type -Namespace DG -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);' }

$Hex = @{ bad = '#F87171'; warn = '#FBBF24'; ok = '#34D399'; info = '#8B93A1'; ask = '#FF6A55' }
# (a cor 'ask' segue o tema; é ajustada depois que o tema é carregado)
$Glyph = @{ bad = [string][char]0xE7BA; warn = [string][char]0xE946; ok = [string][char]0xE73E; info = [string][char]0xE946; ask = [string][char]0xE946 }

function Get-Plural([int]$n, [string]$one, [string]$many) { if ($n -eq 1) { "1 $one" } else { "$n $many" } }

# ---- temas de cores (a base continua escura; muda a cor de destaque e o brilho)
$Themes = [ordered]@{
    vermelho = @{ Nome = 'Vermelho'; A1 = '#FF5A45'; A2 = '#D4145A'; Glow = '#FF3B30'; Bg = '#2A1418'; Icon = '#FF6A55' }
    azul     = @{ Nome = 'Azul';     A1 = '#3B82F6'; A2 = '#4F46E5'; Glow = '#3B82F6'; Bg = '#111A2E'; Icon = '#60A5FA' }
    verde    = @{ Nome = 'Verde';    A1 = '#22C55E'; A2 = '#0D9488'; Glow = '#10B981'; Bg = '#0E2219'; Icon = '#4ADE80' }
    roxo     = @{ Nome = 'Roxo';     A1 = '#A855F7'; A2 = '#DB2777'; Glow = '#A855F7'; Bg = '#1E1230'; Icon = '#C084FC' }
    laranja  = @{ Nome = 'Laranja';  A1 = '#F59E0B'; A2 = '#EA580C'; Glow = '#F59E0B'; Bg = '#2A1D0C'; Icon = '#FBBF24' }
    ciano    = @{ Nome = 'Ciano';    A1 = '#06B6D4'; A2 = '#2563EB'; Glow = '#06B6D4'; Bg = '#0B1F26'; Icon = '#22D3EE' }
}
$SettingsFile = Join-Path $DataDir 'settings.json'
function Get-Settings {
    $h = @{ Theme = 'vermelho' }
    if (Test-Path $SettingsFile) { try { (Get-Content $SettingsFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } } catch { } }
    $h
}
function Save-Settings($h) { $h | ConvertTo-Json | Set-Content $SettingsFile -Encoding UTF8 }
$ThemeKey = (Get-Settings).Theme
if (-not $Themes.Contains($ThemeKey)) { $ThemeKey = 'vermelho' }
$Theme = $Themes[$ThemeKey]
function Use-Theme([string]$x) {
    $x.Replace('__A1__', $Theme.A1).Replace('__A2__', $Theme.A2).Replace('__GLOW__', $Theme.Glow).Replace('__BGR__', $Theme.Bg).
      Replace('__ICON__', $Theme.Icon).Replace('__HALO__', '#1A' + $Theme.A1.Substring(1))
}

$ResXaml = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <SolidColorBrush x:Key="Bg" Color="#0F1115"/>
  <SolidColorBrush x:Key="Surface" Color="#171A21"/>
  <SolidColorBrush x:Key="Surface2" Color="#1F232C"/>
  <SolidColorBrush x:Key="Stroke" Color="#2A2F3A"/>
  <SolidColorBrush x:Key="Text" Color="#E8EAED"/>
  <SolidColorBrush x:Key="Dim" Color="#8B93A1"/>
  <LinearGradientBrush x:Key="Accent" StartPoint="0,0" EndPoint="1,1">
    <GradientStop Color="__A1__" Offset="0"/>
    <GradientStop Color="__A2__" Offset="1"/>
  </LinearGradientBrush>
  <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
  <FontFamily x:Key="Display">Segoe UI Variable Display, Segoe UI</FontFamily>

  <Style x:Key="Pill" TargetType="Button">
    <Setter Property="Foreground" Value="{StaticResource Text}"/>
    <Setter Property="Background" Value="{StaticResource Surface2}"/>
    <Setter Property="BorderBrush" Value="{StaticResource Stroke}"/>
    <Setter Property="Padding" Value="16,8"/>
    <Setter Property="Margin" Value="0,0,8,8"/>
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="B" CornerRadius="18" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="#565E6E"/></Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.75"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.45"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="PillAccent" TargetType="Button" BasedOn="{StaticResource Pill}">
    <Setter Property="Background" Value="{StaticResource Accent}"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="Foreground" Value="White"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
  </Style>
  <Style x:Key="PillBad" TargetType="Button" BasedOn="{StaticResource Pill}">
    <Setter Property="Background" Value="#3A1D22"/>
    <Setter Property="BorderBrush" Value="#7A2E36"/>
    <Setter Property="Foreground" Value="#FCA5A5"/>
  </Style>
  <Style x:Key="Ghost" TargetType="Button">
    <Setter Property="Foreground" Value="{StaticResource Dim}"/>
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border Background="Transparent" Padding="6,4"><ContentPresenter/></Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="{StaticResource Text}"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="MenuBtn" TargetType="Button">
    <Setter Property="Foreground" Value="{StaticResource Text}"/>
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="MinWidth" Value="340"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="B" CornerRadius="8" Background="Transparent" Padding="12,9">
            <ContentPresenter HorizontalAlignment="Left"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#2A2F3A"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="GroupLbl" TargetType="TextBlock">
    <Setter Property="Foreground" Value="{StaticResource Dim}"/>
    <Setter Property="FontSize" Value="10.5"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Margin" Value="3,0,0,7"/>
  </Style>
  <Style x:Key="SectionTitle" TargetType="TextBlock">
    <Setter Property="FontSize" Value="23"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="FontFamily" Value="{StaticResource Display}"/>
  </Style>
  <Style x:Key="SectionSub" TargetType="TextBlock">
    <Setter Property="Foreground" Value="{StaticResource Dim}"/>
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="Margin" Value="0,5,0,0"/>
    <Setter Property="TextWrapping" Value="Wrap"/>
  </Style>
  <Style x:Key="Nav" TargetType="ToggleButton">
    <Setter Property="Foreground" Value="{StaticResource Dim}"/>
    <Setter Property="FontSize" Value="13.5"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Margin" Value="0,0,0,4"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ToggleButton">
          <Border x:Name="B" CornerRadius="10" Background="Transparent" Padding="12,11">
            <Grid>
              <Rectangle x:Name="Bar" Width="3" RadiusX="2" RadiusY="2" HorizontalAlignment="Left" Margin="-7,3,0,3" Fill="{StaticResource Accent}" Visibility="Collapsed"/>
              <StackPanel Orientation="Horizontal">
                <TextBlock FontFamily="{StaticResource Icons}" Text="{TemplateBinding Tag}" FontSize="15" VerticalAlignment="Center" Margin="0,0,12,0"/>
                <ContentPresenter VerticalAlignment="Center"/>
              </StackPanel>
            </Grid>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="#1A1E26"/></Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="B" Property="Background" Value="{StaticResource Surface2}"/>
              <Setter TargetName="Bar" Property="Visibility" Value="Visible"/>
              <Setter Property="Foreground" Value="{StaticResource Text}"/>
              <Setter Property="FontWeight" Value="SemiBold"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="NavBtn" TargetType="Button">
    <Setter Property="Foreground" Value="{StaticResource Dim}"/>
    <Setter Property="FontSize" Value="13.5"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="B" CornerRadius="10" Background="Transparent" Padding="12,11">
            <StackPanel Orientation="Horizontal">
              <TextBlock FontFamily="{StaticResource Icons}" Text="{TemplateBinding Tag}" FontSize="14" VerticalAlignment="Center" Margin="0,0,12,0"/>
              <ContentPresenter VerticalAlignment="Center"/>
            </StackPanel>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="B" Property="Background" Value="#1A1E26"/>
              <Setter Property="Foreground" Value="{StaticResource Text}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="Chip" TargetType="ToggleButton">
    <Setter Property="Foreground" Value="{StaticResource Dim}"/>
    <Setter Property="FontSize" Value="12.5"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Margin" Value="0,0,8,0"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ToggleButton">
          <Border x:Name="B" CornerRadius="14" Background="{StaticResource Surface2}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" Padding="13,6">
            <ContentPresenter/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="#565E6E"/></Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="B" Property="Background" Value="{StaticResource Accent}"/>
              <Setter TargetName="B" Property="BorderBrush" Value="Transparent"/>
              <Setter Property="Foreground" Value="White"/>
              <Setter Property="FontWeight" Value="SemiBold"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="TextBox">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Foreground" Value="{StaticResource Text}"/>
    <Setter Property="CaretBrush" Value="{StaticResource Text}"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
  </Style>

  <Style TargetType="CheckBox">
    <Setter Property="Foreground" Value="{StaticResource Dim}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="CheckBox">
          <StackPanel Orientation="Horizontal" Background="Transparent">
            <Border x:Name="Box" Width="18" Height="18" CornerRadius="5" Background="{StaticResource Surface2}" BorderBrush="{StaticResource Stroke}" BorderThickness="1">
              <TextBlock x:Name="Tick" FontFamily="{StaticResource Icons}" Text="&#xE73E;" FontSize="11" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
            </Border>
            <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="Box" Property="Background" Value="{StaticResource Accent}"/>
              <Setter TargetName="Box" Property="BorderBrush" Value="Transparent"/>
              <Setter TargetName="Tick" Property="Visibility" Value="Visible"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="SlimThumb" TargetType="Thumb">
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Thumb"><Border CornerRadius="4" Background="#3A404C"/></ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="ScrollBar">
    <Setter Property="Width" Value="8"/>
    <Setter Property="MinWidth" Value="8"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Track x:Name="PART_Track" IsDirectionReversed="True">
            <Track.Thumb><Thumb Style="{StaticResource SlimThumb}" Margin="0,2"/></Track.Thumb>
          </Track>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="Orientation" Value="Horizontal">
        <Setter Property="Width" Value="Auto"/>
        <Setter Property="MinWidth" Value="0"/>
        <Setter Property="Height" Value="8"/>
        <Setter Property="MinHeight" Value="8"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="ScrollBar">
              <Track x:Name="PART_Track" IsDirectionReversed="False">
                <Track.Thumb><Thumb Style="{StaticResource SlimThumb}" Margin="2,0"/></Track.Thumb>
              </Track>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Trigger>
    </Style.Triggers>
  </Style>

  <Style TargetType="DataGrid">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Foreground" Value="{StaticResource Text}"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="RowBackground" Value="Transparent"/>
    <Setter Property="AlternatingRowBackground" Value="#13161C"/>
    <Setter Property="GridLinesVisibility" Value="None"/>
    <Setter Property="HeadersVisibility" Value="Column"/>
    <Setter Property="SelectionMode" Value="Single"/>
    <Setter Property="SelectionUnit" Value="FullRow"/>
    <Setter Property="CanUserAddRows" Value="False"/>
    <Setter Property="CanUserDeleteRows" Value="False"/>
    <Setter Property="CanUserResizeRows" Value="False"/>
    <Setter Property="IsReadOnly" Value="True"/>
    <Setter Property="RowHeight" Value="34"/>
    <Setter Property="FontSize" Value="13"/>
  </Style>
  <Style TargetType="DataGridColumnHeader">
    <Setter Property="Foreground" Value="{StaticResource Dim}"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="DataGridColumnHeader">
          <Border Background="Transparent" BorderBrush="{StaticResource Stroke}" BorderThickness="0,0,0,1" Padding="12,10">
            <StackPanel Orientation="Horizontal">
              <ContentPresenter VerticalAlignment="Center"/>
              <TextBlock x:Name="Arrow" FontFamily="{StaticResource Icons}" FontSize="9" Margin="6,1,0,0" VerticalAlignment="Center" Visibility="Collapsed"/>
            </StackPanel>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="SortDirection" Value="Ascending">
              <Setter TargetName="Arrow" Property="Text" Value="&#xE70E;"/>
              <Setter TargetName="Arrow" Property="Visibility" Value="Visible"/>
            </Trigger>
            <Trigger Property="SortDirection" Value="Descending">
              <Setter TargetName="Arrow" Property="Text" Value="&#xE70D;"/>
              <Setter TargetName="Arrow" Property="Visibility" Value="Visible"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="DataGridRow">
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#1C2029"/></Trigger>
      <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="#262B36"/></Trigger>
    </Style.Triggers>
  </Style>
  <!-- dica com o texto inteiro quando a coluna corta (aparece depois de 2 segundos) -->
  <Style TargetType="ToolTip">
    <Setter Property="Foreground" Value="{StaticResource Text}"/>
    <Setter Property="FontSize" Value="12.5"/>
    <Setter Property="MaxWidth" Value="520"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ToolTip">
          <Border Background="#20242E" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="8" Padding="11,8">
            <Border.Effect><DropShadowEffect BlurRadius="14" ShadowDepth="0" Opacity="0.5"/></Border.Effect>
            <ContentPresenter TextBlock.Foreground="{StaticResource Text}"/>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style TargetType="DataGridCell">
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="ToolTip" Value="{Binding RelativeSource={RelativeSource Self}, Path=Content.Text}"/>
    <Setter Property="ToolTipService.InitialShowDelay" Value="2000"/>
    <Setter Property="ToolTipService.ShowDuration" Value="30000"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="DataGridCell">
          <Border Background="Transparent" Padding="12,0"><ContentPresenter VerticalAlignment="Center"/></Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
</ResourceDictionary>
'@

$MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="HollowDrivers" Width="1120" Height="760" MinWidth="980" MinHeight="640" WindowStartupLocation="CenterScreen"
        Background="{StaticResource Bg}" Foreground="{StaticResource Text}" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13"
        UseLayoutRounding="True">
  <Grid>
    <!-- ======================= INÍCIO ======================= -->
    <Grid x:Name="HomeView">
      <Grid.Background>
        <RadialGradientBrush Center="0.5,0.3" GradientOrigin="0.5,0.3" RadiusX="0.6" RadiusY="0.65">
          <GradientStop Color="__BGR__" Offset="0"/>
          <GradientStop Color="#0F1115" Offset="1"/>
        </RadialGradientBrush>
      </Grid.Background>
      <DockPanel>
        <Border x:Name="HomeRail" DockPanel.Dock="Left" Width="200" Background="#12151B" BorderBrush="{StaticResource Stroke}" BorderThickness="0,0,1,0">
          <StackPanel x:Name="HomeRailBox" Margin="14,22,14,14">
            <Button x:Name="BtnRailHome" Style="{StaticResource NavBtn}" Tag="&#xE700;" Content="Recolher menu" Margin="0,0,0,6" HorizontalAlignment="Left"/>
            <Button x:Name="BtnHomeScan" Style="{StaticResource NavBtn}" Tag="&#xE721;" Content="Analisar"/>
            <Button x:Name="BtnHomeConfig" Style="{StaticResource NavBtn}" Tag="&#xE713;" Content="Configurações"/>
            <Button x:Name="BtnAdvanced" Style="{StaticResource NavBtn}" Tag="&#xE8A9;" Content="Config. avançada"/>
          </StackPanel>
        </Border>
        <Grid DockPanel.Dock="Bottom" Margin="28,0,28,16">
          <TextBlock x:Name="FooterText" Foreground="{StaticResource Dim}" FontSize="12" VerticalAlignment="Center"/>
        </Grid>
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,30,0,20" Width="720">
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
              <TextBlock FontFamily="{StaticResource Icons}" Text="&#xEA18;" FontSize="26" Foreground="__ICON__" VerticalAlignment="Center" Margin="0,3,10,0"/>
              <TextBlock Text="HollowDrivers" FontSize="30" FontWeight="SemiBold" FontFamily="{StaticResource Display}"/>
            </StackPanel>
            <TextBlock Text="Verifica seus drivers e avisa quando algo der errado." Foreground="{StaticResource Dim}" FontSize="14" HorizontalAlignment="Center" Margin="0,6,0,0"/>

            <Button x:Name="BigBtn" Width="220" Height="220" Margin="0,40,0,36" Cursor="Hand" HorizontalAlignment="Center" Focusable="False">
              <Button.Template>
                <ControlTemplate TargetType="Button">
                  <Grid x:Name="Root" RenderTransformOrigin="0.5,0.5">
                    <Grid.RenderTransform><ScaleTransform x:Name="Sc" ScaleX="1" ScaleY="1"/></Grid.RenderTransform>
                    <Ellipse Fill="__HALO__" Margin="-18"/>
                    <Ellipse Fill="{StaticResource Accent}">
                      <Ellipse.Effect><DropShadowEffect Color="__GLOW__" BlurRadius="70" ShadowDepth="0" Opacity="0.55"/></Ellipse.Effect>
                    </Ellipse>
                    <Ellipse Margin="12" Stroke="#40FFFFFF" StrokeThickness="1.5"/>
                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Grid>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                      <Trigger.EnterActions>
                        <BeginStoryboard>
                          <Storyboard>
                            <DoubleAnimation Storyboard.TargetName="Sc" Storyboard.TargetProperty="ScaleX" To="1.05" Duration="0:0:0.18"/>
                            <DoubleAnimation Storyboard.TargetName="Sc" Storyboard.TargetProperty="ScaleY" To="1.05" Duration="0:0:0.18"/>
                          </Storyboard>
                        </BeginStoryboard>
                      </Trigger.EnterActions>
                      <Trigger.ExitActions>
                        <BeginStoryboard>
                          <Storyboard>
                            <DoubleAnimation Storyboard.TargetName="Sc" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.18"/>
                            <DoubleAnimation Storyboard.TargetName="Sc" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.18"/>
                          </Storyboard>
                        </BeginStoryboard>
                      </Trigger.ExitActions>
                    </Trigger>
                    <Trigger Property="IsPressed" Value="True"><Setter TargetName="Root" Property="Opacity" Value="0.85"/></Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </Button.Template>
              <Grid Width="220" Height="220">
                <Ellipse x:Name="Spinner" Margin="5" Stroke="White" StrokeThickness="4" StrokeDashArray="30 200" StrokeDashCap="Round" Opacity="0" RenderTransformOrigin="0.5,0.5">
                  <Ellipse.RenderTransform><RotateTransform x:Name="SpinRot"/></Ellipse.RenderTransform>
                </Ellipse>
                <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
                  <TextBlock x:Name="BigIcon" FontFamily="{StaticResource Icons}" Text="&#xE721;" FontSize="36" Foreground="White" HorizontalAlignment="Center"/>
                  <TextBlock x:Name="BigLabel" Text="ANALISAR" FontSize="24" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" Margin="0,8,0,0" FontFamily="{StaticResource Display}"/>
                </StackPanel>
              </Grid>
            </Button>

            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
              <Border x:Name="VerdictBadge" Width="38" Height="38" CornerRadius="19" Background="#1F232C" Margin="0,0,12,0">
                <TextBlock x:Name="VerdictIcon" FontFamily="{StaticResource Icons}" Text="&#xE946;" FontSize="17" Foreground="{StaticResource Dim}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <TextBlock x:Name="VerdictText" Text="Pronto para verificar" FontSize="24" FontWeight="SemiBold" VerticalAlignment="Center" FontFamily="{StaticResource Display}"/>
            </StackPanel>
            <TextBlock x:Name="VerdictSub" Text="Clique no botão para analisar seu PC" Foreground="{StaticResource Dim}" HorizontalAlignment="Center" Margin="0,8,0,0" FontSize="13"/>
            <StackPanel x:Name="Findings" Margin="0,26,0,0"/>
          </StackPanel>
        </ScrollViewer>
      </DockPanel>
    </Grid>

    <!-- ======================= AVANÇADO ======================= -->
    <Grid x:Name="AdvView" Visibility="Collapsed">
      <Grid.ColumnDefinitions>
        <ColumnDefinition x:Name="AdvCol" Width="228"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- ===== barra lateral ===== -->
      <Border Background="#12151B" BorderBrush="{StaticResource Stroke}" BorderThickness="0,0,1,0">
        <DockPanel x:Name="AdvRailBox" Margin="14,18,14,14">
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="10,0,0,24">
            <TextBlock FontFamily="{StaticResource Icons}" Text="&#xEA18;" FontSize="17" Foreground="__ICON__" VerticalAlignment="Center" Margin="0,2,9,0"/>
            <TextBlock x:Name="AdvLogoText" Text="HollowDrivers" FontSize="16" FontWeight="SemiBold" FontFamily="{StaticResource Display}" VerticalAlignment="Center"/>
          </StackPanel>
          <Button x:Name="BtnRailAdv" DockPanel.Dock="Top" Style="{StaticResource NavBtn}" Tag="&#xE700;" Content="Recolher menu" Margin="0,0,0,6" HorizontalAlignment="Left"/>
          <Button x:Name="BtnBack" DockPanel.Dock="Bottom" Style="{StaticResource NavBtn}" Tag="&#xE72B;" Content="Voltar ao início"/>
          <StackPanel>
            <ToggleButton x:Name="NavDrivers" Style="{StaticResource Nav}" Tag="&#xE896;" Content="Drivers" IsChecked="True"/>
            <ToggleButton x:Name="NavVideo" Style="{StaticResource Nav}" Tag="&#xE7F4;" Content="Meus drivers"/>
            <ToggleButton x:Name="NavSystem" Style="{StaticResource Nav}" Tag="&#xE946;" Content="Sistema"/>
            <ToggleButton x:Name="NavGuard" Style="{StaticResource Nav}" Tag="&#xEA18;" Content="Proteção"/>
            <ToggleButton x:Name="NavWin" Style="{StaticResource Nav}" Tag="&#xE895;" Content="Windows Update"/>

          </StackPanel>
        </DockPanel>
      </Border>

      <!-- ===== seção: Drivers ===== -->
      <Grid x:Name="PanDrivers" Grid.Column="1" Margin="26,20,26,14">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel>
          <TextBlock Text="Drivers" Style="{StaticResource SectionTitle}"/>
          <TextBlock Text="Tudo que está instalado no seu PC, com o estado de cada driver." Style="{StaticResource SectionSub}"/>
          <WrapPanel Margin="0,16,0,0">
            <WrapPanel.Resources><Style TargetType="Button" BasedOn="{StaticResource Pill}"/></WrapPanel.Resources>
            <Button x:Name="BtnScan" Style="{StaticResource PillAccent}" Content="Escanear"/>
            <Button x:Name="BtnUpd" Content="Atualizar drivers"/>
            <Button x:Name="BtnAll" Content="Exportar para pendrive"/>
            <Button x:Name="BtnWu" Content="Windows Update"/>
          </WrapPanel>
        </StackPanel>

        <StackPanel Grid.Row="1" Margin="0,10,0,10">
          <StackPanel Orientation="Horizontal">
            <ToggleButton x:Name="ChipAll" Style="{StaticResource Chip}" Tag="all" Content="Todos" IsChecked="True"/>
            <ToggleButton x:Name="ChipBad" Style="{StaticResource Chip}" Tag="bad" Content="Com problema"/>
            <ToggleButton x:Name="ChipOld" Style="{StaticResource Chip}" Tag="old" Content="Antigos"/>
            <ToggleButton x:Name="ChipVideo" Style="{StaticResource Chip}" Tag="Vídeo" Content="Vídeo"/>
            <ToggleButton x:Name="ChipNet" Style="{StaticResource Chip}" Tag="Rede" Content="Rede"/>
            <ToggleButton x:Name="ChipAudio" Style="{StaticResource Chip}" Tag="Áudio" Content="Áudio"/>
            <Border Width="250" Margin="10,0,0,0" Background="{StaticResource Surface2}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="14" Padding="13,4">
              <DockPanel>
                <TextBlock DockPanel.Dock="Left" FontFamily="{StaticResource Icons}" Text="&#xE721;" Foreground="{StaticResource Dim}" VerticalAlignment="Center" Margin="0,0,9,0" FontSize="12"/>
                <TextBox x:Name="SearchBox"/>
              </DockPanel>
            </Border>
          </StackPanel>
          <CheckBox x:Name="ChkMs" Content="Mostrar drivers genéricos da Microsoft" Margin="2,12,0,0"/>
        </StackPanel>

      <Border Grid.Row="2" Background="{StaticResource Surface}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="14" Padding="4">
       <Grid>
        <TextBlock x:Name="EmptyText" Visibility="Collapsed" HorizontalAlignment="Center" VerticalAlignment="Center" TextAlignment="Center" Foreground="{StaticResource Dim}" FontSize="13.5"/>
        <DataGrid x:Name="DriverGrid" AutoGenerateColumns="False">
          <DataGrid.Columns>
            <DataGridTemplateColumn Header="Status" SortMemberPath="Ordem" Width="175">
              <DataGridTemplateColumn.CellTemplate>
                <DataTemplate>
                  <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <Ellipse Width="8" Height="8" Fill="{Binding Cor}" Margin="0,0,9,0"/>
                    <TextBlock Text="{Binding Status}" Foreground="{Binding Cor}" FontWeight="SemiBold"/>
                  </StackPanel>
                </DataTemplate>
              </DataGridTemplateColumn.CellTemplate>
            </DataGridTemplateColumn>
            <DataGridTextColumn Header="Categoria" Binding="{Binding Categoria}" Width="130"/>
            <DataGridTextColumn Header="Dispositivo" Binding="{Binding Dispositivo}" Width="*"/>
            <DataGridTextColumn Header="Fabricante" Binding="{Binding Fabricante}" Width="170"/>
            <DataGridTextColumn Header="Versão" Binding="{Binding Versao}" Width="130"/>
            <DataGridTextColumn Header="Data" Binding="{Binding Data, StringFormat=dd/MM/yyyy}" Width="95"/>
            <DataGridTextColumn Header="Idade" Binding="{Binding Idade}" Width="65"/>
            <DataGridTextColumn Header="INF" Binding="{Binding INF}" Width="95"/>
          </DataGrid.Columns>
        </DataGrid>
       </Grid>
      </Border>

      <TextBlock Grid.Row="3" x:Name="StatusText" Foreground="{StaticResource Dim}" FontSize="12" Margin="4,10,0,0"/>
      </Grid>

      <!-- ===== seção: Meus drivers ===== -->
       <Grid x:Name="PanVideo" Grid.Column="1" Margin="26,20,26,14" Visibility="Collapsed">
         <Grid.RowDefinitions>
           <RowDefinition Height="Auto"/>
           <RowDefinition Height="Auto"/>
           <RowDefinition Height="*"/>
         </Grid.RowDefinitions>
         <StackPanel>
           <TextBlock Text="Meus drivers" Style="{StaticResource SectionTitle}"/>
           <TextBlock Text="Cada driver tem sua própria cópia. Veja o que já está protegido e faça backup dos que faltam." Style="{StaticResource SectionSub}"/>
         </StackPanel>
         <Border Grid.Row="1" Margin="0,18,0,0" Background="{StaticResource Surface2}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="14" Padding="20,16">
           <Grid>
             <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
             <StackPanel>
               <TextBlock Text="PROTEÇÃO DOS DRIVERS" Style="{StaticResource GroupLbl}"/>
               <TextBlock x:Name="KeyCoverage" Text="Verificando cópias..." FontSize="22" FontWeight="SemiBold" FontFamily="{StaticResource Display}" Margin="0,3,0,2"/>
               <TextBlock x:Name="KeyResumo" Foreground="{StaticResource Dim}" FontSize="12.5"/>
             </StackPanel>
             <Button Grid.Column="1" x:Name="BtnKeyAll" Style="{StaticResource PillAccent}" Content="Fazer backup dos que faltam" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="18,0,0,0" Padding="18,10"/>
           </Grid>
         </Border>
         <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" Margin="0,16,0,0">
           <StackPanel>
             <Grid>
               <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
               <Border Background="{StaticResource Surface}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="14" Padding="20,16">
                 <StackPanel>
                   <TextBlock x:Name="GpuText" TextWrapping="Wrap" LineHeight="22"/>
                   <WrapPanel Margin="0,12,0,0">
                     <WrapPanel.Resources><Style TargetType="Button" BasedOn="{StaticResource Pill}"/></WrapPanel.Resources>
                     <Button x:Name="BtnGood" Style="{StaticResource PillAccent}" Content="Fazer backup"/>
                     <Button x:Name="BtnRestore" Content="Restaurar"/>
                     <Button x:Name="BtnHist" Content="Histórico"/>
                     <Button x:Name="BtnEnable" Style="{StaticResource PillAccent}" Content="Reativar placa" Visibility="Collapsed"/>
                   </WrapPanel>
                 </StackPanel>
               </Border>
               <Border Grid.Column="1" Margin="16,0,0,0" Background="{StaticResource Surface}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="14" Padding="20,16">
                 <TextBlock x:Name="SysText" TextWrapping="Wrap" LineHeight="22"/>
               </Border>
             </Grid>
             <StackPanel Margin="0,24,0,0">
               <TextBlock Text="OUTROS DRIVERS" Style="{StaticResource GroupLbl}"/>
               <TextBlock Text="O estado e a cópia de cada driver aparecem separadamente." Foreground="{StaticResource Dim}" FontSize="12.5" Margin="0,1,0,12"/>
               <WrapPanel x:Name="KeyCards"/>
             </StackPanel>
             <Expander Header="Ver lista técnica completa" Foreground="{StaticResource Text}" FontWeight="SemiBold" Margin="0,8,0,20">
               <Border Margin="0,12,0,0" Background="{StaticResource Surface}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="14" Padding="4">
                 <DataGrid x:Name="KeyGrid" AutoGenerateColumns="False" Height="320">
                   <DataGrid.Columns>
                     <DataGridTemplateColumn Header="Situação" Width="190">
                       <DataGridTemplateColumn.CellTemplate>
                         <DataTemplate>
                           <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                             <Ellipse Width="8" Height="8" Fill="{Binding Cor}" Margin="0,0,9,0"/>
                             <TextBlock Text="{Binding Estado}" Foreground="{Binding Cor}" FontWeight="SemiBold"/>
                           </StackPanel>
                         </DataTemplate>
                       </DataGridTemplateColumn.CellTemplate>
                     </DataGridTemplateColumn>
                     <DataGridTextColumn Header="Categoria" Binding="{Binding Categoria}" Width="120"/>
                     <DataGridTextColumn Header="Dispositivo" Binding="{Binding Nome}" Width="*"/>
                     <DataGridTextColumn Header="Fabricante" Binding="{Binding Fabricante}" Width="160"/>
                     <DataGridTextColumn Header="Versão" Binding="{Binding Versao}" Width="130"/>
                     <DataGridTextColumn Header="Cópia salva" Binding="{Binding Backup}" Width="120"/>
                   </DataGrid.Columns>
                 </DataGrid>
               </Border>
             </Expander>
           </StackPanel>
         </ScrollViewer>
       </Grid>
       <!-- ===== seção: Sistema ===== -->
      <Grid x:Name="PanSystem" Grid.Column="1" Margin="26,20,26,14" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <StackPanel>
          <TextBlock Text="Sistema" Style="{StaticResource SectionTitle}"/>
          <TextBlock Text="Saúde do PC, ponto de restauração e os sites oficiais do seu hardware." Style="{StaticResource SectionSub}"/>
        </StackPanel>
        <Border Grid.Row="1" Margin="0,18,0,0" MaxWidth="720" HorizontalAlignment="Left" Background="{StaticResource Surface}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="14" Padding="22,18">
          <TextBlock x:Name="HealthText" TextWrapping="Wrap" LineHeight="23"/>
        </Border>
        <WrapPanel Grid.Row="2" Margin="0,16,0,0">
          <WrapPanel.Resources><Style TargetType="Button" BasedOn="{StaticResource Pill}"/></WrapPanel.Resources>
          <Button x:Name="BtnCrash" Style="{StaticResource PillAccent}" Content="Quedas do PC"/>
          <Button x:Name="BtnPoint" Content="Criar ponto de restauração"/>
          <Button x:Name="BtnSites" Content="Sites oficiais  ▾"/>
          <Button x:Name="BtnCsv" Content="Exportar CSV"/>

        </WrapPanel>
        <Popup x:Name="SitesPopup" PlacementTarget="{Binding ElementName=BtnSites}" Placement="Bottom" StaysOpen="False" AllowsTransparency="True" VerticalOffset="2">
          <Border Background="{StaticResource Surface2}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="12" Padding="6">
            <StackPanel x:Name="SitesList"/>
          </Border>
        </Popup>
      <Border Grid.Row="3" Margin="0,22,0,0" MaxWidth="720" HorizontalAlignment="Left" VerticalAlignment="Top"
                 Background="{StaticResource Surface}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="14" Padding="22,18">
           <StackPanel>
             <TextBlock Text="LIBERAR ESPAÇO" Style="{StaticResource GroupLbl}"/>
             <TextBlock x:Name="StorageText" FontSize="18" FontWeight="SemiBold" FontFamily="{StaticResource Display}" Margin="0,3,0,8"/>
             <TextBlock Text="Revise arquivos temporários, aplicativos sem uso e arquivos grandes. Você escolhe o que apagar nas configurações do Windows."
                        TextWrapping="Wrap" Foreground="{StaticResource Dim}" FontSize="12.5"/>
             <WrapPanel Margin="0,14,0,0">
               <WrapPanel.Resources><Style TargetType="Button" BasedOn="{StaticResource Pill}"/></WrapPanel.Resources>
               <Button x:Name="BtnCleanup" Style="{StaticResource PillAccent}" Content="Ver recomendações de limpeza"/>
               <Button x:Name="BtnStorageSense" Content="Configurar limpeza automática"/>
             </WrapPanel>
           </StackPanel>
         </Border>
       </Grid>

      <!-- ===== seção: Windows Update ===== -->
      <Grid x:Name="PanWin" Grid.Column="1" Margin="26,20,26,14" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <StackPanel>
          <TextBlock Text="Windows Update" Style="{StaticResource SectionTitle}"/>
          <TextBlock Text="Controle o que o Windows instala sozinho e guarde um ponto para voltar se algo quebrar." Style="{StaticResource SectionSub}"/>
        </StackPanel>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="0,18,0,0">
          <StackPanel MaxWidth="760" HorizontalAlignment="Left">
        <Border MaxWidth="760" Background="{StaticResource Surface}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="14" Padding="22,18">
          <StackPanel>
            <TextBlock Text="ATUALIZAÇÕES DO WINDOWS" Style="{StaticResource GroupLbl}"/>
            <TextBlock x:Name="WuText" TextWrapping="Wrap" LineHeight="22"/>
            <WrapPanel Margin="0,14,0,0">
              <WrapPanel.Resources><Style TargetType="Button" BasedOn="{StaticResource Pill}"/></WrapPanel.Resources>
              <Button x:Name="BtnWuHold" Style="{StaticResource PillAccent}" Content="Segurar atualizações"/>
              <Button x:Name="BtnWuKeep" Content="Manter segurado"/>
              <Button x:Name="BtnWuDrv" Content="Bloquear troca de drivers"/>
            </WrapPanel>
          </StackPanel>
        </Border>
        <Border Margin="0,16,0,0" MaxWidth="760" Background="{StaticResource Surface}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="14" Padding="22,18">
          <StackPanel>
            <TextBlock Text="BACKUP DO WINDOWS (PONTO DE RESTAURAÇÃO)" Style="{StaticResource GroupLbl}"/>
            <TextBlock x:Name="SrText" TextWrapping="Wrap" LineHeight="22"/>
            <WrapPanel Margin="0,14,0,0">
              <WrapPanel.Resources><Style TargetType="Button" BasedOn="{StaticResource Pill}"/></WrapPanel.Resources>
              <Button x:Name="BtnSrPoint" Style="{StaticResource PillAccent}" Content="Salvar backup do Windows"/>
              <Button x:Name="BtnSrOpen" Content="Restaurar o Windows"/>
            </WrapPanel>
          </StackPanel>
        </Border>
          </StackPanel>
        </ScrollViewer>
      </Grid>

      <!-- ===== seção: Proteção ===== -->
      <Grid x:Name="PanGuard" Grid.Column="1" Margin="26,20,26,14" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <StackPanel>
          <TextBlock Text="Proteção" Style="{StaticResource SectionTitle}"/>
          <TextBlock Text="O HollowDrivers vigiando seu PC em segundo plano." Style="{StaticResource SectionSub}"/>
        </StackPanel>
        <Border Grid.Row="1" Margin="0,18,0,0" MaxWidth="720" HorizontalAlignment="Left" Background="{StaticResource Surface}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="14" Padding="22,18">
          <TextBlock x:Name="GuardText" TextWrapping="Wrap" LineHeight="23"/>
        </Border>
        <WrapPanel Grid.Row="2" Margin="0,16,0,0">
          <WrapPanel.Resources><Style TargetType="Button" BasedOn="{StaticResource Pill}"/></WrapPanel.Resources>
          <Button x:Name="BtnWatch" Style="{StaticResource PillAccent}" Content="Vigia automático"/>
          <Button x:Name="BtnRescue" Content="Socorro automático"/>
          <Button x:Name="BtnDb" Style="{StaticResource PillBad}" Content="Remover Driver Booster" Visibility="Collapsed"/>
        </WrapPanel>
      </Grid>
    </Grid>

    <!-- ======================= CONFIGURAÇÕES (abre e fecha por cima) ======================= -->
    <Grid x:Name="ConfigView" Background="{StaticResource Bg}" Visibility="Collapsed">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <Grid Margin="30,22,30,0">
        <StackPanel>
          <TextBlock Text="Configurações" Style="{StaticResource SectionTitle}"/>
          <TextBlock Text="Aparência do app e atualizações do próprio HollowDrivers." Style="{StaticResource SectionSub}"/>
        </StackPanel>
        <Button x:Name="BtnConfigClose" Style="{StaticResource NavBtn}" Tag="&#xE711;" Content="Fechar" HorizontalAlignment="Right" VerticalAlignment="Top"/>
      </Grid>
      <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="30,18,30,22">
        <StackPanel MaxWidth="760" HorizontalAlignment="Left">
        <Border Margin="0,18,0,0" MaxWidth="760" Background="{StaticResource Surface}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="14" Padding="22,18">
          <StackPanel>
            <TextBlock Text="TEMA DE CORES" Style="{StaticResource GroupLbl}"/>
            <TextBlock Text="A cor de destaque do app. Ao trocar, o HollowDrivers reabre em um segundo." Foreground="{StaticResource Dim}" FontSize="12.5" Margin="0,0,0,14"/>
            <WrapPanel x:Name="ConfigThemes"/>
          </StackPanel>
        </Border>
        <Border Margin="0,16,0,0" MaxWidth="760" Background="{StaticResource Surface}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="14" Padding="22,18">
          <StackPanel>
            <TextBlock Text="ATUALIZAÇÕES DO HollowDrivers" Style="{StaticResource GroupLbl}"/>
            <TextBlock x:Name="ConfigUpd" TextWrapping="Wrap" LineHeight="22"/>
            <WrapPanel Margin="0,14,0,0">
              <WrapPanel.Resources><Style TargetType="Button" BasedOn="{StaticResource Pill}"/></WrapPanel.Resources>
              <Button x:Name="BtnAppCheck" Content="Procurar atualização"/>
              <Button x:Name="BtnAppInstall" Style="{StaticResource PillAccent}" Content="Instalar atualização" Visibility="Collapsed"/>
            </WrapPanel>
          </StackPanel>
        </Border>
        </StackPanel>
      </ScrollViewer>
    </Grid>
  </Grid>
</Window>
'@

$DialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" SizeToContent="Height" Width="500"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False" ResizeMode="NoResize"
        FontFamily="Segoe UI Variable Text, Segoe UI" Foreground="{StaticResource Text}">
  <Border Background="{StaticResource Surface}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="16" Padding="24,22" Margin="20">
    <Border.Effect><DropShadowEffect BlurRadius="30" ShadowDepth="0" Opacity="0.6"/></Border.Effect>
    <StackPanel>
      <StackPanel Orientation="Horizontal">
        <Border x:Name="Badge" Width="36" Height="36" CornerRadius="18">
          <TextBlock x:Name="Ico" FontFamily="{StaticResource Icons}" FontSize="16" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <TextBlock x:Name="Head" FontSize="17" FontWeight="SemiBold" VerticalAlignment="Center" Margin="12,0,0,0" FontFamily="{StaticResource Display}"/>
      </StackPanel>
      <TextBlock x:Name="Body" TextWrapping="Wrap" Margin="0,14,0,22" Foreground="#C9CED6" LineHeight="21" FontSize="13.5"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="No" Style="{StaticResource Pill}" Content="Cancelar" Visibility="Collapsed" IsCancel="True"/>
        <Button x:Name="Yes" Style="{StaticResource PillAccent}" Content="OK" Margin="0" IsDefault="True"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@

$TableXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="940" Height="500" WindowStartupLocation="CenterOwner" ShowInTaskbar="False"
        Background="{StaticResource Bg}" Foreground="{StaticResource Text}" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13">
  <Grid Margin="22,18,22,18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock x:Name="Head" FontSize="19" FontWeight="SemiBold" FontFamily="{StaticResource Display}"/>
    <Border Grid.Row="1" Margin="0,14,0,14" Background="{StaticResource Surface}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="14" Padding="4">
      <DataGrid x:Name="G" AutoGenerateColumns="True">
        <DataGrid.RowStyle>
          <Style TargetType="DataGridRow" BasedOn="{StaticResource {x:Type DataGridRow}}">
            <Style.Triggers>
              <DataTrigger Binding="{Binding Destaque}" Value="True"><Setter Property="Foreground" Value="#F87171"/></DataTrigger>
            </Style.Triggers>
          </Style>
        </DataGrid.RowStyle>
      </DataGrid>
    </Border>
    <DockPanel Grid.Row="2">
      <Button x:Name="Close" DockPanel.Dock="Right" Style="{StaticResource PillAccent}" Content="Fechar" Margin="12,0,0,0" IsCancel="True"/>
      <TextBlock x:Name="Note" TextWrapping="Wrap" Foreground="{StaticResource Dim}" VerticalAlignment="Center"/>
    </DockPanel>
  </Grid>
</Window>
'@

$app = [Windows.Application]::Current
if (-not $app) { $app = New-Object Windows.Application }
$app.ShutdownMode = 'OnMainWindowClose'
$app.Resources = [Windows.Markup.XamlReader]::Parse((Use-Theme $ResXaml))

$BrushConv = New-Object Windows.Media.BrushConverter
function Get-Brush([string]$hex) { $BrushConv.ConvertFromString($hex) }

function Set-DarkTitle($w) {
    $h = (New-Object Windows.Interop.WindowInteropHelper($w)).Handle
    $v = 1; [void][DG.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$v, 4)
    $c = 0x0015110F; [void][DG.Dwm]::DwmSetWindowAttribute($h, 35, [ref]$c, 4)
}

$Hex.ask = $Theme.Icon
$script:Win = [Windows.Markup.XamlReader]::Parse((Use-Theme $MainXaml))
$Win = $script:Win
foreach ($n in 'HomeView', 'AdvView', 'BtnAdvanced', 'BtnHomeScan', 'BtnHomeConfig', 'FooterText', 'BigBtn', 'Spinner', 'SpinRot', 'BigIcon', 'BigLabel', 'VerdictBadge',
    'VerdictIcon', 'VerdictText', 'VerdictSub', 'Findings', 'BtnBack', 'GpuText', 'HealthText', 'BtnScan', 'BtnUpd', 'BtnGood',
    'BtnRestore', 'BtnPoint', 'BtnAll', 'BtnHist', 'BtnEnable', 'BtnCrash', 'BtnWu', 'BtnSites', 'BtnCsv', 'BtnWatch', 'BtnDb', 'SitesPopup',
    'SitesList', 'SearchBox', 'ChkMs', 'DriverGrid', 'StatusText', 'EmptyText', 'GuardText',
    'NavDrivers', 'NavVideo', 'NavSystem', 'NavGuard', 'NavWin', 'PanWin', 'ConfigView', 'BtnConfigClose', 'WuText', 'SrText', 'BtnWuHold', 'BtnWuKeep', 'BtnWuDrv', 'BtnSrPoint', 'BtnSrOpen', 'StorageText', 'BtnCleanup', 'BtnStorageSense', 'AdvCol', 'AdvLogoText', 'HomeRail', 'HomeRailBox', 'AdvRailBox', 'BtnRailHome', 'BtnRailAdv', 'ConfigThemes', 'ConfigUpd', 'BtnAppCheck', 'BtnAppInstall', 'SysText',
    'KeyCards', 'KeyCoverage', 'KeyResumo', 'BtnKeyAll', 'KeyGrid', 'BtnRescue', 'PanDrivers', 'PanVideo', 'PanSystem', 'PanGuard',
    'ChipAll', 'ChipBad', 'ChipOld', 'ChipVideo', 'ChipNet', 'ChipAudio') {
    Set-Variable -Name $n -Value $Win.FindName($n) -Scope Script
}
$Win.add_SourceInitialized({ Set-DarkTitle $Win })
if (Test-Path $IconFile) { try { $Win.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$IconFile) } catch { } }
$FooterText.Text = "HollowDrivers $AppVersion  •  nada é instalado sem você confirmar  •  só avisos e sites oficiais"

# ---------------------------------------------------------------- diálogos

function Show-Dialog([string]$head, [string]$body, [string]$kind = 'info', [switch]$YesNo, [string]$YesText = 'OK', [string]$NoText = 'Cancelar') {
    $d = [Windows.Markup.XamlReader]::Parse($DialogXaml)
    $col = $Hex[$kind]
    $d.FindName('Head').Text = $head
    $d.FindName('Body').Text = $body
    $ico = $d.FindName('Ico'); $ico.Text = $Glyph[$kind]; $ico.Foreground = Get-Brush $col
    $d.FindName('Badge').Background = Get-Brush ('#26' + $col.Substring(1))
    $yes = $d.FindName('Yes'); $yes.Content = $YesText
    $yes.add_Click({ param($s, $e) [Windows.Window]::GetWindow($s).DialogResult = $true })
    if ($YesNo) {
        $no = $d.FindName('No'); $no.Content = $NoText; $no.Visibility = 'Visible'
        $no.add_Click({ param($s, $e) [Windows.Window]::GetWindow($s).DialogResult = $false })
    } else { $yes.IsCancel = $true }
    $d.add_MouseLeftButtonDown({ param($s, $e) try { $s.DragMove() } catch { } })
    if ($script:Win.IsLoaded) { $d.Owner = $script:Win } else { $d.WindowStartupLocation = 'CenterScreen' }
    [bool]$d.ShowDialog()
}

function Show-TableWindow([string]$title, $rows, [string]$note) {
    $rows = @($rows)
    $w = [Windows.Markup.XamlReader]::Parse($TableXaml)
    $w.Title = $title; $w.FindName('Head').Text = $title; $w.FindName('Note').Text = $note
    $t = New-Object Data.DataTable
    $names = @($rows[0].PSObject.Properties.Name)
    foreach ($n in $names) { if ($n -eq 'Destaque') { [void]$t.Columns.Add($n, [bool]) } else { [void]$t.Columns.Add($n) } }
    foreach ($r in $rows) {
        $row = $t.NewRow()
        foreach ($n in $names) { $row[$n] = $(if ($n -eq 'Destaque') { [bool]$r.$n } else { "$($r.$n)" }) }
        $t.Rows.Add($row)
    }
    $g = $w.FindName('G')
    $g.add_AutoGeneratingColumn({ param($s, $e)
        if ($e.PropertyName -eq 'Destaque') { $e.Cancel = $true }
        elseif ($e.PropertyName -in 'Detalhe', 'Titulo', 'Tipo', 'Estado') { $e.Column.Width = New-Object Windows.Controls.DataGridLength(1, 'Star') }
    })
    $g.ItemsSource = $t.DefaultView
    $w.FindName('Close').add_Click({ param($s, $e) [Windows.Window]::GetWindow($s).Close() })
    $w.add_SourceInitialized({ param($s, $e) Set-DarkTitle $s })
    $w.Owner = $script:Win
    [void]$w.ShowDialog()
}

# ---------------------------------------------------------------- tarefas em segundo plano (a tela não trava)

$script:Tasks = New-Object Collections.ArrayList
$BgTimer = New-Object Windows.Threading.DispatcherTimer
$BgTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$script:Prog = [hashtable]::Synchronized(@{ Text = '' })
$script:ProgRun = $null
$BgTimer.add_Tick({
    if ($script:ProgRun -and $script:Prog.Text -and $script:ProgRun.Text -ne $script:Prog.Text) { $script:ProgRun.Text = $script:Prog.Text }
    foreach ($t in @($script:Tasks)) {
        if (-not $t.Handle.IsCompleted) { continue }
        $script:Tasks.Remove($t)
        $out = $null; $err = $null
        try { $out = $t.Ps.EndInvoke($t.Handle) }
        catch { $err = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message } }
        $t.Ps.Dispose(); $t.Rs.Dispose()
        & $t.Done $out $err
    }
    if (-not $script:Tasks.Count) { $BgTimer.Stop() }
})
function Start-Bg([string]$code, [scriptblock]$onDone) {
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $rs.SessionStateProxy.SetVariable('Prog', $script:Prog)
    $ps = [PowerShell]::Create(); $ps.Runspace = $rs; [void]$ps.AddScript($code)
    [void]$script:Tasks.Add(@{ Ps = $ps; Rs = $rs; Handle = $ps.BeginInvoke(); Done = $onDone })
    $BgTimer.Start()
}

# Roda um script como administrador (o Windows pede confirmação) e devolve o log.
# O script vai inteiro na linha de comando (-EncodedCommand): não existe arquivo .ps1 que um programa
# malicioso pudesse trocar entre o app pedir a permissão e você clicar "Sim" no UAC.
function Invoke-Elevated([string]$tpl, [hashtable]$map, [string]$name, [scriptblock]$onDone) {
    Remove-Item (Join-Path $DataDir "$name.ps1"), (Join-Path $DataDir "$name.log") -Force -ErrorAction SilentlyContinue   # sobras das versões antigas
    $log = Join-Path $DataDir ('{0}-{1}.log' -f $name, [guid]::NewGuid().ToString('N'))
    $code = (Expand-Tpl $ElevLib @{ '__LOG__' = $log }) + "`n" + (Expand-Tpl $tpl $map)
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    if ($enc.Length -gt 30000) { & $onDone '' 'comando grande demais para a linha de comando do Windows'; return }
    $script:ElevLog = $log; $script:ElevDone = $onDone
    Start-Bg ("Start-Process powershell.exe -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList '-NoProfile -ExecutionPolicy Bypass -EncodedCommand {0}'" -f $enc) {
        param($out, $err)
        $text = ''
        if (Test-Path $script:ElevLog) { $text = Get-Content $script:ElevLog -Raw; Remove-Item $script:ElevLog -Force -ErrorAction SilentlyContinue }
        & $script:ElevDone $text $err
    }
}

$LogicText = $Logic.ToString()
$ScanCode = @'
$gpu = Get-GpuInfo
[pscustomobject]@{ Rows = @(Get-DriverScan); Gpu = $gpu; History = @(if ($gpu) { Get-InstallHistory $gpu.VenDev }); Health = Get-Health; SysInfo = Get-SystemInfo; Keys = @(Get-KeyDrivers) }
'@
$WuCode = @'
$se = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
$r = $se.Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
foreach ($u in $r.Updates) {
    [pscustomobject]@{
        Titulo = $u.Title; Fabricante = $u.DriverManufacturer; Modelo = $u.DriverModel; Classe = $u.DriverClass
        Data = $(if ($u.DriverVerDate) { ([datetime]$u.DriverVerDate).ToString('dd/MM/yyyy') } else { '' })
    }
}
'@

# ---------------------------------------------------------------- estado + tabela

$script:Problems = 0; $script:Old = 0; $script:LastScan = $null; $script:History = @(); $script:NeedReboot = @()
$script:Keys = @(); $script:KeyChanges = @(); $script:KeySel = $null
$script:Gpu = $null; $script:Health = $null; $script:SysInfo = $null; $script:Scanning = $false
$script:BackupBusy = $false; $script:BackupVersion = $null; $script:AfterRestore = $null

$dt = New-Object Data.DataTable
foreach ($col in @(
        @('Ordem', [int]), @('Status', [string]), @('Cor', [string]), @('Categoria', [string]), @('Dispositivo', [string]),
        @('Fabricante', [string]), @('Versao', [string]), @('Data', [datetime]), @('Idade', [double]),
        @('INF', [string]), @('Microsoft', [bool]))) {
    [void]$dt.Columns.Add($col[0], $col[1])
}
$dt.DefaultView.Sort = 'Ordem ASC, Categoria ASC, Dispositivo ASC'

# lista completa da seção "Meus drivers" (os cartões ficam acima dela)
$kt = New-Object Data.DataTable
foreach ($col in @('Ordem', 'Estado', 'Cor', 'Categoria', 'Nome', 'Fabricante', 'Versao', 'Backup', 'Id')) { [void]$kt.Columns.Add($col) }
$kt.Columns['Ordem'].DataType = [int]
$kt.DefaultView.Sort = 'Ordem ASC, Categoria ASC, Nome ASC'

$DriverGrid.ItemsSource = $dt.DefaultView

function Add-Line($tb, [string]$text, [string]$hex = '#E8EAED', [double]$size = 13.5, [bool]$bold = $false) {
    if ($tb.Inlines.Count) { $tb.Inlines.Add((New-Object Windows.Documents.LineBreak)) }
    $r = New-Object Windows.Documents.Run($text)
    $r.Foreground = Get-Brush $hex; $r.FontSize = $size
    if ($bold) { $r.FontWeight = [Windows.FontWeights]::SemiBold }
    $tb.Inlines.Add($r)
}

function Set-Status([string]$extra) {
    $t = '{0} exibidos  •  {1} com problema  •  {2} (4+ anos)' -f $dt.DefaultView.Count, $script:Problems, (Get-Plural $script:Old 'antigo' 'antigos')
    if ($script:LastScan) { $t += '  •  escaneado às {0:HH:mm}' -f $script:LastScan }
    if ($extra) { $t += "  •  $extra" }
    $StatusText.Text = $t
}

$script:Chip = 'all'
$ChipNames = 'ChipAll', 'ChipBad', 'ChipOld', 'ChipVideo', 'ChipNet', 'ChipAudio'

function Set-Chip($btn) {
    foreach ($n in $ChipNames) {
        $c = Get-Variable $n -Scope Script -ValueOnly
        $c.IsChecked = ($c -eq $btn)
    }
    $script:Chip = "$($btn.Tag)"
    Update-Filter
}

# contagem em cada filtro rápido, respeitando a opção "mostrar drivers da Microsoft"
function Update-ChipCounts {
    $rows = @($dt.Rows | Where-Object { $ChkMs.IsChecked -or -not $_['Microsoft'] })
    $n = @{
        ChipAll = $rows.Count
        ChipBad = @($rows | Where-Object { $_['Ordem'] -eq 0 }).Count
        ChipOld = @($rows | Where-Object { $_['Ordem'] -eq 1 }).Count
        ChipVideo = @($rows | Where-Object { $_['Categoria'] -eq 'Vídeo' }).Count
        ChipNet = @($rows | Where-Object { $_['Categoria'] -eq 'Rede' }).Count
        ChipAudio = @($rows | Where-Object { $_['Categoria'] -eq 'Áudio' }).Count
    }
    $lbl = @{ ChipAll = 'Todos'; ChipBad = 'Com problema'; ChipOld = 'Antigos'; ChipVideo = 'Vídeo'; ChipNet = 'Rede'; ChipAudio = 'Áudio' }
    foreach ($k in $ChipNames) {
        $c = Get-Variable $k -Scope Script -ValueOnly
        $c.Content = '{0}  {1}' -f $lbl[$k], $n[$k]
        $c.Opacity = $(if ($n[$k] -eq 0 -and -not $c.IsChecked) { 0.45 } else { 1 })
    }
}

function Update-Filter {
    $parts = @()
    if (-not $ChkMs.IsChecked) { $parts += 'Microsoft = false' }
    switch ($script:Chip) {
        'bad' { $parts += 'Ordem = 0' }
        'old' { $parts += 'Ordem = 1' }
        'all' { }
        default { $parts += "Categoria = '$($script:Chip)'" }
    }
    $q = ($SearchBox.Text -replace "[\[\]\*%']", '').Trim()
    if ($q) { $parts += "(Dispositivo LIKE '*$q*' OR Fabricante LIKE '*$q*' OR Categoria LIKE '*$q*')" }
    $dt.DefaultView.RowFilter = ($parts -join ' AND ')
    Update-ChipCounts
    if ($dt.DefaultView.Count -eq 0) {
        $EmptyText.Text = $(if ($q) { "Nenhum driver com `"$q`".`nTente outro nome ou limpe a busca." }
            elseif ($script:Chip -eq 'bad') { "Nenhum driver com problema.`nEstá tudo funcionando." }
            elseif ($script:Chip -eq 'old') { "Nenhum driver antigo (4+ anos)." }
            elseif ($script:LastScan) { "Nenhum driver nesta categoria.`nMarque `"mostrar drivers da Microsoft`" para ver os genéricos." }
            else { 'Clique em Escanear para listar os drivers.' })
        $EmptyText.Visibility = 'Visible'
    } else { $EmptyText.Visibility = 'Collapsed' }
    Set-Status
}

function Update-WatchButton {
    if (Test-WatchEnabled) { $BtnWatch.Content = 'Vigia automático: ligado'; $BtnWatch.Foreground = Get-Brush $Hex.ok }
    else { $BtnWatch.Content = 'Vigia automático: desligado'; $BtnWatch.Foreground = Get-Brush $Hex.info }
}

# ---------------------------------------------------------------- fabricante: links e instruções certas para este PC

function Get-OfficialLinks {
    $links = [ordered]@{}
    $v = if ($script:Gpu) { $script:Gpu.Vendor } else { '' }
    $si = $script:SysInfo
    $amd = 'https://www.amd.com/en/support/download/drivers.html'
    $intel = 'https://www.intel.com.br/content/www/br/pt/support/detect.html'
    switch ($v) {
        'AMD' {
            $label = if ($si -and $si.CpuVendor -eq 'AMD') { 'AMD — vídeo e chipset (baixe o Full Install)' } else { 'AMD — driver de vídeo (baixe o Full Install)' }
            $links[$label] = $amd
        }
        'NVIDIA' { $links['NVIDIA — driver de vídeo'] = 'https://www.nvidia.com/pt-br/drivers/' }
        'Intel' { $links['Intel — vídeo e chipset (assistente oficial)'] = $intel }
    }
    if ($si) {
        if ($si.CpuVendor -eq 'AMD' -and $v -ne 'AMD') { $links['AMD — chipset do processador'] = $amd }
        if ($si.CpuVendor -eq 'Intel' -and $v -ne 'Intel') { $links['Intel — chipset (assistente oficial)'] = $intel }
        # notebook: suporte do fabricante do notebook (modelo completo); desktop: fabricante da placa-mãe
        if ($si.IsLaptop) { $m = $si.Maker; $model = $si.Model; $what = 'drivers do notebook' }
        else { $m = $si.BoardMaker; $model = $si.BoardModel; $what = 'BIOS, rede e áudio' }
        if ($m -and $m -notmatch 'To Be Filled|Default string|System manufacturer') {
            $short = switch -regex ($m) {
                'ASUS' { 'ASUS'; break } 'Micro-Star|MSI' { 'MSI'; break } 'Gigabyte' { 'Gigabyte'; break } 'ASRock' { 'ASRock'; break }
                'Dell' { 'Dell'; break } 'Lenovo' { 'Lenovo'; break } 'HP|Hewlett' { 'HP'; break } 'Acer' { 'Acer'; break }
                'Samsung' { 'Samsung'; break } 'Positivo' { 'Positivo'; break } 'Avell' { 'Avell'; break } 'VAIO|Sony' { 'VAIO'; break }
                default { $m }
            }
            $url = switch ($short) {
                'ASUS' { 'https://www.asus.com/support/download-center/' } 'MSI' { 'https://www.msi.com/support/download' }
                'Gigabyte' { 'https://www.gigabyte.com/Support' } 'ASRock' { 'https://www.asrock.com/support/index.asp' }
                'Dell' { 'https://www.dell.com/support/home' } 'Lenovo' { 'https://pcsupport.lenovo.com' }
                'HP' { 'https://support.hp.com/drivers' } 'Acer' { 'https://www.acer.com/support' }
                default { 'https://www.google.com/search?q=' + [uri]::EscapeDataString("$m $model drivers suporte oficial") }
            }
            $links["$short $model — $what"] = $url
        }
    }
    $links['Windows Update'] = 'ms-settings:windowsupdate'
    $links['Gerenciador de Dispositivos'] = 'devmgmt.msc'
    $links
}

function Update-Sites {
    $SitesList.Children.Clear()
    $links = Get-OfficialLinks
    foreach ($k in $links.Keys) {
        $b = New-Object Windows.Controls.Button
        $b.Content = $k; $b.Tag = $links[$k]; $b.Style = $app.Resources['MenuBtn']
        $b.add_Click({ param($s, $e) $SitesPopup.IsOpen = $false; Start-Process $s.Tag })
        [void]$SitesList.Children.Add($b)
    }
}

function Get-FixSteps {
    switch ($script:Gpu.Vendor) {
        'AMD' { "1.  Baixe no site da AMD o instalador COMPLETO (Full Install) — não o de poucos MB.`n2.  Instale e reinicie o PC." }
        'NVIDIA' { "1.  Baixe o driver Game Ready do seu modelo no site da NVIDIA.`n2.  Instale e reinicie o PC." }
        'Intel' { "1.  Abra o assistente oficial de drivers da Intel.`n2.  Instale o driver de vídeo sugerido e reinicie o PC." }
        default { "1.  Baixe o driver de vídeo no site do fabricante da sua placa.`n2.  Instale e reinicie o PC." }
    }
}

# ---------------------------------------------------------------- cartões do modo avançado

function Update-Cards {
    $g = $script:Gpu; $b = Get-Baseline; $hl = $script:Health
    $bk = if ($b) { Get-Backup $b.Version } else { $null }
    $GpuText.Inlines.Clear()
    Add-Line $GpuText 'PLACA DE VÍDEO' $Hex.info 11 $true
    if (-not $g) {
        Add-Line $GpuText 'Nenhuma placa de vídeo PCI encontrada.' $Hex.bad 15 $true
    } else {
        Add-Line $GpuText $g.Name '#E8EAED' 19 $true
        Add-Line $GpuText ('Driver {0}   •   {1}' -f $g.Version, $g.Inf) '#C9CED6'
        if ($g.Code -eq 0) { Add-Line $GpuText '●  Funcionando — aceleração 3D ativa' $Hex.ok }
        else { Add-Line $GpuText ('●  {0} — jogos não vão abrir' -f (Get-ProblemText $g.Code)) $Hex.bad 13.5 $true }
        if ($g.Code -eq 22) { Add-Line $GpuText '●  Não é falta de driver: a placa está desligada no Windows. Use "Reativar placa".' $Hex.warn 12.5 }
        if (-not $b) { Add-Line $GpuText '●  Sem backup: faça uma cópia enquanto está funcionando' $Hex.warn }
        elseif ($b.Version -eq $g.Version) { Add-Line $GpuText ('●  Igual ao driver salvo em {0}' -f $b.Marcado) $Hex.ok }
        else { Add-Line $GpuText ('●  DRIVER TROCADO — o salvo era {0}' -f $b.Version) $Hex.bad 13.5 $true }
        if ($script:BackupBusy) { Add-Line $GpuText '●  Backup: copiando o driver...' $Hex.info }
        elseif ($bk) { Add-Line $GpuText ('●  Backup: {0}  ({1:N0} MB, {2})' -f $bk.Version, $bk.SizeMB, $bk.Date) $Hex.ok }
        elseif ($b) { Add-Line $GpuText '●  Backup: nenhum' $Hex.warn }
        if ($script:History.Count) {
            $h = $script:History[0]
            Add-Line $GpuText ('Última instalação: {0:dd/MM/yyyy HH:mm} — {1}' -f $h.Quando, $h.Origem) $(if ($h.Origem -like 'Driver Booster*') { $Hex.bad } else { $Hex.info }) 12.5
        }
    }
    $HealthText.Inlines.Clear()
    Add-Line $HealthText 'SAÚDE DO SISTEMA  •  30 DIAS' $Hex.info 11 $true
    if ($hl.Crashes) {
        Add-Line $HealthText (Get-Plural $hl.Crashes 'desligamento inesperado' 'desligamentos inesperados') $Hex.bad 19 $true
        Add-Line $HealthText ('Último em {0:dd/MM HH:mm}' -f $hl.LastCrash) '#C9CED6'
        if (-not $hl.Tdr) { Add-Line $HealthText 'Sem erro de driver → suspeite da fonte/energia' $Hex.info 12.5 }
    } else { Add-Line $HealthText 'Nenhuma queda' $Hex.ok 19 $true }
    Add-Line $HealthText ('Drivers com problema: {0}   •   {1}' -f $script:Problems, (Get-Plural $script:Old 'antigo' 'antigos')) $(if ($script:Problems) { $Hex.bad } else { '#C9CED6' })
    $ab = Get-AllBackupInfo
    if ($ab) { Add-Line $HealthText ('●  Backup dos drivers: {0} ({1} drivers)' -f $ab.Date, $ab.Count) $Hex.ok }
    else { Add-Line $HealthText '●  Backup dos drivers: nenhum' $Hex.warn }
    if ($hl.DriverBooster.Count) { Add-Line $HealthText '●  Driver Booster instalado' $Hex.bad 13.5 $true }
    else { Add-Line $HealthText '●  Driver Booster não instalado' $Hex.ok }
    $BtnDb.Visibility = $(if ($hl.DriverBooster.Count) { 'Visible' } else { 'Collapsed' })

    Update-KeyCards
    Update-SysCard

    $GuardText.Inlines.Clear()
    Add-Line $GuardText 'VIGIA AUTOMÁTICO' $Hex.info 11 $true
    if (Test-WatchEnabled) { Add-Line $GuardText 'Ligado' $Hex.ok 19 $true }
    else { Add-Line $GuardText 'Desligado' $Hex.warn 19 $true }
    Add-Line $GuardText 'Um escudo fica perto do relógio: verde quando está tudo certo, vermelho quando há alerta. O HollowDrivers confere ao ligar o PC e a cada hora.' '#C9CED6' 13
    Add-Line $GuardText '●  avisa se o driver de vídeo for trocado' $Hex.info 12.5
    Add-Line $GuardText '●  avisa se a placa de vídeo der erro' $Hex.info 12.5
    Add-Line $GuardText '●  avisa se o PC cair desde a última verificação' $Hex.info 12.5
    Add-Line $GuardText '●  avisa se o Driver Booster voltar' $Hex.info 12.5
    Add-Line $GuardText '●  procura versões novas de driver uma vez por dia' $Hex.info 12.5
    Add-Line $GuardText 'Não instala nada sozinho e não deixa o PC lento.' '#C9CED6' 12.5
    if (Test-RescueTask) { Add-Line $GuardText '●  Socorro automático: ligado (restaura o vídeo sozinho ao ligar o PC)' $Hex.ok 13 }
    else { Add-Line $GuardText '●  Socorro automático: desligado (a restauração pede sua confirmação)' $Hex.info 13 }
    $ult = Get-ChildItem $DataDir -Filter 'socorro-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($ult) {
        $txt = Get-Content $ult.FullName -Raw
        $res = if ($txt -match 'INSTALAR=0') { 'driver restaurado' } elseif ($txt -match 'ERRO=(.+)') { 'falhou: ' + $matches[1] } else { 'tentativa registrada' }
        Add-Line $GuardText ('Último socorro: {0:dd/MM/yyyy HH:mm} — {1}' -f $ult.LastWriteTime, $res) $Hex.warn 12.5
    }
    if ($hl.DriverBooster.Count) { Add-Line $GuardText ('⚠  Driver Booster instalado em {0}' -f $hl.DriverBooster[0].Path) $Hex.bad 13 $true }
    $BtnRestore.IsEnabled = [bool]$bk -and -not $script:BackupBusy
    $BtnGood.IsEnabled = -not $script:BackupBusy
    $BtnEnable.Visibility = $(if ($g -and $g.Code -eq 22 -and $g.Pnp) { 'Visible' } else { 'Collapsed' })
}

# ---------------------------------------------------------------- seção "Meus drivers"

$CatIcon = @{ 'Vídeo' = [char]0xE7F4; 'Rede' = [char]0xE839; 'Áudio' = [char]0xE767; 'Chipset' = [char]0xE964; 'Armazenamento' = [char]0xEDA2; 'Bluetooth' = [char]0xE702 }

# texto que pode ser cortado: mostra o conteúdo inteiro ao deixar o mouse parado 2 segundos
function Set-Dica($elemento, [string]$texto) {
    $elemento.ToolTip = $texto
    [Windows.Controls.ToolTipService]::SetInitialShowDelay($elemento, 2000)
    [Windows.Controls.ToolTipService]::SetShowDuration($elemento, 30000)
}

function New-KeyCard($k, $estado, $cor, $bk) {
    $card = New-Object Windows.Controls.Border
    $card.Width = 324; $card.Margin = '0,0,10,10'; $card.Padding = '16,14'; $card.CornerRadius = 16
    $card.Background = Get-Brush '#171A21'; $card.BorderBrush = Get-Brush $(if ($estado -eq 'TROCADO') { $cor } else { '#2A2F3A' }); $card.BorderThickness = $(if ($estado -eq 'TROCADO') { 2 } else { 1 })
    $sp = New-Object Windows.Controls.StackPanel

    # linha de cima: categoria + situação
    $top = New-Object Windows.Controls.DockPanel
    $sit = New-Object Windows.Controls.TextBlock
    $sit.Text = $(if ($estado -eq 'Como sempre esteve') { 'Sem alterações' } else { $estado }); $sit.Foreground = Get-Brush $cor; $sit.FontSize = 11.5; $sit.FontWeight = [Windows.FontWeights]::SemiBold
    [Windows.Controls.DockPanel]::SetDock($sit, 'Right'); [void]$top.Children.Add($sit)
    $cat = New-Object Windows.Controls.TextBlock
    $cat.FontSize = 11.5; $cat.Foreground = Get-Brush $Hex.info; $cat.FontWeight = [Windows.FontWeights]::SemiBold
    $ic = New-Object Windows.Documents.Run ("$($CatIcon[$k.Categoria])  ")
    $ic.FontFamily = $app.Resources['Icons']
    $cat.Inlines.Add($ic); $cat.Inlines.Add((New-Object Windows.Documents.Run $k.Categoria.ToUpper()))
    [void]$top.Children.Add($cat)
    [void]$sp.Children.Add($top)

    $nome = New-Object Windows.Controls.TextBlock
    $nome.Text = $k.Nome; $nome.FontSize = 14.5; $nome.FontWeight = [Windows.FontWeights]::SemiBold
    $nome.TextWrapping = 'Wrap'; $nome.Margin = '0,8,0,0'; $nome.Height = 40; $nome.TextTrimming = 'CharacterEllipsis'
    Set-Dica $nome $k.Nome
    [void]$sp.Children.Add($nome)

    $det = New-Object Windows.Controls.TextBlock
    $det.FontSize = 12.5; $det.Foreground = Get-Brush '#C9CED6'; $det.Margin = '0,2,0,0'; $det.TextTrimming = 'CharacterEllipsis'
    $det.Text = '{0}  •  {1}{2}{3}' -f $k.Fabricante, $k.Versao, $(if ($k.Data) { ' de {0:MM/yyyy}' -f $k.Data } else { '' }),
        $(if ($k.Qtd -gt 1) { "  •  $($k.Qtd) dispositivos" } else { '' })
    Set-Dica $det ("{0}`nVersão {1}{2}`nArquivo: {3}{4}" -f $k.Nome, $k.Versao,
        $(if ($k.Data) { ' de {0:dd/MM/yyyy}' -f $k.Data } else { '' }), $k.Inf,
        $(if ($k.Qtd -gt 1) { "`n$($k.Qtd) dispositivos usam este mesmo driver" } else { '' }))
    [void]$sp.Children.Add($det)

    $cop = New-Object Windows.Controls.TextBlock
    $cop.FontSize = 12.5; $cop.Margin = '0,6,0,0'
    if ($bk) {
        $cop.Text = '● Cópia salva: {0:N0} MB, {1}' -f $bk.SizeMB, $bk.Date; $cop.Foreground = Get-Brush $Hex.ok
        Set-Dica $cop ("Cópia guardada em {0}`nVersão {1}  •  {2:N0} MB  •  feita em {3}" -f $bk.Path, $bk.Version, $bk.SizeMB, $bk.Date)
    } else {
        $cop.Text = '● Sem cópia salva'; $cop.Foreground = Get-Brush $Hex.warn
        Set-Dica $cop 'Sem cópia guardada: se este driver for trocado e der problema, não há como voltar com um clique.'
    }
    [void]$sp.Children.Add($cop)

    $acoes = New-Object Windows.Controls.WrapPanel
    $acoes.Margin = '0,12,0,0'
    foreach ($a in @(
            @{ T = $(if ($bk) { 'Refazer cópia' } else { 'Fazer backup' }); S = $(if ($bk) { 'Pill' } else { 'PillAccent' }); F = 'backup'; E = $true },
            @{ T = 'Restaurar'; S = 'Pill'; F = 'restore'; E = [bool]$bk },
            @{ T = 'Origem'; S = 'Pill'; F = 'hist'; E = $true })) {
        $b = New-Object Windows.Controls.Button
        $b.Content = $a.T; $b.Style = $app.Resources[$a.S]; $b.Tag = ('{0}|{1}' -f $a.F, $k.Id)
        $b.FontSize = 12; $b.Padding = '12,6'; $b.Margin = '0,0,6,0'; $b.IsEnabled = $a.E
        $b.add_Click({ param($s, $e)
            $acao, $id = "$($s.Tag)" -split '\|', 2
            switch ($acao) { 'backup' { Act-KeyBackup $id } 'restore' { Act-KeyRestore $id } 'hist' { Act-KeyHist $id } }
        })
        [void]$acoes.Children.Add($b)
    }
    [void]$sp.Children.Add($acoes)
    $card.Child = $sp
    $card
}

function Update-KeyCards {
    $base = Get-KeyBaselines
    $KeyCards.Children.Clear()
    $semCopia = 0; $trocados = 0
    $ordenado = @($script:Keys | Sort-Object @{ e = { switch ($_.Categoria) { 'Vídeo' { 0 } 'Chipset' { 1 } 'Rede' { 2 } 'Áudio' { 3 } default { 4 } } } }, Nome)
    $kt.BeginLoadData(); $kt.Clear()
    foreach ($k in $ordenado) {
        $b = $base[$k.Id]
        if (-not $b) { $ord = 1; $est = 'Nunca visto'; $cor = $Hex.warn }
        elseif ($b.Versao -ne $k.Versao) { $ord = 0; $est = 'TROCADO'; $cor = $Hex.bad; $trocados++ }
        else { $ord = 2; $est = 'Como sempre esteve'; $cor = $Hex.ok }
        $bk = if ($k.Categoria -eq 'Vídeo') { Get-Backup (Get-Baseline).Version } else { Get-DeviceBackup $k.Id }
        if (-not $bk) { $semCopia++ }
        # o vídeo já tem o cartão grande lá em cima: não repete aqui (continua na lista completa)
        if ($k.Categoria -ne 'Vídeo') { [void]$KeyCards.Children.Add((New-KeyCard $k $est $cor $bk)) }
        [void]$kt.Rows.Add($ord, $est, $cor, $k.Categoria, $(if ($k.Qtd -gt 1) { '{0}  ({1} dispositivos)' -f $k.Nome, $k.Qtd } else { $k.Nome }), $k.Fabricante, $k.Versao,
            $(if ($bk) { '{0:N0} MB' -f $bk.SizeMB } else { '—' }), $k.Id)
    }
    $kt.EndLoadData()
    if (-not $KeyGrid.ItemsSource) { $KeyGrid.ItemsSource = $kt.DefaultView }
    $KeyCoverage.Text = '{0} de {1} com cópia salva' -f ($script:Keys.Count - $semCopia), $script:Keys.Count
    $KeyResumo.Text = 'Cópias individuais por driver' + $(if ($trocados) { "  •  $trocados alterado(s)" } else { '  •  nenhuma alteração detectada' })
    $BtnKeyAll.IsEnabled = ($semCopia -gt 0)
    $BtnKeyAll.Content = $(if ($semCopia -gt 0) { 'Fazer backup dos {0} restantes' -f $semCopia } else { 'Todos com cópia salva' })
}

# cartão com processador, placa-mãe, BIOS, chipset e memória
function Update-SysCard {
    $si = $script:SysInfo
    $SysText.Inlines.Clear()
    Add-Line $SysText 'ESTE COMPUTADOR' $Hex.info 11 $true
    if (-not $si) { return }
    Add-Line $SysText $si.Cpu '#E8EAED' 15 $true
    Add-Line $SysText ('{0} núcleos / {1} threads   •   {2} GB de RAM a {3} MHz ({4} pente(s))' -f $si.Cores, $si.Threads, $si.RamGB, $si.RamSpeed, $si.RamSlots) '#C9CED6' 12.5
    $nome = if ($si.IsLaptop -and $si.Model) { '{0} {1}' -f $si.Maker, $si.Model } else { '{0} {1}' -f $si.BoardMaker, $si.BoardModel }
    Add-Line $SysText $nome.Trim() '#C9CED6'
    $anos = { param($d) if ($d) { [math]::Round(((Get-Date) - $d).TotalDays / 365.25, 1) } else { $null } }
    $ab = & $anos $si.BiosDate
    if ($si.BiosVer) {
        $txt = 'BIOS {0}{1}' -f $si.BiosVer, $(if ($si.BiosDate) { ' de {0:MM/yyyy}' -f $si.BiosDate } else { '' })
        # idade não prova que exista versão nova: a placa pode já estar na última. Só informa.
        if ($ab -and $ab -ge 2) { Add-Line $SysText ('●  ' + $txt + " — {0} anos; vale conferir no site do fabricante (pode já ser a última)" -f $ab) $Hex.warn }
        else { Add-Line $SysText ('●  ' + $txt) $Hex.ok }
    }
    $ac = & $anos $si.ChipsetDate
    if ($si.ChipsetVer) {
        $txt = 'Chipset {0} {1}{2}' -f $si.ChipsetMaker, $si.ChipsetVer, $(if ($si.ChipsetDate) { ' de {0:MM/yyyy}' -f $si.ChipsetDate } else { '' })
        if ($ac -and $ac -ge 2) { Add-Line $SysText ('●  ' + $txt + ' — {0} anos; o botão "Atualizar drivers" confere se há versão nova' -f $ac) $Hex.warn }
        else { Add-Line $SysText ('●  ' + $txt) $Hex.ok }
    } else { Add-Line $SysText '●  Driver de chipset não encontrado' $Hex.warn }
}

function Get-KeySel([string]$id) { @($script:Keys | Where-Object { $_.Id -eq $id })[0] }

# o usuário não precisa salvar referência: a primeira análise já registra o "normal" do PC,
# e o backup de um driver atualiza a referência dele.
function Set-KeyNormal($somente) {
    $base = Get-KeyBaselines
    $agora = (Get-Date).ToString('dd/MM/yyyy HH:mm')
    foreach ($k in $script:Keys) {
        if ($somente -and $somente -ne $k.Id) { continue }
        $base[$k.Id] = [pscustomobject]@{ Id = $k.Id; Nome = $k.Nome; Categoria = $k.Categoria; Versao = $k.Versao; Inf = $k.Inf; Marcado = $agora }
    }
    @($base.Values) | ConvertTo-Json -Depth 4 | Set-Content $KeyFile -Encoding UTF8
    $script:KeyChanges = @(Get-KeyChanges $script:Keys)
}

# mostra o que mudou e pergunta se a versão nova pode virar o novo normal
function Act-KeyChanges {
    $ch = @($script:KeyChanges)
    if (-not $ch.Count) { return }
    $rows = @($ch | ForEach-Object { [pscustomobject]@{ Categoria = $_.Categoria; Dispositivo = $_.Nome; Antes = $_.Antes; Agora = $_.Agora } })
    Show-TableWindow 'Drivers principais que mudaram' $rows 'Se algo parou de funcionar depois dessas trocas, restaure o backup em "Meus drivers".'
    if (Show-Dialog 'Está tudo funcionando?' ("Marcar as versões atuais como o normal deste PC?`n`nSe sim, o HollowDrivers para de avisar sobre essas trocas e passa a vigiar a partir delas.`nSe algo está ruim, escolha Não e restaure o backup.") 'ask' -YesNo -YesText 'Está tudo bem' -NoText 'Ainda não') {
        Set-KeyNormal $null
        Update-KeyCards; Update-Cards; Update-Home
    }
}

function Act-KeyBackup([string]$id) {
    $k = Get-KeySel $id
    if (-not $k) { return }
    if ($k.Categoria -eq 'Vídeo') { Act-MarkGood; return }
    $pkg = Get-DriverPackage $k.Inf $k.Versao
    if (-not $pkg) { [void](Show-Dialog 'Backup não disponível' 'Não encontrei o pacote desse driver dentro do Windows.' 'warn'); return }
    $mb = [math]::Round(((Get-ChildItem $pkg.Folder -Recurse -File | Measure-Object Length -Sum).Sum) / 1MB, 1)
    if (-not (Show-Dialog 'Backup do driver' ("Guardar uma cópia do driver de {0}?`n`n{1}`nVersão {2}  •  cerca de {3} MB`n`nCom a cópia salva, dá para voltar para esta versão com um clique." -f $k.Categoria.ToLower(), $k.Nome, $k.Versao, $mb) 'ask' -YesNo -YesText 'Fazer backup')) { return }
    $dst = Join-Path $BackupDir ('dev-{0}-{1}' -f ($k.Inf -replace '\W', ''), $k.Versao)
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    $script:KeyBkId = $k.Id
    $KeyResumo.Text = 'Copiando o driver de {0}...' -f $k.Categoria.ToLower()
    $code = Expand-Tpl $BackupTpl @{ '__SRC__' = $pkg.Folder; '__DST__' = $dst; '__VER__' = $k.Versao; '__NAME__' = $k.Nome; '__INF__' = $pkg.Inf
        '__VENDOR__' = $k.Fabricante; '__DEVID__' = $k.Id; '__CLASSGUID__' = ($k.ClassGuid -replace '[{}]', ''); '__CAT__' = $k.Categoria }
    Start-Bg $code {
        param($out, $err)

        $rc = if ($out -and $out.Count) { [int]"$($out[$out.Count - 1])" } else { 99 }
        if ($err -or $rc -ge 8) { [void](Show-Dialog 'Backup falhou' "Não foi possível copiar o driver (código $rc).`n$err" 'bad') }
        else { Set-KeyNormal $script:KeyBkId }
        Update-KeyCards; Update-Cards; Update-Home
    }
}

# copia de uma vez os drivers que ainda não têm cópia
function Act-KeyAll {
    $base = Get-KeyBaselines
    $faltam = @($script:Keys | Where-Object {
        $bk = if ($_.Categoria -eq 'Vídeo') { Get-Backup (Get-Baseline).Version } else { Get-DeviceBackup $_.Id }
        -not $bk
    })
    if (-not $faltam.Count) { return }
    $tam = @{}
    foreach ($k in $faltam) {
        $p = Get-DriverPackage $k.Inf $k.Versao
        $tam[$k.Id] = $(if ($p) { [math]::Round(((Get-ChildItem $p.Folder -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1MB) } else { 0 })
    }
    $video = @($faltam | Where-Object { $_.Categoria -eq 'Vídeo' })
    $semVideo = [int](($faltam | Where-Object { $_.Categoria -ne 'Vídeo' } | ForEach-Object { $tam[$_.Id] } | Measure-Object -Sum).Sum)
    $comVideo = [int](($faltam | ForEach-Object { $tam[$_.Id] } | Measure-Object -Sum).Sum)
    $lista = (@($faltam | ForEach-Object { '•   {0}: {1} ({2} MB)' -f $_.Categoria, $_.Nome, $tam[$_.Id] }) -join "`n")
    $incluirVideo = $true
    if ($video.Count) {
        $incluirVideo = Show-Dialog 'Incluir o driver de vídeo?' ("O driver de vídeo sozinho ocupa {0} MB; os outros somam {1} MB.`n`nIncluir o vídeo na cópia?" -f ($comVideo - $semVideo), $semVideo) 'ask' -YesNo -YesText 'Incluir' -NoText 'Sem o vídeo'
    }
    if (-not $incluirVideo) { $faltam = @($faltam | Where-Object { $_.Categoria -ne 'Vídeo' }); $lista = (@($faltam | ForEach-Object { '•   {0}: {1} ({2} MB)' -f $_.Categoria, $_.Nome, $tam[$_.Id] }) -join "`n") }
    if (-not $faltam.Count) { return }
    $total = [int](($faltam | ForEach-Object { $tam[$_.Id] } | Measure-Object -Sum).Sum)
    if (-not (Show-Dialog 'Fazer backup de todos' ("Guardar uma cópia de {0} ({1} MB no total)?`n`n{2}`n`nCom as cópias salvas, dá para voltar qualquer um deles com um clique." -f (Get-Plural $faltam.Count 'driver' 'drivers'), $total, $lista) 'ask' -YesNo -YesText 'Fazer backup')) { return }

    $itens = @($faltam | ForEach-Object {
        $p = Get-DriverPackage $_.Inf $_.Versao
        if (-not $p) { return }
        $dst = if ($_.Categoria -eq 'Vídeo') { Join-Path $BackupDir $_.Versao } else { Join-Path $BackupDir ('dev-{0}-{1}' -f ($_.Inf -replace '\W', ''), $_.Versao) }
        [pscustomobject]@{ Src = $p.Folder; Dst = $dst; Inf = $p.Inf; Ver = $_.Versao; Nome = $_.Nome; Vendor = $_.Fabricante; Id = $_.Id; ClassGuid = ($_.ClassGuid -replace '[{}]', ''); Cat = $_.Categoria }
    })
    if (-not $itens.Count) { [void](Show-Dialog 'Backup não disponível' 'Não encontrei os pacotes desses drivers dentro do Windows.' 'warn'); return }
    $BtnKeyAll.IsEnabled = $false; $BtnKeyAll.Content = 'Copiando...'
    $script:KeyAllVideo = @($itens | Where-Object { $_.Cat -eq 'Vídeo' })[0]
    Start-Bg (Expand-Tpl $KeyAllTpl @{ '__JSON__' = (ConvertTo-Json -InputObject @($itens) -Compress -Depth 4) }) {
        param($out, $err)
        $BtnKeyAll.IsEnabled = $true
        $r = if ($out -and $out.Count) { $out[$out.Count - 1] } else { $null }
        if ($err -or -not $r) { [void](Show-Dialog 'Backup falhou' "Não foi possível copiar.`n$err" 'bad') }
        else {
            if ($script:KeyAllVideo -and $script:Gpu) { Save-Baseline $script:Gpu }
            Set-KeyNormal $null
            [void](Show-Dialog 'Cópias guardadas' ("{0} de {1} drivers copiados.`n`nAgora dá para restaurar qualquer um deles pelo próprio cartão." -f $r.Ok, $r.Total) $(if ($r.Ok -eq $r.Total) { 'ok' } else { 'warn' }))
        }
        Update-Cards; Update-Home
    }
}

# Guarda o driver atual antes de instalar outro, mesmo que não tenha sido o app quem o instalou.
# Assim sempre existe para onde voltar.
function Get-DeviceForHw([string]$hw) {
    if (-not $hw) { return $null }
    $k = @($script:Keys | Where-Object { $_.VenDev -eq $hw })[0]
    if ($k) { return $k }
    $d = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
        Where-Object { $_.DeviceID -like "*$hw*" -and $_.DriverVersion -and "$($_.DriverProviderName)" -notmatch '^Microsoft' })[0]
    if (-not $d) { return $null }
    [pscustomobject]@{ Id = $d.DeviceID; Nome = $d.DeviceName; Categoria = 'Outros'; Versao = $d.DriverVersion
        Inf = "$($d.InfName)"; Fabricante = "$($d.DriverProviderName)"; ClassGuid = "$($d.ClassGuid)" }
}

function New-PreBackupItems($devs) {
    $itens = @()
    foreach ($d in @($devs | Where-Object { $_ -and $_.Inf })) {
        $dst = if ($d.Categoria -eq 'Vídeo') { Join-Path $BackupDir $d.Versao } else { Join-Path $BackupDir ('dev-{0}-{1}' -f ($d.Inf -replace '\W', ''), $d.Versao) }
        $meta = Join-Path $dst 'HollowDrivers-backup.json'
        if (Test-Path $meta) {
            $saved = $null
            try { $saved = Get-Content $meta -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { }
            $infPath = if ($saved -and "$($saved.Inf)" -match '^[\w\-\.]+\.inf$') { Join-Path $dst $saved.Inf } else { '' }
            if (-not $saved -or "$($saved.Version)" -ne "$($d.Versao)" -or
                ($saved.DeviceId -and $saved.DeviceId -ne $d.Id) -or
                -not (Test-Path $infPath) -or
                -not @(Get-ChildItem $dst -Recurse -Filter '*.cat' -File -ErrorAction SilentlyContinue).Count) {
                throw "A copia salva de $($d.Nome) esta incompleta. Faca um novo backup antes de continuar."
            }
            continue
        }
        $pkg = Get-DriverPackage $d.Inf $d.Versao
        if (-not $pkg) { throw "Nao foi possivel localizar o pacote atual de $($d.Nome) para fazer backup." }
        $itens += [pscustomobject]@{ Src = $pkg.Folder; Dst = $dst; Inf = $pkg.Inf; Ver = $d.Versao; Nome = $d.Nome
            Vendor = $d.Fabricante; Id = $d.Id; ClassGuid = ($d.ClassGuid -replace '[{}]', ''); Cat = $d.Categoria }
    }
    @($itens)
}

function Stop-PreBackup([string]$reason) {
    $BtnUpd.IsEnabled = $true; $BtnUpd.Content = 'Atualizar drivers'
    $BtnRestore.IsEnabled = $true
    if ($script:UpdState -eq 'installing') { $script:UpdState = 'done' }
    [void](Show-Dialog 'Backup necessario' $reason 'bad')
    Update-Home; Update-Cards
}

# Copia o que estiver faltando e continua apenas depois de conferir o resultado.
function Start-PreBackup($devs, [scriptblock]$depois) {
    try { $itens = @(New-PreBackupItems $devs) }
    catch { Stop-PreBackup $_.Exception.Message; return }
    if (-not $itens.Count) { & $depois; return }
    $script:PreDepois = $depois
    $script:PreCount = $itens.Count
    $script:Prog.Text = 'Guardando copia dos drivers atuais...'
    Start-Bg (Expand-Tpl $KeyAllTpl @{ '__JSON__' = (ConvertTo-Json -InputObject @($itens) -Compress -Depth 4) }) {
        param($out, $err)
        Update-Cards
        $result = if ($out -and $out.Count) { $out[$out.Count - 1] } else { $null }
        if ($err -or -not $result -or $result.Ok -ne $script:PreCount) {
            Stop-PreBackup ('A copia dos drivers atuais nao foi concluida. Nenhum driver foi alterado. ' + $err)
            return
        }
        & $script:PreDepois
    }
}
function Act-KeyRestore([string]$id) {
    $k = Get-KeySel $id
    if (-not $k) { return }
    if ($k.Categoria -eq 'Vídeo') { Act-Restore; return }
    $bk = Get-DeviceBackup $k.Id
    if (-not $bk) { [void](Show-Dialog 'Sem backup' 'Esse driver ainda não tem cópia salva. Use "Backup do selecionado" enquanto ele está funcionando bem.' 'warn'); return }
    if ("$($bk.Inf)" -notmatch '^[\w\-\.]+\.inf$') { [void](Show-Dialog 'Backup inválido' 'O arquivo de controle do backup foi alterado. Faça o backup de novo.' 'bad'); return }
    $msg = "Voltar o driver de {0} para a versão {1} (backup de {2})?`n`n1.   Ponto de restauração do Windows`n2.   Remover o driver atual ({3})`n3.   Instalar o backup`n`nO Windows vai pedir permissão de administrador.{4}" -f
        $k.Categoria.ToLower(), $bk.Version, $bk.Date, $k.Versao, $(if ($k.Categoria -eq 'Rede') { "`n`nA internet pode cair por alguns segundos." } else { '' })
    if (-not (Show-Dialog 'Restaurar driver' $msg 'ask' -YesNo -YesText 'Restaurar')) { return }
    $script:RestoreArgs = @{ '__VENDOR__' = [regex]::Escape("$($bk.Vendor)"); '__SRC__' = $bk.Path; '__INFNAME__' = $bk.Inf
        '__VER__' = $bk.Version; '__CLASSGUID__' = "$($bk.ClassGuid)"; '__DEVID__' = $k.Id; '__CURRENTINF__' = $k.Inf }
    Start-PreBackup @($k) { Start-KeyRestoreNow }
}

function Start-KeyRestoreNow {
    Invoke-Elevated $RestoreTpl $script:RestoreArgs 'restaurar' {
        param($log, $err)
        if ($err) { [void](Show-Dialog 'Restauração cancelada' "O Windows não deu permissão de administrador, então nada foi alterado.`n`n$err" 'warn'); return }
        if ($log -match 'ERRO=(.+)') { [void](Show-Dialog 'Erro na restauração' $matches[1] 'bad') }
        else { [void](Show-Dialog 'Pronto' "O driver foi reinstalado.`n`nReinicie o PC para concluir." 'ok') }
        Start-Scan
    }
}

function Act-KeyHist([string]$id) {
    $k = Get-KeySel $id
    if (-not $k) { return }
    if (-not $k.VenDev) { [void](Show-Dialog 'Sem histórico' 'Não consegui identificar esse dispositivo nos registros do Windows.' 'info'); return }
    $script:HistName = $k.Nome
    Start-Bg ($LogicText + "`nGet-InstallHistory '$($k.VenDev)'") {
        param($out, $err)

        $rows = @($out | Where-Object { $_ } | ForEach-Object {
            [pscustomobject]@{ Quando = $_.Quando.ToString('dd/MM/yyyy HH:mm'); Origem = $_.Origem; Detalhe = $_.Detalhe; Destaque = ($_.Origem -like 'Driver Booster*') }
        })
        if (-not $rows.Count) { [void](Show-Dialog 'Sem histórico' 'Nenhuma instalação desse dispositivo nos registros guardados pelo Windows.' 'info'); return }
        Show-TableWindow ("Quem instalou driver em: $($script:HistName)") $rows 'Fonte: registros de instalação do Windows. Em vermelho: trocas feitas pelo Driver Booster.'
    }
}

# ---------------------------------------------------------------- tela inicial

function Set-Verdict([string]$kind, [string]$text, [string]$sub) {
    $col = $Hex[$kind]
    $VerdictText.Text = $text; $VerdictSub.Text = $sub
    $VerdictIcon.Text = $Glyph[$kind]; $VerdictIcon.Foreground = Get-Brush $col
    $VerdictBadge.Background = Get-Brush ('#26' + $col.Substring(1))
}

$SpinAnim = New-Object Windows.Media.Animation.DoubleAnimation(0, 360, (New-Object Windows.Duration([TimeSpan]::FromSeconds(1))))
$SpinAnim.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever

function Set-BigBusy([bool]$busy) {
    if ($busy) {
        $BigLabel.Text = 'ANALISANDO'; $BigLabel.FontSize = 19; $BigIcon.Visibility = 'Collapsed'
        $Spinner.Opacity = 1; $SpinRot.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $SpinAnim)
        $BigBtn.IsHitTestVisible = $false
    } else {
        $SpinRot.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $null); $Spinner.Opacity = 0
        $BigLabel.Text = 'ANALISAR'; $BigLabel.FontSize = 24; $BigIcon.Visibility = 'Visible'
        if ($script:LastScan) { $BigIcon.Text = [string][char]0xE72C }
        $BigBtn.IsHitTestVisible = $true
    }
}

function Add-Finding([string]$text, [string]$desc, [string]$kind, [string]$btnText, [scriptblock]$action) {
    $col = $Hex[$kind]
    $card = New-Object Windows.Controls.Border
    $card.Background = Get-Brush '#171A21'; $card.BorderBrush = Get-Brush '#2A2F3A'; $card.BorderThickness = 1
    $card.CornerRadius = 14; $card.Padding = '16,14'; $card.Margin = '0,0,0,10'
    $grid = New-Object Windows.Controls.Grid
    foreach ($w in 'Auto', '*', 'Auto') {
        $cd = New-Object Windows.Controls.ColumnDefinition
        $cd.Width = (New-Object Windows.GridLengthConverter).ConvertFromString($w)
        $grid.ColumnDefinitions.Add($cd)
    }
    $badge = New-Object Windows.Controls.Border
    $badge.Width = 36; $badge.Height = 36; $badge.CornerRadius = 18; $badge.Background = Get-Brush ('#26' + $col.Substring(1))
    $badge.VerticalAlignment = 'Top'
    $gl = New-Object Windows.Controls.TextBlock
    $gl.Text = $Glyph[$kind]; $gl.FontFamily = $app.Resources['Icons']; $gl.FontSize = 15; $gl.Foreground = Get-Brush $col
    $gl.HorizontalAlignment = 'Center'; $gl.VerticalAlignment = 'Center'
    $badge.Child = $gl
    $tb = New-Object Windows.Controls.TextBlock
    $tb.TextWrapping = 'Wrap'; $tb.VerticalAlignment = 'Center'; $tb.Margin = '14,0,14,0'
    $t1 = New-Object Windows.Documents.Run($text); $t1.FontSize = 14; $t1.FontWeight = [Windows.FontWeights]::SemiBold
    $tb.Inlines.Add($t1)
    if ($desc) {
        $tb.Inlines.Add((New-Object Windows.Documents.LineBreak))
        $t2 = New-Object Windows.Documents.Run($desc); $t2.FontSize = 12.5; $t2.Foreground = Get-Brush '#9AA2AF'
        $tb.Inlines.Add($t2); $tb.LineHeight = 20
        $script:LastDescRun = $t2
    }
    [Windows.Controls.Grid]::SetColumn($tb, 1)
    [void]$grid.Children.Add($badge); [void]$grid.Children.Add($tb)
    if ($btnText) {
        $b = New-Object Windows.Controls.Button
        $b.Content = $btnText; $b.Margin = '0'; $b.VerticalAlignment = 'Center'
        $b.Style = $app.Resources[$(if ($kind -eq 'bad') { 'PillAccent' } else { 'Pill' })]
        $b.add_Click($action)
        [Windows.Controls.Grid]::SetColumn($b, 2); [void]$grid.Children.Add($b)
    }
    $card.Child = $grid

    $i = $Findings.Children.Count
    $card.Opacity = 0
    $tt = New-Object Windows.Media.TranslateTransform(0, 12); $card.RenderTransform = $tt
    [void]$Findings.Children.Add($card)
    $dur = New-Object Windows.Duration([TimeSpan]::FromMilliseconds(320))
    $ease = New-Object Windows.Media.Animation.CubicEase; $ease.EasingMode = 'EaseOut'
    $a1 = New-Object Windows.Media.Animation.DoubleAnimation(0, 1, $dur); $a1.BeginTime = [TimeSpan]::FromMilliseconds(90 * $i)
    $a2 = New-Object Windows.Media.Animation.DoubleAnimation(12, 0, $dur); $a2.BeginTime = $a1.BeginTime; $a2.EasingFunction = $ease
    $card.BeginAnimation([Windows.UIElement]::OpacityProperty, $a1)
    $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $a2)
}

function Update-Home {
    if (-not $script:LastScan) { return }
    $Findings.Children.Clear()
    $g = $script:Gpu; $b = Get-Baseline; $hl = $script:Health
    $bk = if ($b) { Get-Backup $b.Version } else { $null }
    $bad = 0; $tips = 0


    if ($g -and $g.Code -ne 0) {
        $bad++
        if ($bk) {
            Add-Finding 'O driver da placa de vídeo está quebrado' ("A tela funciona, mas jogos e aceleração 3D não. Você tem um backup do driver que funcionava ({0}) — um clique reinstala ele." -f $bk.Version) 'bad' 'Restaurar driver' { Act-Restore }
        } else {
            Add-Finding 'O driver da placa de vídeo está quebrado' 'O Windows passou a usar um modo de vídeo básico: a tela funciona, mas jogos e aceleração 3D não. Reinstale o driver oficial.' 'bad' 'Como resolver' {
                [void](Show-Dialog 'Como resolver' ((Get-FixSteps) + "`n`nVou abrir o site oficial agora.") 'info' -YesText 'Abrir site')
                Start-Process @((Get-OfficialLinks).Values)[0]
            }
        }
    }
    if ($g -and $g.Code -eq 0 -and $b -and $b.Version -ne $g.Version) {
        $origin = if ($script:History.Count) { $script:History[0].Origem } else { '' }
        if ($origin -like 'Instalador oficial*') {
            $tips++
            Add-Finding 'O driver de vídeo foi atualizado' ("Nova versão {0} instalada pelo {1}. Se o vídeo e os jogos estão funcionando bem, salve esta versão como a nova referência." -f $g.Version, $origin.ToLower()) 'warn' 'Salvar nova versão' { Act-MarkGood }
        } else {
            $bad++
            $who = if ($origin) { " (por: $origin)" } else { '' }
            if ($bk) {
                Add-Finding "O driver de vídeo foi trocado sem você saber$who" ("Se o vídeo ou os jogos começaram a falhar, essa troca é a causa mais provável. Você pode voltar para o driver salvo ({0}) com um clique." -f $bk.Version) 'bad' 'Restaurar driver' { Act-Restore }
            } else {
                Add-Finding "O driver de vídeo foi trocado sem você saber$who" 'Se o vídeo ou os jogos começaram a falhar, essa troca é a causa mais provável. Veja quem trocou e reinstale o driver oficial.' 'bad' 'Ver quem trocou' { Act-History }
            }
        }
    }
    if (@($script:KeyChanges).Count) {
        $bad++
        $n = @($script:KeyChanges)
        $quais = (@($n | Select-Object -First 3 | ForEach-Object { '{0} ({1})' -f $_.Categoria.ToLower(), $_.Nome }) -join ', ')
        Add-Finding ((Get-Plural $n.Count 'driver principal foi trocado' 'drivers principais foram trocados')) "Mudaram de versão desde a última vez: $quais. Se algo parou de funcionar, foi provavelmente isso." 'bad' 'Ver quais' { Act-KeyChanges }
    }
    if ($hl.DriverBooster.Count) {
        $bad++
        Add-Finding 'O Driver Booster está instalado' 'Ele instala drivers de fontes próprias por cima dos oficiais, sem pedir. Isso pode deixar a placa de vídeo instável ou impedir jogos de abrir.' 'bad' 'Remover' { Act-RemoveDb }
    }
    if ($hl.Crashes) {
        $bad++
        $why = if (-not $hl.Tdr) { 'Nenhuma dessas quedas teve erro de driver. Isso costuma ser a fonte de energia não aguentando a placa de vídeo em jogos pesados, e não o driver.' }
               else { 'O Windows registrou falhas do driver de vídeo junto com as quedas. Veja os detalhes para saber quando aconteceram.' }
        Add-Finding ('O PC desligou sozinho {0} no último mês' -f (Get-Plural $hl.Crashes 'vez' 'vezes')) $why 'bad' 'Ver quedas' { Act-Crashes }
    }
    if ($script:NeedReboot.Count) {
        $bad++
        $quais = ($script:NeedReboot | Select-Object -First 3 -Expand Dispositivo) -join ', '
        Add-Finding ((Get-Plural $script:NeedReboot.Count 'driver está esperando você reiniciar' 'drivers estão esperando você reiniciar')) `
            ("$quais só vai funcionar depois de reiniciar o PC. Atualizar o driver de novo não tira esse aviso.`n`nImportante: use Iniciar → Reiniciar. Desligar e ligar não resolve, porque o Windows 11 não desliga de verdade (Inicialização Rápida).") `
            'warn' 'Reiniciar agora' { Act-Reboot }
    }
    if ($script:Problems) {
        $bad++
        Add-Finding ((Get-Plural $script:Problems 'dispositivo com problema' 'dispositivos com problema') + ' no driver') 'Algum componente do PC está sem driver ou com erro e pode não funcionar direito. Veja qual no modo avançado.' 'bad' 'Ver' { Show-View $true }
    }
    $script:ProgRun = $null
    switch ($script:UpdState) {
        'checking' {
            Add-Finding 'Procurando atualizações de driver...' $script:Prog.Text 'info' $null $null
            $script:ProgRun = $script:LastDescRun
        }
        'installing' {
            Add-Finding 'Atualizando drivers...' $script:Prog.Text 'info' $null $null
            $script:ProgRun = $script:LastDescRun
        }
        'error' {
            Add-Finding 'Não foi possível buscar atualizações' 'Sem internet ou o catálogo da Microsoft não respondeu. Tente de novo mais tarde.' 'info' 'Tentar de novo' { Start-UpdateCheck }
        }
        'done' {
            if ($script:Updates.Count) {
                $tips++
                $names = (@($script:Updates | Select-Object -First 3 | ForEach-Object Dispositivo) -join ', ')
                if ($script:Updates.Count -gt 3) { $names += '...' }
                Add-Finding ((Get-Plural $script:Updates.Count 'driver tem versão nova' 'drivers têm versão nova') + ' oficial') "Versões mais novas certificadas pela Microsoft: $names. Antes de instalar é criado um ponto de restauração." 'warn' 'Atualizar' { Show-UpdatesWindow }
            }
        }
    }
    if ($script:BackupBusy) {
        Add-Finding 'Fazendo backup do driver de vídeo...' 'Copiando o driver atual para você poder restaurar com um clique no futuro. Pode continuar usando o PC.' 'info' $null $null
    } elseif ($g -and $g.Code -eq 0 -and -not $b) {
        $tips++
        Add-Finding 'Faça backup do seu driver de vídeo' 'Seu vídeo está funcionando agora. Guardando uma cópia deste driver, se algum programa ou o Windows trocar ele, é só um clique para voltar.' 'warn' 'Fazer backup' { Act-MarkGood }
    } elseif ($g -and $g.Code -eq 0 -and $b -and $b.Version -eq $g.Version -and -not $bk) {
        $tips++
        Add-Finding 'Faça o backup do seu driver de vídeo' 'Seu driver está salvo como referência, mas ainda sem cópia de segurança. Com o backup, dá para restaurar com um clique se algo trocar o driver.' 'warn' 'Fazer backup' { Start-Backup $script:Gpu }
    }
    if ($script:AllBusy) {
        Add-Finding 'Salvando todos os drivers...' 'Copiando os drivers do fabricante para a pasta escolhida. Pode levar alguns minutos — pode continuar usando o PC.' 'info' $null $null
    } elseif (-not (Get-AllBackupInfo)) {
        $tips++
        $dev = if ($script:SysInfo -and $script:SysInfo.IsLaptop) { 'Notebooks dependem' } else { 'Seu PC depende' }
        Add-Finding 'Guarde todos os drivers num pendrive' "$dev de drivers do fabricante (chipset, Wi-Fi, áudio, touchpad, teclas especiais) que o Windows nem sempre instala sozinho depois de formatar. Salve todos agora e reinstale com dois cliques quando precisar." 'warn' 'Fazer backup' { Act-AllBackup }
    }
    if (-not (Test-WatchEnabled)) {
        $tips++
        Add-Finding 'A proteção automática está desligada' 'Quando ligada, um escudo fica perto do relógio: o HollowDrivers confere seu PC em silêncio e só avisa se o driver de vídeo for trocado, a placa der erro, o PC cair ou o Driver Booster voltar. Não instala nada e não deixa o PC lento.' 'warn' 'Ligar' { Act-Watch }
    }

    $sub = 'Última análise às {0:HH:mm}' -f $script:LastScan
    if ($script:UpdState -eq 'done' -and -not $script:Updates.Count) { $sub += '  •  drivers em dia' }
    if ($bad) { Set-Verdict 'bad' (Get-Plural $bad 'problema encontrado' 'problemas encontrados') $sub }
    elseif ($tips) { Set-Verdict 'ok' 'Tudo certo' ('{0}  •  {1} para ficar mais protegido' -f $sub, (Get-Plural $tips 'sugestão' 'sugestões')) }
    else { Set-Verdict 'ok' 'Tudo certo — seu PC está protegido' $sub }
}

# barra lateral: mostra uma seção por vez
$script:Section = 'drivers'
$Sections = @{ drivers = 'NavDrivers,PanDrivers'; video = 'NavVideo,PanVideo'; sistema = 'NavSystem,PanSystem'; protecao = 'NavGuard,PanGuard'; windows = 'NavWin,PanWin' }
function Show-Section([string]$key) {
    if (-not $Sections.ContainsKey($key)) { $key = 'drivers' }
    $script:Section = $key
    foreach ($k in $Sections.Keys) {
        $nav, $pan = $Sections[$k] -split ','
        (Get-Variable $nav -Scope Script -ValueOnly).IsChecked = ($k -eq $key)
        (Get-Variable $pan -Scope Script -ValueOnly).Visibility = $(if ($k -eq $key) { 'Visible' } else { 'Collapsed' })
    }
}

$script:RailOpen = $true
$RailItems = 'BtnHomeScan', 'BtnHomeConfig', 'BtnAdvanced', 'BtnRailHome', 'BtnRailAdv', 'NavDrivers', 'NavVideo', 'NavSystem', 'NavGuard', 'NavWin', 'BtnBack'
$RailText = @{}
function Set-Rail([bool]$open) {
    $script:RailOpen = $open
    if (-not $RailText.Count) { foreach ($n in $RailItems) { $RailText[$n] = (Get-Variable $n -Scope Script -ValueOnly).Content } }
    foreach ($n in $RailItems) {
        $b = Get-Variable $n -Scope Script -ValueOnly
        $b.Content = $(if ($open) { $RailText[$n] } else { '' })
        $b.ToolTip = $(if ($open) { $null } else { $RailText[$n] })
    }
    $HomeRail.Width = $(if ($open) { 200 } else { 64 })
    $AdvCol.Width = $(if ($open) { 228 } else { 64 })
    $HomeRailBox.Margin = $(if ($open) { '14,22,14,14' } else { '6,22,6,14' })
    $AdvRailBox.Margin = $(if ($open) { '14,18,14,14' } else { '6,18,6,14' })
    $AdvLogoText.Visibility = $(if ($open) { 'Visible' } else { 'Collapsed' })
    $BtnRailHome.ToolTip = $BtnRailAdv.ToolTip = $(if ($open) { $null } else { 'Expandir menu' })
}

function Show-Config([bool]$on) {
    $ConfigView.Visibility = $(if ($on) { 'Visible' } else { 'Collapsed' })

}

function Show-View([bool]$adv) {
    Show-Config $false
    if (-not $adv) { Show-Section 'drivers' }
    $AdvView.Visibility = $(if ($adv) { 'Visible' } else { 'Collapsed' })
    $HomeView.Visibility = $(if ($adv) { 'Collapsed' } else { 'Visible' })
    if ($adv -and -not $script:LastScan -and -not $script:Scanning) { Start-Scan }
}

# ---------------------------------------------------------------- ações

function Apply-Scan($r) {
    $rows = @($r.Rows)
    $script:Gpu = $r.Gpu; $script:History = @($r.History); $script:Health = $r.Health; $script:SysInfo = $r.SysInfo
    $script:Keys = @($r.Keys)
    if ($script:Keys.Count -and -not (Get-KeyBaselines).Count) { Set-KeyNormal $null }   # primeira análise = normal do PC
    $script:KeyChanges = @(Get-KeyChanges $script:Keys)
    $script:Problems = @($rows | Where-Object { $_.Status -notin 'OK', 'Antigo' }).Count
    $script:Old = @($rows | Where-Object { $_.Status -eq 'Antigo' }).Count
    $script:NeedReboot = @($rows | Where-Object { $_.Status -like '*código 14*' })
    $dt.BeginLoadData(); $dt.Clear()
    foreach ($x in $rows) {
        if ($x.Status -eq 'OK') { $ord = 2; $cor = $Hex.ok } elseif ($x.Status -eq 'Antigo') { $ord = 1; $cor = $Hex.warn } else { $ord = 0; $cor = $Hex.bad }
        [void]$dt.Rows.Add($ord, $x.Status, $cor, $x.Categoria, $x.Dispositivo, $x.Fabricante, $x.Versao,
            $(if ($x.Data) { $x.Data } else { [DBNull]::Value }),
            $(if ($null -ne $x.Idade) { $x.Idade } else { [DBNull]::Value }),
            $x.INF, $x.Microsoft)
    }
    $dt.EndLoadData()
    $script:LastScan = Get-Date
    Update-Cards; Update-Filter; Update-Home; Update-Sites
    if ($script:WdDepois) { $script:WdDepois = $false; Start-VideoWatchdog 60 }
    if ($script:AfterUpdate) { Show-UpdateResult $rows }
    elseif ($script:UpdState -in 'idle', 'error') { Start-UpdateCheck }
    if ($script:AfterRestore) {
        $want = $script:AfterRestore; $script:AfterRestore = $null
        $g = $script:Gpu
        if ($g -and $g.Code -eq 0 -and $g.Version -eq $want) {
            [void](Show-Dialog 'Driver restaurado' ("A placa de vídeo voltou para o driver $want e está funcionando.`n`nReinicie o PC para finalizar.") 'ok')
        } else {
            $now = if ($g) { "$($g.Version) — $(Get-ProblemText $g.Code)" } else { 'placa não encontrada' }
            [void](Show-Dialog 'Reinicie o PC' ("A restauração terminou, mas a placa ainda mostra: $now.`n`nIsso é normal logo após trocar driver. Reinicie o PC e analise de novo.") 'warn')
        }
    }
}

function Start-Scan {
    if ($script:Scanning) { return }
    $script:Scanning = $true
    Set-BigBusy $true; $BtnScan.IsEnabled = $false
    Set-Verdict 'info' 'Analisando seu PC...' 'Verificando drivers, placa de vídeo e quedas'
    $Findings.Children.Clear()
    $StatusText.Text = 'Escaneando...'
    Start-Bg ($LogicText + "`n" + $ScanCode) {
        param($out, $err)
        $script:Scanning = $false; Set-BigBusy $false; $BtnScan.IsEnabled = $true
        if ($err -or -not $out -or -not $out.Count) {
            Set-Verdict 'info' 'Pronto para verificar' 'Clique no botão para analisar seu PC'
            [void](Show-Dialog 'Erro ao analisar' "$err" 'bad')
            return
        }
        Apply-Scan $out[0]
    }
}

function Start-Backup($g) {
    if (-not $g -or $script:BackupBusy) { return }
    $pkg = Get-DriverPackage $g.Inf $g.Version
    if (-not $pkg) {
        [void](Show-Dialog 'Backup não disponível' 'Não encontrei o pacote do driver de vídeo dentro do Windows. O driver foi salvo como referência (você continua sendo avisado se ele for trocado), mas sem cópia de segurança.' 'warn')
        return
    }
    $dst = Join-Path $BackupDir $g.Version
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    $script:BackupBusy = $true; $script:BackupVersion = $g.Version
    Update-Cards; Update-Home
    $code = Expand-Tpl $BackupTpl @{ '__SRC__' = $pkg.Folder; '__DST__' = $dst; '__VER__' = $g.Version; '__NAME__' = $g.Name; '__INF__' = $pkg.Inf
        '__VENDOR__' = $g.Vendor; '__DEVID__' = ''; '__CLASSGUID__' = '4d36e968-e325-11ce-bfc1-08002be10318'; '__CAT__' = 'Vídeo' }
    Start-Bg $code {
        param($out, $err)
        $script:BackupBusy = $false
        $v = $script:BackupVersion
        $rc = if ($out -and $out.Count) { [int]"$($out[$out.Count - 1])" } else { 99 }
        if ($err -or $rc -ge 8 -or -not (Get-Backup $v)) {
            [void](Show-Dialog 'Backup falhou' ("Não foi possível copiar o driver (código $rc).`n$err") 'bad')
        } else {
            Get-ChildItem $BackupDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $v } |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
        Update-Cards; Update-Home
    }
}

function Act-MarkGood {
    $g = $script:Gpu
    if (-not $g) { return }
    if ($g.Code -ne 0) { [void](Show-Dialog 'Agora não' 'A placa de vídeo está com erro. Salve o driver só quando o vídeo estiver funcionando.' 'warn'); return }
    $msg = "Guardar uma cópia do driver de vídeo $($g.Version)?`n`n•   Com a cópia salva, dá para voltar para esta versão com um clique`n•   Ocupa cerca de 1 GB e substitui o backup anterior`n`nA cópia é feita em segundo plano; pode continuar usando o PC."
    if (-not (Show-Dialog 'Fazer backup do vídeo' $msg 'ask' -YesNo -YesText 'Fazer backup')) { return }
    Save-Baseline $g
    Start-Backup $g
    if ($script:Keys.Count) { Set-KeyNormal (@($script:Keys | Where-Object { $_.Categoria -eq 'Vídeo' })[0]).Id }
    Update-Cards; Update-Home
}

# Depois de qualquer mexida no driver de vídeo, confere por 1 minuto se a placa voltou.
# Se não voltar, restaura a cópia salva sozinho. É a rede de segurança contra ficar sem vídeo.
$WdTimer = New-Object Windows.Threading.DispatcherTimer
$WdTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:WdLeft = 0
$WdTimer.add_Tick({
    $script:WdLeft--
    $g = Get-GpuInfo
    if ($g -and $g.Code -eq 0 -and $script:WdLeft -lt 55) {   # voltou sozinho antes do fim
        $WdTimer.Stop()
        Set-Verdict 'ok' 'Vídeo funcionando' 'A placa respondeu normalmente. Nada mais a fazer.'
        $Findings.Children.Clear(); Start-Scan
        return
    }
    if ($script:WdLeft -gt 0) {
        $VerdictSub.Text = 'Se a placa não voltar em {0}s, eu restauro o driver salvo. NÃO desligue o PC.' -f $script:WdLeft
        return
    }
    $WdTimer.Stop()
    if ($g -and $g.Code -ne 0) {
        Set-Verdict 'bad' 'Restaurando o driver de vídeo...' 'A placa não voltou. Restaurando a cópia salva. Não desligue o PC.'
        Act-Restore -Auto
    } else {
        Set-Verdict 'ok' 'Vídeo funcionando' 'A placa respondeu normalmente.'
        Start-Scan
    }
})

function Start-VideoWatchdog([int]$segundos = 60) {
    $b = Get-Baseline
    if (-not $b -or -not (Get-Backup $b.Version)) { return }   # sem cópia não há como socorrer
    $script:WdLeft = $segundos
    Set-Verdict 'info' 'Conferindo se o vídeo voltou' ('Se a placa não voltar em {0}s, eu restauro o driver salvo. NÃO desligue o PC.' -f $segundos)
    $Findings.Children.Clear()
    Add-Finding 'Rede de segurança ligada' 'Se a tela ficar sem aceleração ou o jogo não abrir, o HollowDrivers reinstala sozinho o driver que estava funcionando. Você pode cancelar se estiver tudo bem.' 'info' 'Cancelar' {
        $WdTimer.Stop(); Set-Verdict 'ok' 'Tudo certo' 'Rede de segurança cancelada.'; Start-Scan
    }
    $WdTimer.Start()
}

function Act-Restore {
    param([switch]$Auto)
    $b = Get-Baseline
    $bk = if ($b) { Get-Backup $b.Version } else { $null }
    if (-not $bk) { [void](Show-Dialog 'Sem backup' 'Ainda não há backup do driver de vídeo. Quando o vídeo estiver funcionando bem, use "Fazer backup".' 'warn'); return }
    $g = $script:Gpu
    $now = if ($g) { $g.Version } else { 'desconhecido' }
    $msg = "Isso vai:`n`n1.   Guardar uma cópia do driver atual, se ainda não houver`n2.   Criar um ponto de restauração do Windows`n3.   Remover o driver de vídeo atual ($now)`n4.   Instalar o driver salvo ($($bk.Version), backup de $($bk.Date))`n`nA tela vai piscar ou apagar por alguns segundos. SE A TELA APAGAR, NÃO DESLIGUE O PC: em 1 minuto eu volto o driver anterior sozinho.`n`nO Windows vai pedir permissão de administrador."
    if (-not $Auto -and -not (Show-Dialog 'Restaurar driver de vídeo' $msg 'ask' -YesNo -YesText 'Restaurar')) { return }
    $vendorRx = switch ($bk.Vendor) {
        'AMD' { 'Advanced Micro Devices|\bAMD\b|ATI Technologies' }
        'NVIDIA' { 'NVIDIA' }
        'Intel' { '\bIntel\b' }
        default { [regex]::Escape("$($bk.Vendor)") }
    }
    $script:RestoreWant = $bk.Version
    $BtnRestore.IsEnabled = $false
    Set-Verdict 'info' 'Restaurando o driver de vídeo...' 'A tela pode piscar. Não desligue o PC.'
    $Findings.Children.Clear()
    # se o vídeo atual está funcionando e ainda não tem cópia, guarda antes de trocar
    $atual = @($script:Keys | Where-Object { $_.Categoria -eq 'Vídeo' })
    if ($g -and $g.Code -ne 0) { $atual = @() }
    if ("$($bk.Inf)" -notmatch '^[\w\-\.]+\.inf$') { [void](Show-Dialog 'Backup inválido' 'O arquivo de controle do backup foi alterado. Faça o backup do driver de vídeo de novo.' 'bad'); return }
    $script:VideoRestoreArgs = @{ '__VENDOR__' = $vendorRx; '__SRC__' = $bk.Path; '__INFNAME__' = $bk.Inf; '__VER__' = $bk.Version
        '__CLASSGUID__' = '4d36e968-e325-11ce-bfc1-08002be10318'; '__DEVID__' = $g.Pnp; '__CURRENTINF__' = $g.Inf }
    Start-PreBackup $atual { Start-VideoRestoreNow }
}

function Start-VideoRestoreNow {
    Invoke-Elevated $RestoreTpl $script:VideoRestoreArgs 'restaurar' {
        param($log, $err)
        if ($err) {
            [void](Show-Dialog 'Restauração cancelada' "O Windows não deu permissão de administrador, então nada foi alterado.`n`n$err" 'warn')
            Update-Home; Update-Cards
            return
        }
        if ($log -match 'ERRO=(.+)') { [void](Show-Dialog 'Erro na restauração' $matches[1] 'bad') }
        $script:AfterRestore = $script:RestoreWant
        $script:WdDepois = $true
        Start-Scan
    }
}

function Act-Point {
    if (-not (Show-Dialog 'Ponto de restauração' "Criar um ponto de restauração do Windows agora?`n`nSe algo der errado depois (driver, programa, atualização), dá para voltar o sistema para este momento. O Windows vai pedir permissão de administrador." 'ask' -YesNo -YesText 'Criar')) { return }
    $BtnPoint.IsEnabled = $false; $BtnPoint.Content = 'Criando ponto...'
    Invoke-Elevated $PointTpl @{} 'ponto' {
        param($log, $err)
        $BtnPoint.IsEnabled = $true; $BtnPoint.Content = 'Criar ponto de restauração'
        if ($err) { [void](Show-Dialog 'Cancelado' 'O Windows não deu permissão de administrador.' 'warn'); return }
        if ($log -match 'PONTO=ok') { [void](Show-Dialog 'Ponto criado' 'Ponto de restauração criado com sucesso.' 'ok') }
        elseif ($log -match 'PONTO=aviso: (.+)') { [void](Show-Dialog 'Já existe um ponto recente' ("O Windows só cria um ponto de restauração a cada 24 horas e já existe um recente — você está protegido.`n`n" + $matches[1].Trim()) 'info') }
        elseif ($log -match 'PONTO=falhou: (.+)') { [void](Show-Dialog 'Não foi possível criar' ("A Proteção do Sistema pode estar desligada no disco C:.`nAtive em: Painel de Controle → Sistema → Proteção do Sistema.`n`nDetalhe: " + $matches[1].Trim()) 'warn') }
        else { [void](Show-Dialog 'Sem resposta' 'Não foi possível confirmar o resultado.' 'warn') }
    }
}

# ---------------------------------------------------------------- backup de TODOS os drivers (para depois de formatar)

$AllInfoFile = Join-Path $DataDir 'drivers-backup.json'
function Get-AllBackupInfo { if (Test-Path $AllInfoFile) { try { Get-Content $AllInfoFile -Raw | ConvertFrom-Json } catch { $null } } }

$AllTpl = @'
$pk = @(Get-OemPackages)
if (-not __VIDEO__) { $pk = @($pk | Where-Object { $_.Class -ne 'DISPLAY' }) }
$ok = 0; $fail = @()
foreach ($p in $pk) {
    $cat = if ($CatMap.ContainsKey($p.Class)) { $CatMap[$p.Class] } else { 'Outros' }
    $d = Join-Path (Join-Path '__DST__' ($cat -replace '[\\/:*?"<>|]', '-')) (([IO.Path]::GetFileNameWithoutExtension($p.Inf)) + ' ' + $p.Version)
    robocopy $p.Folder $d /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -lt 8) { $ok++ } else { $fail += $p.Inf }
}
[pscustomobject]@{
    Ok = $ok; Total = $pk.Count; Fail = @($fail)
    Cats = @($pk | Group-Object { if ($CatMap.ContainsKey($_.Class)) { $CatMap[$_.Class] } else { 'Outros' } } |
        Sort-Object Count -Descending | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Count })
}
'@

$AllBat = @(
    '@echo off'
    'title HollowDrivers - Reinstalar drivers'
    'net session >nul 2>&1'
    'if errorlevel 1 ('
    '  powershell -NoProfile -Command "Start-Process -FilePath ''%~f0'' -Verb RunAs"'
    '  exit /b'
    ')'
    'echo.'
    'echo  Reinstalando os drivers salvos pelo HollowDrivers.'
    'echo  (chipset, rede, Wi-Fi, audio, touchpad, teclas especiais, Bluetooth, camera...)'
    'echo.'
    'echo  Pode levar alguns minutos e a tela pode piscar. Nao desligue o PC.'
    'echo.'
    'pnputil /add-driver "%~dp0*.inf" /subdirs /install'
    'echo.'
    'echo  Pronto. REINICIE o PC para terminar.'
    'echo  Depois, confira no Windows Update se falta algo.'
    'echo.'
    'pause'
) -join "`r`n"

function Act-AllBackup {
    $si = $script:SysInfo
    $what = if ($si -and $si.IsLaptop) { 'do seu notebook' } else { 'do seu PC' }
    $msg = "Vou salvar todos os drivers de fabricante $what — chipset, rede, Wi-Fi, áudio, touchpad, teclas especiais, Bluetooth, câmera, leitor de cartão e as extensões do fabricante.`n`nDepois de formatar, é só dar dois cliques no instalador que fica junto e o Windows volta com tudo funcionando.`n`nNa próxima tela escolha onde salvar — de preferência um PENDRIVE ou uma pasta da nuvem. Se salvar só neste PC, a cópia some ao formatar."
    if (-not (Show-Dialog 'Backup de todos os drivers' $msg 'ask' -YesNo -YesText 'Continuar')) { return }

    $video = $false
    $g = $script:Gpu
    if ($g) {
        $vp = Get-DriverPackage $g.Inf $g.Version
        $vmb = if ($vp) { [math]::Round(((Get-ChildItem $vp.Folder -Recurse -File | Measure-Object Length -Sum).Sum) / 1MB) } else { 0 }
        $vmsg = "Incluir também o driver de vídeo ($($g.Name))?`n`nEle ocupa cerca de $vmb MB. Se não incluir, depois de formatar você baixa ele no site oficial (normalmente a versão mais nova é melhor)."
        $video = Show-Dialog 'Driver de vídeo' $vmsg 'ask' -YesNo -YesText "Incluir (+$vmb MB)" -NoText 'Sem vídeo'
    }

    $usb = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction SilentlyContinue | Select-Object -First 1
    $fb = New-Object Windows.Forms.FolderBrowserDialog
    $fb.Description = 'Onde salvar o backup dos drivers? (de preferência um pendrive)'
    $fb.ShowNewFolderButton = $true
    $fb.SelectedPath = $(if ($usb) { $usb.DeviceID + '\' } else { [Environment]::GetFolderPath('Desktop') })
    if ($fb.ShowDialog() -ne 'OK') { return }

    $label = if ($si -and $si.Model -and $si.Model -notmatch 'To Be Filled|System Product') { $si.Model } else { $env:COMPUTERNAME }
    $label = ($label -replace '[\\/:*?"<>|]', '').Trim()
    $dst = Join-Path $fb.SelectedPath ('HollowDrivers - Drivers ({0}) {1:yyyy-MM-dd}' -f $label, (Get-Date))
    try { New-Item -ItemType Directory -Force -Path $dst -ErrorAction Stop | Out-Null }
    catch { [void](Show-Dialog 'Não foi possível salvar' "Não consegui criar a pasta em:`n$dst`n`n$($_.Exception.Message)" 'bad'); return }

    $script:AllDst = $dst; $script:AllVideo = $video
    $BtnAll.IsEnabled = $false; $BtnAll.Content = 'Copiando drivers... (alguns minutos)'
    $script:AllBusy = $true; Update-Home
    $code = $LogicText + "`n" + (Expand-Tpl $AllTpl @{ '__DST__' = $dst; '__VIDEO__' = $(if ($video) { '$true' } else { '$false' }) })
    Start-Bg $code {
        param($out, $err)
        $script:AllBusy = $false
        $BtnAll.IsEnabled = $true; $BtnAll.Content = 'Backup de todos os drivers'
        $dst = $script:AllDst
        $r = if ($out -and $out.Count) { $out[$out.Count - 1] } else { $null }
        if ($err -or -not $r -or -not $r.Ok) {
            [void](Show-Dialog 'Backup falhou' "Não foi possível copiar os drivers.`n$err" 'bad'); Update-Home; return
        }
        [IO.File]::WriteAllText((Join-Path $dst 'REINSTALAR-DRIVERS.bat'), $AllBat, [Text.Encoding]::ASCII)
        $mb = [math]::Round(((Get-ChildItem $dst -Recurse -File | Measure-Object Length -Sum).Sum) / 1MB)
        [pscustomobject]@{ Date = (Get-Date).ToString('dd/MM/yyyy'); Path = $dst; Count = $r.Ok; Video = [bool]$script:AllVideo; SizeMB = $mb } |
            ConvertTo-Json | Set-Content $AllInfoFile -Encoding UTF8
        $drive = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $dst.Substring(0, 2)) -ErrorAction SilentlyContinue
        $warn = if ($drive -and $drive.DriveType -ne 2 -and $dst -notmatch 'OneDrive|Google Drive|Dropbox') { "`n`nAtenção: você salvou neste PC. Copie a pasta para um pendrive ou para a nuvem, senão ela some ao formatar." } else { '' }
        $failTxt = if (@($r.Fail).Count) { "`n`nNão copiados: " + (@($r.Fail) -join ', ') } else { '' }
        $cats = (@($r.Cats) | Select-Object -First 8) -join ', '
        [void](Show-Dialog 'Backup concluído' ("$($r.Ok) de $($r.Total) drivers salvos ($mb MB):`n$cats`n`nPasta:`n$dst`n`nDepois de formatar: abra a pasta e dê dois cliques em REINSTALAR-DRIVERS.bat, depois reinicie.$failTxt$warn") 'ok')
        Update-Cards; Update-Home
    }
}

# ---------------------------------------------------------------- atualização de drivers (Catálogo do Microsoft Update)

$UpdXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Atualizações de driver" Width="980" Height="520" WindowStartupLocation="CenterOwner" ShowInTaskbar="False"
        Background="{StaticResource Bg}" Foreground="{StaticResource Text}" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13">
  <Grid Margin="22,18,22,18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock x:Name="Head" FontSize="19" FontWeight="SemiBold" FontFamily="{StaticResource Display}"/>
    <TextBlock Grid.Row="1" Foreground="{StaticResource Dim}" TextWrapping="Wrap" Margin="0,6,0,0"
               Text="Drivers certificados pela Microsoft, baixados do servidor oficial do Windows Update. Antes de instalar é criado um ponto de restauração. O driver de vídeo e o firmware (BIOS) não entram aqui de propósito."/>
    <Border Grid.Row="2" Margin="0,14,0,14" Background="{StaticResource Surface}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="14" Padding="4">
      <DataGrid x:Name="G" AutoGenerateColumns="False" IsReadOnly="False">
        <DataGrid.Columns>
          <DataGridTemplateColumn Header="" Width="46">
            <DataGridTemplateColumn.CellTemplate>
              <DataTemplate><CheckBox IsChecked="{Binding Instalar, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center"/></DataTemplate>
            </DataGridTemplateColumn.CellTemplate>
          </DataGridTemplateColumn>
          <DataGridTextColumn Header="Dispositivo" Binding="{Binding Dispositivo}" Width="*" IsReadOnly="True"/>
          <DataGridTextColumn Header="Versão atual" Binding="{Binding Atual}" Width="140" IsReadOnly="True"/>
          <DataGridTextColumn Header="Nova versão" Binding="{Binding Nova}" Width="140" IsReadOnly="True"/>
          <DataGridTextColumn Header="Data" Binding="{Binding Data}" Width="95" IsReadOnly="True"/>
          <DataGridTextColumn Header="Tamanho" Binding="{Binding Tamanho}" Width="85" IsReadOnly="True"/>
        </DataGrid.Columns>
      </DataGrid>
    </Border>
    <DockPanel Grid.Row="3">
      <Button x:Name="Install" DockPanel.Dock="Right" Style="{StaticResource PillAccent}" Content="Instalar selecionados" Margin="10,0,0,0"/>
      <Button x:Name="Close" DockPanel.Dock="Right" Style="{StaticResource Pill}" Content="Agora não" Margin="0" IsCancel="True"/>
      <TextBlock x:Name="Note" Foreground="{StaticResource Dim}" VerticalAlignment="Center" TextWrapping="Wrap"/>
    </DockPanel>
  </Grid>
</Window>
'@

$script:UpdState = 'idle'; $script:Updates = @(); $script:AfterUpdate = $null

function Start-UpdateCheck {
    if ($script:UpdState -in 'checking', 'installing') { return }
    $script:UpdState = 'checking'; $script:Prog.Text = 'Consultando o Catálogo do Microsoft Update...'
    $BtnUpd.IsEnabled = $false; $BtnUpd.Content = 'Procurando atualizações...'
    Update-Home
    Start-Bg ($LogicText + "`nGet-DriverUpdates") {
        param($out, $err)
        $BtnUpd.IsEnabled = $true; $BtnUpd.Content = 'Atualizar drivers'
        $script:Updates = @($out | Where-Object { $_ })
        $script:UpdState = if ($err -and -not $script:Updates.Count) { 'error' } else { 'done' }
        $st = Get-State; $st.LastUpd = (Get-Date).ToString('o'); $st.UpdKey = (@($script:Updates.Id) -join '|'); Save-State $st
        Update-Home
    }
}

function Act-Updates {
    if ($script:UpdState -eq 'checking') { return }
    if ($script:UpdState -ne 'done') { Start-UpdateCheck; return }
    Show-UpdatesWindow
}

function Show-UpdatesWindow {
    $ups = @($script:Updates)
    if (-not $ups.Count) { [void](Show-Dialog 'Drivers em dia' 'Não há versões mais novas no Catálogo do Microsoft Update para os drivers deste PC.' 'ok'); return }
    $w = [Windows.Markup.XamlReader]::Parse($UpdXaml)
    $w.FindName('Head').Text = (Get-Plural $ups.Count 'atualização de driver disponível' 'atualizações de driver disponíveis')
    $t = New-Object Data.DataTable
    [void]$t.Columns.Add('Instalar', [bool])
    foreach ($n in 'Dispositivo', 'Atual', 'Nova', 'Data', 'Tamanho', 'Id') { [void]$t.Columns.Add($n) }
    foreach ($u in $ups) { [void]$t.Rows.Add($true, $u.Dispositivo, $u.Atual, $u.Nova, $u.Data, $u.Tamanho, $u.Id) }
    $w.FindName('G').ItemsSource = $t.DefaultView
    $w.FindName('Note').Text = 'Desmarque o que não quiser atualizar.'
    $w.FindName('Install').add_Click({ param($s, $e) [Windows.Window]::GetWindow($s).DialogResult = $true })
    $w.FindName('Close').add_Click({ param($s, $e) [Windows.Window]::GetWindow($s).Close() })
    $w.add_SourceInitialized({ param($s, $e) Set-DarkTitle $s })
    $w.Owner = $script:Win
    if (-not $w.ShowDialog()) { return }
    foreach ($v in $t.DefaultView) { $v.EndEdit() }
    $ids = @($t.Rows | Where-Object { $_['Instalar'] } | ForEach-Object { $_['Id'] })
    if (-not $ids.Count) { return }
    Start-UpdateInstall @($ups | Where-Object { $_.Id -in $ids })
}

function Start-UpdateInstall($list) {
    $mb = 0; foreach ($u in $list) { if ($u.Tamanho -match '([\d\.,]+) ([KMG])B') { $v = [double]($matches[1] -replace ',', '.'); $mb += switch ($matches[2]) { 'K' { $v / 1024 } 'G' { $v * 1024 } default { $v } } } }
    $msg = "Vou:`n`n1.   Guardar uma cópia dos drivers que estão no PC agora`n2.   Baixar {0} ({1:N0} MB) do servidor oficial da Microsoft e conferir a assinatura digital`n3.   Criar um ponto de restauração do Windows`n4.   Instalar os drivers`n`nSe a versão nova não prestar, dá para voltar pelo botão Restaurar. O Windows vai pedir permissão de administrador." -f (Get-Plural $list.Count 'driver' 'drivers'), [math]::Max(1, $mb)
    $msg += "`n`nSe alguma tela apagar durante a instalação, NÃO desligue o PC: o HollowDrivers tem cópia do driver anterior e consegue voltar."
    if (-not (Show-Dialog 'Atualizar drivers' $msg 'ask' -YesNo -YesText 'Atualizar')) { return }
    $dir = Join-Path $DataDir ('updates\{0:yyyyMMdd-HHmmss}' -f (Get-Date))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $script:UpdDir = $dir; $script:UpdList = @($list)
    $script:UpdState = 'installing'; $script:Prog.Text = 'Preparando download...'
    $BtnUpd.IsEnabled = $false; $BtnUpd.Content = 'Atualizando drivers...'
    Update-Home
    # Antes de instalar, exige um dispositivo identificavel para cada driver ja instalado.
    $devices = @()
    foreach ($u in $script:UpdList) {
        if ($u.Atual -eq 'sem driver') { continue }
        $d = Get-DeviceForHw $u.Hw
        if (-not $d -or -not $d.Inf) {
            Stop-PreBackup ('Nao foi possivel identificar o driver atual de ' + $u.Dispositivo + ' para fazer backup.')
            return
        }
        $devices += $d
    }
    Start-PreBackup $devices { Start-UpdateDownload }
}

function Start-UpdateDownload {
    $json = ConvertTo-Json -InputObject @($script:UpdList | Select-Object Id, Dispositivo) -Compress
    Start-Bg (Expand-Tpl $DlTpl @{ '__JSON__' = $json; '__DIR__' = $script:UpdDir }) {
        param($out, $err)
        $r = if ($out -and $out.Count) { $out[$out.Count - 1] } else { $null }
        $failTxt = if ($r -and @($r.Fail).Count) { "`n`nNão baixados:`n" + (@($r.Fail) -join "`n") } else { '' }
        if ($err -or -not $r -or -not @($r.Ok).Count) {
            $script:UpdState = 'done'; $BtnUpd.IsEnabled = $true; $BtnUpd.Content = 'Atualizar drivers'
            [void](Show-Dialog 'Download falhou' ("Nenhum driver foi baixado, então nada foi alterado.$failTxt`n$err") 'bad')
            Update-Home; return
        }
        $script:UpdFailTxt = $failTxt
        $script:Prog.Text = 'Instalando (aceite a permissão de administrador)...'
        $pins = ConvertTo-Json -InputObject @($r.Pins | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Files = @($_.Files | ForEach-Object { [pscustomobject]@{ P = $_.P; H = $_.H } }) } }) -Compress -Depth 5
        Invoke-Elevated $UpdTpl @{ '__DIR__' = $script:UpdDir; '__PINS__' = $pins } 'atualizar' {
            param($log, $err)
            $BtnUpd.IsEnabled = $true; $BtnUpd.Content = 'Atualizar drivers'
            $script:UpdState = 'done'
            if ($err) {
                [void](Show-Dialog 'Atualização cancelada' "O Windows não deu permissão de administrador, então nada foi instalado.`n`n$err" 'warn')
                Update-Home; return
            }
            $script:UpdLog = $log
            $script:AfterUpdate = $script:UpdList
            Start-Scan
        }
    }
}

# Depois de instalar: confere na análise nova quais drivers realmente mudaram de versão.
function Show-UpdateResult($rows) {
    $list = $script:AfterUpdate; $script:AfterUpdate = $null
    $okN = @(); $keep = @()
    foreach ($u in $list) {
        if ($rows | Where-Object { $_.Dispositivo -eq $u.Dispositivo -and $_.Versao -eq $u.Nova }) { $okN += $u.Dispositivo } else { $keep += $u.Dispositivo }
    }
    Remove-Item $script:UpdDir -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $okN.Count -and $script:UpdLog -match 'RC=259' -and $script:UpdLog -notmatch 'RC=(?!259)\d+') {
        Remove-Item $script:UpdDir -Recurse -Force -ErrorAction SilentlyContinue
        [void](Show-Dialog 'Seus drivers já eram os melhores' "O Windows comparou e manteve os drivers que você já tinha, porque eles são mais recentes que os do catálogo. Nada foi trocado e não precisa reiniciar.`n`nOs pacotes baixados foram removidos." 'ok')
        $script:Updates = @(); Start-UpdateCheck
        return
    }
    $txt = if ($okN.Count) { "Atualizados:`n•   " + ($okN -join "`n•   ") } else { 'Nenhum driver mudou de versão.' }
    if ($keep.Count) { $txt += "`n`nSem mudança por enquanto (o Windows pode aplicar depois de reiniciar, ou manteve a versão atual por ser a mais adequada):`n•   " + ($keep -join "`n•   ") }
    $txt += "`n`nReinicie o PC para concluir. Se algo der errado, use o ponto de restauração criado agora.$($script:UpdFailTxt)"
    [void](Show-Dialog $(if ($okN.Count) { 'Drivers atualizados' } else { 'Atualização concluída' }) $txt $(if ($okN.Count) { 'ok' } else { 'warn' }))
    $script:Updates = @()
    Start-UpdateCheck
}

# ---------------------------------------------------------------- atualização do próprio HollowDrivers

$script:AppUpd = $null
function Start-AppUpdateCheck([bool]$manual) {
    if ($manual) { $BtnAppCheck.IsEnabled = $false; $BtnAppCheck.Content = 'Procurando...' }
    Start-Bg ($LogicText + "`nGet-AppUpdate '$UpdateRepo' '$AppVersion'") {
        param($out, $err)
        $BtnAppCheck.IsEnabled = $true; $BtnAppCheck.Content = 'Procurar atualização'
        $script:AppUpd = if ($out -and $out.Count) { $out[$out.Count - 1] } else { $null }
        $script:AppChecked = $true
        if ($script:AppUpd) { $FooterText.Text = "HollowDrivers $AppVersion  •  versão $($script:AppUpd.Version) disponível em Configurações" }
        Update-ConfigCard
    }
}

# Baixa a versão nova e confere a assinatura RSA com a chave pública embutida no app.
$AppDlTpl = @'
$ProgressPreference = 'SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol = 'Tls12'
Invoke-WebRequest -UseBasicParsing -Uri '__URL__' -OutFile '__OUT__' -TimeoutSec 300
$raw = (Invoke-WebRequest -UseBasicParsing -Uri '__SIGURL__' -TimeoutSec 60).Content
if ($raw -is [byte[]]) { $raw = [Text.Encoding]::ASCII.GetString($raw) }   # o GitHub entrega como binário
$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
$rsa.PersistKeyInCsp = $false
$rsa.FromXmlString('__PUB__')
$ok = $false
try { $ok = $rsa.VerifyData([IO.File]::ReadAllBytes('__OUT__'), 'SHA256', [Convert]::FromBase64String($raw.Trim())) } catch { }
if (-not $ok) { [IO.File]::Delete('__OUT__'); throw 'a versão baixada NÃO tem a assinatura oficial do HollowDrivers e foi descartada' }
'ok'
'@

function Update-WuCard {
    $w = $script:Wu
    $WuText.Inlines.Clear(); $SrText.Inlines.Clear()
    if (-not $w) {
        Add-Line $WuText 'Lendo as configurações do Windows Update...' $Hex.info 13
        Add-Line $SrText 'Lendo a proteção do sistema...' $Hex.info 13
        return
    }
    if ($w.Pausado) {
        Add-Line $WuText ('Atualizações seguradas até {0:dd/MM/yyyy}' -f $w.PausadoAte) $Hex.ok 15 $true
    } else {
        Add-Line $WuText 'Atualizações liberadas (o Windows instala quando quiser)' '#E8EAED' 15 $true
    }
    Add-Line $WuText $(if ($w.SemAuto) { '●  Download e instalação automáticos: desligados' } else { '●  Download e instalação automáticos: ligados' }) $(if ($w.SemAuto) { $Hex.ok } else { $Hex.info }) 13
    Add-Line $WuText $(if ($w.SemDriver) { '●  O Windows NÃO pode trocar seus drivers' } else { '●  O Windows pode trocar seus drivers sozinho' }) $(if ($w.SemDriver) { $Hex.ok } else { $Hex.warn }) 13
    $keep = (Get-State).WuHold -and (Test-WuTask)
    Add-Line $WuText $(if ($keep) { '●  Manter segurado: ligado — se algo liberar, o HollowDrivers segura de novo' } else { '●  Manter segurado: desligado — a pausa do Windows vence sozinha em 35 dias' }) $(if ($keep) { $Hex.ok } else { $Hex.info }) 12.5
    Add-Line $WuText 'Segurar atualização é para investigar problema, não para sempre: correção de segurança também para de chegar.' $Hex.info 12.5
    $BtnWuHold.Content = $(if ($w.Pausado) { 'Liberar atualizações' } else { 'Segurar atualizações' })
    $BtnWuDrv.Content = $(if ($w.SemDriver) { 'Deixar o Windows trocar drivers' } else { 'Bloquear troca de drivers' })
    $BtnWuKeep.Content = $(if ($keep) { 'Manter segurado: ligado' } else { 'Manter segurado: desligado' })
    $BtnWuKeep.Foreground = Get-Brush $(if ($keep) { $Hex.ok } else { $Hex.info })

    if ($null -eq $w.Pontos) {
        Add-Line $SrText 'Pontos de restauração: precisa de permissão de administrador para listar' $Hex.info 15 $true
    } elseif ($w.Pontos) {
        Add-Line $SrText (Get-Plural $w.Pontos 'backup do Windows guardado' 'backups do Windows guardados') $Hex.ok 15 $true
        if ($w.UltimoPonto) { Add-Line $SrText ('Último: {0:dd/MM/yyyy HH:mm}' -f $w.UltimoPonto) '#C9CED6' 13 }
    } else {
        Add-Line $SrText 'Nenhum backup do Windows guardado' $Hex.warn 15 $true
    }
    Add-Line $SrText $(if ($w.SrLigada) { '●  Proteção do sistema: ligada' } else { '●  Proteção do sistema: DESLIGADA — o Windows não guarda nada para voltar' }) $(if ($w.SrLigada) { $Hex.ok } else { $Hex.bad }) 13
    Add-Line $SrText 'O ponto de restauração volta drivers, programas e configurações do Windows. Seus arquivos pessoais não são tocados.' $Hex.info 12.5
}

function Start-WuCheck {
    Start-Bg ($LogicText + "`nGet-WuState") {
        param($out, $err)
        $script:Wu = if ($out -and $out.Count) { $out[$out.Count - 1] } else { $null }
        Update-WuCard
    }
}

function Act-WuHold {
    $ligar = -not ($script:Wu -and $script:Wu.Pausado)
    $msg = if ($ligar) {
        "Segurar as atualizações do Windows por 35 dias (o máximo que o Windows permite)?`n`n" +
        "•   Ele para de baixar e instalar sozinho`n" +
        "•   Você continua podendo atualizar na mão quando quiser`n" +
        "•   Serve para descobrir se uma atualização é a causa de um problema`n`n" +
        "Correções de segurança também ficam de fora nesse período."
    } else {
        "Liberar as atualizações do Windows de novo?`n`nEle volta a baixar e instalar normalmente."
    }
    if (-not (Show-Dialog $(if ($ligar) { 'Segurar atualizações do Windows?' } else { 'Liberar atualizações?' }) $msg 'ask' -YesNo -YesText $(if ($ligar) { 'Segurar' } else { 'Liberar' }))) { return }
    $BtnWuHold.IsEnabled = $false
    Invoke-Elevated $WuTpl @{ '__HOLD__' = $(if ($ligar) { '1' } else { '0' }); '__DRV__' = ''; '__SR__' = ''; '__DESC__' = '' } 'windows' {
        param($log, $err)
        $BtnWuHold.IsEnabled = $true
        if ($err) { [void](Show-Dialog 'Cancelado' 'O Windows não deu permissão de administrador, então nada mudou.' 'warn'); return }
        if ($log -match 'ERRO=(.+)') { [void](Show-Dialog 'Não foi possível' $matches[1] 'bad'); return }
        if ($log -match 'HOLD=1') { [void](Show-Dialog 'Atualizações seguradas' 'O Windows não vai mais baixar nem instalar sozinho pelos próximos 35 dias.' 'ok') }
        else { [void](Show-Dialog 'Atualizações liberadas' 'O Windows voltou ao comportamento normal.' 'ok') }
        Start-WuCheck
    }
}

function Act-WuDrv {
    $ligar = -not ($script:Wu -and $script:Wu.SemDriver)
    $msg = if ($ligar) {
        "Impedir o Windows Update de instalar drivers?`n`nAs correções de segurança continuam chegando normalmente — só a troca automática de driver (vídeo, chipset, rede) fica bloqueada.`n`nÉ o ajuste que evita o Windows trocar o driver da sua placa de vídeo sem avisar."
    } else {
        "Deixar o Windows Update instalar drivers de novo?`n`nEle volta a poder trocar driver de vídeo e outros sozinho."
    }
    if (-not (Show-Dialog 'Drivers pelo Windows Update' $msg 'ask' -YesNo -YesText $(if ($ligar) { 'Bloquear' } else { 'Liberar' }))) { return }
    $BtnWuDrv.IsEnabled = $false
    Invoke-Elevated $WuTpl @{ '__HOLD__' = ''; '__DRV__' = $(if ($ligar) { '1' } else { '0' }); '__SR__' = ''; '__DESC__' = '' } 'windows' {
        param($log, $err)
        $BtnWuDrv.IsEnabled = $true
        if ($err) { [void](Show-Dialog 'Cancelado' 'O Windows não deu permissão de administrador, então nada mudou.' 'warn'); return }
        if ($log -match 'ERRO=(.+)') { [void](Show-Dialog 'Não foi possível' $matches[1] 'bad'); return }
        Start-WuCheck
    }
}

function Act-WuKeep {
    $st = Get-State
    $ligar = -not ($st.WuHold -and (Test-WuTask))
    if ($ligar) {
        $msg = "Manter as atualizações seguradas mesmo depois?`n`n" +
            "A pausa do Windows vence sozinha em 35 dias, e uma atualização grande pode religar tudo. Com isto ligado, o HollowDrivers confere ao ligar o PC e uma vez por dia — se estiver liberado, segura de novo.`n`n" +
            "Para isso é criada uma tarefa do Windows. Ela só faz isso e nada mais. O Windows vai pedir permissão de administrador agora."
        if (-not (Show-Dialog 'Manter segurado?' $msg 'ask' -YesNo -YesText 'Ligar')) { return }
    } else {
        if (-not (Show-Dialog 'Parar de manter segurado?' "A pausa atual continua valendo até vencer, mas o HollowDrivers não vai mais renovar." 'ask' -YesNo -YesText 'Desligar')) { return }
    }
    $run = if (Test-Path $Exe) { $Exe } else { 'powershell.exe' }
    $args = if (Test-Path $Exe) { '-HoldWU' } else { '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -HoldWU' -f $ScriptPath }
    $BtnWuKeep.IsEnabled = $false
    Invoke-Elevated $TaskTpl @{ '__ON__' = $(if ($ligar) { '1' } else { '0' }); '__TASK__' = $WuTask; '__DAILY__' = '1'
        '__RUN__' = $run; '__ARGS__' = $args; '__USER__' = "$env:USERDOMAIN\$env:USERNAME" } 'tarefa' {
        param($log, $err)
        $BtnWuKeep.IsEnabled = $true
        if ($err) { [void](Show-Dialog 'Cancelado' 'O Windows não deu permissão de administrador, então nada mudou.' 'warn'); return }
        if ($log -match 'ERRO=(.+)') { [void](Show-Dialog 'Não foi possível' $matches[1] 'bad'); return }
        $st = Get-State; $st.WuHold = [bool]($log -match 'TAREFA=criada'); Save-State $st
        Update-WuCard
        if ($st.WuHold -and -not ($script:Wu -and $script:Wu.Pausado)) { Act-WuHold }
    }
}

function Act-SrPoint {
    $msg = "Salvar um backup do Windows agora (ponto de restauração)?`n`n" +
        "•   Guarda drivers, programas e configurações do jeito que estão hoje`n" +
        "•   Se uma atualização ou driver quebrar o PC, dá para voltar para este momento`n" +
        "•   Seus arquivos pessoais não entram e não são alterados`n`n" +
        "Se a Proteção do Sistema estiver desligada, ela é ligada antes. O Windows vai pedir permissão de administrador."
    if (-not (Show-Dialog 'Salvar backup do Windows?' $msg 'ask' -YesNo -YesText 'Salvar')) { return }
    $BtnSrPoint.IsEnabled = $false; $BtnSrPoint.Content = 'Salvando...'
    Invoke-Elevated $WuTpl @{ '__HOLD__' = ''; '__DRV__' = ''; '__SR__' = '1'
        '__DESC__' = ('HollowDrivers {0:dd/MM/yyyy HH:mm}' -f (Get-Date)) } 'windows' {
        param($log, $err)
        $BtnSrPoint.IsEnabled = $true; $BtnSrPoint.Content = 'Salvar backup do Windows'
        if ($err) { [void](Show-Dialog 'Cancelado' 'O Windows não deu permissão de administrador, então nada mudou.' 'warn'); return }
        if ($log -match 'PONTO=ok') { [void](Show-Dialog 'Backup salvo' 'Ponto de restauração criado. Se algo quebrar o PC, use "Restaurar o Windows" e escolha este ponto.' 'ok') }
        elseif ($log -match 'PONTO=aviso: (.+)') { [void](Show-Dialog 'Já existe um recente' ("O Windows só cria um ponto a cada 24 horas e já existe um recente — você está protegido.`n`n" + $matches[1].Trim()) 'info') }
        elseif ($log -match 'PONTO=falhou: (.+)') { [void](Show-Dialog 'Não foi possível' ("Detalhe: " + $matches[1].Trim()) 'warn') }
        else { [void](Show-Dialog 'Sem resposta' 'Não foi possível confirmar o resultado.' 'warn') }
        Start-WuCheck
    }
}

function Update-StorageInfo {
    try {
        $root = [IO.Path]::GetPathRoot($env:SystemRoot)
        $drive = New-Object IO.DriveInfo $root
        if (-not $drive.IsReady) { throw 'unavailable' }
        $StorageText.Text = '{0:N1} GB livres de {1:N1} GB em {2}' -f ($drive.AvailableFreeSpace / 1GB), ($drive.TotalSize / 1GB), $drive.Name.TrimEnd('\')
    } catch {
        $StorageText.Text = 'Espaço livre indisponível'
    }
}

function Open-StorageSettings([string]$page) {
    try { Start-Process -FilePath $page -ErrorAction Stop }
    catch { [void](Show-Dialog 'Não foi possível abrir' 'Abra Configurações do Windows > Sistema > Armazenamento.' 'warn') }
}
function Act-SrOpen {
    if (-not (Show-Dialog 'Restaurar o Windows' "Vou abrir a Restauração do Sistema do Windows.`n`nLá você escolhe um dos pontos salvos e o PC reinicia para voltar àquele momento. Drivers, programas e configurações voltam; seus arquivos pessoais ficam como estão." 'ask' -YesNo -YesText 'Abrir')) { return }
    try { Start-Process 'rstrui.exe' } catch { [void](Show-Dialog 'Não foi possível abrir' $_.Exception.Message 'bad') }
}

function Update-ConfigCard {
    $ConfigUpd.Inlines.Clear()
    Add-Line $ConfigUpd ("Versão instalada: {0}" -f $AppVersion) '#E8EAED' 15 $true
    if ($script:AppUpd) {
        Add-Line $ConfigUpd ('Versão {0} disponível ({1} MB)' -f $script:AppUpd.Version, $script:AppUpd.SizeMB) $Hex.warn 13.5 $true
        if ($script:AppUpd.Notes) { Add-Line $ConfigUpd $script:AppUpd.Notes '#C9CED6' 12.5 }
        $BtnAppInstall.Visibility = 'Visible'
    } else {
        Add-Line $ConfigUpd $(if ($script:AppChecked) { 'Nenhuma versão nova por enquanto.' } else { 'Clique em "Procurar atualização" para verificar agora.' }) $(if ($script:AppChecked) { $Hex.ok } else { $Hex.info }) 13
        $BtnAppInstall.Visibility = 'Collapsed'
    }
    Add-Line $ConfigUpd 'O app também verifica sozinho ao abrir e uma vez por dia.' $Hex.info 12.5
}

function Act-AppUpdate {
    $u = $script:AppUpd
    if (-not $u) { return }
    $msg = "Atualizar o HollowDrivers de $AppVersion para $($u.Version)?`n`nO app vai fechar, atualizar e abrir de novo sozinho em alguns segundos. Seu backup e suas configurações são mantidos."
    if ($u.Notes) { $msg += "`n`nNovidades:`n" + $u.Notes }
    if (-not (Show-Dialog 'Atualizar HollowDrivers' $msg 'ask' -YesNo -YesText 'Atualizar')) { return }
    $script:AppSetup = Join-Path $env:TEMP "HollowDrivers-Setup-$($u.Version).exe"
    $FooterText.Text = "Baixando HollowDrivers $($u.Version)..."
    $code = Expand-Tpl $AppDlTpl @{ '__URL__' = $u.Url; '__SIGURL__' = $u.SigUrl; '__OUT__' = $script:AppSetup; '__PUB__' = $UpdatePubKey }
    Start-Bg $code {
        param($out, $err)
        if ($err -or -not $out -or "$($out[$out.Count - 1])" -ne 'ok') {
            $FooterText.Text = "HollowDrivers $AppVersion"
            [void](Show-Dialog 'Atualização falhou' "Não foi possível baixar a versão nova. Nada foi alterado.`n`n$err" 'bad')
            return
        }
        Start-Process $script:AppSetup -ArgumentList '/silent'
        $app.Shutdown()
    }
}

# ---------------------------------------------------------------- temas de cores


function Add-ThemeCards($panel) {
    foreach ($k in $Themes.Keys) {
        $t = $Themes[$k]
        $card = New-Object Windows.Controls.Border
        $card.Width = 136; $card.Margin = '0,0,12,12'; $card.Padding = '10,14'; $card.CornerRadius = 12; $card.Cursor = 'Hand'
        $card.Background = Get-Brush '#1F232C'; $card.BorderThickness = 2; $card.Tag = $k
        $card.BorderBrush = Get-Brush $(if ($k -eq $ThemeKey) { $t.A1 } else { '#2A2F3A' })
        $sp = New-Object Windows.Controls.StackPanel
        $el = New-Object Windows.Shapes.Ellipse
        $el.Width = 48; $el.Height = 48; $el.Margin = '0,0,0,8'
        $el.Fill = New-Object Windows.Media.LinearGradientBrush(([Windows.Media.ColorConverter]::ConvertFromString($t.A1)), ([Windows.Media.ColorConverter]::ConvertFromString($t.A2)), 45)
        $tb = New-Object Windows.Controls.TextBlock
        $tb.Text = $(if ($k -eq $ThemeKey) { "$($t.Nome)  ✓" } else { $t.Nome }); $tb.HorizontalAlignment = 'Center'; $tb.FontSize = 13
        [void]$sp.Children.Add($el); [void]$sp.Children.Add($tb)
        $card.Child = $sp
        # MouseLeftButtonDown + Handled: senão o "arrastar janela" engole o clique
        $card.add_MouseLeftButtonDown({ param($s, $e)
            $e.Handled = $true
            if ($s.Tag -eq $ThemeKey) { return }
            $st = Get-Settings; $st.Theme = $s.Tag; Save-Settings $st
            Start-Launcher ''
            $app.Shutdown()
        })
        [void]$panel.Children.Add($card)
    }
}

function Act-EnableGpu {
    $g = $script:Gpu
    if (-not $g -or -not $g.Pnp) { return }
    $msg = "A placa está DESABILITADA no Windows (código 22) — o driver está instalado, só o dispositivo está desligado.`n`n" +
        "O HollowDrivers vai ligar o dispositivo de novo. A tela pode piscar por um instante.`n`n" +
        "O Windows vai pedir permissão de administrador."
    if (-not (Show-Dialog 'Reativar a placa de vídeo?' $msg 'ask' -YesNo -YesText 'Reativar')) { return }
    $BtnEnable.IsEnabled = $false
    Invoke-Elevated $EnableTpl @{ '__PNP__' = $g.Pnp } 'reativar' {
        param($log, $err)
        $BtnEnable.IsEnabled = $true
        if ($err) { [void](Show-Dialog 'Cancelado' 'O Windows não deu permissão de administrador, então nada mudou.' 'warn'); return }
        if ($log -match 'ERRO=(.+)') { [void](Show-Dialog 'Não foi possível' $matches[1] 'bad'); return }
        $depois = if ($log -match 'DEPOIS=([^\r\n]+)') { $matches[1].Trim() } else { '' }
        if ($depois -match 'OK/CM_PROB_NONE') {
            [void](Show-Dialog 'Placa reativada' 'A placa de vídeo voltou a funcionar. Analise de novo para confirmar.' 'ok')
        } else {
            $extra = if ($log -match 'PNPUTIL=([^\r\n]+)') { "`n`n" + $matches[1].Trim() } else { '' }
            [void](Show-Dialog 'Ainda desabilitada' ("O Windows aceitou o comando, mas a placa continua desligada ($depois).`n`nIsso costuma exigir reinício: reinicie o PC e analise de novo." + $extra) 'warn')
        }
        Start-Scan
    }
}

function Act-Reboot {
    $quais = ($script:NeedReboot | Select-Object -First 4 -Expand Dispositivo) -join "`n•   "
    if (-not (Show-Dialog 'Reiniciar o PC agora?' ("Estes drivers só entram em funcionamento depois do reinício:`n`n•   $quais`n`nSalve o que estiver aberto antes de continuar.") 'ask' -YesNo -YesText 'Reiniciar')) { return }
    try { Restart-Computer -Force -ErrorAction Stop } catch { [void](Show-Dialog 'Não foi possível' $_.Exception.Message 'bad') }
}

function Act-History {
    $rows = @($script:History | ForEach-Object {
        [pscustomobject]@{ Quando = $_.Quando.ToString('dd/MM/yyyy HH:mm'); Origem = $_.Origem; Detalhe = $_.Detalhe; Destaque = ($_.Origem -like 'Driver Booster*') }
    })
    if (-not $rows.Count) { [void](Show-Dialog 'Histórico' 'Nenhuma instalação de driver de vídeo encontrada nos registros do Windows.' 'info'); return }
    Show-TableWindow 'Quem instalou driver na placa de vídeo' $rows 'Fonte: registros de instalação do Windows. Em vermelho: trocas feitas pelo Driver Booster.'
}

function Act-Crashes {
    $list = @(Get-CrashList 90)
    if (-not $list.Count) { [void](Show-Dialog 'Quedas do PC' 'Nenhuma queda inesperada nos últimos 90 dias.' 'ok'); return }
    $sudden = @($list | Where-Object { $_.Tipo -like 'Desligou de repente*' }).Count
    $madrugada = @($list | Where-Object { $_.Quando.Hour -lt 6 }).Count
    $sozinho = @($list | Where-Object { $_.Sozinho }).Count
    $rows = $list | ForEach-Object {
        [pscustomobject]@{
            Quando = $_.Quando.ToString('dd/MM/yyyy HH:mm (ddd)'); Tipo = $_.Tipo; Estado = $_.Estado
            'Ficou desligado' = $_.Desligado
            Destaque = ($_.Tipo -like 'Desligou de repente*')
        }
    }
    $note = '{0} em 90 dias  •  {1} sem erro registrado  •  {2} de madrugada  •  {3} voltaram sozinhas' -f (Get-Plural $list.Count 'queda' 'quedas'), $sudden, $madrugada, $sozinho
    if ($sozinho -eq 0 -and $sudden -ge [Math]::Ceiling($list.Count / 2)) {
        $note += "`nO PC ficou horas desligado depois de cada queda e não voltou sozinho: isso combina tanto com falta de luz quanto com problema na fonte. Veja no seu roteador se ele reiniciou nos mesmos horários — se sim, foi a rede elétrica."
    } elseif ($sozinho) {
        $note += "`nAs que voltaram na hora não são falta de luz (nesse caso o PC ficaria desligado): são travamento ou falha do próprio PC."
    }
    Show-TableWindow 'Quedas do PC — últimos 90 dias' $rows $note
}

function Act-Wu {
    $BtnWu.IsEnabled = $false; $BtnWu.Content = 'Consultando Windows Update...'
    Start-Bg $WuCode {
        param($out, $err)
        $BtnWu.IsEnabled = $true; $BtnWu.Content = 'Windows Update'
        $res = @($out | Where-Object { $_ })
        if ($err -and -not $res.Count) { [void](Show-Dialog 'Windows Update' "Não foi possível consultar o Windows Update.`n`n$err" 'warn') }
        elseif (-not $res.Count) { [void](Show-Dialog 'Windows Update' "Nenhuma atualização de driver oferecida pelo Windows Update.`n`nSe você bloqueou drivers pelo Windows Update (recomendado para placas de vídeo), isso é o esperado." 'ok') }
        else { Show-TableWindow 'Atualizações de driver no Windows Update' $res 'Somente leitura — nada foi instalado. Para vídeo, prefira sempre o instalador oficial do fabricante.' }
    }
}

function Act-Csv {
    $path = Join-Path ([Environment]::GetFolderPath('Desktop')) ('HollowDrivers-{0:yyyyMMdd-HHmm}.csv' -f (Get-Date))
    $dt.DefaultView.ToTable() |
        Select-Object Status, Categoria, Dispositivo, Fabricante, @{ n = 'Versão'; e = { $_.Versao } },
            @{ n = 'Data'; e = { if ($_.Data -is [datetime]) { $_.Data.ToString('dd/MM/yyyy') } } }, @{ n = 'Idade (anos)'; e = { $_.Idade } }, INF |
        Export-Csv $path -NoTypeInformation -Delimiter ';' -Encoding UTF8
    Set-Status 'relatório salvo na Área de Trabalho'
}

$TaskTpl = @'
try {
    if ('__ON__' -eq '1') {
        $a = New-ScheduledTaskAction -Execute '__RUN__' -Argument '__ARGS__'
        $t = @(New-ScheduledTaskTrigger -AtLogOn -User '__USER__')
        if ('__DAILY__' -eq '1') { $t += New-ScheduledTaskTrigger -Daily -At '12:00' }
        $p = New-ScheduledTaskPrincipal -UserId '__USER__' -RunLevel Highest -LogonType Interactive
        $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
        Register-ScheduledTask -TaskName '__TASK__' -Description 'HollowDrivers' -Action $a -Trigger $t -Principal $p -Settings $s -Force | Out-Null
        W 'TAREFA=criada'
    } else {
        Unregister-ScheduledTask -TaskName '__TASK__' -Confirm:$false -ErrorAction Stop
        W 'TAREFA=removida'
    }
} catch { W ('ERRO=' + $_.Exception.Message) }
finally { Save-Log }
'@

function Act-Rescue {
    if (Test-RescueTask) {
        if (-not (Show-Dialog 'Socorro automático' 'Desligar o socorro automático? O HollowDrivers vai voltar a pedir sua confirmação para restaurar o vídeo.' 'ask' -YesNo -YesText 'Desligar')) { return }
        $ligar = $false
    } else {
        $msg = "Criar uma tarefa do Windows que, ao ligar o PC, restaura o driver de vídeo salvo SE a placa estiver com erro?`n`n" +
            "•   Roda só no logon, e só faz isso: reinstalar uma cópia sua já conferida`n" +
            "•   Uma tentativa por inicialização, com registro do que fez`n" +
            "•   Não instala driver novo nem mexe em mais nada`n`n" +
            "É o que permite voltar o vídeo SEM pedir permissão na hora do aperto. Para criar a tarefa, o Windows vai pedir permissão de administrador agora."
        if (-not (Show-Dialog 'Ligar socorro automático?' $msg 'ask' -YesNo -YesText 'Ligar')) { return }
        $ligar = $true
    }
    $run = if (Test-Path $Exe) { $Exe } else { 'powershell.exe' }
    $args = if (Test-Path $Exe) { '-AutoRescue' } else { '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -AutoRescue' -f $ScriptPath }
    $BtnRescue.IsEnabled = $false
    Invoke-Elevated $TaskTpl @{ '__ON__' = $(if ($ligar) { '1' } else { '0' }); '__TASK__' = $RescueTask; '__DAILY__' = '0'
        '__RUN__' = $run; '__ARGS__' = $args; '__USER__' = "$env:USERDOMAIN\$env:USERNAME" } 'tarefa' {
        param($log, $err)
        $BtnRescue.IsEnabled = $true
        if ($err) { [void](Show-Dialog 'Cancelado' 'O Windows não deu permissão de administrador, então nada mudou.' 'warn') }
        elseif ($log -match 'ERRO=(.+)') { [void](Show-Dialog 'Não foi possível' $matches[1] 'bad') }
        elseif ($log -match 'TAREFA=criada') { [void](Show-Dialog 'Socorro automático ligado' "Se a placa de vídeo quebrar, o HollowDrivers restaura o driver salvo sozinho ao ligar o PC, sem pedir nada.`n`nVocê pode desligar isso quando quiser." 'ok') }
        else { [void](Show-Dialog 'Socorro automático desligado' 'A tarefa foi removida.' 'ok') }
        Update-RescueButton; Update-Cards
    }
}

function Update-RescueButton {
    if (Test-RescueTask) { $BtnRescue.Content = 'Socorro automático: ligado'; $BtnRescue.Foreground = Get-Brush $Hex.ok }
    else { $BtnRescue.Content = 'Socorro automático: desligado'; $BtnRescue.Foreground = Get-Brush $Hex.info }
}

function Act-Watch {
    if (Test-WatchEnabled) {
        if (Show-Dialog 'Proteção automática' 'Desligar a proteção automática? O escudo perto do relógio vai sumir.' 'ask' -YesNo -YesText 'Desligar') {
            Set-WatchEnabled $false; Stop-Tray
        }
    } else {
        $msg = "Um escudo fica perto do relógio (verde = tudo certo, vermelho = atenção). O HollowDrivers confere seu PC ao ligar e a cada hora, e só avisa se:`n`n•   o driver de vídeo foi trocado`n•   a placa de vídeo está com erro`n•   o PC caiu desde a última vez`n•   o Driver Booster voltou`n`nNão instala nada. Dá para desligar quando quiser."
        if (Show-Dialog 'Ligar proteção automática?' $msg 'ask' -YesNo -YesText 'Ligar') {
            Set-WatchEnabled $true
            $st = Get-State; $st.LastCheck = (Get-Date).ToString('o'); Save-State $st
            Start-Launcher '-Watch'
        }
    }
    Update-WatchButton; Update-Home
}

function Act-RemoveDb {
    $db = @($script:Health.DriverBooster)[0]
    if (-not $db) { return }
    $exe = $null; $arg = ''
    if ($db.Uninstall -match '^"([^"]+)"\s*(.*)$') { $exe = $matches[1]; $arg = $matches[2] }
    elseif ($db.Uninstall) { $exe = $db.Uninstall }
    if (-not $exe -or -not (Test-Path $exe)) {
        $u = if ($db.Path) { Get-ChildItem $db.Path -Filter 'unins*.exe' -Recurse -Depth 1 -ErrorAction SilentlyContinue | Select-Object -First 1 }
        if ($u) { $exe = $u.FullName; $arg = '' } else { $exe = $null }
    }
    if (-not $exe) { [void](Show-Dialog 'Desinstalador não encontrado' 'Remova pelo Windows: Configurações → Apps → Driver Booster.' 'warn'); return }
    $BtnDb.IsEnabled = $false
    $code = if ($arg) { "Start-Process '{0}' -ArgumentList '{1}' -Wait" -f $exe.Replace("'", "''"), $arg.Replace("'", "''") } else { "Start-Process '{0}' -Wait" -f $exe.Replace("'", "''") }
    Start-Bg $code { param($o, $e) $BtnDb.IsEnabled = $true; Start-Scan }
}

# ---------------------------------------------------------------- eventos

$BigBtn.add_Click({ Start-Scan })
$BtnAdvanced.add_Click({ Show-View $true })
$BtnHomeScan.add_Click({ Start-Scan })
$BtnHomeConfig.add_Click({ Show-Config $true })

$BtnBack.add_Click({ Show-View $false })
$BtnScan.add_Click({ Start-Scan })
$BtnGood.add_Click({ Act-MarkGood })
$BtnUpd.add_Click({ Act-Updates })
$BtnRestore.add_Click({ Act-Restore })
$BtnPoint.add_Click({ Act-Point })
$BtnAll.add_Click({ Act-AllBackup })
$BtnHist.add_Click({ Act-History })
$BtnEnable.add_Click({ Act-EnableGpu })
$BtnCrash.add_Click({ Act-Crashes })
$BtnWu.add_Click({ Act-Wu })
$BtnSites.add_Click({ $SitesPopup.IsOpen = -not $SitesPopup.IsOpen })
$BtnCsv.add_Click({ Act-Csv })
$BtnWatch.add_Click({ Act-Watch })
$BtnRescue.add_Click({ Act-Rescue })
$BtnDb.add_Click({ Act-RemoveDb })
$SearchBox.add_TextChanged({ Update-Filter })
$ChkMs.add_Checked({ Update-Filter })
$ChkMs.add_Unchecked({ Update-Filter })
foreach ($n in $ChipNames) { (Get-Variable $n -Scope Script -ValueOnly).add_Click({ param($s, $e) Set-Chip $s }) }
$NavDrivers.add_Click({ Show-Section 'drivers' })
$NavVideo.add_Click({ Show-Section 'video' })
$NavSystem.add_Click({ Show-Section 'sistema'; Update-StorageInfo })
$NavGuard.add_Click({ Show-Section 'protecao' })
$NavWin.add_Click({ Show-Section 'windows'; Start-WuCheck })

$BtnConfigClose.add_Click({ Show-Config $false })
$BtnWuHold.add_Click({ Act-WuHold })
$BtnWuKeep.add_Click({ Act-WuKeep })
$BtnWuDrv.add_Click({ Act-WuDrv })
$BtnSrPoint.add_Click({ Act-SrPoint })
$BtnSrOpen.add_Click({ Act-SrOpen })
$BtnCleanup.add_Click({
    $page = if ([Environment]::OSVersion.Version.Build -ge 22000) { 'ms-settings:storagerecommendations' } else { 'ms-settings:storagesense' }
    Open-StorageSettings $page
})
$BtnStorageSense.add_Click({ Open-StorageSettings 'ms-settings:storagepolicies' })
$BtnRailHome.add_Click({ Set-Rail (-not $script:RailOpen) })
$BtnRailAdv.add_Click({ Set-Rail (-not $script:RailOpen) })
$BtnAppCheck.add_Click({ Start-AppUpdateCheck $true })
$BtnAppInstall.add_Click({ Act-AppUpdate })

$BtnKeyAll.add_Click({ Act-KeyAll })

# atalhos: F5 escaneia, Ctrl+F busca, Esc volta ao início
$Win.add_KeyDown({ param($s, $e)
    if ($e.Key -eq 'F5') { Start-Scan; $e.Handled = $true; return }
    if ($e.Key -eq 'Escape' -and $ConfigView.Visibility -eq 'Visible') { Show-Config $false; $e.Handled = $true; return }
    if ($e.Key -eq 'Escape' -and $AdvView.Visibility -eq 'Visible') { Show-View $false; $e.Handled = $true; return }
    if ($e.Key -eq 'F' -and ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control)) {
        Show-View $true; Show-Section 'drivers'; [void]$SearchBox.Focus(); $SearchBox.SelectAll(); $e.Handled = $true
    }
})

if (Test-WatchEnabled) { Set-WatchEnabled $true }
Set-Rail $true
Add-ThemeCards $ConfigThemes
Update-StorageInfo
Update-ConfigCard
Update-WuCard
Update-WatchButton
Update-RescueButton
Update-Sites
$Win.add_Loaded({
    Start-AppUpdateCheck $false
    if ($Rescue) {
        $g = Get-GpuInfo
        $b = Get-Baseline
        if ($g -and $g.Code -ne 0 -and $b -and (Get-Backup $b.Version)) {
            $Win.WindowState = 'Normal'; [void]$Win.Activate()
            Set-Verdict 'bad' 'Seu vídeo está quebrado' 'Vou restaurar o driver que estava funcionando. NÃO desligue o PC.'
            $script:WdLeft = 30
            $Findings.Children.Clear()
            Add-Finding 'Socorro automático' ("A placa de vídeo está com erro ({0}) e existe uma cópia do driver {1}. Vou reinstalar essa cópia em alguns segundos; o Windows vai pedir permissão de administrador." -f (Get-ProblemText $g.Code), $b.Version) 'bad' 'Cancelar' {
                $WdTimer.Stop(); Set-Verdict 'info' 'Socorro cancelado' 'Use o botão Restaurar quando quiser.'
            }
            $WdTimer.Start()
        }
    }
})
$BtnRestore.IsEnabled = [bool](Get-Backup (Get-Baseline).Version)

[void]$app.Run($Win)
