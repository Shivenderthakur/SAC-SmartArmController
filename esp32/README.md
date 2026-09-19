# ESP32 receiver

The phone does the vision; this just moves servos.

For a board that runs its own hotspot at a fixed `192.168.4.1`, drives up to
nine servos and takes its pin assignments from the app rather than from these
`#define`s, see [SAC-Firmware/](../SAC-Firmware/). This sketch stays as it is:
four servos, fixed pins, joins your home WiFi.

## Flashing

1. Arduino IDE, ESP32 board support installed.
2. Library Manager → install **ESP32Servo**.
3. Open `smart_arm_esp32.ino`, set `WIFI_SSID` and `WIFI_PASSWORD`, check
   `SERVO_BASE`, `SERVO_SHOULDER`, `SERVO_ELBOW` and `SERVO_GRIPPER` against
   your wiring (25, 26, 27, 33 as shipped).
4. Flash, then open the serial monitor at 115200. It prints:

   ```
   ready at http://192.168.1.50  and socket 192.168.1.50:3333
   ```

5. Type that address into the app's **Arm** screen, press **Test connection**,
   then turn on **Send angles to the arm**.

## Protocol

The same command string either way — pick the transport on the app's **Arm**
screen.

**HTTP**, a connection per command:

```
GET /servo?cmd=1,115;2,95;3,108;4,60;5,120;
```

**Socket**, one connection held open to port 3333, one command per line:

```
1,115;2,95;3,108;4,60;5,120;\n   ->   ok;\n
```

`channel,angle;` pairs, channels 1-based — 1 base, 2 shoulder, 3 elbow,
4 gripper — angles 0–180. Unknown channels are ignored, so extra pairs are
harmless. HTTP returns `200 ok`.

The four-value line the Bluetooth build sent still works, on either transport,
which makes the board testable from a terminal without the app:

```
printf '115,95,108,60\n' | nc 192.168.1.50 3333
```

`GET /` returns the current angle of each channel and whether a socket client is
connected, which is a quick way to check the board is alive from a browser.

### About the socket

It is three to twenty times quicker per command — no handshake, no headers, no
new socket every 80 ms. What it gives up is failure detection. A write into a
TCP socket whose peer has vanished **succeeds**: it lands in the kernel's send
buffer, and the kernel retransmits quietly for tens of seconds. Nothing throws.
The phone would report a healthy link while the arm sat still.

So three things exist to buy that back, and none of them is optional:

- **The `ok;` reply.** Every line is answered, including the app's `?;`
  heartbeat. Anything coming back is proof of life; three seconds of silence and
  the app rebuilds the socket, backing off up to five seconds so a rebooting
  board is not hammered.
- **The newline.** TCP is a stream of bytes, not of messages. A command can
  arrive split across two packets, or two can arrive in one, so the sketch
  buffers until a newline rather than trusting one read to be one command.
- **The idle drop.** The sketch serves one client. A stale connection the board
  still believes in would hold that slot forever, so anything silent for five
  seconds is dropped and the newest connection always wins.

Channel 5 is the claw mirrored (`180 - angle`), for a gripper driven by two
opposed servos. This arm has one, so the sketch ignores it.

Two output corrections survive from the Bluetooth build and live in
`writeServo()`: the base runs backwards against its linkage (`180 - angle`) and
the gripper's travel is half the servo's (`180 - 2 × angle`). If the arm moves
the wrong way after a rebuild, that function is the place to look, not the app.
Note that the app drives the claw over 0–60, so the gripper uses 180–60 of its
range; widen `clawOpenAngle` in `lib/models/hand.dart` if it does not open far
enough.

Angles are not applied the instant they arrive. Each servo walks one degree
every 15 ms toward its target, which is what makes the arm sweep rather than
snap — the Bluetooth build did this with `delay()`, which is fine when nothing
else needs the loop and fatal when a socket does, so it is a timestamp now.

## Notes

The app throttles and coalesces commands — only the newest position is ever
sent, at most one every 80 ms by default, adjustable on the Arm screen. A servo
cannot follow 25 updates a second and neither can this server.

Servos draw far more current than the ESP32's regulator can supply. Power them
from a separate supply and tie the grounds together.
