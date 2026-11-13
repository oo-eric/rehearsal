# native/: the Mac + iPad + iPhone app

The rehearsal display, in Swift: SwiftUI for the screen, AVAudioEngine for the click,
chords and bass, CoreMIDI for pedals, MultipeerConnectivity for linked screens. One
codebase (`Shared/`) builds for macOS 12+ and iOS 15+. It used to wrap the web version
(`../app/`) in a WKWebView; it doesn't anymore. The web version still runs in a browser.

|                                                            | Web (`app/index.html` in a browser) | This app                                              |
| ---------------------------------------------------------- | ----------------------------------- | ----------------------------------------------------- |
| MIDI foot pedals                                           | Chrome only                         | **Built in** (CoreMIDI: USB, Bluetooth MIDI, network) |
| Screen stays on                                            | `caffeinate` / System Settings      | **Automatic** (Mac and iPad)                          |
| Click track with the iPad silent switch on                 | muted                               | **Plays**                                             |
| Bluetooth page-turner pedals on iPhone/iPad                | only with keyboard focus            | **Always** (caught app-wide)                          |
| Tap for the next line, swipe for the next page             | tap only                            | **Both**                                              |
| Update songs without rebuilding                            | swap `songs.js`                     | drop `songs.js` in the app's songs folder             |
| Icon in the Dock / home screen                             | no                                  | yes                                                   |
| Linked screens (all devices follow the same song and beat) | no                                  | **Yes** (see `../README.md`)                          |

## Which devices

Set by what current Xcode (27) can still target:

- **Mac: macOS 12 Monterey or newer**, Intel or Apple silicon (universal binary).
  Monterey runs on Intel Macs from about 2015 on: MacBook Pro / Air early 2015+,
  iMac late 2015+, Mac mini late 2014+, Mac Pro late 2013+.
- **iPad: iPadOS 15 or newer**: iPad Air 2+, iPad mini 4+, iPad 5th gen+, any iPad Pro.
  iPhone works too.

Older than that needs an older Xcode, or just use the web version in Safari.
**Tested** (Swift build) on macOS 27 (Apple silicon) and the iOS 27 iPhone and iPad
simulators. Not yet run on a real device or old hardware, so the first band-computer
launch is the real test.

## Build

```bash
python3 ../build.py     # songs.js from the charts (gets bundled into the app)
./build.sh              # Mac app -> ../dist/OO-Rehearsal-mac.zip
./build.sh ios          # iPad compile check
./build-cli.sh          # Mac app with Command Line Tools only (no Xcode)
./Tests/run.sh          # command-line tests: chords, synth, timeline, linked screens
```

Needs Xcode and `xcodegen` (`brew install xcodegen`), except `build-cli.sh` and the
tests, which need only Command Line Tools. `project.yml` is the source;
the `.xcodeproj` is generated and gitignored. To work in Xcode: `xcodegen`, then
open `OORehearsal.xcodeproj`.

## Install

**Mac (band computer):** copy `OO-Rehearsal-mac.zip` over, unzip, drag
**OO Rehearsal** to Applications. It's ad-hoc signed, not notarized, so the first launch
is right-click > **Open** > Open. (On newer macOS: try to open it once, then System
Settings > Privacy & Security > **Open Anyway**.) After that it opens normally.

**iPad:** plug it into the Mac, open the project in Xcode, choose the
`OORehearsal-iOS` scheme and the iPad, press Run. With the paid developer team in
`project.yml` the install lasts a year. For bandmates' iPads, TestFlight is the
no-cable route (needs an App Store Connect app record first).

## Updating songs without rebuilding

- **Mac:** View > **Show Songs Folder**, drop in a new `songs.js`, then View > Reload Songs (⌘R).
- **iPad:** Files app > On My iPad > **OO Rehearsal**, drop in `songs.js`, relaunch the app.

A `songs.js` there wins over the one built into the app. The pedal-setup panel (K)
says which one loaded. The app reads the JSON inside `songs.js` directly
(`Song.swift`), so it's the same file the web version and `build.py` use.

## Played parts (MIDI)

Drop a bass part at `rehearsal/midi/<song slug>-bass.mid` (e.g. `digital-love-glitch-bass.mid`)
and rebuild: with Bass on (`N`), that song plays the part instead of the generated root
notes. Everything else stays as it was: Chords still plays its patch on top, and the click is unchanged.

- Any DAW export works: one track or many, any channel. Notes sound an octave below how they are written, as Logic's bass instruments play them (`MidiPart.transpose`).
- It follows the beat, not the clock: practice tempos, loops and the speed trainer all
  carry the part with them.
- The file can start with a lead-in (a DAW's bar 1 before the chart begins). The app
  finds it by trying whole-bar shifts until the bass notes land on the chart's chord
  roots. Press `K` to see what it found ("1-bar lead-in skipped, 111/111 chord changes on
  the root"). A low score means the part and the chart disagree, which usually means the chart is wrong.
- `midi/` is gitignored like `songs.js`: unreleased parts stay off GitHub. To update a
  device without rebuilding, put the file in a `midi` folder inside its songs folder.

## Touch (iPad with no keyboard)

Tap the right ⅔ of the screen for the next line, left ⅓ for the previous one (one line
at a time, in page mode too). Swipe left for the next screenful, right to go back a
screenful: in page mode that's a page turn, and it measures tempo like the pedal does.
Tap the **song title** for the
song list, the **PAGE-TURN / TEMPO** label to start/stop tempo mode, outside a panel to
close it.

## How it fits together

```text
MIDIInput (CoreMIDI) --bytes-------> Rehearsal.midi  \
iOS KeyInput / Mac key monitor ----> Rehearsal.key    > Action -> Rehearsal.fire
taps on the page area -------------> Rehearsal.pointer/
PeerLink (Multipeer) <--JSON--> Sync <--snapshots--> Rehearsal
Rehearsal --beats, ~150 ms ahead--> Synth (AVAudioEngine)
Rehearsal --@Published--> StageView / Panels (SwiftUI)
```

- `Shared/Rehearsal.swift`: the model. Navigation, page mode, the beat timeline (a run
  = fromBar + t0 + bpm + count-in + loop; every beat follows from it), tempo/loop/speed
  trainer, sounds, the song picker and setup panel state, linked-screen snapshots.
- `Shared/StageView.swift`, `Shared/Panels.swift`, `Shared/Theme.swift`: the screen.
  Sizes are fractions of the screen (vh/vw, like the CSS was), so one layout reads on a
  TV, an iPad and a phone.
- `Shared/Synth.swift`: `SynthCore` renders the click, the four chord patches and the
  bass from a fixed pool of voices, sample by sample; `Synth` puts it on AVAudioEngine.
  Each buffer records when it will be heard (host time + output latency), and beats
  are scheduled in `HostClock` ms, so a beat lands on its sample.
- `Shared/ChordTheory.swift`: chord symbol -> notes. `Tests/chords-ref.json` pins it to
  the old JS parser's answers for every chord in the charts.
- `Shared/Sync.swift`: clock offsets (NTP-style pings) and message plumbing.
  `Shared/PeerLink.swift`: MultipeerConnectivity session that carries the JSON. Needs
  `NSLocalNetworkUsageDescription` + `NSBonjourServices` (`_oo-rehearsal._tcp/_udp`) in
  `project.yml`, or discovery silently finds nobody.
- `Shared/Config.swift`: key, pedal and MIDI bindings; count-in, chord volume.
- `Shared/Song.swift`: reads `songs.js`, flattens sections -> rows -> bars.
- `Shared/AppCore.swift`: builds the pieces and wires them together.
- `iOS/AppDelegate.swift`: scene lifecycle, full screen, idle timer off, audio session
  `.playback` (so the silent switch doesn't mute the click).
- `iOS/KeyInput.swift` + `iOS/main.swift`: a `UIApplication` subclass that catches every
  hardware key (Bluetooth page-turner pedals, keyboards) app-wide.
- `macOS/AppDelegate.swift`: window, menus, key monitor, display-sleep assertion.
- Debug builds only: the Mac app takes test commands over a distributed notification
  (`oo.rehearsal.test`: `key:`, `tap:`, `snap:<png>`, `size:`, `audio:`), and the iOS
  app takes `-ooKeys "Enter,],p"` at launch, so a script can drive it and screenshot it.

Gotcha: on the 27 SDKs SwiftUI's `@State` is a macro whose compiler plugin ships only
with full Xcode, so `build-cli.sh` (Command Line Tools) can't compile it. Use
`@StateObject` / `@ObservedObject` instead.

Gotcha: `xcodebuild` with no `-destination` builds **only this Mac's architecture**
even with `ARCHS = arm64 x86_64`. `build.sh` passes `generic/platform=macOS` and
fails if the Intel slice is missing. Don't "simplify" that away.

Note: MultipeerConnectivity is marked deprecated in the macOS/iOS 27 SDKs ("use Network
framework"). It still builds and runs, and it's the only option that works the same back
to Monterey / iPadOS 15. If it ever stops working, rewrite `PeerLink.swift` on
`NWListener` + `NWBrowser` (Bonjour, `includePeerToPeer`) behind the same
`PeerTransport` protocol. `Sync` won't change.

Gotcha: iOS 27 kills apps at launch that haven't adopted the UIScene lifecycle
(`UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption` in the crash log).
iOS 26 doesn't, so an iPad on 26 can look fine while every iPhone on 27 crashes. The
window lives in `SceneDelegate`; keep `UIApplicationSceneManifest` in `project.yml`.
