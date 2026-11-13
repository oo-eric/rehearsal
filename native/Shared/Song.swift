import Foundation

// MARK: - Chart data (the shape build.py writes)

/// One chord cell: `c` is the symbol ("" = N.C.), `b` how many beats it lasts.
struct ChordCell: Decodable, Hashable {
    let c: String
    let b: Double
}

struct ChartRow: Decodable {
    let bars: [[ChordCell]]      // each bar = one or more chord cells
    let lyrics: [String]
    let note: String

    enum CodingKeys: String, CodingKey { case bars, lyrics, note }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        bars = try c.decode([[ChordCell]].self, forKey: .bars)
        lyrics = try c.decodeIfPresent([String].self, forKey: .lyrics) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

struct ChartSection: Decodable {
    let name: String
    let from: Int?
    let to: Int?
    let rows: [ChartRow]
    let notes: [String]

    enum CodingKeys: String, CodingKey { case name, from, to, rows, notes }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        from = try c.decodeIfPresent(Int.self, forKey: .from)
        to = try c.decodeIfPresent(Int.self, forKey: .to)
        rows = try c.decode([ChartRow].self, forKey: .rows)
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
    }
}

// MARK: - Song, flattened for navigation

/// A row of the chart with where it sits: section, index in the section, its bars.
struct FlatRow {
    let sec: Int
    let inSec: Int
    let firstBar: Int
    let lastBar: Int
}

struct FlatBar {
    let row: Int                 // flat row index
    let chords: [ChordCell]
    let beats: Double
    let num: Int                 // bar number as printed on the chart
}

/// A song plus its flattened rows and bars (sections -> rows -> bars), which is what
/// navigation and the beat timeline walk.
final class Song: Decodable {
    let slug: String
    let title: String
    let bpm: Int
    let key: String
    let sections: [ChartSection]

    private(set) var rows: [FlatRow] = []
    private(set) var bars: [FlatBar] = []
    private(set) var firstRowOfSection: [Int] = []
    private(set) var barStart: [Double] = []     // chart beat each bar starts on
    var bassPart: MidiPart?                       // midi/<slug>-bass.mid, if there is one

    enum CodingKeys: String, CodingKey { case slug, title, bpm, key, sections }
    required init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        title = try c.decode(String.self, forKey: .title)
        bpm = Int((try? c.decode(Double.self, forKey: .bpm)) ?? 120)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        sections = try c.decode([ChartSection].self, forKey: .sections)
        flatten()
    }

    private func flatten() {
        var running = 1
        for (si, sec) in sections.enumerated() {
            var barNum = sec.from ?? running
            firstRowOfSection.append(rows.count)
            for (ri, row) in sec.rows.enumerated() {
                let first = bars.count
                for chords in row.bars {
                    let sum = chords.reduce(0) { $0 + $1.b }
                    barStart.append((barStart.last ?? 0) + (bars.last?.beats ?? 0))
                    bars.append(FlatBar(row: rows.count, chords: chords, beats: sum > 0 ? sum : 4, num: barNum))
                    barNum += 1
                }
                rows.append(FlatRow(sec: si, inSec: ri, firstBar: first, lastBar: bars.count - 1))
            }
            running = barNum
        }
    }
}

// MARK: - Loading songs.js

/// Where the charts come from. `songs.js` (written by build.py, gitignored because the
/// lyrics are private) is still the file the band passes around, so the app reads it
/// directly: everything between the first `[` and the matching end is plain JSON.
///
/// Order: a `songs.js` dropped into the user songs folder, then the one built into the
/// app, then the bundled demo (`songs.example.js`).
///
/// - iPad / iPhone: Files app > On My iPad > OO Rehearsal > songs.js
/// - Mac: View > Show Songs Folder (~/Library/Application Support/OO Rehearsal/)
enum SongLibrary {
    static func load() -> (songs: [Song], source: String) {
        let lib = loadCharts()
        attachParts(lib.songs)
        return lib
    }

    /// MIDI parts: `midi/<slug>-bass.mid` in the user songs folder first, then the ones
    /// built into the app (the repo's midi/ folder).
    static func attachParts(_ songs: [Song], dirs: [URL]? = nil) {
        let search = dirs ?? [userSongsFolder().appendingPathComponent("midi", isDirectory: true),
                              Bundle.main.resourceURL?.appendingPathComponent("midi", isDirectory: true)].compactMap { $0 }
        for song in songs {
            song.bassPart = nil
            for dir in search {
                let url = dir.appendingPathComponent("\(song.slug)-bass.mid")
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                if let part = try? MidiPart.load(url, for: song), !part.notes.isEmpty { song.bassPart = part; break }
            }
        }
    }

    private static func loadCharts() -> (songs: [Song], source: String) {
        let user = userSongsFolder().appendingPathComponent("songs.js")
        var problems: [String] = []
        if FileManager.default.fileExists(atPath: user.path) {
            switch parse(contentsOf: user) {
            case .success(let s) where !s.isEmpty: return (s, "songs folder (\(user.path))")
            case .success: problems.append("songs folder file has no songs")
            case .failure(let e): problems.append("songs folder file unreadable: \(e.localizedDescription)")
            }
        }
        let note = problems.isEmpty ? "" : " (\(problems.joined(separator: "; ")))"
        if let url = Bundle.main.url(forResource: "songs", withExtension: "js"),
           case .success(let s) = parse(contentsOf: url), !s.isEmpty {
            return (s, "built into the app" + note)
        }
        if let url = Bundle.main.url(forResource: "songs.example", withExtension: "js"),
           case .success(let s) = parse(contentsOf: url) {
            return (s, "demo song only (no songs.js was bundled)" + note)
        }
        return ([], "no songs found" + note)
    }

    static func parse(contentsOf url: URL) -> Result<[Song], Error> {
        do {
            return .success(try parse(try Data(contentsOf: url)))
        } catch {
            return .failure(error)
        }
    }

    /// `window.SONGS = [ ... ];` -> [Song]. Also accepts a bare JSON array (songs.json).
    static func parse(_ data: Data) throws -> [Song] {
        guard let open = data.firstIndex(of: UInt8(ascii: "[")),
              let close = data.lastIndex(of: UInt8(ascii: "]")), close > open else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try JSONDecoder().decode([Song].self, from: data[open...close])
    }

    static func userSongsFolder() -> URL {
        let fm = FileManager.default
        #if os(iOS)
        // Exposed in the Files app via UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace.
        return fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #else
        // Application Support, not ~/Documents: no privacy prompt on newer macOS.
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OO Rehearsal", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
        #endif
    }
}
