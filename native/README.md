# native/: Mac + iPad app

A native shell around the rehearsal display in `../app/`. The display itself is the
same HTML/JS (one codebase, so a fix lands everywhere). The native part adds the things
a browser can't do:

| | Web (`app/index.html` in Safari) | This app |
|---|---|---|
| MIDI foot pedals | Chrome only | **Built in** (CoreMIDI: USB, Bluetooth MIDI, network) |
| Screen stays on | `caffeinate` / System Settings | **Automatic** (Mac and iPad) |
| Click track with the iPad silent switch on | muted | **Plays** |
| Tap the screen to turn pages | yes | yes |
| Update songs without rebuilding | swap `songs.js` | drop `songs.js` in the app's songs folder |
| Icon in the Dock / home screen | no | yes |

## Which devices

Set by what current Xcode (27) can still target:

- **Mac: macOS 12 Monterey or newer**, Intel or Apple silicon (universal binary).
  Monterey runs on Intel Macs from about 2015 on: MacBook Pro / Air early 2015+,
  iMac late 2015+, Mac mini late 2014+, Mac Pro late 2013+.
- **iPad: iPadOS 15 or newer**: iPad Air 2+, iPad mini 4+, iPad 5th gen+, any iPad Pro.
  iPhone works too.

Older than that needs an older Xcode, or just use the web version in Safari.
**Tested** on macOS 27 (Apple silicon) and the iOS 27 iPad simulator only. Not yet run on
real old hardware, so the first band-computer launch is the real test.

## Build

```bash
python3 ../build.py     # songs.js from the charts (gets bundled into the app)
./build.sh              # Mac app -> ../dist/OO-Rehearsal-mac.zip
./build.sh ios          # iPad compile check
```

Needs Xcode and `xcodegen` (`brew install xcodegen`). `project.yml` is the source;
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
says which one loaded.

## Touch (iPad with no keyboard)

Tap the right ⅔ of the screen for next, left ⅓ for back. Tap the **song title** for the
song list, the **PAGE-TURN / TEMPO** label to start/stop tempo mode, outside a panel to
close it.

## How it fits together

- `Shared/Stage.swift`: the WKWebView, the JS bridge (`webkit.messageHandlers.rehearsal`)
- `Shared/MIDIInput.swift`: CoreMIDI in. Raw messages go to JS `Input.fromNative()`,
  so the `midi` rules in `app/config.js` decide what a pedal does, same as Chrome.
- `Shared/WebRoot.swift`: copies `app/` to Caches and swaps in a user `songs.js`
- `iOS/AppDelegate.swift`: full screen, idle timer off, audio session `.playback`
- `macOS/AppDelegate.swift`: window, menus, display-sleep assertion

Gotcha: `xcodebuild` with no `-destination` builds **only this Mac's architecture**
even with `ARCHS = arm64 x86_64`. `build.sh` passes `generic/platform=macOS` and
fails if the Intel slice is missing. Don't "simplify" that away.
