import SwiftUI

/// Dimmed backdrop + panel. Tapping outside the panel closes it.
struct Overlay<Content: View>: View {
    let m: Metrics
    let close: () -> Void
    @ViewBuilder let content: () -> Content
    // @StateObject, not @State: on the 27 SDKs @State is a macro whose plugin ships only
    // with full Xcode, and build-cli.sh builds with Command Line Tools alone.
    @StateObject private var size = Measured()

    var body: some View {
        ZStack {
            Color(hex: 0x050608, alpha: 0.88)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
            // Sized to its content up to 88% of the screen, then it scrolls (phones).
            ScrollView(.vertical, showsIndicators: false) {
                content()
                    .font(Theme.sans(m.vh(2.4)))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, m.vh(3)).padding(.horizontal, m.vw(3))
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ContentHeight.self, value: g.size.height)
                    })
            }
            .onPreferenceChange(ContentHeight.self) { size.height = $0 }
            .frame(width: min(m.vw(92), 1100), height: min(max(size.height, 1), m.vh(88)))
            .background(RoundedRectangle(cornerRadius: m.vh(1.2)).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: m.vh(1.2)).stroke(Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture {}                       // taps inside the panel don't close it
        }
    }
}

final class Measured: ObservableObject { @Published var height: CGFloat = 0 }

private struct ContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PanelTitle: View {
    let text: String
    let m: Metrics
    var body: some View {
        Text(text.uppercased()).font(Theme.sans(m.vh(4), .bold)).foregroundColor(Theme.accent)
            .padding(.bottom, m.vh(2))
    }
}

/// A line of keyboard shortcuts under a panel (Mac only, see Theme.keyHints).
struct Tip: View {
    let text: String
    let m: Metrics
    var body: some View {
        if Theme.keyHints {
            Text(text).font(Theme.sans(m.vh(2.4) * 0.85)).foregroundColor(Theme.dim).padding(.top, m.vh(1.5))
        }
    }
}

// MARK: - tempo & practice (B, or tap the bpm)

struct TempoPanel: View {
    @ObservedObject var model: Rehearsal
    let song: Song
    let m: Metrics

    var body: some View {
        let set = model.bpmOf(song), bpm = model.nowBpm
        let narrow = m.w < 700
        VStack(alignment: .leading, spacing: 0) {
            PanelTitle(text: "Tempo & practice", m: m)
            HStack(spacing: m.vw(0.6)) {
                Spacer(minLength: 0)
                btn("−5") { model.nudgeTempo(-5) }
                btn("−1") { model.nudgeTempo(-1) }
                VStack(spacing: m.vh(0.6)) {
                    Text("\(bpm)").font(Theme.sans(m.vh(8), .bold)).foregroundColor(Theme.ink)
                    Text("bpm").font(Theme.sans(m.vh(2.4))).foregroundColor(Theme.dim)
                    Text("\(Int((Double(bpm) / Double(song.bpm) * 100).rounded()))% of \(song.bpm) (chart)" +
                         (bpm != set ? " · set \(set)" : ""))
                        .font(Theme.sans(m.vh(2))).foregroundColor(Theme.dim).lineLimit(1).minimumScaleFactor(0.6)
                }
                .frame(minWidth: narrow ? m.vw(30) : m.vw(26))
                btn("+1") { model.nudgeTempo(1) }
                btn("+5") { model.nudgeTempo(5) }
                Spacer(minLength: 0)
            }
            .padding(.top, m.vh(1.5)).padding(.bottom, m.vh(2.5))

            row("Speed", narrow) {
                ForEach([50, 60, 75, 90, 100], id: \.self) { p in
                    btn("\(p)%", on: set == Int((Double(song.bpm) * Double(p) / 100).rounded())) {
                        model.setBpm(Double(song.bpm) * Double(p) / 100)
                    }
                }
                btn("Tap") { model.tap() }.padding(.leading, m.vw(0.8))
            }
            row("Loop", narrow) {
                btn("This section", on: model.loop?.kind == "section") { model.toggleLoop("section") }
                btn("This line", on: model.loop?.kind == "line") { model.toggleLoop("line") }
                note(model.loop.map { "Looping " + $0.label } ?? "Not looping")
            }
            row("Speed up", narrow) {
                ForEach([0, 1, 2, 5], id: \.self) { n in
                    btn(n == 0 ? "Off" : "+\(n)", on: model.ramp == n) { model.setRamp(n) }
                }
                note("bpm each loop, up to the chart tempo")
            }
            row("Sound", narrow) {
                btn("Click", on: model.click) { model.fire(.click) }
                btn("Chords", on: model.chords) { model.fire(.chords) }
                btn("Bass", on: model.bass) { model.fire(.bass) }
            }
            row("Chord sound", narrow) {
                ForEach(SynthCore.patches, id: \.self) { p in
                    btn(SynthCore.patchNames[p] ?? p, on: model.chords && model.patch == p) { model.setPatch(p) }
                }
                note("plays along in tempo mode · pluck strums every beat")
            }
            Button(action: { model.fire(.play) }) {
                Text("Start / stop").font(Theme.sans(m.vh(2.2), .bold)).foregroundColor(Theme.hotInk)
                    .padding(.vertical, m.vh(1)).padding(.horizontal, m.vw(1.4))
                    .background(RoundedRectangle(cornerRadius: m.vh(0.6)).fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .padding(.vertical, m.vh(1.6))
            Tip(text: "+ − 1 bpm · . , 5 bpm · 0 chart tempo · T tap · O loop section · C click · H chords · J chord sound · N bass · B or Esc to close", m: m)
        }
    }

    @ViewBuilder
    private func row<C: View>(_ label: String, _ narrow: Bool, @ViewBuilder _ content: () -> C) -> some View {
        let lbl = Text(label.uppercased()).font(Theme.sans(m.vh(1.8))).tracking(m.vh(1.8) * 0.08).foregroundColor(Theme.dim)
        if narrow {
            VStack(alignment: .leading, spacing: m.vh(0.8)) {
                lbl
                HStack(spacing: m.vw(0.8)) { content() }
            }
            .padding(.vertical, m.vh(1.2))
        } else {
            HStack(spacing: m.vw(0.8)) {
                lbl.frame(width: max(80, m.vw(9)), alignment: .leading)
                content()
            }
            .padding(.vertical, m.vh(1.2))
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(Theme.sans(m.vh(1.8))).foregroundColor(Theme.dim).lineLimit(2).minimumScaleFactor(0.7)
            .padding(.leading, m.vw(0.6))
    }

    private func btn(_ title: String, on: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.sans(m.vh(2.2)))
                .lineLimit(1).minimumScaleFactor(0.5)
                .foregroundColor(on ? Theme.hotInk : Theme.ink)
                .padding(.vertical, m.vh(1)).padding(.horizontal, m.vw(1.4))
                .frame(minWidth: m.vw(4.5))
                .background(RoundedRectangle(cornerRadius: m.vh(0.6)).fill(on ? Theme.hot : Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: m.vh(0.6)).stroke(on ? Theme.hot : Theme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - song list (S)

struct PickerPanel: View {
    @ObservedObject var model: Rehearsal
    let m: Metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelTitle(text: "Songs", m: m)
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ForEach(Array(model.songs.enumerated()), id: \.offset) { i, s in
                        let sel = i == model.pickSel
                        HStack(alignment: .firstTextBaseline) {
                            Text(s.title).font(Theme.sans(m.vh(3.2)))
                            Spacer()
                            Text([s.key, "\(s.bpm) bpm"].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(Theme.sans(m.vh(3.2) * 0.7))
                                .foregroundColor(sel ? Theme.hotInk : Theme.dim)
                        }
                        .foregroundColor(sel ? Theme.hotInk : Theme.ink)
                        .padding(.vertical, m.vh(1.2)).padding(.horizontal, m.vw(1.2))
                        .background(RoundedRectangle(cornerRadius: m.vh(0.8)).fill(sel ? Theme.hot : Color.clear))
                        .contentShape(Rectangle())
                        .onTapGesture { model.pick(i) }
                        .id(i)
                    }
                }
                .onAppear { proxy.scrollTo(model.pickSel) }
                .onChange(of: model.pickSel) { proxy.scrollTo($0) }
            }
            Tip(text: "↑ ↓ to choose · Enter to open · F fullscreen", m: m)
        }
    }
}

// MARK: - pedal / clicker setup (K)

struct LearnPanel: View {
    @ObservedObject var model: Rehearsal
    let m: Metrics

    var body: some View {
        VStack(alignment: .leading, spacing: m.vh(1.5)) {
            PanelTitle(text: "Pedal / clicker setup", m: m)
            Text("Press, click, or step on anything. Each input shows up below with the action it triggers. If a pedal shows ")
                + Text("no action").bold()
                + Text(", add its key name to ")
                + Text("native/Shared/Config.swift").foregroundColor(Theme.hot)
                + Text(" and rebuild.")
            Text("MIDI pedals: always on in this app. Plug one in (USB or Bluetooth MIDI) and step on it. M lists connected devices.")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.learnLog) { e in
                    (Text(e.kind + "  ").bold().foregroundColor(Theme.hot)
                     + Text(e.detail)
                     + (e.info ? Text("") : Text("  →  ") + Text(e.action ?? "no action").foregroundColor(Theme.accent)))
                        .font(Theme.mono(m.vh(2)))
                        .padding(.vertical, m.vh(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
                }
            }
            Tip(text: "K to close · M to list MIDI devices", m: m)
        }
    }
}
