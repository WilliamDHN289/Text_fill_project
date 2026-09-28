import AppKit

@MainActor
final class DownloadProgressWindowController: NSObject, NSWindowDelegate {
    private let modelManager: ModelManager
    private let onCancel: () -> Void

    private var window: NSWindow?
    private var progressBar: NSProgressIndicator!
    private var percentLabel: NSTextField!
    private var bytesLabel: NSTextField!
    private var pollTimer: Timer?

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .file
        return f
    }()

    init(modelManager: ModelManager, onCancel: @escaping () -> Void) {
        self.modelManager = modelManager
        self.onCancel = onCancel
        super.init()
    }

    func show() {
        let width: CGFloat = 360
        let height: CGFloat = 150

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Downloading"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let title = NSTextField(labelWithString: "Downloading Local AI Model…")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(title)

        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)
        self.progressBar = bar

        let percent = NSTextField(labelWithString: "0%")
        percent.font = .systemFont(ofSize: 11)
        percent.textColor = .secondaryLabelColor
        percent.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(percent)
        self.percentLabel = percent

        let bytes = NSTextField(labelWithString: "")
        bytes.font = .systemFont(ofSize: 11)
        bytes.textColor = .secondaryLabelColor
        bytes.alignment = .right
        bytes.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bytes)
        self.bytesLabel = bytes

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(cancel)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),

            bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            percent.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
            percent.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),

            bytes.centerYAnchor.constraint(equalTo: percent.centerYAnchor),
            bytes.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])

        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func close() {
        pollTimer?.invalidate()
        pollTimer = nil
        window?.close()
        window = nil
    }

    private func tick() {
        progressBar.doubleValue = modelManager.downloadProgress
        percentLabel.stringValue = "\(Int(modelManager.downloadProgress * 100))%"

        if modelManager.totalBytes > 0 {
            let done = byteFormatter.string(fromByteCount: modelManager.downloadedBytes)
            let total = byteFormatter.string(fromByteCount: modelManager.totalBytes)
            bytesLabel.stringValue = "\(done) / \(total)"
        }

        if !modelManager.isDownloading && modelManager.downloadProgress >= 1.0 {
            close()
        }
    }

    @objc private func cancelTapped() {
        onCancel()
        close()
    }

    // Prevent user from closing via the title bar (no close button shown, but defensive)
    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool { false }
}
