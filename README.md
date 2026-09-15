# Smart Arm Controller

Control a robotic arm with your hand, in front of a phone camera. Point, tilt,
reach and close your fist; four servo angles come out the other side.

It is an Android port of a desktop Python controller that used OpenCV and
MediaPipe Hands over a webcam. The vision runs **entirely on the phone** — the
hand model ships inside the APK and nothing is uploaded anywhere. The only thing
that leaves the device is servo angles, to one ESP32 on your own WiFi.

```
      camera frame                          [ 115, 95, 108, 60 ]
           │                                   X   Y   Z   claw
           ▼
   21 hand landmarks  ──►  palm angle, wrist height, palm size, fist
```

| | |
| --- | --- |
| **Platform** | Android (Flutter + Kotlin) |
| **Tracking** | MediaPipe Hands, 21 landmarks, on-device |
| **Speed** | ~25 fps on a Realme RMX2001 (Helio G90T) |
| **Network** | Local only — one ESP32 on your WiFi. No cloud, no CDN, no WebView. |
| **License** | [Noncommercial](LICENSE) — free to learn and teach with, paid for commercial use |

## What it does

MediaPipe finds 21 hand landmarks in each camera frame. Four numbers are derived
from them, mapped to the 0–180 range a hobby servo wants:

| servo | driven by | range |
| --- | --- | --- |
| **X** — base rotation | tilt of the palm: wrist against the index knuckle | 0–150 |
| **Y** — vertical lift | how high the wrist sits in frame | 0–180 |
| **Z** — reach | palm size, standing in for distance from the camera | 10–180 |
| **Claw** | open hand or closed fist | 0 or 60 |

The maths is ported one to one from the original Python, down to reproducing
Python's floor-towards-negative-infinity division — see
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#two-details-that-had-to-be-preserved-exactly) for why that
detail is not cosmetic.

The skeleton is drawn over the live preview, the four angles are shown as a
readout, and the last angles are held when your hand leaves the frame.

## Driving the arm

The desktop script wrote `"{channel},{angle};"` down a serial port. A phone has
no serial port, so the same command string goes over the network to an ESP32 on
the same WiFi, either way you like:

```
HTTP     GET http://<esp32-ip>/servo?cmd=1,115;2,95;3,108;4,60;5,120;
Socket   1,115;2,95;3,108;4,60;5,120;\n     down one open connection to :3333
```

The wire format is deliberately unchanged, so a sketch that drove the arm from
serial needs almost no rewriting. Channel 5 mirrors the claw (`180 - angle`) for
a gripper on two opposed servos, exactly as the desktop script did; a receiver
with one gripper servo ignores it.

The socket is quicker — no handshake and no headers per command, so an angle
lands in a millisecond or two rather than twenty or forty. What it costs is that
failure stops being obvious: a write into a TCP socket whose peer has vanished
succeeds, sits in the kernel's send buffer and is retransmitted quietly for tens
of seconds, so nothing throws while the arm sits still. The board therefore
answers `ok;` to every line, the app heartbeats when it has nothing to send, and
three seconds of silence rebuilds the socket with a backoff. HTTP needs none of
that — every command carries its own timeout — which is why it is still the
default and still worth choosing on a flaky network.

A ready-to-flash receiver that serves both is in [esp32/](esp32/) — set your WiFi
credentials and servo pins, flash, and type the IP it prints into the app's
**Arm** screen.

Sending is **off until you turn it on**, so the arm cannot move while you are
still setting up. Commands are throttled and coalesced: tracking runs near 25 fps
and neither a servo nor a small server can take that, so only the newest position
is ever sent, at most one every 80 ms by default.

Still not built: the `ok;` proves the board is listening, not that a servo
actually moved — nothing reads the arm's real position back.

## Build

Needs the Flutter SDK (CI pins 3.47.4) and an Android toolchain. Ready-built
APKs are attached to each [release](../../releases).

```bash
git clone git@github.com:Shivenderthakur/SAC-SmartArmController.git
cd SAC-SmartArmController

./tools/fetch_model.sh          # required — see below
flutter pub get
flutter build apk --release

adb install -r build/app/outputs/flutter-apk/app-release.apk
```

The 7.8 MB MediaPipe model is **not in the repository** — binaries do not belong
in git. `tools/fetch_model.sh` downloads it from Google's model host into
`android/app/src/main/assets/`. It is a build-time fetch only; the app itself
never touches the network. The build fails without it.

The APK is about 88 MB, almost all of it MediaPipe's native libraries for four
ABIs plus the model. `--split-per-abi` cuts it considerably if you care.

## The app

Four screens, on a bottom bar you can **scrub**: tap to select, or press and
slide and the selection follows your finger from one destination to the next,
with a click of haptic feedback at each boundary.

| screen | what |
| --- | --- |
| **Track** | Camera, hand skeleton, live angles, frame rate. Flip camera, mirror, and an Auto/Manual switch. |
| **Control** | Drive each servo by hand with sliders, and see the exact command string being sent. |
| **Arm** | ESP32 address, connection test, the send switch, and the rate limit. |
| **Theme** | Light, dark or follow the system; five accents, applied instantly. |

Hand tracking and the sliders both write to one place, and only that place talks
to the arm — so what is on screen is what the arm was told. Touching a slider
switches to manual, because otherwise the next tracked frame would overwrite it.
Tracking keeps running and drawing while manual is on; it just stops driving.

The app asks for camera permission on first launch. Grant it **"While using the
app"** rather than "Only this time", or it will expire and the preview will come
back empty.

**Mirror** flips the overlay horizontally. This is a manual toggle on purpose:
whether the platform mirrors the front-camera texture depends on the device —
Flutter's CameraX plugin mirrors on its ImageReader path but not on its
SurfaceTexture path, and which one you get is decided at runtime. Rather than
guess wrong and paint the skeleton onto the mirror image of your hand, the flip
stays under your thumb. Mirroring is display-only; the angles are computed from
the unflipped frame either way, so toggling it never changes the numbers.

## How it works

Frames come off the `camera` plugin as NV21 and cross a method channel to Kotlin,
which converts and rotates them upright in a single pass and runs MediaPipe's
`HandLandmarker`. Only 21×3 doubles come back — about 500 bytes, against a
megabyte if pixels were returned. The preview is already on screen as a platform
texture, so the overlay is drawn as vector strokes on top of it.

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) traces a frame end to end.

### Why Kotlin, and not a Flutter package

There is no Flutter package for MediaPipe Tasks. Google's ML Kit — the usual
answer for on-device vision in Flutter — has pose detection but **no hand
landmarker**, and pose landmarks give you a wrist and three fingertips, which is
not enough for a fist. Getting 21 points means driving
`com.google.mediapipe:tasks-vision` from Kotlin directly.

### Performance

4.5 fps to 25 fps, measured at each step on the same device:

| change | convert | detect | fps |
| --- | --- | --- | --- |
| starting point | 17 ms | 63 ms | 4.5 |
| notifier-driven repaints instead of `setState` per frame | 17 ms | 47 ms | 10 |
| GPU delegate | 17 ms | 47 ms | 10 |
| half-resolution detection input | 2 ms | 39 ms | 12 |
| two frames in flight | 2 ms | 37 ms | **25** |

Inference now dominates completely, putting the ceiling near 26 fps on this
hardware. Details, including why half resolution costs no accuracy, are in the
[architecture notes](docs/ARCHITECTURE.md#performance-notes).

## Project layout

| path | what |
| --- | --- |
| `lib/main.dart` | App shell, theming, the four-screen scaffold. |
| `lib/models/hand.dart` | The ported Python maths and the servo constants. |
| `lib/services/` | Camera and MediaPipe bridge, arm state, ESP32 client, settings. |
| `lib/screens/` | Track, Control, Arm, Theme. |
| `lib/widgets/` | Scrubbable nav bar, overlay painter, gradient slider. |
| `esp32/` | Arduino sketch for the receiver, and its wiring notes. |
| `android/app/src/main/kotlin/.../MainActivity.kt` | MediaPipe bridge and the NV21 conversion. |
| `android/app/build.gradle.kts` | MediaPipe dependency, `noCompress`, release config. |
| `android/build.gradle.kts` | The AGP 9 fix for `camera_android_camerax`. |
| `tools/fetch_model.sh` | Downloads the hand landmarker model. |
| `assets/icon/app_icon.png` | Source art for the app icon (1254×1254, transparent). |
| `tools/generate_icons.py` | Rebuilds every platform's icon from that source: `python3 tools/generate_icons.py`. |
| `docs/ARCHITECTURE.md` | The frame pipeline and the ported maths, in detail. |
| `docs/BUILD_NOTES.md` | Toolchain problems hit during the port, and their fixes. |

Package `com.roboticdroid.smartcontroller`, app label "Smart Arm".

## Build notes worth reading

The Android toolchain fought this project hard, and two of the failures produced
a **clean build and a broken app**. [docs/BUILD_NOTES.md](docs/BUILD_NOTES.md)
documents all four with symptom, cause and fix. The one most likely to catch
someone else:

> R8 inlines the stack frame MediaPipe's native library loader walks for, so
> `Graph.<clinit>` throws `IllegalStateException: no caller found on the stack`,
> `HandLandmarker.createFromOptions` fails, and every frame reaches the native
> side and bails on its first line. The app launches, the camera runs, and the UI
> just says "no hand" forever. Keep rules cannot fix inlining.

## Roadmap

- Acknowledgements from the ESP32, so the app can tell a delivered command from
  a servo that never moved
- Servo smoothing — raw landmarks are jittery frame to frame
- Calibration for the mapping constants, which are currently the Python's
- Optional full-native CameraX pipeline to get past the 26 fps channel ceiling
- Bluetooth as an alternative to WiFi, for use away from a network

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for branch naming, commit conventions and
what to check before opening a pull request.

## License

[SmartArm Noncommercial License 1.0.0](LICENSE), based on PolyForm Noncommercial
1.0.0.

**Free** for personal use, hobby projects, research, and teaching that learners
are not charged for.

**Requires a commercial license** for anything you make money with, including
paid courses, classes and bootcamps that use it — whoever runs them. The line is
the fee, not the institution: a free university workshop needs nothing, a private
academy charging students for a robotics course needs a license.

See [COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md).
