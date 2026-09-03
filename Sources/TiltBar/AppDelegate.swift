import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let client: TiltClient
    private var timer: Timer?
    private var snapshot: Snapshot?
    private var lastError: String?
    private var menuIsOpen = false
    private var knownErrorNames: Set<String> = []
    private var notificationsReady = false
    private var recentlyTriggered: [String: Date] = [:]

    private let pollInterval: TimeInterval
    private var notifyOnErrors: Bool {
        get { UserDefaults.standard.object(forKey: "notifyOnErrors") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notifyOnErrors") }
    }

    // Tilt UI palette.
    private static let red = NSColor(srgbRed: 0.96, green: 0.38, blue: 0.30, alpha: 1)
    private static let yellow = NSColor(srgbRed: 1.00, green: 0.76, blue: 0.00, alpha: 1)
    private static let green = NSColor(srgbRed: 0.13, green: 0.73, blue: 0.19, alpha: 1)
    private static let gray = NSColor.secondaryLabelColor

    override init() {
        let env = ProcessInfo.processInfo.environment
        let port = Int(env["TILT_PORT"] ?? "") ?? 10350
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        client = TiltClient(webPort: port, configPath: env["TILT_CONFIG"] ?? "\(home)/.tilt-dev/config")
        pollInterval = Double(env["TILTBAR_POLL_SECONDS"] ?? "") ?? 2
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        renderTitle()
        setupNotifications()
        poll()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common) // keep polling while the menu is open
        timer = t
    }

    // MARK: polling

    private func poll() {
        client.fetchResources { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let snap):
                    self.lastError = nil
                    self.detectNewErrors(snap)
                    self.snapshot = snap
                case .failure(let err):
                    self.lastError = "\(err)"
                    self.snapshot = nil
                    self.knownErrorNames = []
                }
                self.renderTitle()
                if self.menuIsOpen { self.rebuildMenu() }
            }
        }
    }

    private func detectNewErrors(_ snap: Snapshot) {
        let current = Set(snap.errors.map { $0.name })
        let fresh = current.subtracting(knownErrorNames)
        if snapshot != nil, !fresh.isEmpty { notify(title: "Tilt: \(fresh.count) resource\(fresh.count == 1 ? "" : "s") failed", body: fresh.sorted().joined(separator: ", ")) }
        knownErrorNames = current
    }

    // MARK: status bar title

    private func renderTitle() {
        let title = NSMutableAttributedString()
        func seg(_ text: String, _ color: NSColor) {
            title.append(NSAttributedString(string: text, attributes: [.foregroundColor: color]))
        }
        guard let snap = snapshot else {
            seg("◦ tilt off", Self.gray)
            statusItem.button?.attributedTitle = title
            statusItem.button?.toolTip = lastError
            return
        }
        let e = snap.errors.count, p = snap.pending.count, h = snap.healthy.count
        seg("✕ \(e)", e > 0 ? Self.red : Self.gray)
        seg("  ", Self.gray)
        seg("⚙ \(p)", p > 0 ? Self.yellow : Self.gray)
        seg("  ", Self.gray)
        seg("✓ \(h)/\(snap.total)", Self.green)
        statusItem.button?.attributedTitle = title
        statusItem.button?.toolTip = "Tilt · \(e) errors, \(p) pending, \(h)/\(snap.total) healthy"
    }

    // MARK: menu

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        guard let snap = snapshot else {
            let item = NSMenuItem(title: "Tilt is not running", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            if let err = lastError {
                let detail = NSMenuItem(title: err, action: nil, keyEquivalent: "")
                detail.isEnabled = false
                detail.attributedTitle = NSAttributedString(string: err, attributes: [.font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
                menu.addItem(detail)
            }
            menu.addItem(.separator())
            addTrailingItems()
            return
        }

        let summary = "\(snap.healthy.count)/\(snap.total) healthy · \(snap.errors.count) errors · \(snap.pending.count) pending"
        menu.addItem(disabledItem(summary))
        let open = NSMenuItem(title: "Open Tilt UI", action: #selector(openTiltUI), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        // Resources that need a human: failed updates/runtimes and manual resources with unapplied changes.
        let needs = snap.needsReload
        menu.addItem(.separator())
        menu.addItem(header("Needs attention (\(needs.count))"))
        if needs.isEmpty {
            menu.addItem(disabledItem("Nothing waiting on you"))
        } else {
            for r in needs { menu.addItem(resourceItem(r)) }
            if snap.pendingChanges.count > 1 {
                let all = NSMenuItem(title: "Apply all pending changes (\(snap.pendingChanges.count))", action: #selector(triggerMany(_:)), keyEquivalent: "")
                all.target = self
                all.representedObject = snap.pendingChanges.map { $0.name }
                menu.addItem(all)
            }
        }

        let building = snap.pending.filter { !$0.hasPendingChanges }
        if !building.isEmpty {
            menu.addItem(.separator())
            menu.addItem(header("In progress (\(building.count))"))
            for r in building { menu.addItem(resourceItem(r)) }
        }

        menu.addItem(.separator())
        let all = NSMenuItem(title: "All resources", action: nil, keyEquivalent: "")
        all.submenu = allResourcesMenu(snap)
        menu.addItem(all)

        if let tiltfile = snap.resources.first(where: { $0.isTiltfile }) {
            let rerun = NSMenuItem(title: "Re-run Tiltfile", action: #selector(triggerOne(_:)), keyEquivalent: "")
            rerun.target = self
            rerun.representedObject = tiltfile.name
            rerun.image = dot(for: tiltfile.health)
            menu.addItem(rerun)
        }

        menu.addItem(.separator())
        addTrailingItems()
    }

    private func addTrailingItems() {
        let notify = NSMenuItem(title: "Notify on new errors", action: #selector(toggleNotify), keyEquivalent: "")
        notify.target = self
        notify.state = notifyOnErrors ? .on : .off
        menu.addItem(notify)
        let refresh = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let quit = NSMenuItem(title: "Quit TiltBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func allResourcesMenu(_ snap: Snapshot) -> NSMenu {
        let sub = NSMenu()
        let grouped = Dictionary(grouping: snap.resources.filter { !$0.isTiltfile }, by: { $0.groupLabel })
        for label in grouped.keys.sorted() {
            let members = grouped[label]!
            let worst = members.map { $0.health }.min() ?? .none
            let item = NSMenuItem(title: "\(label)  (\(members.count))", action: nil, keyEquivalent: "")
            item.image = dot(for: worst)
            let groupMenu = NSMenu()
            for r in members.sorted(by: { ($0.health, $0.name) < ($1.health, $1.name) }) {
                groupMenu.addItem(resourceItem(r))
            }
            item.submenu = groupMenu
            sub.addItem(item)
        }
        return sub
    }

    private func resourceItem(_ r: TiltResource) -> NSMenuItem {
        let item = NSMenuItem(title: r.name, action: nil, keyEquivalent: "")
        item.image = dot(for: r.health)
        if r.hasPendingChanges {
            item.attributedTitle = NSAttributedString(string: "\(r.name)  · pending changes", attributes: [.font: NSFont.menuFont(ofSize: 13)])
        } else if r.disabled {
            item.attributedTitle = NSAttributedString(string: "\(r.name)  · disabled", attributes: [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
        }

        let sub = NSMenu()
        sub.addItem(disabledItem(r.statusSummary))
        if let since = r.pendingBuildSince, r.hasPendingChanges {
            sub.addItem(disabledItem("changes waiting since \(TiltResource.relative(since))"))
        }
        sub.addItem(.separator())

        let verb: String
        if r.hasPendingChanges { verb = "Apply pending changes" }
        else if r.health == .error { verb = "Retry (trigger update)" }
        else if r.isLocal { verb = "Run again" }
        else { verb = "Trigger update" }
        let trigger = NSMenuItem(title: verb, action: #selector(triggerOne(_:)), keyEquivalent: "")
        trigger.target = self
        trigger.representedObject = r.name
        trigger.isEnabled = !r.disabled
        if let t = recentlyTriggered[r.name], Date().timeIntervalSince(t) < 5 {
            trigger.title = "Triggered…"
            trigger.isEnabled = false
        }
        sub.addItem(trigger)

        let open = NSMenuItem(title: "Open in Tilt UI", action: #selector(openResource(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = r.name
        sub.addItem(open)

        for url in r.endpoints {
            let link = NSMenuItem(title: "Open \(url.absoluteString)", action: #selector(openURL(_:)), keyEquivalent: "")
            link.target = self
            link.representedObject = url
            sub.addItem(link)
        }
        item.submenu = sub
        return item
    }

    private func header(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
    }

    private func disabledItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func dot(for health: Health) -> NSImage {
        let color: NSColor
        switch health {
        case .error: color = Self.red
        case .pending, .building: color = Self.yellow
        case .healthy: color = Self.green
        case .none, .disabled: color = NSColor.tertiaryLabelColor
        }
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return image
    }

    // MARK: actions

    @objc private func openTiltUI() {
        NSWorkspace.shared.open(client.webBase)
    }

    @objc private func openResource(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "r/\(encoded)/overview", relativeTo: client.webBase) else { return }
        NSWorkspace.shared.open(url.absoluteURL)
    }

    @objc private func openURL(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    @objc private func triggerOne(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { trigger([name]) }
    }

    @objc private func triggerMany(_ sender: NSMenuItem) {
        if let names = sender.representedObject as? [String] { trigger(names) }
    }

    private func trigger(_ names: [String]) {
        names.forEach { recentlyTriggered[$0] = Date() }
        client.trigger(names) { [weak self] err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let err = err {
                    names.forEach { self.recentlyTriggered[$0] = nil }
                    self.notify(title: "Tilt trigger failed", body: "\(names.joined(separator: ", ")): \(err)")
                } else {
                    self.poll()
                }
            }
        }
    }

    @objc private func toggleNotify() {
        notifyOnErrors.toggle()
    }

    @objc private func refreshNow() {
        poll()
    }

    // MARK: notifications

    private func setupNotifications() {
        // UNUserNotificationCenter aborts the process outside a proper .app bundle.
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.notificationsReady = granted
        }
    }

    private func notify(title: String, body: String) {
        guard notifyOnErrors, notificationsReady else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
