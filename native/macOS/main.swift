import AppKit

// Programmatic entry point: no storyboard or nib to keep in sync.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
