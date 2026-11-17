$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

$configPath = Join-Path $PSScriptRoot 'pc_power_toggle.config.psd1'
$secretPath = Join-Path $PSScriptRoot 'mqtt_secrets.h'
$powerOnIcon = Join-Path $PSScriptRoot 'power_on.ico'
$powerOffIcon = Join-Path $PSScriptRoot 'power_off.ico'
$startupAwaitingConfirmation = $false

function Show-Notice([string]$Message, [string]$Title = 'Remote PC Power Switch') {
  [void][System.Windows.Forms.MessageBox]::Show(
    $Message, $Title,
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
  )
}

function Ask-YesNo([string]$Message, [string]$Title = 'Remote PC Power Switch') {
  return [System.Windows.Forms.MessageBox]::Show(
    $Message, $Title,
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question,
    [System.Windows.Forms.MessageBoxDefaultButton]::Button2
  )
}

function Set-ToggleShortcutIcon([bool]$WillShutdown, [string]$ShortcutPath) {
  if (-not (Test-Path -LiteralPath $ShortcutPath)) { return }
  $iconPath = if ($WillShutdown) { $powerOffIcon } else { $powerOnIcon }
  if (-not (Test-Path -LiteralPath $iconPath)) { return }
  $shell = New-Object -ComObject WScript.Shell
  $link = $shell.CreateShortcut($ShortcutPath)
  $link.IconLocation = "$iconPath,0"
  $link.Save()
}

function Get-RemotePcOnline([string]$TailscaleExe, [string]$PeerName) {
  try {
    $statusLines = @(& $TailscaleExe status --json 2>$null)
    if ($LASTEXITCODE -ne 0 -or $statusLines.Count -eq 0) { return $null }
    $status = ($statusLines -join [Environment]::NewLine) | ConvertFrom-Json
    if ($status.BackendState -ne 'Running' -or $null -eq $status.Peer) { return $null }

    $escapedPeer = [regex]::Escape($PeerName.TrimEnd('.'))
    $matches = @($status.Peer.PSObject.Properties | ForEach-Object { $_.Value } | Where-Object {
      $_.HostName -ieq $PeerName -or $_.DNSName -match "(?i)^$escapedPeer(?:\.|$)"
    })
    if ($matches.Count -ne 1 -or $null -eq $matches[0].Online) { return $null }
    return [bool]$matches[0].Online
  } catch {
    return $null
  }
}

function Wait-ForRemoteState([string]$TailscaleExe, [string]$PeerName, [bool]$ExpectedOnline, [int]$TimeoutSeconds) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Seconds 5
    $online = Get-RemotePcOnline $TailscaleExe $PeerName
    if ($null -ne $online -and $online -eq $ExpectedOnline) { return $true }
  }
  return $false
}

try {
  if (-not (Test-Path -LiteralPath $configPath)) {
    Show-Notice 'Copy pc_power_toggle.config.example.psd1 to pc_power_toggle.config.psd1 and edit the settings first. No action was sent.'
    exit 1
  }
  $config = Import-PowerShellDataFile -LiteralPath $configPath
  foreach ($name in @('TailscalePeer', 'SshHost', 'SshUsername', 'SshPrivateKeyPath', 'AdafruitIoUsername', 'CommandFeed', 'DesktopShortcutName')) {
    if (-not $config.ContainsKey($name) -or [string]::IsNullOrWhiteSpace([string]$config[$name]) -or [string]$config[$name] -match '(?i)your-|replace-|placeholder') {
      Show-Notice "Set $name in pc_power_toggle.config.psd1 first. No action was sent."
      exit 1
    }
  }

  $shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) ([string]$config.DesktopShortcutName)
  $tailscaleExe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
  if (-not (Test-Path -LiteralPath $tailscaleExe)) {
    Show-Notice 'Tailscale CLI was not found. No action was sent.'
    exit 2
  }

  $online = Get-RemotePcOnline $tailscaleExe ([string]$config.TailscalePeer)
  if ($null -eq $online) {
    Show-Notice 'Could not determine the remote PC state from Tailscale. No action was sent.'
    exit 3
  }

  if ($online) {
    Set-ToggleShortcutIcon $true $shortcutPath
    $answer = Ask-YesNo 'The remote PC is online in Tailscale. Shut it down over SSH?'
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }

    $sshExe = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
    $sshKey = [Environment]::ExpandEnvironmentVariables([string]$config.SshPrivateKeyPath)
    if (-not (Test-Path -LiteralPath $sshExe) -or -not (Test-Path -LiteralPath $sshKey)) {
      Show-Notice 'OpenSSH or the configured private key was not found. The PC was not shut down.'
      exit 4
    }

    & $sshExe -i $sshKey -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=8 "$($config.SshUsername)@$($config.SshHost)" 'shutdown.exe /s /t 0'
    $sshExitCode = $LASTEXITCODE
    if ($sshExitCode -eq 0 -or $sshExitCode -eq 255) {
      if (Wait-ForRemoteState $tailscaleExe ([string]$config.TailscalePeer) $false 180) {
        Set-ToggleShortcutIcon $false $shortcutPath
        Show-Notice 'The remote PC is offline in Tailscale. The shortcut now shows ON.'
      } elseif ($sshExitCode -eq 0) {
        Show-Notice 'The shutdown command was sent, but the stopped state was not confirmed.'
      } else {
        Show-Notice 'The SSH result is uncertain and shutdown was not confirmed. Check the PC state before retrying.'
      }
    } else {
      Show-Notice 'SSH shutdown failed. No start request was sent.'
    }
    exit 0
  }

  Set-ToggleShortcutIcon $false $shortcutPath
  Start-Sleep -Seconds 3
  $online = Get-RemotePcOnline $tailscaleExe ([string]$config.TailscalePeer)
  if ($null -eq $online) {
    Show-Notice 'Could not recheck Tailscale. No start request was sent.'
    exit 5
  }
  if ($online) {
    Set-ToggleShortcutIcon $true $shortcutPath
    Show-Notice 'The remote PC is already online. No start request was sent.'
    exit 0
  }

  if (-not (Test-Path -LiteralPath $secretPath)) {
    Show-Notice 'mqtt_secrets.h was not found beside the script. No start request was sent.'
    exit 6
  }
  $secretText = Get-Content -Raw -LiteralPath $secretPath
  $keyMatch = [regex]::Match(
    $secretText,
    '^\s*#define\s+MQTT_DEVICE_PASSWORD\s+"([^"\r\n]+)"\s*(?://.*)?$',
    [System.Text.RegularExpressions.RegexOptions]::Multiline
  )
  if (-not $keyMatch.Success -or $keyMatch.Groups[1].Value -match '(?i)your-|placeholder|change_me|replace') {
    Show-Notice 'The Adafruit IO key in mqtt_secrets.h is not configured. No start request was sent.'
    exit 7
  }

  $startupAwaitingConfirmation = $true
  $aioKey = $keyMatch.Groups[1].Value
  $body = @{ value = '1' } | ConvertTo-Json -Compress
  $aioUser = [Uri]::EscapeDataString([string]$config.AdafruitIoUsername)
  $feed = [Uri]::EscapeDataString([string]$config.CommandFeed)
  $uri = "https://io.adafruit.com/api/v2/$aioUser/feeds/$feed/data"
  $null = Invoke-RestMethod -Uri $uri -Method Post -Headers @{ 'X-AIO-Key' = $aioKey } -ContentType 'application/json' -Body $body -TimeoutSec 10

  if (Wait-ForRemoteState $tailscaleExe ([string]$config.TailscalePeer) $true 300) {
    Set-ToggleShortcutIcon $true $shortcutPath
    $startupAwaitingConfirmation = $false
    Show-Notice 'The remote PC is back online in Tailscale. The shortcut now shows OFF.'
  }
} catch {
  if (-not $startupAwaitingConfirmation) {
    Show-Notice 'The operation did not complete. Check the remote PC state before retrying.'
  }
}
