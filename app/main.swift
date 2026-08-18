// チャイム.app の起動処理。中身は Chime.swift。
import AppKit

// MARK: - 起動

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
