# rehearsal/: rehearsal display (chords + sections + lyrics on a screen)

An offline, no-install web app for the band computer (an **Intel Mac**). It shows the
current section, a row of bars with chords, and the lyric line, sized to read from
across the room on a TV or monitor, so nobody has to squint at paper charts.

```text
rehearsal/
  build.py          lead.md -> app/songs.js (and --zip -> dist/OO-Rehearsal.zip)
  app/              THE APP: copy this folder to any Mac, open index.html
    index.html
    app.js          navigation, rendering, tempo mode (audio-clock click)
    input.js        input adapters: keyboard, pointer, MIDI -> named actions
    sync.js         linked screens: clock offsets + messages between devices (native app only)
    config.js       key/pedal/MIDI bindings (the one file a bandmate might edit)
    style.css
    songs.js        GENERATED from the charts. Gitignored: the lyrics stay private.
    songs.example.js  demo song, so a fresh clone runs. songs.js overrides it.
    HOW TO USE.txt  the card for whoever is at the band computer
  native/           Mac + iPad app wrapping app/ (CoreMIDI pedals, screen-on). See native/README.md
  dist/             build output (gitignored)
```

Plain classic scripts, with no modules, framework, or build step for the app itself.
This is deliberate: it has to run from `file://` in whatever Safari the Intel Mac has.
Tested in Chrome and WebKit 18 (Safari's engine) at 1920×1080 and 1280×720.

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

To update the band computer after a chart change, replace `songs.js` in its
OO-Rehearsal folder, or replace the whole folder.

## Modes

- **Page-turn** (default): one row (phrase) per press. Follows the band.
- **Tempo** (`P`): 1-bar count-in, then auto-advances bar by bar at the song's bpm,
  with an optional Web Audio click scheduled on the audio clock (not timers), so it
  stays steady. `+`/`-` nudge tempo per song (saved in localStorage).

## Linked screens (native app)

Every copy of the native app nearby (Mac, iPad, iPhone) links up automatically and follows
whoever touched a control last: song, row, play/stop, jumps, and tempo nudges. The click
on/off stays per device. The header shows **Linked · N**. Press `L` (or tap the badge)
to take one screen solo, then again to rejoin, which also makes that screen the leader.

- **Transport:** MultipeerConnectivity (`native/Shared/PeerLink.swift`). Works over Wi-Fi,
  peer-to-peer Wi-Fi, or Bluetooth, with no router or internet. First launch asks for
  Local Network permission; say yes.
- **Timing:** `sync.js` pings each peer every second and keeps the clock offset from the
  fastest round trip. A play/jump goes out as "bar X starts at T on my clock", and each
  device converts T to its own clock and re-anchors as clocks drift. Clicks are placed
  with `AudioContext.getOutputTimestamp()`, so speaker latency differences cancel.
  In a simulated test (two WebKit pages, 4 ms + jitter each way) starts landed within
  ±5 ms of each other. Not yet measured on real devices on a real network.
- A device joining mid-song picks up the running song on the next beat.
- Charts must match: a device that lacks the song, or has a different bar count, says
  so in the pedal-setup panel (K).
- Plain browsers have no transport, so the web version stays solo.

## Input: built for a foot pedal we don't own yet

Every input becomes a named **action** (`next`, `prev`, `nextSection`, `play`...).
Bindings live in `app/config.js`; adding a new input device means adding an adapter in
`input.js` that calls `Input.fire(action)`.

- **Today:** keyboard, a wireless mouse (right ⅔ of the screen = next, left ⅓ = back), or
  any wireless presentation clicker (they send PageUp/PageDown, already bound).
- **Bluetooth/USB page-turner pedals** (AirTurn, PageFlip, iRig BlueTurn, generic
  "page turner pedal"): they act as keyboards and send arrows or PageUp/PageDown.
  **Already bound, no code needed.** Prefer a 2-button model (next + back). A
  3–4-button one can map the extras to `nextSection` / `play`.
- **Pedal setup panel** (`K`): shows every key/click/MIDI message and the action it
  maps to. That's how to find what an unknown pedal sends, then add it to `config.js`.
- **MIDI footswitches**: an adapter is written (`cc` / `note` / `pc` rules in
  `config.js`), but it's **untested without hardware** and **Chrome-only** (Safari has
  no Web MIDI). Enabled from the setup panel (`M`) because Chrome asks permission.
  If the band goes MIDI, run the app in Chrome on the band computer.

## Roadmap / not built yet

- **Sync to the recording** (play the track, chart follows it). The bar grid fits
  Echoes through Chorus 2, but from the Bridge on the vocals land 2–4 s earlier than
  lead.md's bar numbers predict. Either the recorded bridge is shorter than 24 bars or
  something shifts. Needs a per-section anchor map (bar → seconds) before it's
  trustworthy. The karaoke `.ass` files + beat tracking (librosa) are the raw material.
- **Setlists**: an ordered list of songs, where "next" at the end of a song moves to the next song.
- **Per-instrument views**: bass.md / drums.md exist for some songs. A `V` toggle
  could swap the chord grid for bass notes or drum cues.
- **Linked screens in plain browsers**: native apps link (above); two browser windows
  don't. Would need a tiny local server or BroadcastChannel (same browser only).
