# SAC firmware

PlatformIO firmware that turns the ESP32 into its own WiFi hotspot at an address
that never changes, so the phone never has to go looking for it.

It drives up to **nine servos** — eight joints and a gripper — on GPIO 16, 17,
18, 19, 21, 22, 23, 32 and 33. Which channel drives which pin is decided in the
app's **Board** screen and pushed down the link, so moving a joint to another
pin never means reflashing the board.

Serial output is off by default; [turn it on](#serial-log) to watch every
command arrive. The Arduino sketch in [esp32/](../esp32/) is the older receiver
that joins your home WiFi instead of running a hotspot.

## Flash

Needs [PlatformIO](https://platformio.org), CLI or the VS Code extension. No
extra libraries.

```bash
cd SAC-Firmware
pio run -t upload
```

On Linux, `Permission denied: '/dev/ttyUSB0'` means your user is not in the
`dialout` group:

```bash
sudo usermod -aG dialout $USER      # then log out and back in
```

## Connect the app

1. On the phone, join the `SAC-Arm` WiFi network.
2. On the app's **Arm** screen enter `192.168.4.1`, pick Socket or HTTP, press
   **Test connection**, then turn on **Send angles to the arm**.

The board pins itself to `192.168.4.1` before the hotspot starts, so the address
is the same on every boot and every phone.

Opening `http://192.168.4.1/` in a browser shows the latest angles, the command
and heartbeat counts, and how many devices are on the hotspot — the quickest
check that the board is up, with or without the serial log.

The hotspot has no internet. Some Android phones then keep routing traffic over
mobile data and the app reports *unreachable* — turn mobile data off, or choose
to stay connected when Android warns that the network has no internet.

## Serial log

Every serial call goes through `LOGF`, which is compiled out unless `SAC_LOG` is
set, so a normal build keeps the UART quiet. To watch the board, build with the
flag and open the monitor:

```bash
PLATFORMIO_BUILD_FLAGS="-D SAC_LOG=1" pio run -t upload
pio device monitor          # 115200
```

A plain `pio run -t upload` afterwards silences it again. With the log on, boot
prints:

```
hotspot  SAC-Arm  password sacarm123
address  192.168.4.1   <- enter this on the app's Arm screen
socket   192.168.4.1:3333
http     http://192.168.4.1/servo?cmd=...
```

and then, as the phone joins and the app streams:

```
[hotspot] device joined 3c:2e:ff:12:34:56
[hotspot] device got 192.168.4.2
[socket] 192.168.4.2 connected
[socket 192.168.4.2] #1  base=115 shoulder=95 elbow=108 claw=60 claw2=120   raw=1,115;2,95;3,108;4,60;5,120;
[socket] 192.168.4.2 disconnected (idle)
```

A channel that has not been sent yet shows `-1`. The app's `?;` heartbeat is
counted but not printed.

## Protocol

The same one the app already speaks — see `lib/services/arm_link.dart`.

| transport | wire |
| --- | --- |
| Socket | one TCP connection to port `3333`, one line at a time, every line answered |
| HTTP | `GET /servo?cmd=<the same line>`, answered `200 ok,<mask>` |

Two kinds of line arrive. **Angles** are `channel,angle;` pairs, channels
1-based, clamped to 0–180, answered `ok;`:

```
1,115;2,95;3,108;4,60;
```

**The pin map** is one line of `M,<channel>,<gpio>;` tokens, `-1` for a joint
with no pin, answered `map,<hex mask>;` naming the channels that actually
attached:

```
M,1,16;M,2,17;M,3,18;M,4,19;   ->   map,f;
```

The board takes the whole map line or none of it, so a truncated line can never
leave half the arm re-wired, and it refuses any pin outside the nine above or
the same pin twice. Channels with no pin still remember their angle, so a
nine-channel command is harmless on a three-servo rig.

**The map lives in RAM only.** The app pushes it on every connect, and the board
answers the app's `?;` heartbeat with `ok,0;` while it holds no map and `ok,1;`
once it does — which is how a phone notices a board that rebooted underneath a
socket that survived. `GET /map` prints the same thing for a browser.

Angles are not applied the instant they arrive: each servo walks one degree
every 15 ms toward its target, which is what makes the arm sweep rather than
snap. When the phone disconnects the servos hold position — detaching them would
drop the holding torque and the arm would sag under its own weight.

The socket serves one client. The newest connection wins, and a client silent
for 5 seconds is dropped — the app heartbeats every 700 ms when it has nothing
to send, so only a phone that is really gone goes quiet that long.

To test without the app, from a laptop joined to the hotspot:

```bash
printf '1,115;2,95;3,108;4,60;\n' | nc 192.168.4.1 3333
curl 'http://192.168.4.1/servo?cmd=1,90;2,90;'
```

## Hotspot name and password

The defaults live in `src/main.cpp`. To use your own without committing them:

```bash
cp include/secrets.example.h include/secrets.h    # git-ignored
```

Edit it and flash again. The password must be 8–63 characters, or the hotspot
refuses to start (with `SAC_LOG=1`, the serial monitor says so).
