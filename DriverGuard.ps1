param([switch]$SelfTest, [switch]$Watch)

$AppVersion = '1.1.3'
$UpdateRepo = 'Wjunior30/DriverGuard'   # onde as versões novas são publicadas (GitHub Releases)
$Here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$DataDir = Join-Path $env:LOCALAPPDATA 'DriverGuard'
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
foreach ($f in 'baseline-video.json', 'watch-state.json') {
    foreach ($old in @((Join-Path $Here $f), (Join-Path $env:USERPROFILE "DriverGuard\$f"))) {
        if ((Test-Path $old) -and -not (Test-Path (Join-Path $DataDir $f))) { Copy-Item $old (Join-Path $DataDir $f) }
    }
}
$BaselineFile = Join-Path $DataDir 'baseline-video.json'
$WatchState = Join-Path $DataDir 'watch-state.json'
$BackupDir = Join-Path $DataDir 'backup'
$Exe = Join-Path $Here 'DriverGuard.exe'
$Launcher = Join-Path $Here 'DriverGuard.vbs'
$IconFile = Join-Path $Here 'DriverGuard.ico'
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
        1 = 'Mal configurado (código 1)'; 10 = 'Não iniciou (código 10)'; 22 = 'DESABILITADO (código 22)'
        28 = 'SEM DRIVER (código 28)'; 31 = 'Falha ao carregar (código 31)'; 43 = 'FALHOU (código 43)'
    }
    function Get-ProblemText([int]$code) {
        if ($code -eq 0) { return 'OK' }
        if ($ProblemText.ContainsKey($code)) { return $ProblemText[$code] }
        "Erro (código $code)"
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
            Code = [int]$vc.ConfigManagerErrorCode; VenDev = $venDev; Vendor = $vendor
        }
    }

    function Get-SystemInfo {
        $bb = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
        $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
        $cv = if ("$($cpu.Manufacturer)" -match 'AMD') { 'AMD' } elseif ("$($cpu.Manufacturer)" -match 'Intel') { 'Intel' } else { "$($cpu.Manufacturer)" }
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        $enc = Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue | Select-Object -First 1
        $laptop = [bool](@($enc.ChassisTypes) | Where-Object { $_ -in 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32 }) -or
                  [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
        [pscustomobject]@{
            BoardMaker = "$($bb.Manufacturer)".Trim(); BoardModel = "$($bb.Product)".Trim()
            Maker = "$($cs.Manufacturer)".Trim(); Model = "$($cs.Model)".Trim(); IsLaptop = $laptop
            Cpu = "$($cpu.Name)".Trim(); CpuVendor = $cv
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

    # ---- versão nova do próprio DriverGuard (GitHub Releases)
    function Get-AppUpdate([string]$repo, [string]$current) {
        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = 'Tls12'
        $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'DriverGuard' } -TimeoutSec 20
        $v = $null; try { $v = [version](("$($r.tag_name)") -replace '^[vV]', '') } catch { }
        if (-not $v -or $v -le [version]$current) { return }
        $exe = @($r.assets | Where-Object { $_.name -eq 'DriverGuard-Setup.exe' })[0]
        $sha = @($r.assets | Where-Object { $_.name -eq 'DriverGuard-Setup.exe.sha256' })[0]
        if (-not $exe -or -not $sha) { return }
        [pscustomobject]@{ Version = "$v"; Url = $exe.browser_download_url; ShaUrl = $sha.browser_download_url; Notes = "$($r.body)".Trim(); SizeMB = [math]::Round($exe.size / 1MB, 1) }
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
        if ($cmd -match 'pnputil') { return 'pnputil (manual / DriverGuard)' }
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

    function Get-CrashList([int]$days = 90) {
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = (Get-Date).AddDays(-$days) } -ErrorAction SilentlyContinue |
            ForEach-Object {
                $h = @{}
                ([xml]$_.ToXml()).Event.EventData.Data | ForEach-Object { $h[$_.Name] = $_.'#text' }
                $bc = [int64]("0$($h['BugcheckCode'])"); $btn = [int64]("0$($h['PowerButtonTimestamp'])"); $sl = [int]("0$($h['SleepInProgress'])")
                $tipo = if ($bc -ne 0) { 'Tela azul (0x{0:X})' -f $bc }
                    elseif ($btn -ne 0) { 'Você segurou o botão de ligar' }
                    elseif ($sl -ne 0) { 'Travou ao desligar/suspender' }
                    else { 'Desligou de repente (sem erro)' }
                [pscustomobject]@{ Quando = $_.TimeCreated; Tipo = $tipo }
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

function Get-Backup([string]$version) {
    if (-not $version) { return $null }
    $d = Join-Path $BackupDir $version
    $j = Join-Path $d 'driverguard-backup.json'
    if (-not (Test-Path $j)) { return $null }
    try { $o = Get-Content $j -Raw | ConvertFrom-Json; $o | Add-Member -NotePropertyName Path -NotePropertyValue $d -Force; $o } catch { $null }
}

function Test-WatchEnabled { $null -ne (Get-ItemProperty $RunKey -Name DriverGuard -ErrorAction SilentlyContinue) }
function Set-WatchEnabled([bool]$on) {
    if ($on) {
        $cmd = if (Test-Path $Exe) { '"{0}" -Watch' -f $Exe } else { 'wscript.exe "{0}" -Watch' -f $Launcher }
        Set-ItemProperty $RunKey -Name DriverGuard -Value $cmd
    } else { Remove-ItemProperty $RunKey -Name DriverGuard -ErrorAction SilentlyContinue }
}
function Stop-Tray {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*DriverGuard.ps1*-Watch*' -and $_.ProcessId -ne $PID } |
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
    if ((Find-DriverBooster).Count) { $issues += 'Driver Booster instalado.' }
    $st = Get-State; $st.LastCheck = (Get-Date).ToString('o'); Save-State $st
    $issues
}

# ================================================================ vigia: ícone fixo perto do relógio
if ($Watch) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $mtx = New-Object Threading.Mutex($false, 'Local\DriverGuardTray')
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
    $ni.Icon = $icoOk; $ni.Text = 'DriverGuard'; $ni.Visible = $true
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
                if ($au -and ($manual -or $st.AppKey -ne $au.Version)) { $updLine = ("DriverGuard $($au.Version) disponível. " + $updLine).Trim() }
                $st.AppKey = $(if ($au) { $au.Version } else { '' }); Save-State $st
            }
        }
        $issues = @(Get-WatchIssues)
        if ($issues.Count) {
            $ni.Icon = $icoBad
            $ni.Text = $(if ($issues.Count -eq 1) { 'DriverGuard — 1 alerta' } else { 'DriverGuard — {0} alertas' -f $issues.Count })
        } else { $ni.Icon = $icoOk; $ni.Text = 'DriverGuard — tudo certo' }
        $key = $issues -join '|'
        if ($issues.Count -and ($manual -or $key -ne $script:LastIssues)) {
            $txt = (@($issues) + @($updLine | Where-Object { $_ })) -join "`n"
            $ni.ShowBalloonTip(20000, 'DriverGuard — atenção', $txt.Substring(0, [Math]::Min(250, $txt.Length)), 'Warning')
        } elseif ($updLine) {
            $ni.ShowBalloonTip(15000, 'DriverGuard', "$updLine Clique para abrir e atualizar.", 'Info')
        } elseif ($manual) {
            $ni.ShowBalloonTip(8000, 'DriverGuard', 'Tudo certo com seus drivers.', 'Info')
        }
        $script:LastIssues = $key
    }

    $menu = New-Object Windows.Forms.ContextMenuStrip
    [void]$menu.Items.Add('Abrir DriverGuard', $null, { Start-Launcher '' })
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
  <Style TargetType="DataGridCell">
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
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
        Title="DriverGuard" Width="1120" Height="760" MinWidth="980" MinHeight="640" WindowStartupLocation="CenterScreen"
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
        <Grid DockPanel.Dock="Bottom" Margin="28,0,28,16">
          <TextBlock x:Name="FooterText" Foreground="{StaticResource Dim}" FontSize="12" VerticalAlignment="Center"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnTheme" Style="{StaticResource Ghost}" Margin="0,0,18,0">
              <StackPanel Orientation="Horizontal">
                <TextBlock FontFamily="{StaticResource Icons}" Text="&#xE790;" VerticalAlignment="Center" Margin="0,1,7,0"/>
                <TextBlock Text="Tema"/>
              </StackPanel>
            </Button>
            <Button x:Name="BtnAdvanced" Style="{StaticResource Ghost}" Content="Modo avançado  →"/>
          </StackPanel>
        </Grid>
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,30,0,20" Width="720">
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
              <TextBlock FontFamily="{StaticResource Icons}" Text="&#xEA18;" FontSize="26" Foreground="__ICON__" VerticalAlignment="Center" Margin="0,3,10,0"/>
              <TextBlock Text="DriverGuard" FontSize="30" FontWeight="SemiBold" FontFamily="{StaticResource Display}"/>
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
    <Grid x:Name="AdvView" Visibility="Collapsed" Margin="24,20,24,14">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <StackPanel Orientation="Horizontal">
        <Button x:Name="BtnBack" Style="{StaticResource Pill}" Margin="0,0,14,0">
          <StackPanel Orientation="Horizontal">
            <TextBlock FontFamily="{StaticResource Icons}" Text="&#xE72B;" VerticalAlignment="Center" Margin="0,0,8,0" FontSize="12"/>
            <TextBlock Text="Início"/>
          </StackPanel>
        </Button>
        <TextBlock Text="Modo avançado" FontSize="22" FontWeight="SemiBold" VerticalAlignment="Center" FontFamily="{StaticResource Display}"/>
      </StackPanel>

      <Grid Grid.Row="1" Margin="0,18,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="11*"/>
          <ColumnDefinition Width="16"/>
          <ColumnDefinition Width="9*"/>
        </Grid.ColumnDefinitions>
        <Border Background="{StaticResource Surface}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="14" Padding="20,16">
          <TextBlock x:Name="GpuText" TextWrapping="Wrap" LineHeight="23"/>
        </Border>
        <Border Grid.Column="2" Background="{StaticResource Surface}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="14" Padding="20,16">
          <TextBlock x:Name="HealthText" TextWrapping="Wrap" LineHeight="23"/>
        </Border>
      </Grid>

      <WrapPanel Grid.Row="2" Margin="0,16,0,0">
        <WrapPanel.Resources>
          <Style TargetType="Button" BasedOn="{StaticResource Pill}"/>
        </WrapPanel.Resources>
        <Button x:Name="BtnScan" Style="{StaticResource PillAccent}" Content="Escanear"/>
        <Button x:Name="BtnUpd" Content="Atualizar drivers"/>
        <Button x:Name="BtnGood" Content="Salvar e fazer backup do vídeo"/>
        <Button x:Name="BtnRestore" Content="Restaurar driver salvo"/>
        <Button x:Name="BtnPoint" Content="Criar ponto de restauração"/>
        <Button x:Name="BtnAll" Content="Backup de todos os drivers"/>
        <Button x:Name="BtnHist" Content="Histórico do vídeo"/>
        <Button x:Name="BtnCrash" Content="Quedas do PC"/>
        <Button x:Name="BtnWu" Content="Windows Update"/>
        <Button x:Name="BtnSites" Content="Sites oficiais  ▾"/>
        <Button x:Name="BtnCsv" Content="Exportar CSV"/>
        <Button x:Name="BtnWatch" Content="Vigia automático"/>
        <Button x:Name="BtnTheme2" Content="Tema de cores"/>
        <Button x:Name="BtnDb" Style="{StaticResource PillBad}" Content="Remover Driver Booster" Visibility="Collapsed"/>
      </WrapPanel>
      <Popup x:Name="SitesPopup" PlacementTarget="{Binding ElementName=BtnSites}" Placement="Bottom" StaysOpen="False" AllowsTransparency="True" VerticalOffset="2">
        <Border Background="{StaticResource Surface2}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="12" Padding="6">
          <StackPanel x:Name="SitesList"/>
        </Border>
      </Popup>

      <StackPanel Grid.Row="3" Orientation="Horizontal" Margin="0,6,0,12">
        <Border Width="320" Background="{StaticResource Surface2}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="17" Padding="14,7">
          <DockPanel>
            <TextBlock DockPanel.Dock="Left" FontFamily="{StaticResource Icons}" Text="&#xE721;" Foreground="{StaticResource Dim}" VerticalAlignment="Center" Margin="0,0,10,0" FontSize="12"/>
            <TextBox x:Name="SearchBox"/>
          </DockPanel>
        </Border>
        <CheckBox x:Name="ChkMs" Content="Mostrar drivers genéricos da Microsoft" Margin="18,0,0,0" VerticalAlignment="Center"/>
      </StackPanel>

      <Border Grid.Row="4" Background="{StaticResource Surface}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="14" Padding="4">
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
      </Border>

      <TextBlock Grid.Row="5" x:Name="StatusText" Foreground="{StaticResource Dim}" FontSize="12" Margin="4,10,0,0"/>
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

# modelos de script que rodam com permissão de administrador (só quando o usuário confirma)
$RestoreTpl = @'
$L = New-Object Collections.ArrayList
function W([string]$t) { [void]$L.Add($t) }
try {
    try {
        Checkpoint-Computer -Description 'DriverGuard - antes de restaurar driver de video' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue -WarningVariable wv
        if ($wv) { W ('PONTO=aviso: ' + $wv[0]) } else { W 'PONTO=ok' }
    } catch { W ('PONTO=falhou: ' + $_.Exception.Message) }
    $blocks = ((pnputil /enum-drivers) -join "`n") -split '(?m)^\s*$'
    foreach ($b in $blocks) {
        if ($b -notmatch '\{4d36e968-e325-11ce-bfc1-08002be10318\}') { continue }
        if ($b -notmatch '__VENDOR__') { continue }
        if ($b -match '(oem\d+\.inf)') {
            $oem = $matches[1]
            $o = pnputil /delete-driver $oem /uninstall /force 2>&1 | Out-String
            W ('REMOVIDO=' + $oem)
        }
    }
    $o = pnputil /add-driver '__INF__' /install 2>&1 | Out-String
    W ('INSTALAR=' + $LASTEXITCODE)
    W $o.Trim()
    pnputil /scan-devices | Out-Null
} catch { W ('ERRO=' + $_.Exception.Message) }
finally { $L | Set-Content '__LOG__' -Encoding UTF8 }
'@

$PointTpl = @'
$L = New-Object Collections.ArrayList
try {
    Checkpoint-Computer -Description 'DriverGuard - ponto manual' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue -WarningVariable wv
    if ($wv) { [void]$L.Add('PONTO=aviso: ' + $wv[0]) } else { [void]$L.Add('PONTO=ok') }
} catch { [void]$L.Add('PONTO=falhou: ' + $_.Exception.Message) }
finally { $L | Set-Content '__LOG__' -Encoding UTF8 }
'@

$BackupTpl = @'
robocopy '__SRC__' '__DST__' /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
$rc = $LASTEXITCODE
if ($rc -lt 8) {
    $size = (Get-ChildItem '__DST__' -Recurse -File | Measure-Object Length -Sum).Sum
    [pscustomobject]@{ Version = '__VER__'; Name = '__NAME__'; Inf = '__INF__'; Vendor = '__VENDOR__'; Date = (Get-Date).ToString('dd/MM/yyyy HH:mm'); SizeMB = [math]::Round($size / 1MB) } |
        ConvertTo-Json | Set-Content (Join-Path '__DST__' 'driverguard-backup.json') -Encoding UTF8
}
$rc
'@

$DlTpl = @'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
$items = @(ConvertFrom-Json '__JSON__' | ForEach-Object { $_ })   # PS 5 devolve a lista inteira como um item só
$ok = @(); $fail = @(); $i = 0
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
            $sig = Get-AuthenticodeSignature $cab
            if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft') { throw 'assinatura digital da Microsoft inválida' }
            & expand.exe -F:* $cab $x | Out-Null
            Remove-Item $cab -Force
        }
        if (-not (Get-ChildItem $x -Recurse -Filter '*.inf')) { throw 'pacote sem arquivo .inf' }
        $ok += $u.Id
    } catch {
        $fail += ('{0}: {1}' -f $u.Dispositivo, $_.Exception.Message)
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
[pscustomobject]@{ Ok = @($ok); Fail = @($fail) }
'@

$UpdTpl = @'
$L = New-Object Collections.ArrayList
function W([string]$t) { [void]$L.Add($t) }
try {
    try {
        Checkpoint-Computer -Description 'DriverGuard - antes de atualizar drivers' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue -WarningVariable wv
        if ($wv) { W ('PONTO=aviso: ' + $wv[0]) } else { W 'PONTO=ok' }
    } catch { W ('PONTO=falhou: ' + $_.Exception.Message) }
    foreach ($d in Get-ChildItem '__DIR__' -Directory) {
        $o = pnputil /add-driver (Join-Path $d.FullName 'arquivos\*.inf') /subdirs /install 2>&1 | Out-String
        $rc = $LASTEXITCODE
        W ('PACOTE=' + $d.Name + ' RC=' + $rc)
        if ($rc -eq 259) {
            foreach ($m in [regex]::Matches($o, 'oem\d+\.inf')) { pnputil /delete-driver $m.Value 2>&1 | Out-Null; W ('LIMPO=' + $m.Value) }
        }
    }
} catch { W ('ERRO=' + $_.Exception.Message) }
finally { $L | Set-Content '__LOG__' -Encoding UTF8 }
'@

function Expand-Tpl([string]$tpl, [hashtable]$map) {
    foreach ($k in $map.Keys) { $tpl = $tpl.Replace($k, "$($map[$k])".Replace("'", "''")) }
    $tpl
}

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
foreach ($n in 'HomeView', 'AdvView', 'BtnAdvanced', 'BtnTheme', 'BtnTheme2', 'FooterText', 'BigBtn', 'Spinner', 'SpinRot', 'BigIcon', 'BigLabel', 'VerdictBadge',
    'VerdictIcon', 'VerdictText', 'VerdictSub', 'Findings', 'BtnBack', 'GpuText', 'HealthText', 'BtnScan', 'BtnUpd', 'BtnGood',
    'BtnRestore', 'BtnPoint', 'BtnAll', 'BtnHist', 'BtnCrash', 'BtnWu', 'BtnSites', 'BtnCsv', 'BtnWatch', 'BtnDb', 'SitesPopup',
    'SitesList', 'SearchBox', 'ChkMs', 'DriverGrid', 'StatusText') {
    Set-Variable -Name $n -Value $Win.FindName($n) -Scope Script
}
$Win.add_SourceInitialized({ Set-DarkTitle $Win })
if (Test-Path $IconFile) { try { $Win.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$IconFile) } catch { } }
$FooterText.Text = "DriverGuard $AppVersion  •  nada é instalado sem você confirmar  •  só avisos e sites oficiais"

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
        elseif ($e.PropertyName -in 'Detalhe', 'Titulo', 'Tipo') { $e.Column.Width = New-Object Windows.Controls.DataGridLength(1, 'Star') }
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
function Invoke-Elevated([string]$tpl, [hashtable]$map, [string]$name, [scriptblock]$onDone) {
    $log = Join-Path $DataDir "$name.log"
    $file = Join-Path $DataDir "$name.ps1"
    Remove-Item $log -Force -ErrorAction SilentlyContinue
    $map['__LOG__'] = $log
    [IO.File]::WriteAllText($file, (Expand-Tpl $tpl $map), (New-Object Text.UTF8Encoding $true))
    $script:ElevLog = $log; $script:ElevDone = $onDone
    $argList = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $file
    Start-Bg ("Start-Process powershell.exe -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList '{0}'" -f $argList) {
        param($out, $err)
        $text = if (Test-Path $script:ElevLog) { Get-Content $script:ElevLog -Raw } else { '' }
        & $script:ElevDone $text $err
    }
}

$LogicText = $Logic.ToString()
$ScanCode = @'
$gpu = Get-GpuInfo
[pscustomobject]@{ Rows = @(Get-DriverScan); Gpu = $gpu; History = @(if ($gpu) { Get-InstallHistory $gpu.VenDev }); Health = Get-Health; SysInfo = Get-SystemInfo }
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

$script:Problems = 0; $script:Old = 0; $script:LastScan = $null; $script:History = @()
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

function Update-Filter {
    $parts = @()
    if (-not $ChkMs.IsChecked) { $parts += 'Microsoft = false' }
    $q = ($SearchBox.Text -replace "[\[\]\*%']", '').Trim()
    if ($q) { $parts += "(Dispositivo LIKE '*$q*' OR Fabricante LIKE '*$q*' OR Categoria LIKE '*$q*')" }
    $dt.DefaultView.RowFilter = ($parts -join ' AND ')
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
        if (-not $b) { Add-Line $GpuText '●  Nenhum driver salvo como referência' $Hex.warn }
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
    $BtnRestore.IsEnabled = [bool]$bk -and -not $script:BackupBusy
    $BtnGood.IsEnabled = -not $script:BackupBusy
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

    if ($script:AppUpd) {
        $tips++
        $notes = ($script:AppUpd.Notes -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 2) -join ' '
        if ($notes.Length -gt 160) { $notes = $notes.Substring(0, 160) + '...' }
        if ($notes) { $notes += ' ' }
        Add-Finding "Nova versão do DriverGuard: $($script:AppUpd.Version)" ($notes + "Atualiza em segundos ($($script:AppUpd.SizeMB) MB) e mantém seu backup e suas configurações.") 'warn' 'Atualizar app' { Act-AppUpdate }
    }
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
        Add-Finding 'Salve e faça backup do seu driver de vídeo' 'Seu vídeo está funcionando agora. O DriverGuard guarda uma cópia deste driver e avisa se algum programa ou o Windows trocar — aí é só um clique para voltar.' 'warn' 'Salvar' { Act-MarkGood }
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
        Add-Finding 'A proteção automática está desligada' 'Quando ligada, um escudo fica perto do relógio: o DriverGuard confere seu PC em silêncio e só avisa se o driver de vídeo for trocado, a placa der erro, o PC cair ou o Driver Booster voltar. Não instala nada e não deixa o PC lento.' 'warn' 'Ligar' { Act-Watch }
    }

    $sub = 'Última análise às {0:HH:mm}' -f $script:LastScan
    if ($script:UpdState -eq 'done' -and -not $script:Updates.Count) { $sub += '  •  drivers em dia' }
    if ($bad) { Set-Verdict 'bad' (Get-Plural $bad 'problema encontrado' 'problemas encontrados') $sub }
    elseif ($tips) { Set-Verdict 'ok' 'Tudo certo' ('{0}  •  {1} para ficar mais protegido' -f $sub, (Get-Plural $tips 'sugestão' 'sugestões')) }
    else { Set-Verdict 'ok' 'Tudo certo — seu PC está protegido' $sub }
}

function Show-View([bool]$adv) {
    $AdvView.Visibility = $(if ($adv) { 'Visible' } else { 'Collapsed' })
    $HomeView.Visibility = $(if ($adv) { 'Collapsed' } else { 'Visible' })
    if ($adv -and -not $script:LastScan -and -not $script:Scanning) { Start-Scan }
}

# ---------------------------------------------------------------- ações

function Apply-Scan($r) {
    $rows = @($r.Rows)
    $script:Gpu = $r.Gpu; $script:History = @($r.History); $script:Health = $r.Health; $script:SysInfo = $r.SysInfo
    $script:Problems = @($rows | Where-Object { $_.Status -notin 'OK', 'Antigo' }).Count
    $script:Old = @($rows | Where-Object { $_.Status -eq 'Antigo' }).Count
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
    $code = Expand-Tpl $BackupTpl @{ '__SRC__' = $pkg.Folder; '__DST__' = $dst; '__VER__' = $g.Version; '__NAME__' = $g.Name; '__INF__' = $pkg.Inf; '__VENDOR__' = $g.Vendor }
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
    $msg = "Salvar o driver $($g.Version) como a versão boa?`n`n•   O DriverGuard avisa sempre que esse driver for trocado`n•   Guarda uma cópia do driver para restaurar com um clique (pode ocupar 1 GB ou mais; substitui o backup anterior)`n`nA cópia é feita em segundo plano."
    if (-not (Show-Dialog 'Salvar e fazer backup' $msg 'ask' -YesNo -YesText 'Salvar')) { return }
    Save-Baseline $g
    Start-Backup $g
    Update-Cards; Update-Home
}

function Act-Restore {
    $b = Get-Baseline
    $bk = if ($b) { Get-Backup $b.Version } else { $null }
    if (-not $bk) { [void](Show-Dialog 'Sem backup' 'Ainda não há backup do driver de vídeo. Quando o vídeo estiver funcionando bem, use "Salvar e fazer backup".' 'warn'); return }
    $g = $script:Gpu
    $now = if ($g) { $g.Version } else { 'desconhecido' }
    $msg = "Isso vai:`n`n1.   Criar um ponto de restauração do Windows`n2.   Remover o driver de vídeo atual ($now)`n3.   Instalar o driver salvo ($($bk.Version), backup de $($bk.Date))`n`nA tela vai piscar ou apagar por alguns segundos. O Windows vai pedir permissão de administrador. Salve o que estiver fazendo antes."
    if (-not (Show-Dialog 'Restaurar driver de vídeo' $msg 'ask' -YesNo -YesText 'Restaurar')) { return }
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
    Invoke-Elevated $RestoreTpl @{ '__VENDOR__' = $vendorRx; '__INF__' = (Join-Path $bk.Path $bk.Inf) } 'restaurar' {
        param($log, $err)
        if ($err) {
            [void](Show-Dialog 'Restauração cancelada' "O Windows não deu permissão de administrador, então nada foi alterado.`n`n$err" 'warn')
            Update-Home; Update-Cards
            return
        }
        if ($log -match 'ERRO=(.+)') { [void](Show-Dialog 'Erro na restauração' $matches[1] 'bad') }
        $script:AfterRestore = $script:RestoreWant
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
    'title DriverGuard - Reinstalar drivers'
    'net session >nul 2>&1'
    'if errorlevel 1 ('
    '  powershell -NoProfile -Command "Start-Process -FilePath ''%~f0'' -Verb RunAs"'
    '  exit /b'
    ')'
    'echo.'
    'echo  Reinstalando os drivers salvos pelo DriverGuard.'
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
    $dst = Join-Path $fb.SelectedPath ('DriverGuard - Drivers ({0}) {1:yyyy-MM-dd}' -f $label, (Get-Date))
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
    $msg = "Vou:`n`n1.   Baixar {0} ({1:N0} MB) do servidor oficial da Microsoft e conferir a assinatura digital`n2.   Criar um ponto de restauração do Windows`n3.   Instalar os drivers`n`nO Windows vai pedir permissão de administrador. A tela ou a internet podem piscar por alguns segundos." -f (Get-Plural $list.Count 'driver' 'drivers'), [math]::Max(1, $mb)
    if (-not (Show-Dialog 'Atualizar drivers' $msg 'ask' -YesNo -YesText 'Atualizar')) { return }
    $dir = Join-Path $DataDir ('updates\{0:yyyyMMdd-HHmmss}' -f (Get-Date))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $script:UpdDir = $dir; $script:UpdList = @($list)
    $script:UpdState = 'installing'; $script:Prog.Text = 'Preparando download...'
    $BtnUpd.IsEnabled = $false; $BtnUpd.Content = 'Atualizando drivers...'
    Update-Home
    $json = ConvertTo-Json -InputObject @($list | Select-Object Id, Dispositivo) -Compress
    Start-Bg (Expand-Tpl $DlTpl @{ '__JSON__' = $json; '__DIR__' = $dir }) {
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
        Invoke-Elevated $UpdTpl @{ '__DIR__' = $script:UpdDir } 'atualizar' {
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

# ---------------------------------------------------------------- atualização do próprio DriverGuard

$script:AppUpd = $null
function Start-AppUpdateCheck {
    Start-Bg ($LogicText + "`nGet-AppUpdate '$UpdateRepo' '$AppVersion'") {
        param($out, $err)
        $script:AppUpd = if ($out -and $out.Count) { $out[$out.Count - 1] } else { $null }
        if ($script:AppUpd) {
            $FooterText.Text = "DriverGuard $AppVersion  •  versão $($script:AppUpd.Version) disponível"
            Update-Home
        }
    }
}

function Act-AppUpdate {
    $u = $script:AppUpd
    if (-not $u) { return }
    $msg = "Atualizar o DriverGuard de $AppVersion para $($u.Version)?`n`nO app vai fechar, atualizar e abrir de novo sozinho em alguns segundos. Seu backup e suas configurações são mantidos."
    if ($u.Notes) { $msg += "`n`nNovidades:`n" + $u.Notes }
    if (-not (Show-Dialog 'Atualizar DriverGuard' $msg 'ask' -YesNo -YesText 'Atualizar')) { return }
    $script:AppSetup = Join-Path $env:TEMP "DriverGuard-Setup-$($u.Version).exe"
    $FooterText.Text = "Baixando DriverGuard $($u.Version)..."
    $code = @"
`$ProgressPreference = 'SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol = 'Tls12'
Invoke-WebRequest -UseBasicParsing -Uri '$($u.Url)' -OutFile '$($script:AppSetup)' -TimeoutSec 300
`$raw = (Invoke-WebRequest -UseBasicParsing -Uri '$($u.ShaUrl)' -TimeoutSec 60).Content
if (`$raw -is [byte[]]) { `$raw = [Text.Encoding]::ASCII.GetString(`$raw) }   # o GitHub entrega como binário
`$want = (`$raw -split '\s+')[0].Trim().ToLower()
`$got = (Get-FileHash '$($script:AppSetup)' -Algorithm SHA256).Hash.ToLower()
if (`$want -ne `$got) { Remove-Item '$($script:AppSetup)' -Force; throw 'o arquivo baixado não confere (hash diferente)' }
'ok'
"@
    Start-Bg $code {
        param($out, $err)
        if ($err -or -not $out -or "$($out[$out.Count - 1])" -ne 'ok') {
            $FooterText.Text = "DriverGuard $AppVersion"
            [void](Show-Dialog 'Atualização falhou' "Não foi possível baixar a versão nova. Nada foi alterado.`n`n$err" 'bad')
            return
        }
        Start-Process $script:AppSetup -ArgumentList '/silent'
        $app.Shutdown()
    }
}

# ---------------------------------------------------------------- temas de cores

$ThemeXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" SizeToContent="WidthAndHeight"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False" ResizeMode="NoResize"
        FontFamily="Segoe UI Variable Text, Segoe UI" Foreground="{StaticResource Text}">
  <Border Background="{StaticResource Surface}" BorderBrush="{StaticResource Stroke}" BorderThickness="1" CornerRadius="16" Padding="24,22" Margin="20">
    <Border.Effect><DropShadowEffect BlurRadius="30" ShadowDepth="0" Opacity="0.6"/></Border.Effect>
    <StackPanel>
      <TextBlock Text="Tema de cores" FontSize="18" FontWeight="SemiBold" FontFamily="{StaticResource Display}"/>
      <TextBlock Text="Escolha a cor do DriverGuard. O app reabre em um segundo com a cor nova." Foreground="{StaticResource Dim}" Margin="0,6,0,18"/>
      <WrapPanel x:Name="Swatches" Width="444"/>
      <Button x:Name="Close" Style="{StaticResource Pill}" Content="Fechar" HorizontalAlignment="Right" Margin="0,12,0,0" IsCancel="True"/>
    </StackPanel>
  </Border>
</Window>
'@

function Show-ThemePicker {
    $w = [Windows.Markup.XamlReader]::Parse($ThemeXaml)
    $panel = $w.FindName('Swatches')
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
        $card.add_MouseLeftButtonUp({ param($s, $e)
            [Windows.Window]::GetWindow($s).Close()
            if ($s.Tag -eq $ThemeKey) { return }
            $st = Get-Settings; $st.Theme = $s.Tag; Save-Settings $st
            Start-Launcher ''
            $app.Shutdown()
        })
        [void]$panel.Children.Add($card)
    }
    $w.FindName('Close').add_Click({ param($s, $e) [Windows.Window]::GetWindow($s).Close() })
    $w.add_MouseLeftButtonDown({ param($s, $e) try { $s.DragMove() } catch { } })
    $w.Owner = $script:Win
    [void]$w.ShowDialog()
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
    $rows = $list | ForEach-Object { [pscustomobject]@{ Quando = $_.Quando.ToString('dd/MM/yyyy HH:mm (ddd)'); Tipo = $_.Tipo; Destaque = ($_.Tipo -like 'Desligou de repente*') } }
    $note = '{0} em 90 dias  •  {1} sem nenhum erro registrado' -f (Get-Plural $list.Count 'queda' 'quedas'), $sudden
    if ($sudden -ge [Math]::Ceiling($list.Count / 2)) { $note += '  →  padrão típico de fonte/energia, não de driver.' }
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
    $path = Join-Path ([Environment]::GetFolderPath('Desktop')) ('DriverGuard-{0:yyyyMMdd-HHmm}.csv' -f (Get-Date))
    $dt.DefaultView.ToTable() |
        Select-Object Status, Categoria, Dispositivo, Fabricante, @{ n = 'Versão'; e = { $_.Versao } },
            @{ n = 'Data'; e = { if ($_.Data -is [datetime]) { $_.Data.ToString('dd/MM/yyyy') } } }, @{ n = 'Idade (anos)'; e = { $_.Idade } }, INF |
        Export-Csv $path -NoTypeInformation -Delimiter ';' -Encoding UTF8
    Set-Status 'relatório salvo na Área de Trabalho'
}

function Act-Watch {
    if (Test-WatchEnabled) {
        if (Show-Dialog 'Proteção automática' 'Desligar a proteção automática? O escudo perto do relógio vai sumir.' 'ask' -YesNo -YesText 'Desligar') {
            Set-WatchEnabled $false; Stop-Tray
        }
    } else {
        $msg = "Um escudo fica perto do relógio (verde = tudo certo, vermelho = atenção). O DriverGuard confere seu PC ao ligar e a cada hora, e só avisa se:`n`n•   o driver de vídeo foi trocado`n•   a placa de vídeo está com erro`n•   o PC caiu desde a última vez`n•   o Driver Booster voltou`n`nNão instala nada. Dá para desligar quando quiser."
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
$BtnTheme.add_Click({ Show-ThemePicker })
$BtnTheme2.add_Click({ Show-ThemePicker })
$BtnBack.add_Click({ Show-View $false })
$BtnScan.add_Click({ Start-Scan })
$BtnGood.add_Click({ Act-MarkGood })
$BtnUpd.add_Click({ Act-Updates })
$BtnRestore.add_Click({ Act-Restore })
$BtnPoint.add_Click({ Act-Point })
$BtnAll.add_Click({ Act-AllBackup })
$BtnHist.add_Click({ Act-History })
$BtnCrash.add_Click({ Act-Crashes })
$BtnWu.add_Click({ Act-Wu })
$BtnSites.add_Click({ $SitesPopup.IsOpen = -not $SitesPopup.IsOpen })
$BtnCsv.add_Click({ Act-Csv })
$BtnWatch.add_Click({ Act-Watch })
$BtnDb.add_Click({ Act-RemoveDb })
$SearchBox.add_TextChanged({ Update-Filter })
$ChkMs.add_Checked({ Update-Filter })
$ChkMs.add_Unchecked({ Update-Filter })

if (Test-WatchEnabled) { Set-WatchEnabled $true }
Update-WatchButton
Update-Sites
$Win.add_Loaded({ Start-AppUpdateCheck })
$BtnRestore.IsEnabled = [bool](Get-Backup (Get-Baseline).Version)

[void]$app.Run($Win)
