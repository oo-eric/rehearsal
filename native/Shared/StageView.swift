import SwiftUI

/// The whole screen: header, song map, the current section's rows, what's next, and the
/// overlays (count-in, toast, tempo panel, song list, pedal setup).
struct StageView: View {
    @ObservedObject var model: Rehearsal

    var body: some View {
        GeometryReader { geo in
            let m = Metrics(w: geo.size.width, h: geo.size.height)
            ZStack {
                if let song = model.song {
                    VStack(spacing: 0) {
                        HeaderView(model: model, song: song, m: m)
                        // Everything below the header is the page-turn zone: tap the
                        // left third for back, the rest for next.
                        VStack(spacing: 0) {
                            MapView(model: model, song: song, m: m)
                            SectionView(model: model, song: song, m: m)
                            NextView(model: model, song: song, m: m)
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                            model.pointer(x: Double(v.location.x / max(1, m.w)))
                        })
                    }
                } else {
                    NoSongsView(source: model.songsSource, m: m)
                }

                if let n = model.countIn {
                    ZStack {
                        Color(hex: 0x0b0c0e, alpha: 0.72)
                        Text("\(n)").font(Theme.cond(m.vh(40), .heavy)).foregroundColor(Theme.accent)
                    }
                    .allowsHitTesting(false)
                }

                if model.tempoOpen, let song = model.song {
                    Overlay(m: m, close: { model.toggleTempoPanel() }) { TempoPanel(model: model, song: song, m: m) }
                }
                if model.pickerOpen {
                    Overlay(m: m, close: { model.closePicker() }) { PickerPanel(model: model, m: m) }
                }
                if model.learnOpen {
                    Overlay(m: m, close: { model.toggleLearn() }) { LearnPanel(model: model, m: m) }
                }

                if let t = model.toast {
                    VStack {
                        Text(t)
                            .font(Theme.sans(m.vh(3.4), .bold))
                            .foregroundColor(Theme.hotInk)
                            .padding(.vertical, m.vh(1.2)).padding(.horizontal, m.vw(2.4))
                            .background(RoundedRectangle(cornerRadius: m.vh(1)).fill(Theme.hot))
                            .padding(.top, m.vh(14))
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Theme.bg.ignoresSafeArea())
        .foregroundColor(Theme.ink)
    }
}

// MARK: - header

struct HeaderView: View {
    @ObservedObject var model: Rehearsal
    let song: Song
    let m: Metrics

    private var meta: String {
        let bpm = model.nowBpm, pct = Int((Double(bpm) / Double(song.bpm) * 100).rounded())
        return [song.key, "\(bpm) bpm" + (bpm != song.bpm ? " (\(pct)%)" : "")].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var mode: String {
        let chordsLabel = [model.chords ? (SynthCore.patchNames[model.patch] ?? model.patch).lowercased() : nil,
                           model.bass ? "bass" : nil].compactMap { $0 }.joined(separator: " + ")
        let sound = [model.click ? "click" : nil, chordsLabel.isEmpty ? nil : chordsLabel]
            .compactMap { $0 }.joined(separator: " + ")
        var s = model.page ? "Page · " + (sound.isEmpty ? "silent" : sound) + (model.pedalTempo ? " · pedal tempo" : "")
            : model.tempo ? "Tempo · " + (sound.isEmpty ? "silent" : sound)
            : "Page-turn" + (chordsLabel.isEmpty ? "" : " · " + chordsLabel)
        if let L = model.loop {
            s += " · loop " + L.label + (model.tempo && model.pass > 0 ? " ×\(model.pass + 1)" : "")
        }
        return s.uppercased()
    }

    var body: some View {
        let size = m.vh(2.4)
        HStack(alignment: .center, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: m.vw(1.2)) {
                Text(song.title.uppercased()).font(Theme.sans(size, .bold)).tracking(size * 0.04).lineLimit(1)
                Text(meta).font(Theme.sans(size)).foregroundColor(Theme.dim).lineLimit(1)
                    .onTapGesture { model.fire(.tempo) }
            }
            .onTapGesture { model.fire(.songs) }
            Spacer(minLength: m.vw(2))
            HStack(alignment: .center, spacing: m.vw(1.2)) {
                if model.sync != nil { linkLabel(size).onTapGesture { model.fire(.link) } }
                Text(mode)
                    .font(Theme.sans(size * 0.85, model.tempo ? .bold : .regular))
                    .tracking(size * 0.85 * 0.08)
                    .foregroundColor(model.loop != nil ? Theme.hot : model.tempo ? Theme.accent : Theme.dim)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if model.tempo {
                    HStack(spacing: m.vh(0.6)) {
                        ForEach(0..<4, id: \.self) { i in
                            Circle()
                                .fill(i == model.beat ? (i == 0 ? Theme.accent : Theme.hot) : Theme.faint)
                                .frame(width: m.vh(1.6), height: m.vh(1.6))
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.fire(.play) }
        }
        .padding(.top, m.vh(1.2)).padding(.bottom, m.vh(0.6)).padding(.horizontal, m.vw(2))
        .contentShape(Rectangle())
        .onTapGesture { model.fire(.songs) }
    }

    private func linkLabel(_ size: CGFloat) -> some View {
        let peers = model.peerNames.count
        let text = !model.linkEnabled ? "Unlinked" : peers > 0 ? "Linked · \(peers + 1)" : "Solo"
        let font = Theme.sans(size * 0.75)
        return (peers > 0 && model.linkEnabled ? Text("●  ").foregroundColor(Theme.linkOn) : Text(""))
            .font(font) +
            Text(text.uppercased())
            .font(font)
            .tracking(size * 0.75 * 0.08)
            .strikethrough(!model.linkEnabled)
            .foregroundColor(peers > 0 && model.linkEnabled ? Theme.dim : Theme.faint)
    }
}

// MARK: - song map

struct MapView: View {
    @ObservedObject var model: Rehearsal
    let song: Song
    let m: Metrics

    var body: some View {
        let cur = song.rows[model.row].sec
        HStack(spacing: m.vw(0.4)) {
            ForEach(Array(song.sections.enumerated()), id: \.offset) { i, sec in
                Text(sec.name)
                    .font(Theme.sans(m.vh(1.6)))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(i < cur ? Theme.faint : i == cur ? Theme.ink : Theme.dim)
                    .padding(.vertical, m.vh(0.5)).padding(.horizontal, m.vw(0.4))
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: m.vh(0.5)).fill(i == cur ? Theme.line : Theme.panel))
                    .overlay(alignment: .bottom) {
                        if i == cur { Rectangle().fill(Theme.accent).frame(height: m.vh(0.4)) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: m.vh(0.5)))
            }
        }
        .padding(.top, m.vh(0.4)).padding(.bottom, m.vh(1)).padding(.horizontal, m.vw(2))
    }
}

// MARK: - the section on stage

struct SectionView: View {
    @ObservedObject var model: Rehearsal
    let song: Song
    let m: Metrics

    var body: some View {
        // In page mode the beat must not drag the page along, so the window comes from
        // the page anchor; everywhere else it follows the current row.
        let cur = song.rows[model.anchorRow]
        let sec = song.sections[cur.sec]
        let b = model.pageBounds(sec, cur.inSec)
        let firstFlat = song.firstRowOfSection[cur.sec]
        let more = sec.rows.count - b.start - b.shown
        let range = sec.from.map { "bars \($0)–\(sec.to ?? $0)" }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: m.vw(1.5)) {
                Text(sec.name.uppercased())
                    .font(Theme.cond(m.vh(7), .heavy)).tracking(m.vh(7) * 0.02)
                    .foregroundColor(Theme.accent).lineLimit(1).minimumScaleFactor(0.5)
                Text(([range].compactMap { $0 } + sec.notes).filter { !$0.isEmpty }.joined(separator: "  ·  "))
                    .font(Theme.sans(m.vh(2.2))).foregroundColor(Theme.dim).lineLimit(1)
            }
            .padding(.bottom, m.vh(0.8))

            GeometryReader { g in
                let avail = g.size.height
                let rowh = max(1, min((avail - (more > 0 ? 28 : 0)) / CGFloat(max(b.shown, 1)), avail / 2.6))
                VStack(spacing: 0) {
                    ForEach(0..<b.shown, id: \.self) { wi in
                        let flat = firstFlat + b.start + wi
                        RowView(model: model, song: song, flat: flat, row: sec.rows[b.start + wi],
                                rowh: rowh, first: wi == 0, m: m)
                    }
                    if more > 0 {
                        Text("▼ \(more) more row\(more > 1 ? "s" : "") in \(sec.name)")
                            .font(Theme.sans(m.vh(2))).foregroundColor(Theme.dim)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.top, m.vh(0.3))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, m.vw(2))
        .frame(maxHeight: .infinity)
    }
}

struct RowView: View {
    @ObservedObject var model: Rehearsal
    let song: Song
    let flat: Int
    let row: ChartRow
    let rowh: CGFloat
    let first: Bool
    let m: Metrics

    var body: some View {
        let isCurrent = flat == model.row
        let fr = song.rows[flat]
        let cols = max(4, row.bars.count)
        let ring = m.vh(0.35)
        VStack(spacing: 0) {
            HStack(spacing: m.vw(0.5)) {
                ForEach(0..<cols, id: \.self) { bi in
                    if bi < row.bars.count {
                        BarView(model: model, song: song, barIndex: fr.firstBar + bi, isCurrentRow: isCurrent,
                                rowh: rowh, m: m)
                    } else {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(height: rowh * 0.5)
            .overlay(
                Group {
                    if isCurrent && !model.tempo {
                        RoundedRectangle(cornerRadius: m.vh(0.8)).stroke(Theme.hot, lineWidth: ring).padding(-ring / 2)
                    }
                }
            )
            LyricsView(row: row, current: isCurrent, rowh: rowh, m: m)
        }
        .padding(.vertical, m.vh(0.4))
        .frame(height: rowh)
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .opacity(flat < model.row ? 0.28 : flat == model.row ? 1 : 0.62)
        .animation(.linear(duration: 0.12), value: model.row)
    }
}

struct BarView: View {
    @ObservedObject var model: Rehearsal
    let song: Song
    let barIndex: Int
    let isCurrentRow: Bool
    let rowh: CGFloat
    let m: Metrics

    var body: some View {
        let bar = song.bars[barIndex]
        let now = isCurrentRow && model.tempo && model.bar == barIndex
        // which chord of a split bar is sounding
        var which = 0
        if now {
            var acc = 0.0
            for (k, c) in bar.chords.enumerated() {
                if Double(model.beat) >= acc { which = k }
                acc += c.b
            }
        }
        let total = max(bar.chords.reduce(0) { $0 + $1.b }, 1)
        return GeometryReader { g in
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(Array(bar.chords.enumerated()), id: \.offset) { ci, c in
                        chord(c, split: bar.chords.count > 1, on: now && bar.chords.count > 1 && ci == which)
                            .frame(width: g.size.width * CGFloat(c.b / total))
                            .overlay(alignment: .leading) {
                                if ci > 0 { DashedLine().stroke(Theme.faint, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(width: 1) }
                            }
                    }
                }
                Text("\(bar.num)")
                    .font(Theme.sans(rowh * 0.09))
                    .foregroundColor(now ? Theme.hotInk : Theme.dim)
                    .padding(.top, m.vh(0.3)).padding(.leading, m.vw(0.5))
            }
        }
        .frame(maxWidth: .infinity)
        .background(now ? Theme.hot : isCurrentRow ? Theme.barCurrent : Theme.panel)
        .foregroundColor(now ? Theme.hotInk : Theme.ink)
        .clipShape(RoundedRectangle(cornerRadius: m.vh(0.6)))
    }

    private func chord(_ c: ChordCell, split: Bool, on: Bool) -> some View {
        let nc = c.c.isEmpty
        let scale: CGFloat = split ? 0.29 : c.c.count > 6 ? 0.27 : 0.36
        return Text(nc ? "N.C." : c.c)
            .font(Theme.cond(rowh * scale, nc ? .regular : .bold))
            .foregroundColor(nc ? Theme.faint : nil)
            .lineLimit(1)
            .minimumScaleFactor(0.3)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(on ? Color.black.opacity(0.12) : Color.clear)
    }
}

struct DashedLine: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        return p
    }
}

struct LyricsView: View {
    let row: ChartRow
    let current: Bool
    let rowh: CGFloat
    let m: Metrics

    var body: some View {
        let empty = row.lyrics.isEmpty
        let long = row.lyrics.joined(separator: " ").count > 72 || row.lyrics.count > 1
        let size = rowh * (long ? 0.18 : 0.23)
        var text = empty
            ? Text("(instrumental)").font(Theme.sans(size, .italic)).foregroundColor(Theme.faint)
            : Text(row.lyrics.joined(separator: "\n")).font(Theme.sans(size)).foregroundColor(current ? Theme.ink : Theme.lyric)
        if !row.note.isEmpty {
            text = text + Text("\n" + row.note).font(Theme.sans(size * 0.8, .italic)).foregroundColor(Theme.accent)
        }
        // Shrinks to fit: long verses and stacked lines get smaller, never cut off.
        return text
            .lineSpacing(size * 0.12)
            .minimumScaleFactor(0.25)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: rowh * 0.46)
            .padding(.horizontal, m.vw(0.4))
    }
}

// MARK: - footer

struct NextView: View {
    @ObservedObject var model: Rehearsal
    let song: Song
    let m: Metrics

    var body: some View {
        let size = m.vh(2.6)
        let cur = song.rows[model.row].sec
        let nxt = cur + 1 < song.sections.count ? song.sections[cur + 1] : nil
        HStack(alignment: .firstTextBaseline, spacing: m.vw(1.2)) {
            Text("NEXT").font(Theme.sans(size * 0.75)).tracking(size * 0.075).foregroundColor(Theme.dim)
            Text((nxt?.name ?? "End").uppercased()).font(Theme.sans(size, .bold)).foregroundColor(Theme.accent).lineLimit(1)
            if let n = nxt, let first = n.rows.first {
                Text(Self.chordsText(first)).font(Theme.cond(size, .regular)).lineLimit(1).truncationMode(.tail)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 0)
            Text("→ next · ← back · ] [ section · P tempo · G page mode · B speed & loop · S songs · K pedal setup")
                .font(Theme.sans(size * 0.7)).foregroundColor(Theme.faint).lineLimit(1)
                .opacity(model.idle ? 0 : 1)
                .layoutPriority(-2)
        }
        .padding(.top, m.vh(1)).padding(.bottom, m.vh(1.4)).padding(.horizontal, m.vw(2))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    static func chordsText(_ row: ChartRow) -> String {
        row.bars.map { $0.map { $0.c.isEmpty ? "N.C." : $0.c }.joined(separator: " ") }.joined(separator: "  ·  ")
    }
}

struct NoSongsView: View {
    let source: String
    let m: Metrics
    var body: some View {
        VStack(alignment: .leading, spacing: m.vh(2)) {
            Text("NO SONGS").font(Theme.cond(m.vh(7), .heavy)).foregroundColor(Theme.accent)
            Text("songs.js is missing or empty. Run rehearsal/build.py, or drop songs.js into the app's songs folder.")
                .font(Theme.sans(m.vh(2.4))).foregroundColor(Theme.dim)
            Text(source).font(Theme.sans(m.vh(1.8))).foregroundColor(Theme.faint)
        }
        .padding(m.vw(4))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
