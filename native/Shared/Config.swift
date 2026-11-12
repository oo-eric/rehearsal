import Foundation

/// Every input (keyboard, foot pedal, clicker, MIDI, touch) becomes one of these.
enum Action: String, CaseIterable {
    case next, prev                 // one row (phrase) forward / back
    case nextSection, prevSection   // jump a whole section
    case restart                    // back to bar 1
    case play                       // start/stop tempo mode (auto-advance at the song's bpm)
    case click                      // metronome click on/off
    case chords                     // play the chart's chords in tempo mode, on/off
    case bass                       // bass note on each chord's root (or slash note), on/off
    case patch                      // next chord sound: pad, keys, organ, pluck
    case faster, slower             // tempo +/- 1 bpm (remembered per song)
    case faster5, slower5           // tempo +/- 5 bpm
    case tempoReset                 // back to the chart's tempo
    case tap                        // tap tempo (3+ taps)
    case loop                       // loop the current section in tempo mode (on/off)
    case tempo                      // tempo & practice panel
    case songs                      // song list
    case fullscreen                 // toggle full screen (Mac)
    case learn                      // input-learn panel (see what a pedal/clicker sends)
    case link                       // link/unlink with other OO Rehearsal apps nearby
    case page                       // page mode: the pedal turns a screenful, tempo from the gap
}

/// What used to be app/config.js.
///
/// FOOT PEDALS: most Bluetooth/USB page-turner pedals (AirTurn, PageFlip, iRig BlueTurn,
/// generic "Bluetooth page turner" pedals) pretend to be a keyboard and send arrow keys,
/// PageUp/PageDown, or Space/Enter. Those already work, with no setup. If yours sends
/// something else: press K in the app, step on the pedal, read the key name it reports,
/// and add it to the right list here.
///
/// Key names are the web's `KeyboardEvent.key` names ("ArrowRight", "PageDown", " ",
/// "Enter", single lowercase letters), so the old config.js lists carry over as-is.
enum Config {
    static let keys: [Action: [String]] = [
        .next:        ["ArrowRight", "ArrowDown", "PageDown", " ", "Enter"],
        .prev:        ["ArrowLeft", "ArrowUp", "PageUp", "Backspace"],
        .nextSection: ["]", "Shift+ArrowRight", "Shift+ArrowDown", "Shift+PageDown"],
        .prevSection: ["[", "Shift+ArrowLeft", "Shift+ArrowUp", "Shift+PageUp"],
        .restart:     ["Home", "r"],
        .play:        ["p"],
        .click:       ["c"],
        .chords:      ["h"],
        .patch:       ["j"],
        .bass:        ["n"],
        .faster:      ["=", "+"],
        .slower:      ["-", "_"],
        .faster5:     ["."],
        .slower5:     [","],
        .tempoReset:  ["0"],
        .tap:         ["t"],
        .loop:        ["o"],
        .tempo:       ["b"],
        .songs:       ["Escape", "s"],
        .fullscreen:  ["f"],
        .learn:       ["k"],
        .link:        ["l"],
        .page:        ["g"],
    ]

    /// Tap the right two-thirds of the screen = next, the left third = back.
    static let pointer = true

    /// MIDI pedals and footswitches. Each rule matches a message; value >= 64 counts as
    /// "pressed". type: "cc" (control change), "note" (note on), "pc" (program change).
    static let midi: [Action: [(type: String, number: Int)]] = [
        .next:        [("cc", 64), ("cc", 80)],
        .prev:        [("cc", 65), ("cc", 81)],
        .nextSection: [("cc", 66)],
        .prevSection: [("cc", 67)],
        .play:        [("cc", 82)],
    ]

    // Tempo mode
    static let countInBars = 1        // bars of count-in clicks before auto-advance starts
    static let clickOnStart = true    // metronome click on by default in tempo mode
    static let chordVolume = 0.8      // chord + bass level (0-1); the click is always on top
    static let chordPatch = "pad"     // starting chord sound until someone picks one

    /// Key name -> action. Shift+X with no Shift binding falls back to plain X.
    static func action(forKey name: String) -> Action? {
        let plain = name.hasPrefix("Shift+") ? String(name.dropFirst(6)) : name
        for (a, list) in keys where list.contains(name) { return a }
        if plain != name { for (a, list) in keys where list.contains(plain) { return a } }
        return nil
    }

    static func action(midiType type: String, number: Int) -> Action? {
        for (a, rules) in midi where rules.contains(where: { $0.type == type && $0.number == number }) { return a }
        return nil
    }
}
