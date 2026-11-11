# Development

A native Swift app: SwiftUI with Liquid Glass, CoreBluetooth, and SQLite from the macOS SDK. It has no package dependencies, no WebView, and no network code.

Requirements: macOS 26 and Xcode 26 (Swift 6.2 or later). The Command Line Tools are enough for building; `#Preview` blocks compile only in debug builds because the release toolchain from the Command Line Tools lacks the preview macro plugin.

## Layout

| Path | Contents |
|---|---|
| `Sources/WalkingPadCore` | Protocols (FTMS, KingSmith legacy), command queue, speed rules, statistics, SQLite store. No UI. |
| `Sources/WalkingPadApp` | Menu-bar app: Bluetooth controller, app model, popup, Settings, menu-bar readout. |
| `Tests/WalkingPadCoreTests` | Protocol bytes, decoding, queueing, statistics, migrations. |
| `Tests/WalkingPadUITests` | Render checks for the popup, Settings rows, and menu-bar readout, plus the opt-in hardware test. |
| `scripts/build-app.sh` | Builds `build/WalkingPad.app` and signs it. |
| `scripts/install-app.sh` | Builds, quits the running copy, replaces `/Applications/WalkingPad.app`, and launches it. |
| `Resources/AppIcon.icon` | App icon source in Icon Composer format; layers drawn by `scripts/draw-icon.swift`. |
| `Resources/Icon` | Compiled icon (`Assets.car`, `AppIcon.icns`), committed so builds don't need full Xcode. Regenerate with `bash scripts/make-icon.sh`. |
| `Formula/walkingpad.rb` | Homebrew formula; the repo doubles as its tap. |

## Build and run

```sh
bash scripts/install-app.sh          # build, install to /Applications, launch
bash scripts/build-app.sh            # build only: build/WalkingPad.app
```

Run the bundle, not `swift run`. macOS grants Bluetooth permission to the app bundle; under `swift run` it would go to the terminal.

### Signing

`build-app.sh` signs with the first "Apple Development" identity in your keychain. A stable identity keeps the Bluetooth permission across rebuilds. Without one it signs ad hoc, which gives each build a new identity, so macOS asks for Bluetooth again (or reports it denied). Override with `WALKINGPAD_SIGN_IDENTITY`, or set it to `-` for ad hoc.

If macOS keeps denying Bluetooth after switching identities, reset it and relaunch:

```sh
tccutil reset BluetoothAlways app.walkingpad.native
```

The Homebrew formula always signs ad hoc, which is why users get the permission prompt after each upgrade. Developer ID signing and notarization are not set up; they need a paid Apple Developer account.

## Checks

```sh
swift test
bash scripts/build-app.sh && codesign --verify --strict build/WalkingPad.app
```

- `WALKINGPAD_SNAPSHOTS=1 swift test --filter ControlPanelRender` shows the belt controls in a window briefly and saves light and dark captures to `.build/design-checks`. `BarReadoutTests` saves `menubar-{light,dark}.png` there the same way.
- `WALKINGPAD_HARDWARE=KS-BDC2 swift test --filter Hardware` runs the Bluetooth controller against a real, awake pad: discovery, connection, and polled telemetry, without moving the belt. Add `WALKINGPAD_MOTOR=1` to also run Start, a speed change, and Stop through the app; run that only with nobody on the pad. Without the variables these tests are skipped.

## Releasing

1. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `Resources/Info.plist`.
2. Commit, tag `vX.Y.Z`, and push the tag.
3. Hash the archive GitHub generates:
   ```sh
   curl -sL https://github.com/mrRedSun/macos-kingsmith-app/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256
   ```
4. Update `url` and `sha256` in `Formula/walkingpad.rb`, commit, and push.
5. Check it: `brew update && brew upgrade walkingpad`, or `brew install --build-from-source` on a clean machine.

## Bluetooth protocol

The app picks a protocol from the services the pad actually exposes, preferring FTMS when several are present. Discovery lists a device only if it advertises a supported service or its name starts with `Walking` or `KS-`.

| Service | Characteristics | Status |
|---|---|---|
| KingSmith `FE00` | notify `FE01`, write `FE02` | Verified on KS-BDC2 (C2) |
| KingSmith `FFF0` | notify `FFF1`, write `FFF2` | Same frames assumed, unverified |
| FTMS `1826` | treadmill data `2ACD`, control point `2AD9`, speed range `2AD4` | Implemented, unverified on hardware |

Legacy characteristic roles are confirmed from their properties during connection.

### KingSmith frames (verified on KS-BDC2)

Frames are `F7 <header> <payload…> <checksum> FD`; the checksum is the low byte of the sum of the header and payload bytes. Replies start with `F8`.

- **Status query** `F7 A2 00 00 A2 FD`, sent every second while connected; the pad sends nothing unprompted. Reply `F8 A2`: byte 2 state, 3 speed in 0.1 km/h, 4 mode (1 manual, 2 standby), 5–7 seconds, 8–10 distance in 10 m units, 11–13 steps. Counters are big-endian and reset when the pad enters standby.
- **Start**: the pad ignores Start in standby. The app sends manual mode `F7 A2 02 01 A5 FD`, waits 0.5 s, then Start `F7 A2 04 01 A7 FD`; sent back-to-back, Start is ignored. Stop during the wait cancels the unsent Start. The pad counts down 3 s (states 9, 8, 7) before the belt moves.
- **Speed**: opcode `01` in 0.1 km/h, e.g. `F7 A2 01 19 BC FD` for 2.5 km/h. **Stop** is speed 0, `F7 A2 01 00 A3 FD`; the belt slows over about 3 s.
- **Latest walk record**: query `F7 A7 AA FF 50 FD`. Reply `F8 A7`, 20 bytes: [2..5] walk ID (UInt32 BE, the walk's start time on the pad's own clock), [6..7] seconds, [8..9] distance in 10 m units, [10..11] steps, checksum at [18]. All zeros during a walk. After Stop, every query returns the same record; reading doesn't clear it. The reference library's `AA 00` variant appears to mark it read, so the app never sends it.
- Stop then Start continues the same walk (same ID, counters continue). The pad counts only while someone walks; an empty belt for 42 s added 3 s.

### FTMS

- Optional fields are decoded by their flags, including fragments without instantaneous speed. Missing values show as `—`, not zero.
- Steps aren't standard FTMS. **FTMS step extension** in Settings decodes exactly one little-endian UInt16 appended to treadmill data. Enabling it starts a new step baseline. Unknown suffixes are not guessed.
- The speed range from `2AD4` is used when readable. Otherwise controls stay within 0.5–6 km/h in 0.1 km/h steps.

### Commands and safety

- Start and speed need fresh telemetry and granted control. Speed works only while the belt moves, because older pads treat speed 0 as Stop and may treat a speed command as Start.
- Rapid − and + taps coalesce into one command. Stop can be sent without fresh telemetry and jumps ahead of any queued command. After a timeout, a queued Stop gets one best-effort attempt; Start and speed are never retried.
- A GATT write acknowledgement is not motor confirmation. FTMS waits for the matching control-point indication and reports rejection or timeout. Legacy pads have no acceptance indication; check the live speed.
- **Step-off stop** (`StepOffDetector`, KingSmith pads only): while speed > 0, if neither the time nor the step counter changes for the configured delay (default 5 s), the app sends Stop once. Checking starts 10 s after the belt starts moving, to allow stepping on. Basis: on KS-BDC2 an empty belt added 2 s of time (during start-up) and no steps in 42 s. Verified on KS-BDC2 by stepping off mid-walk with the default 5 s. Distance isn't used; in 10 m units it advances too slowly at low speed. FTMS pads aren't covered because their elapsed time may count without a walker.
- Auto-connect uses `retrievePeripherals(withIdentifiers:)` and a pending `connect`, which CoreBluetooth never times out, so it completes when the pad wakes. It only reads status.

## Statistics

Sessions are stored in `~/Library/Application Support/WalkingPad/statistics.sqlite` (schema version 3). Settings live in the app's defaults domain.

### KingSmith pads (`PadWalks`)

- A session mirrors the pad's own per-walk counters, so time walked while disconnected is included and a reconnect mid-walk continues the session.
- On connect, and 3 s after the belt stops, the app reads the latest-walk record. It fills in a partly seen walk, merges a walk split by a reconnect, or adds a walk the app never saw. Re-reading an unchanged record writes nothing.
- The walk ID is a pad-clock timestamp (on the test pad, about 178 days behind real time). The app learns the offset from a walk it watched live (`padClockOffset` default) and uses it to date imported walks. Before that, an imported walk is dated as ending at connect time.
- Sessions belong to the day they started and are not split at midnight.

### FTMS pads (`SessionAccumulator`)

- Only observed deltas count. Each connection's first value is a baseline; counter decreases and 16-bit step wraps start new baselines.
- Sessions split on reconnect and at local midnight; a delta spanning midnight belongs to the receiving sample's day. Disconnected activity is not imported.
- Without an elapsed-time field, connected moving intervals of up to 15 s are estimated and marked `~`.

### Storage

Writes go through the `SessionStore` actor, off the UI thread. SQLite runs in WAL mode with full synchronous commits; upserts are revision-guarded so an older snapshot can't overwrite newer totals. Idle or identical samples don't write. Quit drains pending writes and offers quitting without saving if storage fails. CSV export has UTC timestamps, meters, seconds, optional steps, and `time_estimated`.

## Not yet measured

Idle CPU, memory, and latency. FTMS is notification-driven; legacy connections poll once a second only while connected, and discovery scans stop after 12 seconds.
