# Windows remote toggle setup

The optional Windows shortcut combines a Tailscale peer check with Windows OpenSSH:

- Peer online: ask for confirmation, then run shutdown.exe /s /t 0 through SSH.
- Peer offline: send one Adafruit IO command and wait for Tailscale to report the peer online.
- The shortcut icon indicates the next action; it is not an independent power sensor.

## Configure the shortcut

1. Run windows/install.ps1. It installs the helper, creates placeholder configuration files, generates generic ON/OFF icons, and creates a desktop shortcut.
2. Edit %LOCALAPPDATA%\PCPowerSwitch\pc_power_toggle.config.psd1. Set TailscalePeer, SshHost, SshUsername, and SshPrivateKeyPath to your own values.
3. Edit %LOCALAPPDATA%\PCPowerSwitch\mqtt_secrets.h with your Adafruit IO username and active key.
4. Keep the configuration file, real secrets header, and SSH private key local.

The SSH public key must be installed in the target Windows account's authorized_keys, and the target must have Windows OpenSSH Server enabled. Use the Tailscale DNS name for both peer and SSH host when available.

## Test safely

Confirm the target is online before testing shutdown. Confirm it is fully offline before testing startup. The start request is a physical power-button pulse and can turn an already-running PC off.
