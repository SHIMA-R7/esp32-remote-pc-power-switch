#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <ESPmDNS.h>
#include <WiFiClientSecure.h>
#include <ArduinoMqttClient.h>
#include <time.h>
#include <cstring>

#include "wifi_secrets.h"
#include "switch_secrets.h"
#include "mqtt_secrets.h"

// Wiring: GPIO25 -> PC817 input LED through its resistor; GPIO33 -> red LED;
// GPIO27 -> green LED. The optocoupler transistor is across motherboard PWR_SW.
static constexpr uint8_t POWER_OPTO_PIN = 25;
static constexpr uint8_t LED_RED_PIN = 33;
static constexpr uint8_t LED_GREEN_PIN = 27;
static constexpr uint32_t POWER_PULSE_MS = 450;
static constexpr uint32_t PRESS_COOLDOWN_MS = 2500;
static constexpr char MDNS_NAME[] = "pc-switch";
static constexpr uint32_t MQTT_RETRY_MS = 60000;
static constexpr uint32_t MQTT_KEEPALIVE_MS = 30000;
static constexpr time_t VALID_CLOCK_AFTER = 1700000000;

static constexpr char MQTT_COMMAND_FEED[] = "pc-power-command";
static constexpr char MQTT_STATUS_FEED[] = "pc-power-status";
static String mqttCommandTopic;
static String mqttStatusTopic;

WebServer server(80);
WiFiClientSecure mqttTls;
MqttClient mqttClient(mqttTls);

static bool serverStarted = false;
static bool pulseActive = false;
static bool ntpRequested = false;
static bool statusPending = false;
static const char* pendingStatus = "";
static uint32_t pulseDeadline = 0;
static uint32_t lastPressAt = 0;
static uint32_t lastWifiReconnectAt = 0;
static uint32_t lastMqttAttemptAt = 0;
static bool mqttAttempted = false;

static const char INDEX_HTML[] PROGMEM = R"HTML(
<!doctype html><html lang="ja"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>PC Power Switch</title>
<style>body{font:16px system-ui,sans-serif;max-width:540px;margin:40px auto;padding:0 18px;background:#10151b;color:#f3f5f7}input,button{font:inherit;padding:12px;border-radius:8px;border:1px solid #59636f}input{width:100%;box-sizing:border-box;background:#1d2630;color:white;margin:8px 0 16px}button{background:#1976d2;color:white;border:0;width:100%;font-weight:700}button:disabled{opacity:.5}.status{padding:12px;background:#1d2630;border-radius:8px;margin:18px 0}.hint{color:#aeb9c6;font-size:.9rem}</style>
<h1>PC Power Switch</h1><p class="hint">ボタンを短く押した動作を送ります。</p>
<label>アクセスキー<input id="key" type="password" autocomplete="current-password" placeholder="キーを入力"></label>
<div class="status" id="status">状態を確認中…</div><button id="press">電源ボタンを短く押す</button><p class="hint">PC稼働中に押すと、Windows側の電源ボタン設定に従います。</p>
<script>
const keyEl=document.querySelector('#key'), statusEl=document.querySelector('#status'), btn=document.querySelector('#press');
keyEl.value=localStorage.getItem('pcSwitchKey')||'';
function headers(){const k=keyEl.value.trim();if(k)localStorage.setItem('pcSwitchKey',k);return {'X-Access-Key':k};}
async function refresh(){try{const r=await fetch('/api/status',{headers:headers(),cache:'no-store'});if(r.status===401){statusEl.textContent='アクセスキーを入力してください';return;}const d=await r.json();statusEl.textContent=!d.wifi?'Wi-Fi未接続':(d.mqtt?'クラウド接続済み':'Wi-Fi接続済み / クラウド未接続');}catch(e){statusEl.textContent='ESP32に接続できません';}}
btn.onclick=async()=>{btn.disabled=true;try{const r=await fetch('/api/press',{method:'POST',headers:headers()});const d=await r.json();statusEl.textContent=r.ok?'電源ボタンを短く押しました':(d.error||'操作できません');}catch(e){statusEl.textContent='通信エラー';}setTimeout(()=>btn.disabled=false,2500);};
keyEl.onchange=refresh;refresh();setInterval(refresh,10000);
</script></html>
)HTML";

static bool mqttConfigReady() {
  return MQTT_BROKER_HOST[0] != '\0' &&
         strcmp(MQTT_BROKER_HOST, "io.adafruit.com") == 0 &&
         MQTT_DEVICE_USERNAME[0] != '\0' &&
         strcmp(MQTT_DEVICE_USERNAME, "your-adafruit-username") != 0 &&
         MQTT_DEVICE_PASSWORD[0] != '\0' &&
         strcmp(MQTT_DEVICE_PASSWORD, "your-adafruit-io-key") != 0;
}

static void sendUnauthorized() {
  server.sendHeader("Cache-Control", "no-store");
  server.send(401, "application/json; charset=utf-8", "{\"error\":\"アクセスキーが違います\"}");
}

static bool authorized() {
  const String supplied = server.header("X-Access-Key");
  return supplied.length() == strlen(PC_SWITCH_ACCESS_TOKEN) && supplied == PC_SWITCH_ACCESS_TOKEN;
}

static void queueStatus(const char* message) {
  pendingStatus = message;
  statusPending = true;
}

static bool requestPowerPulse() {
  const uint32_t now = millis();
  if (pulseActive || (lastPressAt != 0 && now - lastPressAt < PRESS_COOLDOWN_MS)) return false;
  lastPressAt = now;
  pulseActive = true;
  pulseDeadline = now + POWER_PULSE_MS;
  digitalWrite(POWER_OPTO_PIN, HIGH);
  return true;
}

static void handleIndex() {
  server.sendHeader("Cache-Control", "no-store");
  server.send_P(200, "text/html; charset=utf-8", INDEX_HTML);
}

static void handleStatus() {
  if (!authorized()) { sendUnauthorized(); return; }
  String body = "{\"wifi\":";
  body += (WiFi.status() == WL_CONNECTED && serverStarted) ? "true" : "false";
  body += ",\"mqtt\":";
  body += mqttClient.connected() ? "true" : "false";
  body += ",\"pulse\":";
  body += pulseActive ? "true" : "false";
  body += "}";
  server.sendHeader("Cache-Control", "no-store");
  server.send(200, "application/json; charset=utf-8", body);
}

static void handlePress() {
  if (!authorized()) { sendUnauthorized(); return; }
  if (!requestPowerPulse()) {
    server.send(429, "application/json; charset=utf-8", "{\"error\":\"少し待ってから再操作してください\"}");
    return;
  }
  queueStatus("pressed");
  server.send(200, "application/json; charset=utf-8", "{\"ok\":true,\"pulseMs\":450}");
}

static void startServerIfReady() {
  if (serverStarted || WiFi.status() != WL_CONNECTED) return;
  server.begin();
  MDNS.begin(MDNS_NAME);
  serverStarted = true;
  Serial.print("Local PC switch ready at http://");
  Serial.print(WiFi.localIP());
  Serial.println("/ (also http://pc-switch.local/ on supported LANs)");
}

static void onMqttMessage(int messageSize) {
  const String topic = mqttClient.messageTopic();
  const bool retained = mqttClient.messageRetain() != 0;
  char payload[128] = {};
  size_t used = 0;
  while (mqttClient.available()) {
    const int value = mqttClient.read();
    if (value < 0) break;
    if (used < sizeof(payload) - 1) payload[used++] = static_cast<char>(value);
  }
  payload[used] = '\0';

  // Adafruit IO's dashboard momentary button sends 1 on press and 0 on release.
  // Accept PRESS as well for manual MQTT clients. Never trigger on release.
  if (retained || topic != mqttCommandTopic ||
      !((messageSize == 1 && strcmp(payload, "1") == 0) ||
        (messageSize == 5 && strcmp(payload, "PRESS") == 0))) return;
  queueStatus(requestPowerPulse() ? "pressed" : "busy");
}

static void publishMqttStatus() {
  if (!mqttClient.connected() || !statusPending) return;
  const char* message = pendingStatus;
  const unsigned long size = static_cast<unsigned long>(strlen(message));
  if (mqttClient.beginMessage(mqttStatusTopic.c_str(), size, false, 1)) {
    mqttClient.write(reinterpret_cast<const uint8_t*>(message), size);
    mqttClient.endMessage();
  }
  statusPending = false;
}

static void startClockSync() {
  if (ntpRequested || WiFi.status() != WL_CONNECTED) return;
  configTime(9 * 60 * 60, 0, "ntp.nict.jp", "pool.ntp.org", "time.google.com");
  ntpRequested = true;
}

static void serviceMqtt(uint32_t now) {
  if (!mqttConfigReady() || WiFi.status() != WL_CONNECTED) return;
  startClockSync();

  if (mqttClient.connected()) {
    mqttClient.poll();
    publishMqttStatus();
    return;
  }

  if (mqttAttempted && now - lastMqttAttemptAt < MQTT_RETRY_MS) return;
  lastMqttAttemptAt = now;
  mqttAttempted = true;
  if (time(nullptr) < VALID_CLOCK_AFTER) return;  // TLS certificate validation needs a real clock.

  Serial.printf("Connecting to MQTT broker %s:%u\n", MQTT_BROKER_HOST, MQTT_BROKER_PORT);
  mqttClient.beginWill(mqttStatusTopic.c_str(), 7, false, 1);
  mqttClient.print("offline");
  mqttClient.endWill();
  if (!mqttClient.connect(MQTT_BROKER_HOST, MQTT_BROKER_PORT)) {
    Serial.print("MQTT connection failed, code ");
    Serial.println(mqttClient.connectError());
    return;
  }
  mqttClient.onMessage(onMqttMessage);
  Serial.print("Subscribing to command topic: ");
  Serial.println(mqttCommandTopic);
  if (!mqttClient.subscribe(mqttCommandTopic.c_str(), 0)) {
    Serial.printf("MQTT command subscription failed: SUBACK=%d, connected=%u\n",
                  mqttClient.subscribeQoS(), static_cast<unsigned>(mqttClient.connected()));
    mqttClient.stop();
    return;
  }
  Serial.println("MQTT remote control connected");
  queueStatus("online");
  publishMqttStatus();
}

static void updateLeds(uint32_t now) {
  digitalWrite(LED_GREEN_PIN, mqttConfigReady() && mqttClient.connected() ? HIGH : LOW);
  if (pulseActive) digitalWrite(LED_RED_PIN, HIGH);
  else if (!mqttConfigReady() || !mqttClient.connected()) digitalWrite(LED_RED_PIN, ((now / 300) & 1) ? HIGH : LOW);
  else digitalWrite(LED_RED_PIN, LOW);
}

void setup() {
  // Set the optocoupler input inactive before starting Wi-Fi or MQTT.
  digitalWrite(POWER_OPTO_PIN, LOW);
  pinMode(POWER_OPTO_PIN, OUTPUT);
  pinMode(LED_RED_PIN, OUTPUT);
  pinMode(LED_GREEN_PIN, OUTPUT);
  digitalWrite(LED_RED_PIN, LOW);
  digitalWrite(LED_GREEN_PIN, LOW);

  Serial.begin(115200);
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.begin(WIFI_SSID, WIFI_PASS);

  mqttTls.setCACert(MQTT_ROOT_CA_CERT);
  String mqttClientId = String("pc-switch-") + WiFi.macAddress();
  mqttClientId.replace(":", "");
  mqttClient.setId(mqttClientId);
  Serial.print("MQTT client ID: ");
  Serial.println(mqttClientId);
  mqttClient.setUsernamePassword(MQTT_DEVICE_USERNAME, MQTT_DEVICE_PASSWORD);
  mqttClient.setKeepAliveInterval(MQTT_KEEPALIVE_MS);
  mqttClient.setConnectionTimeout(5000);

  mqttCommandTopic = String(MQTT_DEVICE_USERNAME) + "/feeds/" + MQTT_COMMAND_FEED;
  mqttStatusTopic = String(MQTT_DEVICE_USERNAME) + "/feeds/" + MQTT_STATUS_FEED;

  const char* headers[] = {"X-Access-Key"};
  server.collectHeaders(headers, 1);
  server.on("/", HTTP_GET, handleIndex);
  server.on("/api/status", HTTP_GET, handleStatus);
  server.on("/api/press", HTTP_POST, handlePress);
  server.onNotFound([]() { server.send(404, "text/plain; charset=utf-8", "Not found"); });

  if (!mqttConfigReady()) Serial.println("MQTT settings are placeholders; local mode remains available.");
}

void loop() {
  const uint32_t now = millis();
  if (pulseActive && static_cast<int32_t>(now - pulseDeadline) >= 0) {
    digitalWrite(POWER_OPTO_PIN, LOW);
    pulseActive = false;
  }

  if (WiFi.status() == WL_CONNECTED) {
    startServerIfReady();
    serviceMqtt(now);
    if (serverStarted) server.handleClient();
  } else if (now - lastWifiReconnectAt > 10000) {
    lastWifiReconnectAt = now;
    WiFi.disconnect();
    WiFi.begin(WIFI_SSID, WIFI_PASS);
  }
  updateLeds(now);
}
