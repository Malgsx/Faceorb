import AppKit
import Combine
import FaceOrbCore
import SwiftUI

/// Owns the single AppModel and Updater, the review window and the status item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let updater = Updater()
    let windows: AppWindows
    private var statusBar: StatusBarController?

    override init() {
        windows = AppWindows(model: model, updater: updater)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController(model: model, updater: updater, windows: windows)
        model.resumePendingScan()
        // `faceorb` passes --show so a cold start opens the dropdown too. show() waits until the item is placed.
        if CommandLine.arguments.contains("--show") { statusBar?.show() }
    }

    /// Opening FaceOrb again (the `faceorb` command, Finder) shows the dropdown instead of nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusBar?.show()
        return false
    }
}

/// Shows the review window as a plain AppKit window, so it lives independently of the dropdown.
@MainActor
final class AppWindows: ObservableObject {
    @Published var dropdownPinned = false
    private let model: AppModel
    private let updater: Updater
    private var window: NSWindow?
    private var phoneWindow: NSWindow?

    init(model: AppModel, updater: Updater) {
        self.model = model
        self.updater = updater
    }

    func showReview(_ section: ReviewSection? = nil) {
        if let section { model.section = section }
        if window == nil {
            let controller = NSHostingController(rootView: ReviewWindow()
                .environmentObject(model)
                .environmentObject(updater)
                .environmentObject(self))
            // The window keeps the size the user gives it instead of following its content.
            controller.sizingOptions = []
            let w = NSWindow(contentViewController: controller)
            w.title = "FaceOrb"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 820, height: 560)
            w.setContentSize(NSSize(width: 1100, height: 720))
            w.center()
            w.setFrameAutosaveName("FaceOrbReview")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func showPhoneSetup() {
        if phoneWindow == nil {
            let controller = NSHostingController(rootView: PhoneAccessView().environmentObject(model))
            controller.sizingOptions = []
            let window = NSWindow(contentViewController: controller)
            window.title = "FaceOrb — Phone setup"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 600, height: 500)
            window.setContentSize(NSSize(width: 640, height: 740))
            window.center()
            phoneWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        phoneWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Borderless panel that can take keyboard focus and closes on Esc.
private final class DropdownPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
}

@MainActor
final class StatusBarController: NSObject {
    private let model: AppModel
    private let updater: Updater
    private let windows: AppWindows
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panel: DropdownPanel?
    private var hosting: NSHostingController<AnyView>?
    private var globalMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var sizeObservation: NSKeyValueObservation?
    /// Turns the orb's reflections while FaceOrb is working (one turn every 1.5 s).
    private var spinTimer: Timer?
    private var spin = 0.0

    init(model: AppModel, updater: Updater, windows: AppWindows) {
        self.model = model
        self.updater = updater
        self.windows = windows
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refreshIcon()
        Publishers.Merge(model.objectWillChange.map { _ in () }, updater.objectWillChange.map { _ in () })
            // Throttle, not debounce: progress publishes constantly during a scan, and the arc must keep moving.
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.refreshIcon() }
            .store(in: &cancellables)
    }

    deinit { MainActor.assumeIsolated { removeMonitor(); spinTimer?.invalidate() } }

    private func refreshIcon() {
        let activity = model.activity
        let count = model.count(.review)
        let update = updater.updateAvailable
        item.button?.image = OrbIcon.image(progress: activity.isBusy ? .some(activity.fraction) : nil,
                                           count: activity.isBusy ? 0 : count,
                                           update: update, spin: spin)
        let spinning = activity.isBusy && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if spinning, spinTimer == nil {
            spinTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.spin = (self.spin + 1.0 / 30).truncatingRemainder(dividingBy: 1)
                    self.refreshIcon()
                }
            }
        } else if !spinning, let timer = spinTimer {
            timer.invalidate()
            spinTimer = nil
        }
        item.button?.setAccessibilityLabel(activity.isBusy ? activity.label
            : "FaceOrb, \(count) photos to review\(update ? ", update available" : "")")
    }

    /// Waits (up to ~2 s) for the status item to be placed, so a show right after launch isn't positioned off screen.
    func show(attempts: Int = 20) {
        guard panel?.isVisible != true else { return }
        if let frame = item.button?.window?.frame, frame.minY > 0 || attempts == 0 { open(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated { self.show(attempts: attempts - 1) }
        }
    }

    @objc private func toggle() {
        if panel?.isVisible == true { close() } else { open() }
    }

    private func makePanel() -> DropdownPanel {
        let root = AnyView(OrbPopover()
            .environmentObject(model)
            .environmentObject(updater)
            .environmentObject(windows))
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = .preferredContentSize
        let size = controller.view.fittingSize

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        controller.view.frame = effect.bounds
        controller.view.autoresizingMask = [.width, .height]
        effect.addSubview(controller.view)

        let p = DropdownPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        p.contentView = effect
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        // Above normal windows, but below open panels and alerts (.modalPanel) so "Choose a folder…" isn't hidden.
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.onCancel = { [weak self] in self?.close() }
        hosting = controller
        sizeObservation = controller.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.resizePanel() }
        }
        return p
    }

    private func resizePanel() {
        guard let panel, let size = hosting?.preferredContentSize, size.width > 0, size.height > 0 else { return }
        var frame = panel.frame
        guard abs(frame.height - size.height) > 0.5 || abs(frame.width - size.width) > 0.5 else { return }
        frame.origin.y += frame.height - size.height  // keep the top edge fixed
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    private func position(_ panel: NSPanel) {
        guard let button = item.button, let bw = button.window else { return }
        let anchor = bw.frame
        let size = panel.frame.size
        let visible = (bw.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = anchor.minY - size.height - 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func open() {
        let p = panel ?? makePanel()
        panel = p
        resizePanel()
        position(p)
        updater.check()
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        item.button?.highlight(true)
        // Global monitors only see events delivered to other apps, so clicks in our own
        // review window, sheets, open panels and Settings never reach this. Title-bar drags
        // on our own windows can still arrive here (WindowServer handles part of the drag),
        // so the handler ignores any click that lands inside a visible FaceOrb window.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.windows.dropdownPinned else { return }
                let point = NSEvent.mouseLocation
                if NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(point) }) { return }
                self.close()
            }
        }
        // Command-Tab and Dock switches don't click anywhere, so close when FaceOrb stops being active.
        // Activation can flicker while windows are dragged or sheets/open panels appear, so re-check after a short delay.
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated {
                    guard let self, !self.windows.dropdownPinned, !NSApp.isActive else { return }
                    self.close()
                }
            }
        }
    }

    private func close() {
        removeMonitor()
        panel?.orderOut(nil)
        item.button?.highlight(false)
    }

    private func removeMonitor() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        resignObserver = nil
    }
}
