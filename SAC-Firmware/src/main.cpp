// SAC firmware: the ESP32 runs its own hotspot and drives up to nine servos.
//
//   Hotspot  SSID "SAC-Arm", the board is always 192.168.4.1
//   Socket   192.168.4.1:3333, one command per line, each answered "ok;"
//   HTTP     GET http://192.168.4.1/servo?cmd=1,115;2,95;3,108;4,60;5,120;
//
// The app owns joint names, ranges and pin choices; this only maps a channel to
// a GPIO and walks each servo toward its target. Two line kinds arrive:
//
//   1,115;2,95;      angles, "channel,angle;" pairs, 1-based, 0-180
//   M,1,16;M,2,17;   the pin map, one line, answered "map,<hex mask>;"
//
// The map lives in RAM only: the phone pushes it on every connect. A board that
// reboots answers the app's "?;" heartbeat with "ok,0;" until it is mapped
// again, which is how the phone knows to re-send it.
//
// Serial output is off unless built with SAC_LOG=1:
//   PLATFORMIO_BUILD_FLAGS="-D SAC_LOG=1" pio run -t upload

#include <Arduino.h>
#include <ESP32Servo.h>
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

#ifndef SAC_LOG
#define SAC_LOG 0
#endif
// Dead code when SAC_LOG is 0, but still compiled, so the log cannot rot.
#define LOGF(...) do { if (SAC_LOG) Serial.printf(__VA_ARGS__); } while (0)

const IPAddress AP_IP(192, 168, 4, 1);
const IPAddress AP_SUBNET(255, 255, 255, 0);

const uint16_t STREAM_PORT = 3333;

// The app heartbeats every 700 ms, so this much silence means the phone is gone.
const unsigned long CLIENT_IDLE_MS = 5000;

// Nine channels of "M,9,33;" plus the newline.
const unsigned int MAX_LINE = 128;

const int CHANNELS = 9;

// Every pin that can carry a servo. Anything else is refused: the rest of the
// header is strapping pins, flash, or the USB serial the log goes out on.
const int8_t ALLOWED_PINS[] = {16, 17, 18, 19, 21, 22, 23, 32, 33};

// One degree per tick is what makes the arm sweep instead of snap. It is a
// timestamp rather than a delay() because a loop that blocks is a loop that is
// not reading the socket.
const unsigned long STEP_EVERY_MS = 15;

Servo servos[CHANNELS];
int8_t pinFor[CHANNELS];   // -1 = unassigned
int target[CHANNELS];      // -1 = never commanded
int current[CHANNELS];

WebServer http(80);
WiFiServer stream(STREAM_PORT);
WiFiClient client;
bool linked = false;
IPAddress linkedFrom;
String inbox;
unsigned long lastHeard = 0;
unsigned long lastStep = 0;
unsigned long commands = 0;
unsigned long heartbeats = 0;

bool pinAllowed(int gpio) {
  for (unsigned i = 0; i < sizeof(ALLOWED_PINS); i++) {
    if (ALLOWED_PINS[i] == gpio) return true;
  }
  return false;
}

// Which channels currently hold a servo, as a bitmask. The app compares this
// against the map it sent and badges anything the board refused.
uint16_t attachedMask() {
  uint16_t mask = 0;
  for (int i = 0; i < CHANNELS; i++) {
    if (servos[i].attached()) mask |= (1 << i);
  }
  return mask;
}

// Re-attaches only what changed, so re-assigning one joint never twitches the
// others, and a channel keeps its position across a re-map.
void applyMap(const int8_t wanted[CHANNELS]) {
  for (int i = 0; i < CHANNELS; i++) {
    if (wanted[i] == pinFor[i]) continue;

    if (servos[i].attached()) servos[i].detach();
    pinFor[i] = wanted[i];

    if (pinFor[i] >= 0) {
      servos[i].setPeriodHertz(50);
      servos[i].attach(pinFor[i], 500, 2400);
      if (current[i] >= 0) servos[i].write(current[i]);
    }
    LOGF("[map] channel %d -> %s%d\n", i + 1, pinFor[i] < 0 ? "none " : "GPIO",
         pinFor[i] < 0 ? 0 : pinFor[i]);
  }
}

// "M,<channel>,<gpio>;" tokens. The whole line is parsed into a shadow map and
// committed only if every token is good, so a truncated line cannot leave half
// the arm re-wired.
bool parseMap(const String& line) {
  int8_t wanted[CHANNELS];
  for (int i = 0; i < CHANNELS; i++) wanted[i] = -1;

  int start = 0;
  int seen = 0;

  while (start < (int)line.length()) {
    int end = line.indexOf(';', start);
    if (end < 0) break;

    String token = line.substring(start, end);
    start = end + 1;
    token.trim();
    if (token.length() == 0) continue;
    if (token[0] != 'M' && token[0] != 'm') return false;

    int firstComma = token.indexOf(',');
    int lastComma = token.lastIndexOf(',');
    if (firstComma < 0 || lastComma <= firstComma) return false;

    int channel = token.substring(firstComma + 1, lastComma).toInt();
    int gpio = token.substring(lastComma + 1).toInt();
    if (channel < 1 || channel > CHANNELS) return false;
    if (gpio >= 0 && !pinAllowed(gpio)) return false;

    // The same pin twice would leave two channels fighting over one servo.
    for (int i = 0; i < CHANNELS; i++) {
      if (gpio >= 0 && wanted[i] == gpio) return false;
    }

    wanted[channel - 1] = gpio < 0 ? -1 : (int8_t)gpio;
    seen++;
  }

  if (seen == 0) return false;
  applyMap(wanted);
  return true;
}

// "channel,angle;" pairs, channels 1-based. Returns how many were applied.
// Channels with no pin are still stored, so a nine-channel command is harmless
// on a three-servo rig.
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

    const int angle = constrain(pair.substring(comma + 1).toInt(), 0, 180);
    const int i = channel - 1;
    target[i] = angle;
    // First command for this channel: take the position rather than sweeping to
    // it from wherever the horn happens to be.
    if (current[i] < 0) {
      current[i] = angle;
      if (servos[i].attached()) servos[i].write(angle);
    }
    applied++;
  }
  return applied;
}

// One degree per servo per tick, toward the target. Nothing here blocks.
void stepServos() {
  if (millis() - lastStep < STEP_EVERY_MS) return;
  lastStep = millis();

  for (int i = 0; i < CHANNELS; i++) {
    if (!servos[i].attached() || target[i] < 0 || current[i] == target[i]) continue;
    current[i] += (target[i] > current[i]) ? 1 : -1;
    servos[i].write(current[i]);
  }
}

// Returns what to answer with: every line gets a reply, because silence is the
// only evidence the app has that the link died.
String handleLine(const char* via, IPAddress from, String line) {
  line.trim();
  if (line.length() == 0) return "ok;";

  if (line == "?;" || line == "?") {
    heartbeats++;
    // Tells a phone whose socket outlived a board reboot to push the map again.
    return attachedMask() == 0 ? "ok,0;" : "ok,1;";
  }

  if (line[0] == 'M' || line[0] == 'm') {
    const bool ok = parseMap(line);
    LOGF("[%s %s] map %s: %s\n", via, from.toString().c_str(),
         ok ? "applied" : "rejected", line.c_str());
    return "map," + String(attachedMask(), HEX) + ";";
  }

  if (applyCommand(line) == 0) {
    LOGF("[%s %s] unparsed: %s\n", via, from.toString().c_str(), line.c_str());
    return "ok;";
  }

  commands++;
  LOGF("[%s %s] #%lu ", via, from.toString().c_str(), commands);
  for (int i = 0; i < CHANNELS; i++) {
    if (pinFor[i] >= 0) LOGF(" %d:%d", i + 1, target[i]);
  }
  LOGF("   raw=%s\n", line.c_str());
  return "ok;";
}

void handleServo() {
  if (!http.hasArg("cmd")) {
    http.send(400, "text/plain", "missing cmd");
    return;
  }
  const String reply = handleLine("http", http.client().remoteIP(), http.arg("cmd"));
  // HTTP is stateless, so the mask rides on every reply: it is all a phone on
  // that transport has to notice a board that rebooted underneath it.
  http.send(200, "text/plain", reply == "ok;"
                                   ? "ok," + String(attachedMask(), HEX)
                                   : reply);
}

void handleMap() {
  String body = "mask " + String(attachedMask(), HEX) + "\n";
  for (int i = 0; i < CHANNELS; i++) {
    body += "channel " + String(i + 1) + ": ";
    body += pinFor[i] < 0 ? "unassigned" : "GPIO" + String(pinFor[i]);
    body += target[i] < 0 ? "\n" : ", at " + String(current[i]) +
                                       ", going to " + String(target[i]) + "\n";
  }
  http.send(200, "text/plain", body);
}

void handleRoot() {
  String body = "SAC firmware\n\n";
  for (int i = 0; i < CHANNELS; i++) {
    if (pinFor[i] < 0 && target[i] < 0) continue;
    body += "channel " + String(i + 1) + " (";
    body += pinFor[i] < 0 ? "no pin" : "GPIO" + String(pinFor[i]);
    body += "): " + String(current[i]) + " -> " + String(target[i]) + "\n";
  }
  body += "\ncommands " + String(commands) + ", heartbeats " + String(heartbeats);
  body += "\nhotspot devices " + String(WiFi.softAPgetStationNum());
  body += "\nsocket " + (linked ? "connected from " + linkedFrom.toString() : String("idle")) + "\n";
  http.send(200, "text/plain", body);
}

// The servos keep their pins and their positions. Detaching here would drop
// holding torque and the arm would collapse under its own weight, along with
// whatever the gripper is holding.
void dropClient(const char* why) {
  client.stop();
  linked = false;
  LOGF("[socket] %s disconnected (%s)\n", linkedFrom.toString().c_str(), why);
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
    LOGF("[socket] %s connected\n", linkedFrom.toString().c_str());
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
      client.print(handleLine("socket", linkedFrom, inbox) + "\n");
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
      LOGF("[hotspot] device joined %02x:%02x:%02x:%02x:%02x:%02x\n",
           m[0], m[1], m[2], m[3], m[4], m[5]);
      break;
    }
    case ARDUINO_EVENT_WIFI_AP_STAIPASSIGNED:
      LOGF("[hotspot] device got %s\n",
           IPAddress(info.wifi_ap_staipassigned.ip.addr).toString().c_str());
      break;
    case ARDUINO_EVENT_WIFI_AP_STADISCONNECTED:
      LOGF("[hotspot] device left\n");
      break;
    default:
      break;
  }
}

void setup() {
  if (SAC_LOG) {
    Serial.begin(115200);
    delay(200);
  }

  // ESP32Servo drives the servos off the LEDC timers, and attach() fails unless
  // they are handed over first.
  ESP32PWM::allocateTimer(0);
  ESP32PWM::allocateTimer(1);
  ESP32PWM::allocateTimer(2);
  ESP32PWM::allocateTimer(3);

  for (int i = 0; i < CHANNELS; i++) {
    pinFor[i] = -1;
    target[i] = -1;
    current[i] = -1;
  }

  WiFi.onEvent(onWiFiEvent);
  WiFi.mode(WIFI_AP);
  WiFi.softAPConfig(AP_IP, AP_IP, AP_SUBNET);
  if (!WiFi.softAP(AP_SSID, AP_PASSWORD)) {
    LOGF("[hotspot] failed to start; AP_PASSWORD must be 8-63 characters\n");
    while (true) delay(1000);
  }

  http.on("/", handleRoot);
  http.on("/servo", handleServo);
  http.on("/map", handleMap);
  http.begin();
  stream.begin();
  stream.setNoDelay(true);

  lastStep = millis();

  String ip = WiFi.softAPIP().toString();
  LOGF("\nhotspot  %s  password %s\n", AP_SSID, AP_PASSWORD);
  LOGF("address  %s   <- enter this on the app's Arm screen\n", ip.c_str());
  LOGF("socket   %s:%u\n", ip.c_str(), STREAM_PORT);
  LOGF("http     http://%s/servo?cmd=...\n", ip.c_str());
  LOGF("waiting for the app to push a pin map\n\n");
}

void loop() {
  http.handleClient();
  pumpStream();
  stepServos();
}
