import AppKit
import ShanshuoCore

// Entry point. `--transcribe` runs the developer CLI; otherwise start the menu-bar app (no Dock icon).
let arguments = CommandLine.arguments
if arguments.count > 1, arguments[1] == "--transcribe" {
    exit(CLI.transcribe(Array(arguments.dropFirst(2))))
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let modelItem = NSMenuItem(title: "语音模型：加载中…", action: nil, keyEquivalent: "")
    private let asrQueue = DispatchQueue(label: "com.arnow117.shanshuo.asr", qos: .userInitiated)
    private(set) var recognizer: Qwen3Recognizer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: ShanshuoInfo.displayName)
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "\(ShanshuoInfo.displayName) \(Paths.version)（\(Paths.buildID)）", action: nil, keyEquivalent: ""))
        menu.addItem(modelItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出\(ShanshuoInfo.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        loadModel()
    }

    /// ED-002: load once in the background after launch and keep it resident.
    private func loadModel() {
        let dir = Paths.modelDir
        asrQueue.async {
            let t0 = Date()
            let result = Result { try Qwen3Recognizer(files: Qwen3ModelFiles(dir: dir)) }
            let dt = Date().timeIntervalSince(t0)
            DispatchQueue.main.async {
                switch result {
                case .success(let r):
                    self.recognizer = r
                    self.modelItem.title = String(format: "语音模型：就绪（加载 %.1f 秒）", dt)
                case .failure(let e):
                    self.modelItem.title = "语音模型：\(e)"
                }
            }
        }
    }
}
