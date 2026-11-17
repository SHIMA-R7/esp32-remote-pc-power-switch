# Optional ChatGPT Action

chatgpt_pc_power_action.yaml is a template for an Action that sends the fixed 1 command to Adafruit IO. Before importing it, replace YOUR_ADAFRUIT_USERNAME in the path with your own Adafruit IO username.

Configure authentication as an API key in the X-AIO-Key header. Enter the active key only in the Action's authentication settings; do not put it in the YAML or this repository. Keep the Action private. It can send a power-button pulse but cannot read the PC's power state.
