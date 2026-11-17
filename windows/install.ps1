$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$installDir = Join-Path $env:LOCALAPPDATA 'PCPowerSwitch'
New-Item -ItemType Directory -Path $installDir -Force | Out-Null

& (Join-Path $PSScriptRoot 'generate_icons.ps1') -OutputDirectory $installDir
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'pc_power_toggle.ps1') -Destination $installDir -Force

$configPath = Join-Path $installDir 'pc_power_toggle.config.psd1'
$configExample = Join-Path $PSScriptRoot 'pc_power_toggle.config.example.psd1'
if (-not (Test-Path -LiteralPath $configPath)) {
  Copy-Item -LiteralPath $configExample -Destination $configPath
}

$secretPath = Join-Path $installDir 'mqtt_secrets.h'
$secretExample = Join-Path $repoRoot 'firmware\esp32_pc_switch\mqtt_secrets.example.h'
if (-not (Test-Path -LiteralPath $secretPath)) {
  Copy-Item -LiteralPath $secretExample -Destination $secretPath
}

$config = Import-PowerShellDataFile -LiteralPath $configPath
$shortcutName = [string]$config.DesktopShortcutName
if ([string]::IsNullOrWhiteSpace($shortcutName)) { $shortcutName = 'Remote PC Power Switch.lnk' }
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) $shortcutName
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$scriptPath = Join-Path $installDir 'pc_power_toggle.ps1'
$shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $scriptPath + '"'
$shortcut.WorkingDirectory = $installDir
$shortcut.IconLocation = (Join-Path $installDir 'power_on.ico') + ',0'
$shortcut.Description = 'Toggle the configured remote PC power state'
$shortcut.Save()

Write-Output "Installed to $installDir"
Write-Output "Shortcut: $shortcutPath"
Write-Output 'Edit pc_power_toggle.config.psd1 and mqtt_secrets.h before using the shortcut.'
