# WalkingPad for macOS

A native Swift menu-bar client for WalkingPad firmware exposing FTMS `1826`, KingSmith `FE00`, or `FFF0` Bluetooth services. No JavaScript, WebView, Electron, downloaded packages, or network service. Requires macOS 26 or later and a Swift 6.2 toolchain. The popup and Settings use native Liquid Glass controls.

## Install with Homebrew

Homebrew builds the app on your Mac from source. This is a personal tap, not the official Homebrew list. You need macOS 26 and Xcode 26 or its Command Line Tools (`xcode-select --install`).

```sh
brew tap mrRedSun/walkingpad https://github.com/mrRedSun/macos-kingsmith-app
brew install mrRedSun/walkingpad/walkingpad
ln -sf "$(brew --prefix)/opt/walkingpad/WalkingPad.app" /Applications/WalkingPad.app
open /Applications/WalkingPad.app
```

The app is not notarized by Apple. macOS opens it anyway, because Homebrew builds it locally instead of downloading it. The build takes about a minute. The app lives in Homebrew's folder; the link in `/Applications` points to it and keeps working after upgrades.

- Update with `brew update && brew upgrade walkingpad`. macOS asks for Bluetooth access again after each upgrade, because every local build has a new ad hoc signature.
- Install the latest `main` instead of the last release with `brew install --HEAD mrRedSun/walkingpad/walkingpad`.
- Uninstall with `brew uninstall walkingpad`, `rm /Applications/WalkingPad.app` (removes only the link), and `brew untap mrRedSun/walkingpad`. Statistics stay in `~/Library/Application Support/WalkingPad`.

To release a new version, bump `CFBundleShortVersionString` in `Resources/Info.plist`, push a `vX.Y.Z` tag, then update `url` and `sha256` in `Formula/walkingpad.rb`. Get the hash with `curl -sL https://github.com/mrRedSun/macos-kingsmith-app/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256`.

## Build from a clone

```sh
bash scripts/build-app.sh
open build/WalkingPad.app
```

To install into `/Applications` instead, run `bash scripts/install-app.sh`. It builds, quits the running copy, replaces `/Applications/WalkingPad.app`, and launches it.

The build script builds an optimized executable, creates an app bundle with Bluetooth permission text, and signs it for local use. It uses your Apple Development identity if the keychain has one, so macOS keeps the Bluetooth permission across rebuilds. Otherwise it signs ad hoc, and macOS may ask for Bluetooth access again after each rebuild. Set `WALKINGPAD_SIGN_IDENTITY` to choose an identity, or `-` for ad hoc. The bundle is built for the host architecture. Distribution signing and notarization are not configured.

Use the bundle rather than `swift run`, so macOS assigns Bluetooth consent to WalkingPad instead of a terminal process. Allow Bluetooth access when macOS asks. Denied permission can be changed in System Settings > Privacy & Security > Bluetooth.

## Everything stays in the tray

1. Click the WalkingPad readout in the macOS menu bar. It shows the metrics chosen in Settings, each with an icon instead of a unit, stacked two per column unless **Two rows** is off. With every metric off, it shows a walking icon. There is no Dock icon or main window.
2. The first time, choose **Find walking pad**, then select your pad. Wake the pad and disconnect other apps first. After that, the app reconnects on its own (see below).
3. Press **Start** to start the belt. Once it moves, change speed with − and + (0.5 steps, or ↓ and ↑) or tap a preset. Press **Stop belt**, or Space, to stop.
4. Switch to **History** inside the same popup for saved walks and CSV export.
5. Open **Settings** for menu-bar metrics, order, units, and step decoding. Settings is the only application window.

The status item defaults to an icon. Enable any combination of speed, steps, distance, and duration in Settings. Counter sources are live pad totals, the observed session, or observed today. Speed always comes from live telemetry. Speed controls step in the display unit, and each step is rounded to the pad's 0.1 km/h increment. Edit the four presets in Settings; the defaults are 2, 3, 4, and 5 km/h.

With **Connect automatically** on (the default), the app remembers the last pad that connected and keeps a pending connection to it. It connects when the pad wakes and reconnects after a dropped link. **Disconnect** or **Stop waiting** in the popup pauses this until you pick a pad again or relaunch. Auto-connect only reads status. The app does not auto-start or change the belt on launch. It does not stop the belt when disconnected or closed. Keep the physical remote within reach. **Bluetooth Stop is not an emergency stop.**

## C2 compatibility

The app selects a protocol from the services actually exposed by the pad. It prefers FTMS when several supported services are present. Discovery lists a device only if it advertises a supported service or a name starting with `Walking` or `KS-`.

FTMS uses treadmill data `2ACD` and write/indicate control point `2AD9`. KingSmith `FE00` uses notify `FE01` and write `FE02`, verified on a KS-BDC2. `FFF0` expects notify `FFF1` and write `FFF2`, which is unverified. Legacy roles are confirmed from characteristic properties during connection. Legacy pads send nothing until queried, so the app sends the status query `F7 A2 00 00 A2 FD` every second while connected. Replies contain big-endian elapsed, distance, and step counters, which are decoded automatically after checksum validation.

Verified on KS-BDC2 with nobody on the belt: discovery, connection, status polling, Start, speed changes, and Stop.

- The pad ignores Start in standby (status mode 2). The app first sends manual mode (`F7 A2 02 01 A5 FD`), waits 0.5 seconds, then sends Start (`F7 A2 04 01 A7 FD`). Sent back-to-back, Start is ignored. During that wait, Stop cancels the unsent Start.
- Start shows a 3-second countdown on the pad (status states 9, 8, 7) before the belt moves.
- Speed is opcode `01` in 0.1 km/h units, for example `F7 A2 01 19 BC FD` for 2.5 km/h. Stop is speed 0 (`F7 A2 01 00 A3 FD`); the belt slows to a halt over about 3 seconds.

- FTMS optional fields are decoded according to their flags, including fragmented packets without instantaneous speed. Missing values appear as `—`, not zero.
- Step counts are not standard FTMS data. Enable **FTMS step extension** only after checking that your FTMS firmware appends exactly one little-endian 16-bit counter. FE00/FFF0 steps do not require this option. This starts a new step baseline and cannot recover earlier unobserved steps. Unknown suffixes are not guessed.
- Supported speed range `2AD4` is used when readable. Controls stay between 0.5 and 6 km/h on the reported increment. A conservative 0.5–6 km/h, 0.1 km/h range is used if no range is supplied. Confirm this range for your pad.
- Start sends immediately, with no confirmation step. Start and speed require fresh telemetry and granted control. Speed controls only work while the belt is moving, because older pads treat speed 0 as Stop and might treat a speed command as Start. Rapid − and + taps are combined into one command. Stop can be sent without fresh telemetry. If a command is already pending, Stop queues ahead of any future command. After a command timeout, a queued Stop receives one best-effort attempt. No Start or speed command is retried.
- A GATT write acknowledgement is not motor confirmation. FTMS waits for the matching control-point indication and reports rejection or timeout. Late responses for unrelated opcodes are ignored. FE00/FFF0 serialize writes and prioritize Stop, but have no equivalent motor-acceptance indication. Check the live speed and keep the remote available. A physical remote or another app may take control away.

## How statistics are counted

**KingSmith pads (FE00/FFF0)** count each walk themselves, and sessions follow those counters:

- A session is one walk on the pad. Its totals are the pad's own time, distance, and steps for that walk, including anything walked while the app was disconnected or closed. Reconnecting mid-walk continues the same session. Stop then Start on the pad continues the walk; the pad resets its counters when a new walk begins.
- The pad counts only while someone walks. A belt running empty adds almost nothing.
- After each Stop, and on connect, the app reads the pad's record of its latest walk (query `F7 A7 AA FF 50 FD`, reply `F8 A7`). The record fills in a walk the app saw only partly, merges a walk split by a reconnect, or adds a walk the app never saw. The pad keeps only its latest walk, so if you take several walks while the app is closed, only the last one is imported. Reading the record doesn't clear it, so the official app still receives it.
- The record's ID is the walk's start time on the pad's own clock, which is not set to real time. The app learns the offset from walks it watches live and uses it to date imported walks. Until it has learned the offset, an imported walk is dated as ending when the app connected.
- Sessions belong to the day they started. They are not split at midnight.

**FTMS pads** report observed activity, not the pad's lifetime totals:

- Each connection's first value establishes an independent baseline for each counter. Repeated packets add nothing. Counter decreases establish new baselines rather than importing reset values. A 16-bit step wrap is treated the same way, so the crossing interval can be undercounted.
- A session is saved only after a positive distance, step, or walking-time change. Sessions split on reconnection and local calendar-day changes. A delta spanning midnight belongs to the receiving sample's day. Disconnected activity is not imported.
- Walking time normally uses the pad's elapsed counter while moving. If the connection has never supplied elapsed time, connected moving intervals of at most 15 seconds supply an estimate. `~` marks sessions with estimated time. Once a device clock appears, missing clock fragments are not estimated or double-counted.
- Steps can be partial if the extension is enabled partway through a walk. Nothing estimates unavailable steps. History labels these as observed steps.
- Changes checkpoint to SQLite off the UI thread. SQLite uses WAL, full synchronous commits, a versioned schema, and revision-guarded upserts so asynchronous older snapshots cannot overwrite newer totals. Identical or idle samples do not trigger writes. A crash can lose a snapshot still waiting to commit; committed rows survive reopening.

Database location:

```text
~/Library/Application Support/WalkingPad/statistics.sqlite
```

Settings use the application's macOS defaults domain. There is no telemetry upload, cloud sync, or account. CSV exports contain UTC timestamps, meters, walking seconds, optional observed steps, and a `time_estimated` column. Database or export errors remain visible. Quit drains pending writes and offers an explicit quit-without-saving option if storage fails.

## Development checks

```sh
swift test
swift build -c release
bash scripts/build-app.sh
codesign --verify --strict build/WalkingPad.app
```

The tests cover service/profile selection, FTMS field alignment and truncation, the optional step suffix, exact legacy command bytes, checksums and split/coalesced notifications, commands and speed bounds, Stop priority, counter baselines and resets, missing-clock estimates, midnight rollover, SQLite reopen/concurrent revisions, and CSV output. `WALKINGPAD_SNAPSHOTS=1 swift test --filter ControlPanelRender` briefly shows the belt controls in an on-screen window and saves light and dark captures to `.build/design-checks`. A native AppKit render check verifies the four-row metric layout in light and dark appearances. It does not replace interactive Settings testing.

With a pad awake nearby, `WALKINGPAD_HARDWARE=KS-BDC2 swift test --filter Hardware` runs the app's Bluetooth controller against the real pad. It checks discovery, connection, and polled telemetry. It never calls Start, Stop, or speed. Without that variable, the test is skipped.

## Hardware verification still required

The app has not been validated against a physical C2. Before relying on it:

1. Confirm discovery, permission prompts, popup layout, and Settings opening without any main window.
2. Compare speed, distance, time, and opt-in steps with the pad's display. Confirm the reported speed range and optional field layout on your firmware.
3. Test control acquisition, Start, a low preset, and Stop with the belt clear and the physical remote ready.
4. Check physical-remote takeover, stale telemetry, pad sleep, Bluetooth off/on, and reconnection. Never test transport failures by relying on this app as the only way to stop the belt.
5. Reopen the app after a walk and compare history/CSV with the observed deltas, including a session crossing midnight.

No idle CPU, memory, or hardware latency claims have been measured yet. FTMS is notification-driven. Legacy connections poll every second, only while connected; disconnected discovery is bounded to twelve seconds. There is no per-sample history table.

Licensed under the [MIT License](LICENSE). See [protocol attribution and licensing notes](THIRD_PARTY_NOTICES.md).
