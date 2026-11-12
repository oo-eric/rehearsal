import Foundation

/// Builds the app's pieces and plugs them together. Platform shells (iOS/, macOS/) own
/// one of these and add the window, hardware keys, and screen-wake handling.
///
///   MIDIInput (CoreMIDI) --bytes--> Rehearsal.midi --> Action
///   PeerLink (Multipeer) <--JSON--> Sync <--snapshots--> Rehearsal
///   Rehearsal --beats--> Synth (AVAudioEngine)
///   Rehearsal --@Published--> StageView (SwiftUI)
final class AppCore {
    let model: Rehearsal
    private let midi = MIDIInput()

    init() {
        model = Rehearsal(synth: Synth(), sync: Sync(link: PeerLink()))
        midi.onMessage = { [weak model] bytes, from in model?.midi(bytes, from: from) }
        model.onMidiStatus = { [weak self] in
            self?.midi.connectAll()
            return self?.midi.sourceNames ?? []
        }
        midi.start()
        model.synth?.start()      // warm: silence until the first beat, but no first-click dropout
        model.boot()
    }
}
