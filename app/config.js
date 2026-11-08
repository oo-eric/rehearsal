// Rehearsal display: input bindings.
// Every input (keyboard, mouse, foot pedal, MIDI) is translated into one of these ACTIONS:
//   next, prev               one row (phrase) forward / back
//   nextSection, prevSection jump a whole section
//   restart                  back to bar 1
//   play                     start/stop tempo mode (auto-advance at the song's bpm)
//   click                    metronome click on/off (tempo mode)
//   faster, slower           tempo +/- 1 bpm (remembered per song)
//   songs                    open the song list
//   fullscreen               toggle fullscreen
//   learn                    show the input-learn panel (see what a pedal/clicker sends)
//
// FOOT PEDALS: most Bluetooth/USB page-turner pedals (AirTurn, PageFlip, iRig BlueTurn,
// generic "Bluetooth page turner" pedals) pretend to be a keyboard and send arrow keys,
// PageUp/PageDown, or Space/Enter. Those already work below, with no setup.
// If yours sends something else: press K in the app, step on the pedal, read the key it
// reports, and add that name to the right list here.
window.REHEARSAL_CONFIG = {
  keys: {
    next:        ["ArrowRight", "ArrowDown", "PageDown", " ", "Enter"],
    prev:        ["ArrowLeft", "ArrowUp", "PageUp", "Backspace"],
    nextSection: ["]", "Shift+ArrowRight", "Shift+ArrowDown", "Shift+PageDown"],
    prevSection: ["[", "Shift+ArrowLeft", "Shift+ArrowUp", "Shift+PageUp"],
    restart:     ["Home", "r"],
    play:        ["p"],
    click:       ["c"],
    faster:      ["=", "+"],
    slower:      ["-", "_"],
    songs:       ["Escape", "s"],
    fullscreen:  ["f"],
    learn:       ["k"]
  },

  // Mouse / trackpad / touch: tap the right two-thirds of the screen = next,
  // left third = prev. A wireless mouse works as a hand-held "pedal" today.
  pointer: true,

  // MIDI pedals and footswitches (Chrome only; Safari has no Web MIDI).
  // Off until enabled from the learn panel (press K, then M), because Chrome asks
  // for permission. Each rule matches a MIDI message; value >= 64 counts as "pressed".
  //   { type: "cc",   number: 64 }   control change #64 (sustain-pedal style footswitch)
  //   { type: "note", number: 60 }   note-on middle C
  //   { type: "pc",   number: 1 }    program change 1
  midi: {
    next:        [{ type: "cc", number: 64 }, { type: "cc", number: 80 }],
    prev:        [{ type: "cc", number: 65 }, { type: "cc", number: 81 }],
    nextSection: [{ type: "cc", number: 66 }],
    prevSection: [{ type: "cc", number: 67 }],
    play:        [{ type: "cc", number: 82 }]
  },

  // Tempo mode
  countInBars: 1,     // bars of count-in clicks before auto-advance starts
  clickOnStart: true  // metronome click on by default in tempo mode
};
