// SAC firmware: the ESP32 runs its own hotspot and prints what the app sends.
//
//   Hotspot  SSID "SAC-Arm", the board is always 192.168.4.1
//   Socket   192.168.4.1:3333, one command per line, each answered "ok;"
//   HTTP     GET http://192.168.4.1/servo?cmd=1,115;2,95;3,108;4,60;5,120;
//
// Join the hotspot from the phone and enter 192.168.4.1 on the app's Arm screen.
// Servos are not driven yet: every command is printed to the serial monitor.

#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>

#if __has_include("secrets.h")
#include "secrets.h"
#endif
#ifndef AP_SSID
#define AP_SSID "SAC-Arm"
#endif
#ifndef AP_PASSWORD
#define AP_PASSWORD "sacarm123"  // WPA2 refuses anything under 8 characters
#endif

const IPAddress AP_IP(192, 168, 4, 1);
const IPAddress AP_SUBNET(255, 255, 255, 0);

const uint16_t STREAM_PORT = 3333;

// The app heartbeats every 700 ms, so this much silence means the phone is gone.
const unsigned long CLIENT_IDLE_MS = 5000;
const unsigned int MAX_LINE = 64;

const int CHANNELS = 5;
const char* NAMES[CHANNELS] = {"base", "shoulder", "elbow", "claw", "claw2"};
int angles[CHANNELS] = {-1, -1, -1, -1, -1};

WebServer http(80);
WiFiServer stream(STREAM_PORT);
WiFiClient client;
bool linked = false;
IPAddress linkedFrom;
String inbox;
unsigned long lastHeard = 0;
unsigned long commands = 0;
unsigned long heartbeats = 0;

// "channel,angle;" pairs, channels 1-based. Returns how many were applied.
int applyCommand(const String& line) {
  int applied = 0;
  int start = 0;
  while (start < (int)line.length()) {
    int end = line.indexOf(';', start);
    if (end < 0) break;
    String pair = line.substring(start, end);
    start = end + 1;

    int comma = pair.indexOf(',');
    if (comma < 0) continue;
    int channel = pair.substring(0, comma).toInt();
    if (channel < 1 || channel > CHANNELS) continue;
    angles[channel - 1] = constrain(pair.substring(comma + 1).toInt(), 0, 180);
    applied++;
  }
  return applied;
}

void handleLine(const char* via, IPAddress from, String line) {
  line.trim();
  if (line.length() == 0) return;
  if (line == "?;" || line == "?") {
    heartbeats++;
    return;
  }

  if (applyCommand(line) == 0) {
    Serial.printf("[%s %s] unparsed: %s\n", via, from.toString().c_str(), line.c_str());
    return;
  }

  commands++;
  Serial.printf("[%s %s] #%lu ", via, from.toString().c_str(), commands);
  for (int i = 0; i < CHANNELS; i++) Serial.printf(" %s=%d", NAMES[i], angles[i]);
  Serial.printf("   raw=%s\n", line.c_str());
}

void handleServo() {
  if (!http.hasArg("cmd")) {
    http.send(400, "text/plain", "missing cmd");
    return;
  }
  handleLine("http", http.client().remoteIP(), http.arg("cmd"));
  http.send(200, "text/plain", "ok");
}

void handleRoot() {
  String body = "SAC firmware\n\n";
  for (int i = 0; i < CHANNELS; i++) body += String(NAMES[i]) + ": " + String(angles[i]) + "\n";
  body += "\ncommands " + String(commands) + ", heartbeats " + String(heartbeats);
  body += "\nhotspot devices " + String(WiFi.softAPgetStationNum());
  body += "\nsocket " + (linked ? "connected from " + linkedFrom.toString() : String("idle")) + "\n";
  http.send(200, "text/plain", body);
}

void dropClient(const char* why) {
  client.stop();
  linked = false;
  Serial.printf("[socket] %s disconnected (%s)\n", linkedFrom.toString().c_str(), why);
}

void pumpStream() {
  // Newest connection wins: a phone that reconnects never closed the old socket.
  WiFiClient incoming = stream.accept();
  if (incoming) {
    if (linked) dropClient("replaced");
    client = incoming;
    client.setNoDelay(true);
    linked = true;
    linkedFrom = client.remoteIP();
    inbox = "";
    lastHeard = millis();
    Serial.printf("[socket] %s connected\n", linkedFrom.toString().c_str());
  }

  if (!linked) return;
  if (!client.connected()) {
    dropClient("closed");
    return;
  }

  while (client.available()) {
    char c = client.read();
    lastHeard = millis();

    if (c == '\n') {
      handleLine("socket", linkedFrom, inbox);
      // The app treats silence as a dead link, so every line gets an answer.
      client.print("ok;\n");
      inbox = "";
    } else if (c != '\r') {
      if (inbox.length() < MAX_LINE) inbox += c;
      else inbox = "";
    }
  }

  if (millis() - lastHeard > CLIENT_IDLE_MS) dropClient("idle");
}

void onWiFiEvent(arduino_event_id_t event, arduino_event_info_t info) {
  switch (event) {
    case ARDUINO_EVENT_WIFI_AP_STACONNECTED: {
      const uint8_t* m = info.wifi_ap_staconnected.mac;
      Serial.printf("[hotspot] device joined %02x:%02x:%02x:%02x:%02x:%02x\n",
                    m[0], m[1], m[2], m[3], m[4], m[5]);
      break;
    }
    case ARDUINO_EVENT_WIFI_AP_STAIPASSIGNED:
      Serial.printf("[hotspot] device got %s\n",
                    IPAddress(info.wifi_ap_staipassigned.ip.addr).toString().c_str());
      break;
    case ARDUINO_EVENT_WIFI_AP_STADISCONNECTED:
      Serial.println("[hotspot] device left");
      break;
    default:
      break;
  }
}

void setup() {
  Serial.begin(115200);
  delay(200);

  WiFi.onEvent(onWiFiEvent);
  WiFi.mode(WIFI_AP);
  WiFi.softAPConfig(AP_IP, AP_IP, AP_SUBNET);
  if (!WiFi.softAP(AP_SSID, AP_PASSWORD)) {
    Serial.println("[hotspot] failed to start; AP_PASSWORD must be 8-63 characters");
    while (true) delay(1000);
  }

  http.on("/", handleRoot);
  http.on("/servo", handleServo);
  http.begin();
  stream.begin();
  stream.setNoDelay(true);

  String ip = WiFi.softAPIP().toString();
  Serial.printf("\nhotspot  %s  password %s\n", AP_SSID, AP_PASSWORD);
  Serial.printf("address  %s   <- enter this on the app's Arm screen\n", ip.c_str());
  Serial.printf("socket   %s:%u\n", ip.c_str(), STREAM_PORT);
  Serial.printf("http     http://%s/servo?cmd=...\n\n", ip.c_str());
}

void loop() {
  http.handleClient();
  pumpStream();
}
