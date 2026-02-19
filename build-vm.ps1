<#  build-vm.ps1  (ALL-IN-ONE, PATCHED)
    VirtualBox VM builder (Windows) - Debian 12 netinst - Preseed (Http or Iso) - GNOME - UEFI - Dual NIC
    + Post-install over SSH: install Guest Additions from VBoxGuestAdditions.iso
    + Enable bidirectional clipboard + drag&drop
    + Shared folder mechanics (hostshare)

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

function Invoke-VBox([string]$VBoxManage, [string[]]$VBoxArgs) {
  if (-not $VBoxArgs -or $VBoxArgs.Count -eq 0) {
    throw "BUG: Invoke-VBox called with empty argument list."
  }

  # Quote args that contain spaces or quotes
  $quoted = $VBoxArgs | ForEach-Object {
    if ($_ -match '[\s"]') {
      '"' + ($_ -replace '"','\"') + '"'
    } else {
      $_
    }
  }

  $cmdLine = $quoted -join ' '
  Write-Host "VBoxManage $cmdLine"

  $p = Start-Process -FilePath $VBoxManage -ArgumentList $cmdLine -NoNewWindow -Wait -PassThru
  if ($p.ExitCode -ne 0) {
    throw "VBoxManage failed (exit code $($p.ExitCode)) with args: $cmdLine"
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
  if ((-not $ssh) -or (-not $sshkey)) {
    throw "OpenSSH client not found (ssh/ssh-keygen). Install Windows optional feature 'OpenSSH Client'."
  }
  return [pscustomobject]@{ Ssh=$ssh.Source; SshKeygen=$sshkey.Source }
}

# Robust, collision-free: generate a dedicated key under workDir\ssh\<vmName>, with fallbacks if ssh-keygen is picky.
function New-HostSshKeyPair([string]$sshKeygenPath, [string]$baseDir, [string]$vmName) {
  $sshDir = Join-Path $baseDir "ssh"
  if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }

  $safeVm = ($vmName -replace '[^a-zA-Z0-9_.-]', '_')
  $keyPath = Join-Path $sshDir ("id_ed25519_" + $safeVm)
  $pubPath = "$keyPath.pub"

  if ((Test-Path $keyPath) -or (Test-Path $pubPath)) {
    $suffix = [Guid]::NewGuid().ToString("N").Substring(0,8)
    $keyPath = Join-Path $sshDir ("id_ed25519_" + $safeVm + "_" + $suffix)
    $pubPath = "$keyPath.pub"
  }

  Write-Host "Generating dedicated SSH key for this VM:"
  Write-Host "  $keyPath"

  # Attempt 1: standard non-interactive generation
  & $sshKeygenPath -t ed25519 -f $keyPath -N "" -q | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed (exit $LASTEXITCODE). Key path: $keyPath" }
  # $args1 = @("-t","ed25519","-f",$keyPath,"-N","", "-q")
  # $p1 = Start-Process -FilePath $sshKeygenPath -ArgumentList $args1 -NoNewWindow -Wait -PassThru
  # if ($p1.ExitCode -ne 0) {
    # Attempt 2: use cmd.exe quoting for -N "" (some Windows OpenSSH builds are finicky)
  #   $cmdLine = "`"$sshKeygenPath`" -t ed25519 -f `"$keyPath`" -N `"""`" -q"
  #   $p2 = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", $cmdLine) -NoNewWindow -Wait -PassThru
  #   if ($p2.ExitCode -ne 0) {
  #     throw "ssh-keygen failed (exit $($p2.ExitCode)). Try running without -q to see message. Key path: $keyPath"
  #   }
  # }

  if (-not (Test-Path $pubPath)) {
    # regenerate pub from private
    $p3 = Start-Process -FilePath $sshKeygenPath -ArgumentList @("-y","-f",$keyPath) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $pubPath
    if (($p3.ExitCode -ne 0) -or (-not (Test-Path $pubPath))) {
      throw "Public key not found and regeneration failed: $pubPath"
    }
  }

  return [pscustomobject]@{
    Private    = $keyPath
    Public     = $pubPath
    PublicText = (Get-Content -Raw -Path $pubPath).Trim()
  }
}

function Write-PreseedFile([string]$path, [hashtable]$vars) {
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

### ===== FULLY AUTOMATIC DISK (THIS IS THE MISSING PIECE) =====

d-i partman-auto/method string lvm
d-i partman-auto-lvm/guided_size string max

# wipe any previous structures
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true

d-i partman-md/device_remove_md boolean true
d-i partman-md/confirm boolean true

# remove old partitions
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/confirm_write_new_label boolean true

# choose recipe automatically
d-i partman-auto/choose_recipe select atomic

# DO NOT STOP
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i partman/confirm_write_new_label boolean true

# really non interactive
d-i partman/early_command string \
    debconf-set partman-auto/disk "`$(list-devices disk | head -n1)"


tasksel tasksel/first multiselect standard, desktop, gnome-desktop
d-i pkgsel/include string openssh-server sudo curl ca-certificates gnupg build-essential dkms linux-headers-amd64 acpid
d-i pkgsel/upgrade select safe-upgrade

d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
d-i preseed/late_command string \
  in-target usermod -aG sudo $($vars.Username) ; \
  in-target sh -c 'echo "$($vars.Username) ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-$($vars.Username)' ; \
  in-target chmod 440 /etc/sudoers.d/90-$($vars.Username) ; \
  in-target mkdir -p /home/$($vars.Username)/.ssh ; \
  in-target sh -c 'printf "%s\n" "$($vars.HostSshPubKey)" > /home/$($vars.Username)/.ssh/authorized_keys' ; \
  in-target chown -R $($vars.Username):$($vars.Username) /home/$($vars.Username)/.ssh ; \
  in-target chmod 700 /home/$($vars.Username)/.ssh ; \
  in-target chmod 600 /home/$($vars.Username)/.ssh/authorized_keys ; \
  in-target sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config ; \
  in-target sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config ; \
  in-target mkdir -p /etc/systemd/system/multi-user.target.wants ; \
  in-target ln -sf /lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service || true ;

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
  # Accepte: 7.0.12  |  7.0.12r159484  |  7.0.12-159484
  if ($VBoxVersion -match '^(?<ver>\d+\.\d+\.\d+)(?:r|-)?(?<rev>\d+)?$') {
    $ver = $Matches.ver
    $rev = $Matches.rev
  } else {
    throw "Invalid VBoxVersion format: $VBoxVersion"
  }

  $dir = $ver

  # Essaye d'abord le fichier avec revision si on l'a, sinon sans
  $candidates = @()
  if ($rev) { $candidates += "Oracle_VM_VirtualBox_Extension_Pack-$ver-$rev.vbox-extpack" }

  foreach ($extName in $candidates) {
    $url = "https://download.virtualbox.org/virtualbox/$dir/$extName"
    $tmp = Join-Path $env:TEMP $extName

    Write-Host "Downloading Extension Pack: $url"
    try {
      Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
      Write-Host "Installing Extension Pack..."
      & $VBoxManage extpack install --replace $tmp
      if ($LASTEXITCODE -ne 0) { throw "Extension Pack install failed." }
      return
    } catch {
      Write-Warning "Failed with: $url"
    }
  }

  throw "Could not download Extension Pack for version $VBoxVersion (tried: $($candidates -join ', '))."
}

function New-Disk([string]$VBoxManage, [string]$vmName, [int]$diskGB) {
  $vmFolder = Join-Path (Join-Path $env:USERPROFILE "VirtualBox VMs") $vmName
  $diskPath = Join-Path $vmFolder "disk.vdi"
  Invoke-VBox $VBoxManage @("createmedium","disk","--filename",$diskPath,"--size",("$($diskGB*1024)"))
  return $diskPath
}

function Test-Ssh([string]$sshPath, [string]$keyPath, [int]$port, [string]$user) {
  $arg = @(
    "-i", $keyPath,
    "-p", "$port",
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=NUL",
    "-o", "ConnectTimeout=5",
    "$user@127.0.0.1",
    "true"
  )
  $p = Start-Process -FilePath $sshPath -ArgumentList $arg -NoNewWindow -Wait -PassThru
  return ($p.ExitCode -eq 0)
}

function Wait-ForSsh([string]$sshPath, [string]$keyPath, [int]$port, [string]$user, [int]$timeoutSeconds, [string]$label) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $timeoutSeconds) {
    if (Test-Ssh $sshPath $keyPath $port $user) {
      Write-Host "$label is ready on 127.0.0.1:$port"
      return $true
    }
    Start-Sleep -Seconds 3
  }
  return $false
}

function Wait-ForTcp([string]$targetHost, [int]$port, [int]$timeoutSeconds, [string]$label) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $timeoutSeconds) {
    try {
      $client = New-Object System.Net.Sockets.TcpClient
      $iar = $client.BeginConnect($targetHost, $port, $null, $null)
      if ($iar.AsyncWaitHandle.WaitOne(2000, $false)) {
        $client.EndConnect($iar); $client.Close()
        Write-Host "$label is reachable on $($targetHost):$port"
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
  $arg = @(
    "-i", $keyPath,
    "-p", "$port",
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "ConnectTimeout=10",
    "$user@127.0.0.1",
    $command
  )
  Write-Host "ssh $($arg -join ' ')"
  $p = Start-Process -FilePath $sshPath -ArgumentList $arg -NoNewWindow -Wait -PassThru
  if ($p.ExitCode -ne 0) { throw "SSH command failed (exit $($p.ExitCode)): $command" }
}

function PostInstall-GuestAdditions([string]$VBoxManage, [string]$vmName, [string]$sshPath, [string]$sshKeyPath, [int]$sshPort, [string]$user) {
  Write-Host ""
  Write-Host "== Post-install: Guest Additions =="
  
  # seulement si toujours allumée
  $stateLine = (& $VBoxManage showvminfo $vmName --machinereadable) | Select-String '^VMState='
  if (-not ($stateLine -and $stateLine.Line -match 'poweroff')) {
      Write-Warning "Forced poweroff fallback"
      Invoke-VBox $VBoxManage @("controlvm",$vmName,"poweroff")
      Start-Sleep 5
  }

  Write-Host "Modifying VM"
  # Ensure NAT port-forward still exists (some VBox changes can wipe it)
  Invoke-VBox $VBoxManage @("modifyvm",$vmName,"--nic1","nat")
  try { Invoke-VBox $VBoxManage @("modifyvm",$vmName,"--natpf1","delete","ssh") } catch {}
  Invoke-VBox $VBoxManage @("modifyvm",$vmName,"--natpf1","ssh,tcp,127.0.0.1,$sshPort,,22")

  # IMPORTANT: apply settings and attach ISO while VM is OFF
  Invoke-VBox $VBoxManage @("modifyvm",$vmName,"--clipboard","bidirectional")
  Invoke-VBox $VBoxManage @("modifyvm",$vmName,"--draganddrop","bidirectional")

  $gaIso = Get-VBoxGuestAdditionsIsoPath
  Write-Host "Attaching Guest Additions ISO: $gaIso"
  Invoke-VBox $VBoxManage @("storageattach",$vmName,"--storagectl","IDE","--port","0","--device","0","--type","dvddrive","--medium",$gaIso)

  Invoke-VBox $VBoxManage @("modifyvm",$vmName,"--boot1","disk","--boot2","dvd","--boot3","none","--boot4","none")

  Write-Host "Starting VM headless..."
  Invoke-VBox $VBoxManage @("startvm",$vmName,"--type","headless")

  & $VBoxManage showvminfo $vmName --machinereadable | Select-String -Pattern 'nic1=|natpf1|bridgeadapter|VMState='
  & $VBoxManage controlvm $vmName screenshotpng (Join-Path $env:TEMP "$vmName.png")

  Write-Host "Waiting for SSH to be READY..."
  $ok = Wait-ForSsh -sshPath $sshPath -keyPath $sshKeyPath -port $sshPort -user $user -timeoutSeconds (5*60) -label "SSH"
  if (-not $ok) { throw "SSH did not become ready after restarting the VM." }

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
sudo usermod -aG vboxsf "$USER"
'@

  $cmdB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cmd))
  $remote = "bash -lc `"echo $cmdB64 | base64 -d | bash`""
  Ssh-Run $sshPath $sshKeyPath $sshPort $user $remote

  Ssh-Run $sshPath $sshKeyPath $sshPort $user "sudo reboot" | Out-Null
  Start-Sleep -Seconds 5

  $ok = Wait-ForSsh -sshPath $sshPath -keyPath $sshKeyPath -port $sshPort -user $user -timeoutSeconds (15*60) -label "SSH after GA reboot"
  if (-not $ok) { throw "VM did not come back on SSH after Guest Additions install/reboot." }

  Ssh-Run $sshPath $sshKeyPath $sshPort $user "bash -lc `"lsmod | awk '{print `$1}' | grep -E '^(vboxguest|vboxsf|vboxvideo)$' || true`""
  Write-Host "Guest Additions installed. Switching back to graphical target..."

  # If you masked gdm3 during install, unmask it here (safe to run even if not masked)
  Ssh-Run $sshPath $sshKeyPath $sshPort $user "sudo systemctl unmask gdm3 || true"
  Ssh-Run $sshPath $sshKeyPath $sshPort $user "sudo systemctl unmask display-manager || true"
  Ssh-Run $sshPath $sshKeyPath $sshPort $user "sudo systemctl set-default graphical.target"
  Ssh-Run $sshPath $sshKeyPath $sshPort $user "sudo ln -sf /lib/systemd/system/gdm3.service /etc/systemd/system/display-manager.service"
  Ssh-Run $sshPath $sshKeyPath $sshPort $user "sudo systemctl restart gdm3 || sudo systemctl restart display-manager || true"
  Ssh-Run $sshPath $sshKeyPath $sshPort $user "sudo reboot" | Out-Null
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
  $arg = " auto=true priority=critical preseed/file=$preseedIsoPath nomodeset DEBIAN_FRONTEND=text fb=false vga=normal"

  $grubCfg = Join-Path $rootDir "boot\grub\grub.cfg"
  if (Test-Path $grubCfg) {
    Write-Host "Patching UEFI GRUB: $grubCfg"
    $txt2 = Get-Content -Raw -Path $grubCfg

    # Nettoyage pour éviter double injection (idempotent)
    $txt2 = $txt2 -replace '\s+auto=true\s+priority=critical\s+preseed/file=/preseed\.cfg(?:\s+nomodeset)?', ''

    # Injection robuste ligne-par-ligne (GRUB)
    $lines = $txt2 -split "`n"
    for ($i=0; $i -lt $lines.Count; $i++) {
      $line = $lines[$i]
    
      # cible: lignes linux ... --- ...
      if ($line -match '^\s*linux\s+' -and $line -match '\s---(\s|$)') {
    
        # si déjà nos params auto+preseed sont présents, ne rien faire
        if ($line -match 'auto=true' -and $line -match 'preseed/file=/preseed\.cfg') { continue }
        
        # sinon, retire anciens fragments éventuels puis injecte proprement
        $line = $line -replace '\s+auto=true\b', ''
        $line = $line -replace '\s+priority=critical\b', ''
        $line = $line -replace '\s+preseed/file=/preseed\.cfg\b', ''
        $line = $line -replace '\s+nomodeset\b', ''
        $line = $line -replace '\s+DEBIAN_FRONTEND=text\b', ''
        $line = $line -replace '\s+fb=false\b', ''
        $line = $line -replace '\s+vga=normal\b', ''
        $lines[$i] = $line -replace '\s---(\s|$)', ($arg + ' ---$1')
      }
    }
    $txt2 = ($lines -join "`n")

    # Optionnel : retire vga=... (souvent inutile en UEFI)
    $txt2 = $txt2 -replace '\svga=\d+\b', ''

    # Supprime proprement les menuentry GTK (initrd gtk) en respectant les accolades
    $lines = $txt2 -split "`n"
    
    $out = New-Object System.Collections.Generic.List[string]
    $inEntry = $false
    $depth = 0
    $entryLines = New-Object System.Collections.Generic.List[string]
    $entryIsGtk = $false
    
    foreach ($l in $lines) {
      if (-not $inEntry) {
        if ($l -match '^\s*menuentry\b') {
          $inEntry = $true
          $depth = 0
          $entryIsGtk = $false
          $entryLines.Clear()
        } else {
          $out.Add($l)
          continue
        }
      }
    
      # dans un menuentry
      $entryLines.Add($l)
      if ($l -match '^\s*initrd\s+/install\.amd/gtk/initrd\.gz\b') { $entryIsGtk = $true }
    
      # compter accolades (simple mais suffisant ici)
      $depth += ([regex]::Matches($l, '\{')).Count
      $depth -= ([regex]::Matches($l, '\}')).Count
    
      # fin de bloc menuentry quand on est revenu à 0 et qu’on a vu au moins une ouverture
      if ($depth -le 0 -and ($entryLines -join "`n") -match '\{') {
        if (-not $entryIsGtk) {
          foreach ($el in $entryLines) { $out.Add($el) }
        }
        $inEntry = $false
      }
    }
    
    $txt2 = ($out -join "`n")

    $txt2 = $txt2 -replace '\s+quiet\b', ''
    
    # default + timeout
    $txt2 = $txt2 -replace 'set timeout=\d+', 'set timeout=1'
    if ($txt2 -notmatch 'set timeout=') { $txt2 = "set timeout=1`n" + $txt2 }

    # Ajoute en tête (patch safe)
    $inject = "terminal_output console`nset gfxpayload=text`n"
    if ($txt2 -notmatch '(?m)^\s*terminal_output\s+console\s*$') {
      $txt2 = $txt2 -replace '(?m)^(set timeout=\d+\s*)$', "`$1`n$inject"
    }

    $txt2 = $txt2 -replace 'set default="?\d+"?', 'set default=0'
    if ($txt2 -notmatch 'set default=') { $txt2 = "set default=0`n" + $txt2 }

    # ... juste avant Set-Content
  if (Test-Path $grubCfg) {
      # enlève ReadOnly si présent
      try { attrib -R $grubCfg } catch {}
    }
    
    # écriture forcée
    Set-Content -Path $grubCfg -Value $txt2 -Encoding UTF8 -Force
  } else {
    Write-Warning "UEFI GRUB config not found: $grubCfg"
  }

  $isoTxtCfg = Join-Path $rootDir "isolinux\txt.cfg"
  if (Test-Path $isoTxtCfg) {
    Write-Host "Patching BIOS ISOLINUX: $isoTxtCfg"
    $txt = Get-Content -Raw -Path $isoTxtCfg

    # Nettoyage idempotent
    $txt = $txt -replace '\s+auto=true\s+priority=critical\s+preseed/file=/preseed\.cfg(?:\s+nomodeset)?', ''

    $txt2 = $txt -replace '(\n\s*append\s+[^\n]+)', ('$1' + $arg)

    if (Test-Path $isoTxtCfg) {
      try { attrib -R $isoTxtCfg } catch {}
    }
    Set-Content -Path $isoTxtCfg -Value $txt2 -Encoding ASCII -Force
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
    $env:MSYS2_ARG_CONV_EXCL="*"
  
    function To-MsysPath([string]$p) {
      $cyg = Get-Command cygpath.exe -ErrorAction SilentlyContinue
      if (-not $cyg) { throw "cygpath.exe not found. Ensure C:\msys64\usr\bin is in PATH." }
      (& $cyg.Source -u $p).Trim()
    }
  
    $srcIsoMsys   = To-MsysPath $sourceIso
    $customIso    = Join-Path $workDir ("debian12-preseeded-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".iso")
    $customIsoMsys = To-MsysPath $customIso
  
    # On prépare une petite arborescence de patch (sur disque Windows)
    $patchDir = Join-Path $workDir "iso-patch"
    if (Test-Path $patchDir) { Remove-Item -Recurse -Force $patchDir }
    New-Item -ItemType Directory -Path $patchDir | Out-Null
  
    $patchedGrub = Join-Path $patchDir "grub.cfg"
    $patchedTxt  = Join-Path $patchDir "txt.cfg"
  
    # 1) Extraire SEULEMENT les fichiers à patcher depuis l'ISO d'origine (pas toute l'ISO !)
    Write-Host "Extracting boot configs from original ISO..."
    $old = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
      & $tool.Path -osirrox on -indev $srcIsoMsys -extract /boot/grub/grub.cfg (To-MsysPath $patchedGrub) 2>&1 | Out-Null
      & $tool.Path -osirrox on -indev $srcIsoMsys -extract /isolinux/txt.cfg     (To-MsysPath $patchedTxt)  2>&1 | Out-Null
      $exit = $LASTEXITCODE
    } finally {
      $PSNativeCommandUseErrorActionPreference = $old
    }
    if (-not (Test-Path $patchedGrub)) { throw "Failed to extract /boot/grub/grub.cfg from ISO." }
    if (-not (Test-Path $patchedTxt))  { throw "Failed to extract /isolinux/txt.cfg from ISO." }
  
    # 2) Appliquer tes patchs sur les fichiers extraits (GRUB + ISOLINUX)
    #    On réutilise ta fonction Patch-Debian12InstallerMenus, mais sur un "root" artificiel
    #    qui contient juste les 2 fichiers aux bons emplacements.
    $fakeRoot = Join-Path $patchDir "root"
    New-Item -ItemType Directory -Path (Join-Path $fakeRoot "boot\grub") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fakeRoot "isolinux") -Force | Out-Null
  
    Copy-Item $patchedGrub (Join-Path $fakeRoot "boot\grub\grub.cfg") -Force
    Copy-Item $patchedTxt  (Join-Path $fakeRoot "isolinux\txt.cfg")   -Force
  
    Patch-Debian12InstallerMenus -rootDir $fakeRoot -preseedIsoPath "/cdrom/preseed.cfg"
  
    $finalGrub = Join-Path $fakeRoot "boot\grub\grub.cfg"
    $finalTxt  = Join-Path $fakeRoot "isolinux\txt.cfg"
  
    # 3) Recréer une ISO en "replay" depuis l'ISO d'origine, et remapper uniquement les fichiers modifiés
    #    => garde tous les symlinks (dont /debian), RR/Joliet, etc.
    $preseedMsys = To-MsysPath $preseedPath
    $finalGrubMsys = To-MsysPath $finalGrub
    $finalTxtMsys  = To-MsysPath $finalTxt
  
    Write-Host "Rebuilding ISO with xorriso replay (preserves symlinks like /debian)..."
    $old = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
      $procOut = & $tool.Path `
        -indev $srcIsoMsys `
        -outdev $customIsoMsys `
        -boot_image any replay `
        -map $preseedMsys /preseed.cfg `
        -map $finalGrubMsys /boot/grub/grub.cfg `
        -map $finalTxtMsys /isolinux/txt.cfg 2>&1
      $exit = $LASTEXITCODE
    } finally {
      $PSNativeCommandUseErrorActionPreference = $old
    }
  
    if ($exit -ne 0) {
      $procOut | ForEach-Object { Write-Host $_ }
      throw "xorriso replay build failed."
    }
  
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

# ----------------- MAIN -----------------
ThrowIfMissing "DebianIsoPath" $DebianIsoPath
if (-not (Test-Path $DebianIsoPath)) { throw "Debian ISO not found at: $DebianIsoPath" }

ThrowIfMissing "VmCpu" $VmCpu
ThrowIfMissing "VmRamMB" $VmRamMB
ThrowIfMissing "DiskMaxGB" $DiskMaxGB
ThrowIfMissing "SharedFolderHostPath" $SharedFolderHostPath
if (-not (Test-Path $SharedFolderHostPath)) { throw "SharedFolderHostPath does not exist: $SharedFolderHostPath" }

$VBoxManage = Get-VBoxManagePath
$sshTools = Ensure-OpenSSH

# IMPORTANT: only generate vmName/workDir ONCE (your current file had duplicates)
$vmName = New-VmName
$workDir = Join-Path $PSScriptRoot "work-$vmName"
New-Item -ItemType Directory -Path $workDir | Out-Null

$logPath = Join-Path $workDir "build.log.txt"
Start-Transcript -Path $logPath | Out-Null

$hostKey = New-HostSshKeyPair -sshKeygenPath $sshTools.SshKeygen -baseDir $workDir -vmName $vmName

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

#if ($InstallExtensionPack) {
#  try { Ensure-ExtensionPack -VBoxManage $VBoxManage -VBoxVersion $VBoxVersion }
#  catch { Write-Warning $_; Write-Warning "Continuing without Extension Pack." }
#}

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

Invoke-VBox $VBoxManage @("createvm","--name",$vmName,"--ostype","Debian_64","--register")

Invoke-VBox $VBoxManage @("modifyvm",$vmName,
  "--firmware","efi",
  "--cpus",$VmCpu,
  "--memory",$VmRamMB,
  "--vram","128",
  "--graphicscontroller","vmsvga",
  "--accelerate3d","off",
  "--usb","on",
  "--usbxhci","on"
)

if (($NetworkMode -eq 'NatOnly') -or ($NetworkMode -eq 'Dual')) {
  Invoke-VBox $VBoxManage @("modifyvm",$vmName,"--nic1","nat")
  Invoke-VBox $VBoxManage @("modifyvm",$vmName,"--natpf1","ssh,tcp,127.0.0.1,$SshHostPort,,22")
} else {
  Invoke-VBox $VBoxManage @("modifyvm",$vmName,"--nic1","none")
}

if ($NetworkMode -eq 'BridgedOnly') {
  Invoke-VBox $VBoxManage @("modifyvm",$vmName,"--nic1","bridged","--bridgeadapter1",$BridgedAdapterName)
}

# NIC2 désactivée pendant l'installation
Invoke-VBox $VBoxManage @("modifyvm",$vmName,"--nic2","none")

Invoke-VBox $VBoxManage @("storagectl",$vmName,"--name","SATA","--add","sata","--controller","IntelAhci")
Invoke-VBox $VBoxManage @("storagectl",$vmName,"--name","IDE","--add","ide")

$diskPath = New-Disk -VBoxManage $VBoxManage -vmName $vmName -diskGB $DiskMaxGB
Invoke-VBox $VBoxManage @("storageattach",$vmName,"--storagectl","SATA","--port","0","--device","0","--type","hdd","--medium",$diskPath)

Invoke-VBox $VBoxManage @("storageattach",$vmName,"--storagectl","IDE","--port","0","--device","0","--type","dvddrive","--medium",$isoToUse)

Invoke-VBox $VBoxManage @("sharedfolder","add",$vmName,"--name","hostshare","--hostpath",$SharedFolderHostPath,"--automount")

Write-Host "Starting VM in GUI mode..."
Invoke-VBox $VBoxManage @("startvm",$vmName,"--type","gui")

if ($PreseedMode -eq 'Http') {
  Write-Warning "HTTP mode: If installer doesn't auto-start, edit GRUB entry and append:"
  Write-Host "  auto=true priority=critical preseed/url=$preseedUrl"
}

$timeoutSeconds = $InstallTimeoutMinutes * 60
Write-Host "Waiting up to $InstallTimeoutMinutes minutes for SSH on localhost:$SshHostPort (post-install)..."
$sshUp = Wait-ForSsh -sshPath $sshTools.Ssh -keyPath $hostKey.Private -port $SshHostPort -user $Username -timeoutSeconds $timeoutSeconds -label "SSH"

if (-not $sshUp) {
  Write-Warning "SSH did not become available within timeout."
  if ($PreseedMode -eq 'Http') { Write-Warning "Likely boot args not applied. Prefer PreseedMode=Iso." }
} else {
  Write-Host ""
  Write-Host "SSH access (key-based):"
  Write-Host "  ssh -i `"$($hostKey.Private)`" -p $SshHostPort $Username@127.0.0.1"

  Ssh-Run $sshTools.Ssh $hostKey.Private $SshHostPort $Username "sudo -n shutdown -h now"

  # wait for shutdown
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt 120) {
      $stateLine = (& $VBoxManage showvminfo $vmName --machinereadable) | Select-String '^VMState='
      if ($stateLine -and $stateLine.Line -match 'poweroff') { break }
      Write-Host "Waited $($sw.Elapsed.TotalSeconds) for shutdown. Waiting for another 3 seconds"
      Start-Sleep 3
  }
  
  if ($NetworkMode -eq 'Dual') {
    Write-Host "Enabling bridged NIC2 now that the system is installed..."
    Invoke-VBox $VBoxManage @("modifyvm",$vmName,"--nic2","bridged","--bridgeadapter2",$BridgedAdapterName)
  }

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