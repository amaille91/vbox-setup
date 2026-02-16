<#  build-vm.ps1  (ALL-IN-ONE)
    VirtualBox VM builder (Windows) - Debian 12 netinst - Preseed (Http or Iso) - GNOME - UEFI - Dual NIC
    + Post-install over SSH: install Guest Additions from VBoxGuestAdditions.iso
    + Enable bidirectional clipboard + drag&drop
    + Shared folder mechanics (hostshare)

    Notes:
      - Iso mode is the recommended fully unattended path (robust). Requires xorriso OR oscdimg (+ xorriso for extraction).
      - Http mode serves preseed over HTTP but may require manual GRUB edit on UEFI installer (varies by ISO).

    Run example:
      pwsh .\build-vm.ps1 -PreseedMode Iso -DebianIsoPath "C:\ISO\debian-12.x.x-amd64-netinst.iso" `
        -VmCpu 4 -VmRamMB 8192 -DiskMaxGB 60 -SharedFolderHostPath "C:\dev\share" -InstallExtensionPack -InstallGuestAdditions
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('Http','Iso')]
  [string]$PreseedMode,

  [Parameter(Mandatory=$true)]
  [string]$DebianIsoPath,

  [Parameter(Mandatory=$false)]
  [string]$VBoxVersion = '7.2.6',

  # REQUIRED by design (throw if missing/0)
  [int]$VmCpu = 0,
  [int]$VmRamMB = 0,
  [int]$DiskMaxGB = 0,
  [string]$SharedFolderHostPath = '',

  [ValidateSet('gnome')]
  [string]$Desktop = 'gnome',

  [int]$SshHostPort = 2222,

  [string]$Username = 'dev',
  [string]$UserPassword = 'dev',

  # root exists for su, but NOT allowed over SSH
  [string]$RootPassword = 'dev',

  [ValidateSet('Dual','NatOnly','BridgedOnly')]
  [string]$NetworkMode = 'Dual',

  [string]$BridgedAdapterName = '',

  [int]$HttpPort = 8000,

  [ValidateSet('Auto','Xorriso','Oscdimg')]
  [string]$IsoTool = 'Auto',

  [switch]$InstallExtensionPack,

  [switch]$InstallGuestAdditions = $true,

  [int]$InstallTimeoutMinutes = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ThrowIfMissing([string]$name, $value) {
  if ($null -eq $value) { throw "Missing required parameter: $name" }
  if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) { throw "Missing required parameter: $name" }
  if ($value -is [int] -and $value -le 0) { throw "Missing/invalid required parameter: $name (must be > 0)" }
}

function Get-VBoxManagePath {
  $cmd = Get-Command VBoxManage.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $default = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
  if (Test-Path $default) { return $default }
  throw "VBoxManage.exe not found. Ensure VirtualBox is installed and VBoxManage is in PATH."
}

function Invoke-VBox([string]$VBoxManage, [string[]]$Args) {
  Write-Host "VBoxManage $($Args -join ' ')"
  $p = Start-Process -FilePath $VBoxManage -ArgumentList $Args -NoNewWindow -Wait -PassThru
  if ($p.ExitCode -ne 0) {
    throw "VBoxManage failed (exit code $($p.ExitCode)) with args: $($Args -join ' ')"
  }
}

function Get-DefaultBridgedAdapter([string]$VBoxManage) {
  $out = & $VBoxManage list bridgedifs 2>$null
  if (-not $out) { throw "No bridged interfaces returned by VBoxManage." }

  $ifs = @()
  $cur = [ordered]@{}
  foreach ($line in $out) {
    if ($line -match '^\s*Name:\s*(.+)$') { $cur.Name = $Matches[1].Trim() }
    elseif ($line -match '^\s*Status:\s*(.+)$') { $cur.Status = $Matches[1].Trim() }
    elseif ([string]::IsNullOrWhiteSpace($line) -and $cur.Count -gt 0) {
      $ifs += [pscustomobject]$cur
      $cur = [ordered]@{}
    }
  }
  if ($cur.Count -gt 0) { $ifs += [pscustomobject]$cur }

  $up = $ifs | Where-Object { $_.Status -match 'Up' }
  if (-not $up) { throw "No bridged interface in Up status. Check your network adapters." }

  $wifi = $up | Where-Object { $_.Name -match 'Wi-?Fi|Wireless' } | Select-Object -First 1
  if ($wifi) { return $wifi.Name }
  return ($up | Select-Object -First 1).Name
}

function New-VmName {
  return "debian12-gnome-" + (Get-Date -Format "yyyyMMdd-HHmmss")
}

function Ensure-OpenSSH {
  $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
  $sshkey = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
  if (-not $ssh -or -not $sshkey) {
    throw "OpenSSH client not found (ssh/ssh-keygen). Install Windows optional feature 'OpenSSH Client'."
  }
  return [pscustomobject]@{ Ssh=$ssh.Source; SshKeygen=$sshkey.Source }
}

function Ensure-HostSshKey([string]$sshKeygenPath) {
  $sshDir = Join-Path $HOME ".ssh"
  if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }

  $keyPath = Join-Path $sshDir "id_ed25519"
  $pubPath = "$keyPath.pub"
  if (-not (Test-Path $keyPath) -or -not (Test-Path $pubPath)) {
    Write-Host "Generating SSH key for host: $keyPath"
    & $sshKeygenPath -t ed25519 -f $keyPath -N "" | Out-Null
  }
  return [pscustomobject]@{
    Private=$keyPath
    Public=$pubPath
    PublicText=(Get-Content -Raw -Path $pubPath).Trim()
  }
}

function Write-PreseedFile([string]$path, [hashtable]$vars) {
  # Inject host public key so SSH is passwordless immediately after install
@"
### Debian 12 preseed - GNOME - UEFI - LVM (no encryption)

d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i keyboard-configuration/variant select intl
d-i time/zone string Europe/Paris
d-i clock-setup/utc boolean true
d-i clock-setup/ntp boolean true

d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string debian-dev
d-i netcfg/get_domain string local

d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string

d-i passwd/root-login boolean true
d-i passwd/root-password password $($vars.RootPassword)
d-i passwd/root-password-again password $($vars.RootPassword)

d-i passwd/make-user boolean true
d-i passwd/user-fullname string Developer
d-i passwd/username string $($vars.Username)
d-i passwd/user-password password $($vars.UserPassword)
d-i passwd/user-password-again password $($vars.UserPassword)

popularity-contest popularity-contest/participate boolean false

d-i partman-auto/method string lvm
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-auto-lvm/guided_size string max
d-i partman-auto/choose_recipe select atomic
d-i partman/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

tasksel tasksel/first multiselect standard, desktop, gnome-desktop
d-i pkgsel/include string openssh-server sudo curl ca-certificates gnupg build-essential dkms linux-headers-amd64
d-i pkgsel/upgrade select safe-upgrade

d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true

d-i preseed/late_command string \
  in-target usermod -aG sudo $($vars.Username) ; \
  in-target mkdir -p /home/$($vars.Username)/.ssh ; \
  in-target sh -c 'echo "$($vars.HostSshPubKey)" > /home/$($vars.Username)/.ssh/authorized_keys' ; \
  in-target chown -R $($vars.Username):$($vars.Username) /home/$($vars.Username)/.ssh ; \
  in-target chmod 700 /home/$($vars.Username)/.ssh ; \
  in-target chmod 600 /home/$($vars.Username)/.ssh/authorized_keys ; \
  in-target sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config ; \
  in-target sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config ; \
  in-target systemctl enable ssh ; \
  in-target systemctl restart ssh || true

d-i finish-install/reboot_in_progress note
"@ | Set-Content -Path $path -Encoding UTF8
}

function Start-PreseedHttpServer([string]$filePath, [int]$port) {
  $listener = New-Object System.Net.HttpListener
  $prefix = "http://*:$port/"
  $listener.Prefixes.Add($prefix)
  $listener.Start()
  Write-Host "Preseed HTTP server started at $prefix (serving /preseed.cfg)"

  $job = Start-Job -ScriptBlock {
    param($listener, $filePath)
    try {
      while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response

        if ($req.Url.AbsolutePath -eq '/preseed.cfg') {
          $bytes = [System.Text.Encoding]::UTF8.GetBytes((Get-Content -Raw -Path $filePath))
          $res.ContentType = "text/plain; charset=utf-8"
          $res.StatusCode = 200
          $res.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
          $res.StatusCode = 404
        }
        $res.OutputStream.Close()
      }
    } catch {}
  } -ArgumentList $listener, $filePath

  return [pscustomobject]@{ Listener = $listener; Job = $job }
}

function Stop-PreseedHttpServer($server) {
  if ($server -and $server.Listener) { try { $server.Listener.Stop() } catch {} }
  if ($server -and $server.Job) {
    try { Stop-Job $server.Job -Force | Out-Null } catch {}
    try { Remove-Job $server.Job -Force | Out-Null } catch {}
  }
}

function Ensure-ExtensionPack([string]$VBoxManage, [string]$VBoxVersion) {
  $extName = "Oracle_VirtualBox_Extension_Pack-$VBoxVersion.vbox-extpack"
  $url = "https://download.virtualbox.org/virtualbox/$VBoxVersion/$extName"
  $tmp = Join-Path $env:TEMP $extName

  Write-Host "Downloading Extension Pack: $url"
  Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing

  Write-Host "Installing Extension Pack (you may be prompted to accept license)..."
  & $VBoxManage extpack install --replace $tmp
  if ($LASTEXITCODE -ne 0) { throw "Extension Pack install failed. Re-run and accept the license prompt." }
}

function New-Disk([string]$VBoxManage, [string]$vmName, [int]$diskGB) {
  $vmFolder = Join-Path (Join-Path $env:USERPROFILE "VirtualBox VMs") $vmName
  $diskPath = Join-Path $vmFolder "disk.vdi"
  Invoke-VBox $VBoxManage @("createmedium","disk","--filename",$diskPath,"--size",("$($diskGB*1024)"))
  return $diskPath
}

function Wait-ForTcp([string]$host, [int]$port, [int]$timeoutSeconds, [string]$label) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $timeoutSeconds) {
    try {
      $client = New-Object System.Net.Sockets.TcpClient
      $iar = $client.BeginConnect($host, $port, $null, $null)
      if ($iar.AsyncWaitHandle.WaitOne(2000, $false)) {
        $client.EndConnect($iar); $client.Close()
        Write-Host "$label is reachable on $host:$port"
        return $true
      }
      $client.Close()
    } catch {}
    Start-Sleep -Seconds 3
  }
  return $false
}

function Get-VBoxGuestAdditionsIsoPath {
  $p = "C:\Program Files\Oracle\VirtualBox\VBoxGuestAdditions.iso"
  if (Test-Path $p) { return $p }
  throw "VBoxGuestAdditions.iso not found at default path: $p"
}

function Ssh-Run([string]$sshPath, [string]$keyPath, [int]$port, [string]$user, [string]$command) {
  $args = @(
    "-i", $keyPath,
    "-p", "$port",
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "ConnectTimeout=10",
    "$user@127.0.0.1",
    $command
  )
  Write-Host "ssh $($args -join ' ')"
  $p = Start-Process -FilePath $sshPath -ArgumentList $args -NoNewWindow -Wait -PassThru
  if ($p.ExitCode -ne 0) { throw "SSH command failed (exit $($p.ExitCode)): $command" }
}

function PostInstall-GuestAdditions([string]$VBoxManage, [string]$vmName, [string]$sshPath, [string]$sshKeyPath, [int]$sshPort, [string]$user) {
  Write-Host ""
  Write-Host "== Post-install: Guest Additions =="

  # Enable clipboard + drag&drop
  Invoke-VBox $VBoxManage @("modifyvm",$vmName,"--clipboard","bidirectional")
  Invoke-VBox $VBoxManage @("modifyvm",$vmName,"--draganddrop","bidirectional")

  # Attach GA ISO on the same DVD drive
  $gaIso = Get-VBoxGuestAdditionsIsoPath
  Write-Host "Attaching Guest Additions ISO: $gaIso"
  Invoke-VBox $VBoxManage @("storageattach",$vmName,"--storagectl","IDE","--port","0","--device","0","--type","dvddrive","--medium",$gaIso)

  $cmd = @'
set -euxo pipefail
sudo apt-get update
sudo apt-get install -y build-essential dkms perl linux-headers-$(uname -r)

sudo mkdir -p /mnt/vbox
if ! mountpoint -q /mnt/vbox; then
  sudo mount /dev/cdrom /mnt/vbox 2>/dev/null || sudo mount /dev/sr0 /mnt/vbox 2>/dev/null || true
fi
if [ ! -f /mnt/vbox/VBoxLinuxAdditions.run ]; then
  echo "VBoxLinuxAdditions.run not found on mounted media" >&2
  ls -la /mnt/vbox || true
  exit 2
fi

sudo sh /mnt/vbox/VBoxLinuxAdditions.run --nox11 || sudo sh /mnt/vbox/VBoxLinuxAdditions.run

# shared folder group access
sudo usermod -aG vboxsf "$USER"
'@

  $quoted = $cmd.Replace("`","``").Replace('"','\"')
  Ssh-Run $sshPath $sshKeyPath $sshPort $user "bash -lc `"$quoted`""

  # reboot
  Ssh-Run $sshPath $sshKeyPath $sshPort $user "sudo reboot" | Out-Null

  Start-Sleep -Seconds 5
  $ok = Wait-ForTcp -host "127.0.0.1" -port $sshPort -timeoutSeconds (15*60) -label "SSH after GA reboot"
  if (-not $ok) { throw "VM did not come back on SSH after Guest Additions install/reboot." }

  Ssh-Run $sshPath $sshKeyPath $sshPort $user "bash -lc 'lsmod | grep -E \"vboxguest|vboxsf\" || true'"
  Write-Host "Guest Additions installed and VM rebooted."
}

function Find-IsoTool([string]$pref) {
  $x = Get-Command xorriso.exe -ErrorAction SilentlyContinue
  $o = Get-Command oscdimg.exe -ErrorAction SilentlyContinue

  if ($pref -eq 'Xorriso') { if ($x) { return [pscustomobject]@{ Tool='xorriso'; Path=$x.Source } } }
  if ($pref -eq 'Oscdimg') { if ($o) { return [pscustomobject]@{ Tool='oscdimg'; Path=$o.Source } } }

  if ($pref -eq 'Auto') {
    if ($x) { return [pscustomobject]@{ Tool='xorriso'; Path=$x.Source } }
    if ($o) { return [pscustomobject]@{ Tool='oscdimg'; Path=$o.Source } }
  }
  return $null
}

function Update-IsoMd5Sums([string]$rootDir) {
  $md5File = Join-Path $rootDir "md5sum.txt"
  if (-not (Test-Path $md5File)) { return }

  Write-Host "Updating md5sum.txt..."
  $lines = @()

  $allFiles = Get-ChildItem -Path $rootDir -Recurse -File | Where-Object { $_.FullName -ne $md5File }

  foreach ($f in $allFiles) {
    $rel = $f.FullName.Substring($rootDir.Length).Replace('\','/')
    if ($rel.StartsWith('/')) { $rel = $rel.Substring(1) }
    $h = Get-FileHash -Algorithm MD5 -Path $f.FullName
    $lines += ("{0}  {1}" -f $h.Hash.ToLowerInvariant(), $rel)
  }

  $lines | Set-Content -Path $md5File -Encoding ASCII
}

function Patch-Debian12InstallerMenus([string]$rootDir, [string]$preseedIsoPath) {
  $args = " auto=true priority=critical preseed/file=$preseedIsoPath"

  $grubCfg = Join-Path $rootDir "boot\grub\grub.cfg"
  if (Test-Path $grubCfg) {
    Write-Host "Patching UEFI GRUB: $grubCfg"
    $txt = Get-Content -Raw -Path $grubCfg
    $txt2 = $txt -replace '(\n\s*linux\s+[^\n]+)', ('$1' + $args)
    Set-Content -Path $grubCfg -Value $txt2 -Encoding UTF8
  } else {
    Write-Warning "UEFI GRUB config not found: $grubCfg"
  }

  $isoTxtCfg = Join-Path $rootDir "isolinux\txt.cfg"
  if (Test-Path $isoTxtCfg) {
    Write-Host "Patching BIOS ISOLINUX: $isoTxtCfg"
    $txt = Get-Content -Raw -Path $isoTxtCfg
    $txt2 = $txt -replace '(\n\s*append\s+[^\n]+)', ('$1' + $args)
    Set-Content -Path $isoTxtCfg -Value $txt2 -Encoding ASCII
  }
}

function Build-CustomDebian12Iso([string]$sourceIso, [string]$workDir, [string]$preseedPath, [string]$toolPref) {
  $tool = Find-IsoTool -pref $toolPref
  if (-not $tool) {
    throw @"
No ISO build tool found.

Install one of:
  - xorriso (recommended): easiest to keep Debian ISO boot settings (replay).
    Example via MSYS2:
      1) Install MSYS2
      2) pacman -Syu
      3) pacman -S xorriso
      4) Add xorriso.exe to PATH

  - oscdimg (Windows ADK Deployment Tools):
      1) Install Windows ADK
      2) Select 'Deployment Tools'
      3) Ensure oscdimg.exe is in PATH
"@
  }

  $extractDir = Join-Path $workDir "iso-root"
  if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
  New-Item -ItemType Directory -Path $extractDir | Out-Null

  $customIso = Join-Path $workDir ("debian12-preseeded-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".iso")
  $preseedIsoPath = "/preseed.cfg"

  if ($tool.Tool -eq 'xorriso') {
    Write-Host "Extracting ISO with xorriso..."
    & $tool.Path -osirrox on -indev $sourceIso -extract / $extractDir
    if ($LASTEXITCODE -ne 0) { throw "xorriso extract failed." }

    Copy-Item -Path $preseedPath -Destination (Join-Path $extractDir "preseed.cfg") -Force

    Patch-Debian12InstallerMenus -rootDir $extractDir -preseedIsoPath $preseedIsoPath
    Update-IsoMd5Sums -rootDir $extractDir

    Write-Host "Repacking ISO with xorriso (replaying boot config)..."
    & $tool.Path -indev $sourceIso -outdev $customIso `
      -map $extractDir / `
      -boot_image any replay `
      -compliance no_emul_toc -padding included

    if ($LASTEXITCODE -ne 0) { throw "xorriso repack failed." }
    return $customIso
  }

  if ($tool.Tool -eq 'oscdimg') {
    $x = Get-Command xorriso.exe -ErrorAction SilentlyContinue
    if (-not $x) {
      throw "oscdimg mode requires xorriso for reliable ISO extraction. Install xorriso or use -IsoTool Xorriso."
    }

    Write-Host "Extracting ISO with xorriso (needed on Windows)..."
    & $x.Source -osirrox on -indev $sourceIso -extract / $extractDir
    if ($LASTEXITCODE -ne 0) { throw "xorriso extract failed." }

    Copy-Item -Path $preseedPath -Destination (Join-Path $extractDir "preseed.cfg") -Force

    Patch-Debian12InstallerMenus -rootDir $extractDir -preseedIsoPath $preseedIsoPath
    Update-IsoMd5Sums -rootDir $extractDir

    $biosBoot = "isolinux\isolinux.bin"
    $bootCat  = "isolinux\boot.cat"
    $efiImg   = "boot\grub\efi.img"

    foreach ($p in @($biosBoot,$bootCat,$efiImg)) {
      if (-not (Test-Path (Join-Path $extractDir $p))) {
        throw "Expected boot file not found in extracted ISO: $p. Use -IsoTool Xorriso."
      }
    }

    Write-Host "Repacking ISO with oscdimg..."
    $args = @(
      "-m","-o","-u2","-udfver102",
      "-bootdata:2#p0,e,b$biosBoot#pEF,e,b$efiImg",
      "-bootcatalog",$bootCat,
      $extractDir,
      $customIso
    )
    & $tool.Path @args
    if ($LASTEXITCODE -ne 0) { throw "oscdimg repack failed." }
    return $customIso
  }

  throw "Unsupported ISO tool."
}

# ----------------- VALIDATION -----------------
ThrowIfMissing "DebianIsoPath" $DebianIsoPath
if (-not (Test-Path $DebianIsoPath)) { throw "Debian ISO not found at: $DebianIsoPath" }

ThrowIfMissing "VmCpu" $VmCpu
ThrowIfMissing "VmRamMB" $VmRamMB
ThrowIfMissing "DiskMaxGB" $DiskMaxGB
ThrowIfMissing "SharedFolderHostPath" $SharedFolderHostPath
if (-not (Test-Path $SharedFolderHostPath)) { throw "SharedFolderHostPath does not exist: $SharedFolderHostPath" }

$VBoxManage = Get-VBoxManagePath
$sshTools = Ensure-OpenSSH
$hostKey = Ensure-HostSshKey -sshKeygenPath $sshTools.SshKeygen

$vmName = New-VmName
$workDir = Join-Path $PSScriptRoot "work-$vmName"
New-Item -ItemType Directory -Path $workDir | Out-Null
$logPath = Join-Path $workDir "build.log.txt"
Start-Transcript -Path $logPath | Out-Null

Write-Host "VM Name: $vmName"
Write-Host "Preseed mode: $PreseedMode"
Write-Host "Working dir: $workDir"
Write-Host "Host SSH key: $($hostKey.Private)"

$preseedPath = Join-Path $workDir "preseed.cfg"
Write-PreseedFile -path $preseedPath -vars @{
  Username=$Username
  UserPassword=$UserPassword
  RootPassword=$RootPassword
  HostSshPubKey=$hostKey.PublicText
}

if ($InstallExtensionPack) {
  try { Ensure-ExtensionPack -VBoxManage $VBoxManage -VBoxVersion $VBoxVersion }
  catch { Write-Warning $_; Write-Warning "Continuing without Extension Pack." }
}

$existing = & $VBoxManage list vms | Select-String -Pattern ('"' + [regex]::Escape($vmName) + '"')
if ($existing) { throw "VM already exists: $vmName" }

if ($NetworkMode -in @('Dual','BridgedOnly')) {
  if ([string]::IsNullOrWhiteSpace($BridgedAdapterName)) {
    $BridgedAdapterName = Get-DefaultBridgedAdapter -VBoxManage $VBoxManage
    Write-Host "Auto-selected bridged adapter (prefers Wi-Fi): $BridgedAdapterName"
    Write-Host "If incorrect: VBoxManage list bridgedifs  (then pass -BridgedAdapterName '<Name>')"
  }
}

$httpServer = $null
$preseedUrl = $null
if ($PreseedMode -eq 'Http') {
  $preseedUrl = "http://10.0.2.2:$HttpPort/preseed.cfg"
  $httpServer = Start-PreseedHttpServer -filePath $preseedPath -port $HttpPort
  Write-Host "Preseed URL (from guest): $preseedUrl"
}

$isoToUse = $DebianIsoPath
if ($PreseedMode -eq 'Iso') {
  Write-Host "Building custom Debian 12 ISO (preseed embedded)..."
  $isoToUse = Build-CustomDebian12Iso -sourceIso $DebianIsoPath -workDir $workDir -preseedPath $preseedPath -toolPref $IsoTool
  Write-Host "Custom ISO created: $isoToUse"
}

# ----------------- CREATE VM -----------------
Invoke-VBox $VBoxManage @("createvm","--name",$vmName,"--ostype","Debian_64","--register")

Invoke-VBox $VBoxManage @("modifyvm",$vmName,
  "--firmware","efi",
  "--cpus",$VmCpu,
  "--memory",$VmRamMB,
  "--vram","128",
  "--graphicscontroller","vmsvga",
  "--accelerate3d","on",
  "--usb","on",
  "--usbxhci","on"
)

# NICs
if ($NetworkMode -eq 'NatOnly' -or $NetworkMode -eq 'Dual') {
  Invoke-VBox $VBoxManage @("modifyvm",$vmName,"--nic1","nat")
  Invoke-VBox $VBoxManage @("modifyvm",$vmName,"--natpf1","ssh,tcp,127.0.0.1,$SshHostPort,,22")
} else {
  Invoke-VBox $VBoxManage @("modifyvm",$vmName,"--nic1","none")
}

if ($NetworkMode -eq 'BridgedOnly') {
  Invoke-VBox $VBoxManage @("modifyvm",$vmName,"--nic1","bridged","--bridgeadapter1",$BridgedAdapterName)
} elseif ($NetworkMode -eq 'Dual') {
  Invoke-VBox $VBoxManage @("modifyvm",$vmName,"--nic2","bridged","--bridgeadapter2",$BridgedAdapterName)
}

# Storage controllers
Invoke-VBox $VBoxManage @("storagectl",$vmName,"--name","SATA","--add","sata","--controller","IntelAhci")
Invoke-VBox $VBoxManage @("storagectl",$vmName,"--name","IDE","--add","ide")

# Disk
$diskPath = New-Disk -VBoxManage $VBoxManage -vmName $vmName -diskGB $DiskMaxGB
Invoke-VBox $VBoxManage @("storageattach",$vmName,"--storagectl","SATA","--port","0","--device","0","--type","hdd","--medium",$diskPath)

# ISO
Invoke-VBox $VBoxManage @("storageattach",$vmName,"--storagectl","IDE","--port","0","--device","0","--type","dvddrive","--medium",$isoToUse)

# Shared folder (works after GA)
Invoke-VBox $VBoxManage @("sharedfolder","add",$vmName,"--name","hostshare","--hostpath",$SharedFolderHostPath,"--automount")

# Start VM (GUI)
Write-Host "Starting VM in GUI mode..."
Invoke-VBox $VBoxManage @("startvm",$vmName,"--type","gui")

if ($PreseedMode -eq 'Http') {
  Write-Warning "HTTP mode: If installer doesn't auto-start, edit GRUB entry and append:"
  Write-Host "  auto=true priority=critical preseed/url=$preseedUrl"
}

# ----------------- WAIT FOR SSH -----------------
$timeoutSeconds = $InstallTimeoutMinutes * 60
Write-Host "Waiting up to $InstallTimeoutMinutes minutes for SSH on localhost:$SshHostPort (post-install)..."
$sshUp = Wait-ForTcp -host "127.0.0.1" -port $SshHostPort -timeoutSeconds $timeoutSeconds -label "SSH"

if (-not $sshUp) {
  Write-Warning "SSH did not become available within timeout."
  if ($PreseedMode -eq 'Http') { Write-Warning "Likely boot args not applied. Prefer PreseedMode=Iso." }
} else {
  Write-Host ""
  Write-Host "SSH access (key-based):"
  Write-Host "  ssh -i `"$($hostKey.Private)`" -p $SshHostPort $Username@127.0.0.1"
  Write-Host "  (password auth also enabled; root SSH login disabled; use 'su' inside VM)"

  if ($InstallGuestAdditions) {
    PostInstall-GuestAdditions -VBoxManage $VBoxManage -vmName $vmName `
      -sshPath $sshTools.Ssh -sshKeyPath $hostKey.Private -sshPort $SshHostPort -user $Username
  }
}

if ($httpServer) { Stop-PreseedHttpServer $httpServer }

Write-Host ""
Write-Host "Build output:"
Write-Host "  VM name: $vmName"
Write-Host "  VM disk: $diskPath"
Write-Host "  ISO used: $isoToUse"
Write-Host "  Log: $logPath"
Write-Host "  Preseed: $preseedPath"
Write-Host "  Network: $NetworkMode (NAT SSH localhost:$SshHostPort; Bridged: $BridgedAdapterName)"
Write-Host ""
Write-Host "Host SSH key summary:"
Write-Host "  Private: $($hostKey.Private)"
Write-Host "  Public : $($hostKey.Public)"
Write-Host "Done."

Stop-Transcript | Out-Null
