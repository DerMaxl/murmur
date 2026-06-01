import AppKit

/// A small floating panel shown while recording or dictating: animated level bars
/// (so you can see the mic is picking you up) and an elapsed-time readout.
///
/// It is a non-activating panel positioned at the bottom-center of the screen, so
/// it never steals keyboard focus from the app you're dictating into.
///
/// Drawing is driven by a timer that forces a synchronous redraw. Murmur is a
/// background (menu-bar) app, and background apps don't reliably repaint on
/// `needsDisplay`, so we push frames ourselves while visible.
@MainActor
final class RecordingHUD {
    private let panel: NSPanel
    private let meter = LevelMeterView()
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private var startDate: Date?
    private var lastShownSecond = -1
    private var latestLevel: CGFloat = 0
    private var timer: Timer?
    private var activity: NSObjectProtocol?

    init() {
        let size = NSSize(width: 168, height: 44)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timeLabel.textColor = .white
        timeLabel.alignment = .right
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        meter.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(meter)
        background.addSubview(timeLabel)
        NSLayoutConstraint.activate([
            meter.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            meter.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            meter.heightAnchor.constraint(equalToConstant: 24),
            meter.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -10),
            timeLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            timeLabel.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            timeLabel.widthAnchor.constraint(equalToConstant: 40),
        ])
        panel.contentView = background
    }

    func show() {
        meter.reset()
        latestLevel = 0
        timeLabel.stringValue = "0:00"
        lastShownSecond = 0
        startDate = Date()
        positionBottomCenter()
        panel.orderFrontRegardless()   // show without taking focus

        // Keep the app lively so the meter keeps animating in the background.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Recording meter")

        timer?.invalidate()
        // ~15 fps: the bars scroll gently rather than racing across.
        let t = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)   // fire during menu tracking too
        timer = t
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        startDate = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        panel.orderOut(nil)
    }

    /// Store the newest loudness; the timer turns it into animation frames.
    func push(level: Float) {
        latestLevel = CGFloat(max(0, min(1, level)))
    }

    private func tick() {
        meter.advance(latestLevel)
        meter.display()   // force a synchronous redraw (background app)

        guard let startDate else { return }
        let elapsed = Int(Date().timeIntervalSince(startDate))
        if elapsed != lastShownSecond {
            lastShownSecond = elapsed
            timeLabel.stringValue = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        }
    }

    private func positionBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                     y: visible.minY + 90))
    }
}

/// Draws a rolling history of recent loudness values as rounded vertical bars that
/// bounce with your voice.
@MainActor
private final class LevelMeterView: NSView {
    private var levels = [CGFloat](repeating: 0, count: 26)

    func reset() {
        levels = [CGFloat](repeating: 0, count: levels.count)
    }

    /// Shift in one new frame (called ~15x/sec by the HUD timer).
    func advance(_ level: CGFloat) {
        levels.removeFirst()
        levels.append(max(0, min(1, level)))
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = CGFloat(levels.count)
        let slot = bounds.width / count
        let barWidth = max(1.5, slot - 3)

        // Build all bars into one path, then fill with a single horizontal gradient so
        // the meter shares the app icon's teal→indigo wave.
        let bars = NSBezierPath()
        for (i, level) in levels.enumerated() {
            // Square-root curve so quiet speech is still visibly tall.
            let height = max(3, sqrt(level) * bounds.height)
            let x = CGFloat(i) * slot + (slot - barWidth) / 2
            let y = (bounds.height - height) / 2
            bars.append(NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: height),
                                     xRadius: barWidth / 2, yRadius: barWidth / 2))
        }
        NSGraphicsContext.current?.saveGraphicsState()
        bars.addClip()
        // Brand teal → indigo, painted left-to-right across the meter (matches the icon).
        NSGradient(colors: [Brand.tealNS, Brand.indigoNS])?.draw(in: bounds, angle: 0)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
