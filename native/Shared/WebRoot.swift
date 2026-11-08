import Foundation

/// Where the web display is loaded from.
///
/// The app bundles `app/` from this repo (index.html, app.js, songs.js...). On launch
/// it copies that folder to Caches and, if the band has dropped a newer `songs.js` into
/// the user songs folder, swaps it in. Charts can be updated without rebuilding the app:
///
/// - iPad: Files app > On My iPad > OO Rehearsal > songs.js
/// - Mac:  View > Show Songs Folder (~/Library/Application Support/OO Rehearsal/)
enum WebRoot {
    static func prepare() -> (root: URL, songsSource: String) {
        let fm = FileManager.default
        let bundled = Bundle.main.resourceURL!.appendingPathComponent("app", isDirectory: true)
        let cacheBase = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "rehearsal", isDirectory: true)
        let web = cacheBase.appendingPathComponent("web", isDirectory: true)
        do {
            try fm.createDirectory(at: cacheBase, withIntermediateDirectories: true)
            try? fm.removeItem(at: web)
            try fm.copyItem(at: bundled, to: web)
        } catch {
            return (bundled, "built into the app (cache copy failed: \(error.localizedDescription))")
        }
        let user = userSongsFolder().appendingPathComponent("songs.js")
        if fm.fileExists(atPath: user.path) {
            let dst = web.appendingPathComponent("songs.js")
            try? fm.removeItem(at: dst)
            if (try? fm.copyItem(at: user, to: dst)) != nil {
                return (web, "songs folder (\(user.path))")
            }
        }
        let builtIn = fm.fileExists(atPath: web.appendingPathComponent("songs.js").path)
        return (web, builtIn ? "built into the app" : "demo song only (no songs.js was bundled)")
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
