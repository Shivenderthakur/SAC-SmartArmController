# Contributing

## Branch naming

Branches are named `<type>/<short-kebab-description>`, using the same type
vocabulary as the commit messages:

| prefix | for |
| --- | --- |
| `feat/` | a new capability |
| `fix/` | a bug or a broken build |
| `perf/` | a change made for speed, with numbers to back it |
| `refactor/` | restructuring with no behaviour change |
| `docs/` | documentation only |
| `test/` | tests only |
| `chore/` | tooling, dependencies, project plumbing |

Keep the description short and specific — the branch says what changes, not how.
`perf/frame-pipeline`, not `perf/make-it-faster`; `fix/android-build-toolchain`,
not `fix/bug`.

`main` is the only long-lived branch, and it is always expected to build and run.
Everything else is a topic branch that lives until it merges.

## Commits

[Conventional Commits](https://www.conventionalcommits.org): `type(scope): summary`
in the subject, imperative mood, no trailing period, under about 72 characters.
Scope is optional and names the area — `android`, `app`, `ui`, `gradle`,
`esp32`, `sac-firmware`.

The body matters more than the subject. Explain **why**, and put the evidence in:
the error message you were chasing, the before and after numbers, the thing you
tried that did not work. A year from now the diff will still be readable and the
reasoning will not be.

```
perf(app): keep two frames in flight to hide the channel round trip

The strict one-at-a-time gate meant the round trip to the native side was dead
time on every single frame: nothing was converted or inferred while the result
made its way back to Dart.

Single biggest win of the three: 12 -> 25 fps.
```

## Merging

Topic branches merge into `main` with `--no-ff`, so the branch structure survives
in the history and a feature can be reverted as a unit:

```bash
git checkout main
git merge --no-ff feat/your-branch
```

## Before you open a pull request

```bash
flutter analyze          # must be clean
flutter build apk --release
```

CI runs both on every push with Flutter **3.47.4**. Use the same version locally:
a newer analyzer finds infos an older one did not, and `flutter analyze` fails
on infos too.

If you touched `SAC-Firmware/`, build it as well — CI does not:

```bash
pio run -d SAC-Firmware
```

A release build compiling is **not** proof it works. This project has already
shipped two bugs that built perfectly and failed only at run time — see
[docs/BUILD_NOTES.md](docs/BUILD_NOTES.md). If you change anything on the frame
path, install it and watch `adb logcat -s SmartArm` before you call it done.

## Releases

The version lives in `pubspec.yaml` and nowhere else. CI builds every push to
`main` with that version as the version name and the workflow run number as the
build number, so each APK's `versionCode` is higher than the last.

When a push to `main` carries a version that has no tag yet, CI tags the commit
`v<version>` and publishes a GitHub Release of that name with
`smart-arm-<version>.apk` attached. To cut the
next release, bump the version in the pull request that should ship it:

```yaml
version: 1.1.0+1     # the +1 is only for local builds; CI supplies the build number
```

A push that leaves the version alone still builds, and its APK is kept as a
workflow artifact, but nothing is released.

### Signing

Android installs an update only if it is signed with the same key as the app
already on the phone. So every release is signed with one permanent key, held in
the repository's Actions secrets, and CI refuses to publish a release without it.

Create the key once, **outside the repository**, and keep the file and its
password somewhere safe. Lose them and every install has to be removed before the
next release will go on.

```bash
keytool -genkeypair -v -keystore ~/smart-arm-release.jks -keyalg RSA -keysize 2048 \
  -validity 10000 -alias smartarm
base64 -w0 ~/smart-arm-release.jks > ~/smart-arm-release.jks.b64
```

Then add four secrets under **Settings → Secrets and variables → Actions**:

| secret | value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | the contents of `~/smart-arm-release.jks.b64` |
| `ANDROID_KEYSTORE_PASSWORD` | the password you gave `keytool` |
| `ANDROID_KEY_ALIAS` | `smartarm` |
| `ANDROID_KEY_PASSWORD` | the same password — `keytool` keys share the keystore's |

Builds without the key — pull requests, and local builds — fall back to the debug
key. To sign a local release build, put the same values in `android/key.properties`,
which is git-ignored:

```properties
storeFile=/home/you/smart-arm-release.jks
storePassword=...
keyAlias=smartarm
keyPassword=...
```

Avoid backslashes in the password: `key.properties` reads them as escapes.

Releases published before the key was set up were each signed with a different
throwaway key, so moving from one of those to a signed release needs one last
uninstall.

## Performance claims

If a change is for speed, measure it. The native side logs a rolling 30-frame
average and the app shows its own frame rate in the status line, so there is no
excuse for guessing:

```
frames=630 hands=0 240x360 on GPU convert=2ms detect=37ms
```

Put the before and after in the commit message.

## Licensing

Contributions are accepted under the [project license](LICENSE). By opening a
pull request you agree that your contribution can be licensed on those terms,
including in commercial licenses the maintainer grants to third parties.
