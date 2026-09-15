# SAC firmware

PlatformIO firmware that turns the ESP32 into its own WiFi hotspot at an address
that never changes, so the phone never has to go looking for it.

For now it **prints every command the app sends** to the serial monitor and does
not drive the servos — that comes next. The Arduino sketch in [esp32/](../esp32/)
is the one that moves servos over your home WiFi.

## Flash

Needs [PlatformIO](https://platformio.org), CLI or the VS Code extension. No
extra libraries.

```bash
cd SAC-Firmware
pio run -t upload
pio device monitor          # 115200
```

On Linux, `Permission denied: '/dev/ttyUSB0'` means your user is not in the
`dialout` group:

```bash
sudo usermod -aG dialout $USER      # then log out and back in
```

On boot it prints:

```
hotspot  SAC-Arm  password sacarm123
address  192.168.4.1   <- enter this on the app's Arm screen
socket   192.168.4.1:3333
http     http://192.168.4.1/servo?cmd=...
```

## Connect the app

1. On the phone, join the `SAC-Arm` WiFi network.
2. On the app's **Arm** screen enter `192.168.4.1`, pick Socket or HTTP, press
   **Test connection**, then turn on **Send angles to the arm**.

The board pins itself to `192.168.4.1` before the hotspot starts, so the address
is the same on every boot and every phone.

The hotspot has no internet. Some Android phones then keep routing traffic over
mobile data and the app reports *unreachable* — turn mobile data off, or choose
to stay connected when Android warns that the network has no internet.

## Serial output

```
[hotspot] device joined 3c:2e:ff:12:34:56
[hotspot] device got 192.168.4.2
[socket] 192.168.4.2 connected
[socket 192.168.4.2] #1  base=115 shoulder=95 elbow=108 claw=60 claw2=120   raw=1,115;2,95;3,108;4,60;5,120;
[socket] 192.168.4.2 disconnected (idle)
```

A channel that has not been sent yet shows `-1`. The app's `?;` heartbeat is
counted but not printed. Opening `http://192.168.4.1/` in a browser shows the
latest angles, the command and heartbeat counts, and how many devices are on
the hotspot.

## Protocol

The same one the app already speaks — see `lib/services/arm_link.dart`.

| transport | wire |
| --- | --- |
| Socket | one TCP connection to port `3333`, one command per line, every line answered `ok;` |
| HTTP | `GET /servo?cmd=1,115;2,95;3,108;4,60;5,120;`, answered `200 ok` |

`channel,angle;` pairs, channels 1-based: 1 base, 2 shoulder, 3 elbow, 4 claw,
5 the claw mirrored. Angles are clamped to 0–180.

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
refuses to start and the serial monitor says so.
