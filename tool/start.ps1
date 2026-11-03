# BetterFireTV – Windows-Start.
# Besorgt adb (Android platform-tools) und Git Bash, sucht den Fire TV im Heimnetz und
# startet dann tool/betterfiretv.sh, das die eigentliche Arbeit macht.
# Wird von Einrichten.cmd, Rueckgaengig.cmd, Backup.cmd, Status.cmd, Startbildschirm.cmd und
# Hintergrund.cmd aufgerufen.
# Läuft mit Windows PowerShell 5.1 (in Windows 10/11 enthalten).
param(
    [string]$Root = '',
    [ValidateSet('einrichten', 'rueckgaengig', 'backup', 'status', 'startbildschirm', 'hintergrund')]
    [string]$Modus = 'einrichten',
    [string]$Ip = '',
    [switch]$Trockenlauf
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
$Tools = Join-Path $Root 'tools'

function Say([string]$Text, [string]$Color = 'Gray') { Write-Host $Text -ForegroundColor $Color }
function Step([string]$Text) { Write-Host ''; Write-Host $Text -ForegroundColor White }

function ConvertTo-UnixPath([string]$Path) {
    $p = $Path -replace '\\', '/'
    if ($p -match '^([A-Za-z]):/(.*)$') { return '/' + $Matches[1].ToLower() + '/' + $Matches[2] }
    return $p
}

function Get-File([string]$Url, [string]$Dest) {
    Say "  Lade $Url"
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'BetterFireTV')
    if ($wc.Proxy) { $wc.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials }
    $wc.DownloadFile($Url, $Dest)
}

# --- adb -----------------------------------------------------------------------------------
function Find-Adb {
    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Path }
    $candidates = @()
    if ($env:ANDROID_HOME) { $candidates += (Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe') }
    if ($env:ANDROID_SDK_ROOT) { $candidates += (Join-Path $env:ANDROID_SDK_ROOT 'platform-tools\adb.exe') }
    $candidates += (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe')
    $candidates += (Join-Path $Tools 'platform-tools\adb.exe')
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }

    Step 'adb fehlt, lade die Android platform-tools von Google (ca. 7 MB) ...'
    New-Item -ItemType Directory -Force -Path $Tools | Out-Null
    $zip = Join-Path $Tools 'platform-tools.zip'
    Get-File 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' $zip
    Expand-Archive -LiteralPath $zip -DestinationPath $Tools -Force
    Remove-Item -LiteralPath $zip -Force
    $adb = Join-Path $Tools 'platform-tools\adb.exe'
    if (-not (Test-Path -LiteralPath $adb)) { throw 'adb.exe wurde nach dem Entpacken nicht gefunden.' }
    return $adb
}

# --- Git Bash (nicht die WSL-bash aus System32) ----------------------------------------------
function Find-GitBash {
    $candidates = @()
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) {
        $dir = Split-Path -Parent $git.Path
        for ($i = 0; $i -lt 3; $i++) {
            $candidates += (Join-Path $dir 'bin\bash.exe')
            $dir = Split-Path -Parent $dir
            if (-not $dir) { break }
        }
    }
    foreach ($key in 'HKLM:\SOFTWARE\GitForWindows', 'HKCU:\SOFTWARE\GitForWindows') {
        try {
            $installPath = (Get-ItemProperty -Path $key -ErrorAction Stop).InstallPath
            if ($installPath) { $candidates += (Join-Path $installPath 'bin\bash.exe') }
        } catch { }
    }
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Git\bin\bash.exe') }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe') }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe') }
    $candidates += (Join-Path $Tools 'PortableGit\bin\bash.exe')
    foreach ($c in $candidates) {
        if ($c -notmatch '\\System32\\' -and (Test-Path -LiteralPath $c)) { return $c }
    }

    Step 'Git Bash fehlt, lade PortableGit von GitHub (ca. 60 MB, einmalig) ...'
    New-Item -ItemType Directory -Force -Path $Tools | Out-Null
    $release = Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent' = 'BetterFireTV' } `
        -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest'
    $asset = $release.assets | Where-Object { $_.name -match '^PortableGit-.*-64-bit\.7z\.exe$' } | Select-Object -First 1
    if (-not $asset) { throw 'PortableGit wurde im aktuellen Git-for-Windows-Release nicht gefunden.' }
    $exe = Join-Path $Tools $asset.name
    Get-File $asset.browser_download_url $exe
    $dest = Join-Path $Tools 'PortableGit'
    Say '  Entpacke PortableGit ...'
    $p = Start-Process -FilePath $exe -ArgumentList @('-y', "-o`"$dest`"") -Wait -PassThru
    Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
    $bash = Join-Path $dest 'bin\bash.exe'
    if (-not (Test-Path -LiteralPath $bash)) { throw "PortableGit konnte nicht entpackt werden (Code $($p.ExitCode))." }
    return $bash
}

# --- Fire TV im Heimnetz suchen ----------------------------------------------------------------
# Nur private Heimnetze mit Gateway. VPN- und virtuelle Adapter werden ausgelassen, damit nie
# ein Firmennetz abgesucht wird.
function Get-HomeNetworks {
    $skip = 'Cisco|AnyConnect|VPN|Virtual|Hyper-V|VMware|VirtualBox|WSL|TAP-|Tunnel|Zscaler|Fortinet|GlobalProtect|PANGP|WireGuard|Juniper|Pulse|Loopback|Bluetooth'
    $result = @()
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne 'Up') { continue }
        if ($nic.NetworkInterfaceType -eq 'Loopback' -or $nic.NetworkInterfaceType -eq 'Tunnel') { continue }
        if (($nic.Description + ' ' + $nic.Name) -match $skip) { continue }
        $props = $nic.GetIPProperties()
        $gateways = @($props.GatewayAddresses | Where-Object {
                $_.Address.AddressFamily -eq 'InterNetwork' -and $_.Address.ToString() -ne '0.0.0.0' })
        if ($gateways.Count -eq 0) { continue }
        foreach ($ua in $props.UnicastAddresses) {
            if ($ua.Address.AddressFamily -ne 'InterNetwork') { continue }
            $addr = $ua.Address.ToString()
            if ($addr -notmatch '^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)') { continue }
            $prefix = 24
            try { $prefix = [int]$ua.PrefixLength } catch { }
            $result += New-Object PSObject -Property @{ Ip = $addr; Prefix = $prefix; Name = $nic.Name }
        }
    }
    return $result
}

function Get-HostList([string]$Addr, [int]$Prefix) {
    $o = @($Addr.Split('.') | ForEach-Object { [int]$_ })
    $thirds = @($o[2])
    if ($Prefix -ge 22 -and $Prefix -lt 24) {
        $span = [int][math]::Pow(2, 24 - $Prefix)
        $start = $o[2] - ($o[2] % $span)
        $thirds = @($start..($start + $span - 1))
    }
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($t in $thirds) {
        for ($i = 1; $i -le 254; $i++) {
            $h = '{0}.{1}.{2}.{3}' -f $o[0], $o[1], $t, $i
            if ($h -ne $Addr) { $list.Add($h) }
        }
    }
    return , $list
}

# Prüft alle Adressen gleichzeitig auf den ADB-Port 5555 (dauert etwa 2 Sekunden).
function Find-AdbHosts($HostList) {
    $pending = New-Object System.Collections.Generic.List[object]
    foreach ($h in $HostList) {
        $client = New-Object System.Net.Sockets.TcpClient
        $task = $client.ConnectAsync($h, 5555)
        $pending.Add((New-Object PSObject -Property @{ Host = $h; Client = $client; Task = $task }))
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 2500) {
        $open = 0
        foreach ($p in $pending) { if (-not $p.Task.IsCompleted) { $open++ } }
        if ($open -eq 0) { break }
        Start-Sleep -Milliseconds 150
    }
    $found = @()
    foreach ($p in $pending) {
        if ($p.Task.IsCompleted -and -not $p.Task.IsFaulted -and -not $p.Task.IsCanceled -and $p.Client.Connected) {
            $found += $p.Host
        }
        try { $p.Client.Close() } catch { }
    }
    return $found
}

# --- Hintergrundbilder auswählen und fürs TV vorbereiten -------------------------------------
# Öffnet ein Auswahlfenster, dreht Handy-Fotos richtig herum (EXIF), verkleinert auf Full HD und
# legt sie als JPEG in hintergruende\ ab. Gibt die neuen Dateinamen zurück.
function Add-Wallpapers([string]$Dir) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Hintergrundbilder für den Fernseher auswählen'
    $dialog.Filter = 'Bilder (*.jpg;*.jpeg;*.png;*.bmp)|*.jpg;*.jpeg;*.png;*.bmp'
    $dialog.Multiselect = $true
    $dialog.InitialDirectory = [Environment]::GetFolderPath('MyPictures')
    $owner = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true
    $added = @()
    if ($dialog.ShowDialog($owner) -ne [System.Windows.Forms.DialogResult]::OK) {
        Say '  Kein Bild ausgewählt. Es werden nur die vorhandenen Bilder abgeglichen.' 'Yellow'
        return $added
    }
    $jpeg = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
    foreach ($src in $dialog.FileNames) {
        $name = [IO.Path]::GetFileNameWithoutExtension($src)
        $name = $name -creplace 'ä', 'ae' -creplace 'ö', 'oe' -creplace 'ü', 'ue' -creplace 'Ä', 'Ae' -creplace 'Ö', 'Oe' -creplace 'Ü', 'Ue' -creplace 'ß', 'ss'
        $name = ($name -replace '[^A-Za-z0-9._-]+', '-').Trim('-', '.')
        if (-not $name) { $name = 'bild' }
        $dest = Join-Path $Dir ($name + '.jpg')
        $n = 2
        while (Test-Path -LiteralPath $dest) { $dest = Join-Path $Dir ('{0}-{1}.jpg' -f $name, $n); $n++ }
        $img = $null; $bmp = $null; $g = $null
        try {
            $img = [System.Drawing.Image]::FromFile($src)
            if ($img.PropertyIdList -contains 0x0112) {
                switch ([int]$img.GetPropertyItem(0x0112).Value[0]) {
                    3 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone) }
                    6 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipNone) }
                    8 { $img.RotateFlip([System.Drawing.RotateFlipType]::Rotate270FlipNone) }
                }
            }
            # So klein, dass 1920x1080 gerade noch ganz gefüllt ist; nie vergrößern.
            $k = [Math]::Min(1.0, [Math]::Max(1920.0 / $img.Width, 1080.0 / $img.Height))
            $w = [int][Math]::Round($img.Width * $k)
            $h = [int][Math]::Round($img.Height * $k)
            $bmp = New-Object System.Drawing.Bitmap $w, $h
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.DrawImage($img, 0, 0, $w, $h)
            $params = New-Object System.Drawing.Imaging.EncoderParameters 1
            $params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), ([long]88)
            $bmp.Save($dest, $jpeg, $params)
            $added += (Split-Path -Leaf $dest)
            Say ("  + {0}  ({1}x{2})" -f (Split-Path -Leaf $dest), $w, $h) 'Green'
        } catch {
            Say "  Übersprungen: $src ($($_.Exception.Message))" 'Yellow'
        } finally {
            if ($g) { $g.Dispose() }
            if ($bmp) { $bmp.Dispose() }
            if ($img) { $img.Dispose() }
        }
    }
    return $added
}

# --- Ablauf --------------------------------------------------------------------------------------
$code = 1
try {
    Write-Host ''
    Write-Host '  BetterFireTV' -ForegroundColor Cyan -NoNewline
    Write-Host "  ·  $Modus" -ForegroundColor DarkGray

    Step 'Werkzeuge prüfen'
    $adb = Find-Adb
    Say "  adb:      $adb"
    $bash = Find-GitBash
    Say "  Git Bash: $bash"

    $candidates = @()
    if (-not $Ip) {
        Step 'Fire TV im Heimnetz suchen'
        $nets = @(Get-HomeNetworks)
        if ($nets.Count -eq 0) {
            Say '  Kein Heimnetz gefunden. Ist ein VPN aktiv? Die IP kann gleich auch von Hand eingegeben werden.' 'Yellow'
        }
        foreach ($n in $nets) {
            Say ("  Netz {0}/{1} ({2}) ..." -f $n.Ip, $n.Prefix, $n.Name)
            foreach ($h in (Find-AdbHosts (Get-HostList $n.Ip $n.Prefix))) {
                Say "  ADB offen bei $h" 'Green'
                $candidates += $h
            }
        }
        if ($nets.Count -gt 0 -and $candidates.Count -eq 0) {
            Say '  Kein Gerät mit offenem ADB-Port gefunden.' 'Yellow'
        }
    }

    $neu = @()
    if ($Modus -eq 'hintergrund') {
        Step 'Hintergrundbilder auswählen'
        $neu = @(Add-Wallpapers (Join-Path $Root 'hintergruende'))
    }

    $bashArgs = @('--noprofile', '--norc', (ConvertTo-UnixPath (Join-Path $Root 'tool\betterfiretv.sh')), $Modus)
    if ($Ip) { $bashArgs += @('--ip', $Ip) }
    if ($candidates.Count -gt 0) { $bashArgs += @('--kandidaten', ($candidates -join ' ')) }
    if ($Trockenlauf) { $bashArgs += '--trockenlauf' }
    if ($neu.Count -gt 0) { $bashArgs += @('--neu', ($neu -join ' ')) }

    $env:ADB = ConvertTo-UnixPath $adb
    $env:CHERE_INVOKING = '1'
    & $bash @bashArgs
    $code = $LASTEXITCODE
}
catch {
    Write-Host ''
    Write-Host "FEHLER: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.Message -match 'Gruppenrichtlinie|group policy|blocked|blockiert') {
        Write-Host 'Windows blockiert hier ein Programm (Firmenrichtlinie). Am besten an einem privaten PC ausführen.' -ForegroundColor Yellow
    }
    $code = 1
}

Write-Host ''
if ($code -eq 0) { Write-Host '  Fertig.' -ForegroundColor Green }
else { Write-Host "  Beendet mit Code $code. Das Protokoll liegt im Ordner logs." -ForegroundColor Yellow }
try { [void](Read-Host '  Enter drücken zum Schließen') } catch { }
exit $code
