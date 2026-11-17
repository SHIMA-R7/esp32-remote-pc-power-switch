@{
  # Tailscale peer name used to determine reachability.
  TailscalePeer = 'your-pc-hostname'

  # SSH destination and account on the remote Windows PC.
  SshHost = 'your-pc-hostname'
  SshUsername = 'your-windows-username'
  SshPrivateKeyPath = '%USERPROFILE%\.ssh\id_ed25519_pc_power'

  # Adafruit IO account and feed used for the start pulse.
  AdafruitIoUsername = 'your-adafruit-username'
  CommandFeed = 'pc-power-command'

  # Desktop shortcut file name.
  DesktopShortcutName = 'Remote PC Power Switch.lnk'
}
