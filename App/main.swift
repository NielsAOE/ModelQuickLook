import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let label = NSTextField(wrappingLabelWithString: """
        FBX Quick Look is installed.

        Select an .fbx file in Finder and press Space.
        If nothing appears, enable the extension in System Settings → Login Items & Extensions → Quick Look.
        """)
        label.frame = NSRect(x: 20, y: 20, width: 440, height: 100)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 140),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ModelQuickLook"
        window.contentView?.addSubview(label)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
