# ESP32 Remote PC Power Switch

An ESP32 DevKit can momentarily close a motherboard's power-switch input through an optocoupler. Adafruit IO relays a one-shot start request while the PC is off. A Windows helper can use Tailscale and SSH to shut the PC down and send a start request.

The motherboard power switch is a toggle. The ESP32 cannot tell whether the PC is on, so only send a start request after confirming that the PC is off.

## Components

- ESP32 DevKit compatible board
- PC817 or equivalent optocoupler and a suitable series resistor for its input LED
- Red and green status LEDs with current-limiting resistors
- Adafruit IO account with pc-power-command and pc-power-status feeds
- Optional: Tailscale and Windows OpenSSH for the Windows toggle shortcut

## Signal wiring

~~~~text
ESP32 GPIO25 ── series resistor ── PC817 pin 1 (anode)
ESP32 GND ──────────────────────── PC817 pin 2 (cathode)

PC817 pin 4 (collector) ────────── motherboard PWR_SW signal
PC817 pin 3 (emitter) ──────────── motherboard PWR_SW ground

ESP32 GPIO33 ── resistor ── red LED ── GND
ESP32 GPIO27 ── resistor ── green LED ── GND
~~~~

The optocoupler's transistor side is isolated from the ESP32. Check the optocoupler pinout and motherboard header labels before wiring. GPIO25 sends a 450 ms pulse; GPIO33 indicates a pulse or missing cloud connection, and GPIO27 indicates an active MQTT connection.

## Firmware setup

1. Open firmware/esp32_pc_switch/esp32_pc_switch.ino with the Arduino IDE.
2. Copy wifi_secrets.example.h, mqtt_secrets.example.h, and switch_secrets.example.h to files with the corresponding names without .example.
3. Fill in your 2.4 GHz Wi-Fi credentials, Adafruit IO username and active key, and a long random local access token.
4. Create the two Adafruit IO feeds named pc-power-command and pc-power-status.
5. Install the ArduinoMqttClient library, select your ESP32 board, build, and upload.

The real *_secrets.h files are ignored by Git. Never commit an Adafruit IO active key, Wi-Fi password, or local access token.

## Optional Windows toggle shortcut

windows/pc_power_toggle.ps1 checks the configured Tailscale peer. If it is online, it asks for confirmation before issuing an SSH shutdown command. If it is offline, it sends one Adafruit IO start request and waits for the peer to return online before changing the icon.

Run windows/install.ps1, then edit the configuration and secret files it creates under %LOCALAPPDATA%\PCPowerSwitch. Keep the SSH private key and real credentials outside Git. See docs/windows-remote-setup.md.

## Optional MCP server

mcp/pc_power_mcp_server.mjs exposes one request_pc_power_on tool. Set ADAFRUIT_IO_USERNAME and ADAFRUIT_IO_KEY in the MCP server's private runtime environment. It sends a single 1 value and cannot confirm that the PC booted. See mcp/.env.example.

## Safety and limits

- A successful Adafruit IO response only confirms that the service accepted the request.
- Tailscale online status is a reachability check, not a Windows power-state sensor.
- Do not expose the ESP32's local HTTP server directly to the public internet.
- Keep API keys, passwords, access tokens, and SSH private keys out of source control.
