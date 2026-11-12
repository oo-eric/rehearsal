# rehearsal/: rehearsal display (chords + sections + lyrics on a screen)

A native Mac / iPad / iPhone app for the band computer (an **Intel Mac**) and everyone's
tablets. It shows the current section, a row of bars with chords, and the lyric line,
sized to read from across the room on a TV or monitor, so nobody has to squint at
paper charts. Nearby copies link up and stay on the same song and beat.

```text
rehearsal/
  build.py          lead.md -> app/songs.js (and --zip -> dist/OO-Rehearsal.zip)
  native/           THE APP: SwiftUI, one codebase for Mac + iPad + iPhone. See native/README.md
    Shared/
      Rehearsal.swift   navigation, page mode, tempo timeline, practice tools, sync state
      StageView.swift   the screen (header, song map, rows, next); Panels.swift: overlays
      Synth.swift       click + chord patches + bass, rendered on AVAudioEngine
      ChordTheory.swift chord symbol -> notes
      Sync.swift        linked screens: clock offsets + messages; PeerLink.swift: the wire
      Config.swift      key/pedal/MIDI bindings (the file a bandmate might edit)
      Song.swift        reads songs.js; AppCore.swift wires it all together
    Tests/          command-line tests: chords, synth, timeline, sync (./Tests/run.sh)
  app/              the old web version (browser fallback) + where songs.js lives
    songs.js        GENERATED from the charts. Gitignored: the lyrics stay private.
    songs.example.js  demo song, so a fresh clone runs. songs.js overrides it.
    HOW TO USE.txt  the card for whoever is at the band computer
  dist/             build output (gitignored)
```

The app used to be a web page in a WKWebView. It is now native Swift end to end
(SwiftUI views, AVAudioEngine synth, CoreMIDI, MultipeerConnectivity), on macOS 12+ and
iOS 15+. `app/` still runs in a browser as a fallback, but new features land in Swift
first; see [The web version](#the-web-version).

## Where the songs come from

This repo is public; the charts are not. It lives inside the band repo as a git
submodule at `rehearsal/`, and `build.py` reads `../songs/<slug>/lead.md` (or
`--songs DIR`). A fresh clone with no charts shows the demo song. The band computer
gets real songs through the zip, never through GitHub.


`songs/<slug>/lead.md`. `build.py` parses every song that has one: `## Section — bars A-B`
headings, `| Chord //// |` rows (split bars like `| A // E // |` keep their beats),
lyric lines under each row, `(note)` cells as cues. Tempo comes from lead.md's
`NNN bpm` line, falling back to meta.md. **Never edit `songs.js`. Fix lead.md and
rebuild.**

```bash
python3 rehearsal/build.py          # rebuild songs.js (prints chart warnings)
python3 rehearsal/build.py --check  # warnings only
python3 rehearsal/build.py --zip    # + dist/OO-Rehearsal.zip for the band computer
python3 build.py --songs ~/charts   # charts somewhere other than ../songs
```

`build.py` prints chart warnings (bar counts that don't match the section heading,
gaps between sections). The current list lives in the band repo's `songs/README.md`.

The app reads `songs.js` as is (the JSON inside it), so the file the band passes around
didn't change. To update charts without rebuilding the app, drop a new `songs.js` into
the app's songs folder (Mac: View > Show Songs Folder, then ⌘R; iPad/iPhone: Files app >
On My iPad > OO Rehearsal, then relaunch). A rebuilt app bundles whatever is in
`app/songs.js`.

## Modes

- **Page-turn** (default): one row (phrase) per press. Follows the band.
- **Tempo** (`P`): 1-bar count-in, then auto-advances bar by bar at the song's bpm,
  with an optional click placed on an exact audio sample (not a timer), so it stays
  steady.
- **Tempo & practice** (`B`, or tap the bpm in the header): ±1/±5 bpm, 50–100% of the
  chart tempo, tap tempo (`T`), reset (`0`), loop this section (`O`) or this line, and a
  speed trainer that adds 1/2/5 bpm each loop pass up to the chart tempo. Changes made
  while playing land on the next downbeat, so the groove doesn't stumble. The set tempo
  is remembered per song on each device; the header shows it as a % of the chart.
  Moving outside a loop turns it off.
- **Chord playback** (`H`, or Sound > Chords in the panel): in tempo mode, plays each
  chart chord, on the same
  timeline as the click, so it follows loops, ramps, jumps, and linked screens. It's
  per device and remembered. `ChordTheory.swift` reads every spelling in the charts (`F#m7(9,11)`,
  `A7(b9)/Eb`, `Gno3(6)`...); N.C. and `(rest)` are silent. Level: `chordVolume` in
  `Config.swift`. **Bass** (`N`, or Sound > Bass) is its own toggle: a round sine on the
  root (or slash note), with a little 2nd/3rd harmonic so it reads on iPad and phone
  speakers. Play it alone with the click, or under the chords. Four patches (`J` cycles, or Chord sound in the panel; remembered per
  device): **Pad** (soft saws, sustained), **Keys** (FM electric piano, decays),
  **Organ** (drawbars + tremolo), **Pluck** (strums every beat, down/up: the only one
  with rhythm). A guide to play over, not a backing track. New patch = a voice builder in
  `SynthCore` (`Synth.swift`), a case in `play(chord:)`, and its name in
  `patches`/`patchNames` (the panel and `J` pick it up from there).

## Linked screens

Every copy of the native app nearby (Mac, iPad, iPhone) links up automatically and follows
whoever touched a control last: song, row, play/stop, jumps, and tempo nudges. The click
on/off stays per device. The header shows **Linked · N**. Press `L` (or tap the badge)
to take one screen solo, then again to rejoin, which also makes that screen the leader.

- **Transport:** MultipeerConnectivity (`native/Shared/PeerLink.swift`). Works over Wi-Fi,
  peer-to-peer Wi-Fi, or Bluetooth, with no router or internet. First launch asks for
  Local Network permission; say yes.
- **Timing:** `Sync.swift` pings each peer every second and keeps the clock offset from
  the fastest round trip. A play/jump goes out as "bar X starts at T on my clock", and
  each device converts T to its own clock and re-anchors as clocks drift. Each audio
  buffer knows when it will be heard (host time + output latency), so speaker latency
  differences cancel. In the simulated test (`native/Tests`, 4 ms + jitter each way,
  10% of pings lost) starts land within ±3 ms. Not yet measured on real devices.
- **Mixed builds:** the messages are byte-for-byte the web-view build's, so a device
  still on the old build links with the Swift one.
- A device joining mid-song picks up the running song on the next beat.
- Charts must match: a device that lacks the song, or has a different bar count, says
  so in the pedal-setup panel (K).
- Plain browsers have no transport, so the web version stays solo.

## Page mode

`G`. One pedal press turns a whole screenful instead of one line, and the lines
light themselves in between. The tempo comes from the gap between presses: a page is
many bars of music, so dividing that interval by the beats on the page is a far steadier
reading than tapping a beat, and it tracks what the band is actually playing rather than
what the chart says. It drives the click and chord playback too.

Back is two-stage, the same shape as `prevSection`: the first press returns to the top
of the page you are on, and only a second press leaves for the page before. A fumbled
page costs one press instead of your place.

The page never turns on its own. If the measured tempo runs past the end of the page the
highlight parks on the last line and waits -- a page turned early loses everyone's place,
which is worse than a highlight that sits still. Intervals that imply under 40 or over
260 bpm (a pause between songs, a stumble, a false step) are discarded rather than
yanking the tempo, and the last three readings are averaged.

## Input: built for a foot pedal we don't own yet

Every input becomes a named **action** (`next`, `prev`, `nextSection`, `play`...).
Bindings live in `native/Shared/Config.swift` (key names are the web's `KeyboardEvent.key`
names, so old `config.js` lists carry over). A new input device = something that calls
`Rehearsal.fire(action)` (or `key(...)` / `midi(...)` to show up in the setup panel).

- **Today:** keyboard, a wireless mouse (right ⅔ of the screen = next, left ⅓ = back), or
  any wireless presentation clicker (they send PageUp/PageDown, already bound).
- **Bluetooth/USB page-turner pedals** (AirTurn, PageFlip, iRig BlueTurn, generic
  "page turner pedal"): they act as keyboards and send arrows or PageUp/PageDown.
  **Already bound, no code needed.** Prefer a 2-button model (next + back). A
  3–4-button one can map the extras to `nextSection` / `play`.
- **Pedal setup panel** (`K`): shows every key/click/MIDI message and the action it
  maps to. That's how to find what an unknown pedal sends, then add it to `Config.swift`.
- **MIDI footswitches**: always on (CoreMIDI: USB, Bluetooth MIDI, network). `cc` /
  `note` / `pc` rules in `Config.swift`. **Untested without hardware.** `M` in the
  setup panel lists connected MIDI devices.

## Roadmap / not built yet

- **Sync to the recording** (play the track, chart follows it). The bar grid fits
  Echoes through Chorus 2, but from the Bridge on the vocals land 2–4 s earlier than
  lead.md's bar numbers predict. Either the recorded bridge is shorter than 24 bars or
  something shifts. Needs a per-section anchor map (bar → seconds) before it's
  trustworthy. The karaoke `.ass` files + beat tracking (librosa) are the raw material.
- **Setlists**: an ordered list of songs, where "next" at the end of a song moves to the next song.
- **Per-instrument views**: bass.md / drums.md exist for some songs. A `V` toggle
  could swap the chord grid for bass notes or drum cues.
- **Retire the web version** once the Swift app has a rehearsal or two behind it.

## The web version

`app/` is the original browser app (classic scripts, runs from `file://`, Chrome or
Safari). It still works and still reads the same `songs.js`, but it is frozen at the
feature set of the Swift port (tempo, practice, page mode, chords + bass, solo only:
no linked screens in a browser). Open `app/index.html`, or `build.py --zip` for a
folder to copy to any Mac. Its own key bindings are in `app/config.js`.
