import AppKit
import Carbon
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let line = Line()
    private var panel: LinePanel!
    private var statusItem: NSStatusItem!
    private var watcher: ScreenshotWatcher!
    /// In inbox mode, a second watcher on the Desktop. If a macOS version
    /// ignores the screenshot settings (macOS 27 renamed one), captures keep
    /// landing on the Desktop, and they still hang on the line.
    private var safetyWatcher: ScreenshotWatcher?
    private var clipboard: ClipboardWatcher!
    private var folderCheck: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var hotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?
    private var moveMonitors: [Any] = []

    /// Whether the panel is ordered in. It can be in and still tucked away
    /// above the top edge, like an auto-hiding Dock.
    private var isPresent = false
    /// Whether the line has slid down into view.
    private var isRevealed = false
    /// Opened on purpose with the shortcut or the menu: it stays down until
    /// the cursor has visited it and left, or the shortcut is pressed again.
    private var pinned = false
    /// A new screenshot shows itself for a moment, then tucks away.
    private var peekUntil = Date.distantPast
    private var hotZoneSince: Date?
    /// After a click in the menu bar the line stays up there hidden until the
    /// pointer leaves the menu bar, so it does not come back over a menu.
    private var menuBarSuppressed = false
    private var clickMonitors: [Any] = []
    private var awaySince: Date?
    /// Whether the line should be up, if nothing prevents it. A full screen
    /// app on that screen does: the line waits until you leave full screen.
    private var wanted = false
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false
    private var lastIDs = Set<UUID>()
    /// Items that join the line without bringing it down: clips, and
    /// screenshots that were already waiting in the inbox.
    private var quietIDs = Set<UUID>()
    /// The screen a new capture was taken on: the line goes there.
    private var pendingScreen: NSScreen?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Inbox.restoreOnCrash()
        Inbox.repairIfOrphaned()

        let host = NSHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        panel = LinePanel(content: host)
        panel.placeOnScreen()
        updateCapacity()
        line.restore()
        lastIDs = Set(line.items.map(\.id))

        if Inbox.isEnabled { Inbox.apply() }
        restoreSettingsOnTermination()
        startWatcher()
        startFolderCheck()

        clipboard = ClipboardWatcher { [weak self] url in self?.hangQuietly(url) }
        clipboard.start()

        registerHotKey()
        setUpStatusItem()
        watchMenuBarClicks()

        Markup.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        line.onFall = { [weak self] item in self?.fall(item) }

        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)

        // Entering or leaving full screen switches Space. Check again once the
        // switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refresh() }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.placeOnScreen()
                self?.updateCapacity()
            }
        }

        if !Inbox.wasOffered {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.offerInbox() }
        }

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            keepOpen = true
            wanted = true
            refresh()
            reveal(pinned: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.line.liveCount == 0 else { return }
                self.keepOpen = false
                self.wanted = false
                self.refresh()
            }
        } else if line.liveCount > 0 {
            wanted = true
            refresh()
        }

        #if DEBUG
        // Debug builds only: SINAMPAY_SNAPSHOT=/path.png shows the line and
        // writes what it draws to a file, to check the design without a
        // screen recording permission.
        if let path = ProcessInfo.processInfo.environment["SINAMPAY_SNAPSHOT"] {
            toggle()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                let renderer = ImageRenderer(content: LineView(line: self.line)
                    .frame(width: self.panel.frame.width, height: Layout.panelHeight)
                    .background(Color(white: 0.93)))
                renderer.scale = 2
                guard let cg = renderer.cgImage else { return }
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path))
            }
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Inbox.isEnabled { Inbox.restore() }
    }

    // MARK: Watching for screenshots

    private func startWatcher() {
        watcher?.stop()
        safetyWatcher?.stop()
        safetyWatcher = nil
        if Inbox.isEnabled { Inbox.ensureFolder() }
        let folder = ScreenshotWatcher.screenshotFolder()
        let isInbox = folder.standardizedFileURL.path == Inbox.folder.standardizedFileURL.path
        watcher = ScreenshotWatcher(
            folder: folder,
            adoptExisting: isInbox,
            onNew: { [weak self] url, fresh in fresh ? self?.hangCapture(url) : self?.hangQuietly(url) },
            onChange: { [weak self] in self?.line.prune() })
        watcher.start()
        if Inbox.isEnabled, folder.standardizedFileURL.path != ScreenshotWatcher.desktop.standardizedFileURL.path {
            let safety = ScreenshotWatcher(
                folder: ScreenshotWatcher.desktop,
                onNew: { [weak self] url, fresh in
                    guard fresh else { return }
                    log.notice("Screenshot landed on the Desktop despite inbox mode: \(url.lastPathComponent, privacy: .public)")
                    self?.hangCapture(url)
                },
                onChange: { [weak self] in self?.line.prune() })
            safety.start()
            safetyWatcher = safety
        }
    }

    /// Every few seconds, checks that the watcher still looks at the right
    /// folder. The save location can change in Cmd+Shift+5 while Sinampay
    /// runs, and the folder itself can be deleted or replaced in Finder.
    private func startFolderCheck() {
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkWatchedFolder() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        folderCheck = timer
    }

    private func checkWatchedFolder() {
        if Inbox.isEnabled {
            Inbox.ensureFolder()
            if ScreenshotWatcher.screenshotFolder().standardizedFileURL.path != Inbox.folder.standardizedFileURL.path {
                // Someone picked another save location while the mode was
                // on. That is the user's call: step aside and follow it.
                log.notice("Screenshot location changed by the user; inbox mode turned off")
                Inbox.relinquish()
            }
        }
        let expected = ScreenshotWatcher.screenshotFolder().standardizedFileURL
        let healthy = watcher.isHealthy && (safetyWatcher?.isHealthy ?? true)
        if watcher.folder.standardizedFileURL.path != expected.path || !healthy {
            log.notice("Watching \(expected.path, privacy: .public) again")
            startWatcher()
        }
    }

    private func setInbox(_ on: Bool) {
        Inbox.isEnabled = on
        if on { Inbox.apply() } else { Inbox.restore() }
        startWatcher()
    }

    /// Asked once. Changing system settings is the user's call, never ours.
    private func offerInbox() {
        Inbox.wasOffered = true
        let alert = NSAlert()
        alert.messageText = L("Let Sinampay handle your screenshots?",
                              fil: "Ipaubaya na sa Sinampay ang iyong mga screenshot?",
                              es: "¿Quieres que Sinampay se encargue de tus capturas?")
        alert.informativeText = L(
            "Screenshots will hang on the line the instant you take them, without the floating thumbnail, and will not pile up on your Desktop. Drag one to a folder to keep it, or discard it with the cross. You can turn this off from the menu bar, and your settings come back when Sinampay quits.",
            fil: "Agad na isasampay ang bawat screenshot, walang lumulutang na thumbnail, at hindi na magkakalat sa Desktop. I-drag sa isang folder para itago, o itapon gamit ang ekis. Puwede itong patayin sa menu bar, at babalik ang dati mong settings pag-quit ng Sinampay.",
            es: "Las capturas se colgarán al instante, sin la miniatura flotante, y no se acumularán en el Escritorio. Arrastra una a una carpeta para guardarla, o descártala con la cruz. Puedes desactivarlo desde la barra de menús, y tus ajustes vuelven a ser los de antes al salir de Sinampay.")
        alert.addButton(withTitle: L("Turn on", fil: "Buksan", es: "Activar"))
        alert.addButton(withTitle: L("Not now", fil: "Mamaya na", es: "Ahora no"))
        if let icon = NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setInbox(true) }
    }

    /// Quitting from the menu or logging out runs applicationWillTerminate.
    /// A plain kill does not, so settings are also restored on those signals.
    private func restoreSettingsOnTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                if Inbox.isEnabled { Inbox.restore() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Showing and hiding

    private func itemsChanged() {
        let live = Set(line.items.filter { !$0.falling }.map(\.id))
        let arrived = live.subtracting(lastIDs)
        if !arrived.isEmpty {
            wanted = true
            if arrived.isSubset(of: quietIDs) {
                refresh()
            } else {
                panel.placeOnScreen(pendingScreen)
                updateCapacity()
                refresh()
                reveal(peekFor: 2.5)
            }
            pendingScreen = nil
            quietIDs.subtract(arrived)
        } else if live.isEmpty && !keepOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.line.liveCount == 0, !self.keepOpen else { return }
                self.wanted = false
                self.refresh()
            }
        }
        lastIDs = live
    }

    /// Clips, and screenshots already waiting in the inbox at launch, join
    /// the line without bringing it down: copying text all day should not
    /// keep pulling a clothesline over your work.
    private func hangQuietly(_ url: URL) {
        line.hangLater(url, quietly: true) { [weak self] id in
            if let id { self?.quietIDs.insert(id) }
        }
    }

    // MARK: The capture flying to the line

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    private func hangCapture(_ url: URL) {
        let from = captureRect(of: url)
        if let from {
            let center = CGPoint(x: from.midX, y: from.midY)
            pendingScreen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
        }
        line.hangLater(url, flying: from != nil) { [weak self] id in
            guard let id, let from else { return }
            // Let the line come down and lay out before measuring the landing spot.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                self?.fly(id, from: from)
            }
        }
    }

    private func fly(_ id: UUID, from: CGRect) {
        guard isPresent, isRevealed, let screen = panel.screen,
              let to = cardFrame(for: id),
              let item = line.items.first(where: { $0.id == id }) else {
            line.land(id)
            return
        }
        let pixels = Int(max(from.width, from.height) * screen.backingScaleFactor)
        guard let image = makeThumbnail(item.url, maxPixels: min(3000, max(400, pixels)))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            line.land(id)
            return
        }
        CaptureFlight.fly(image: image, from: from, to: to, tilt: CGFloat(item.tilt), sipit: item.sipit,
                          on: screen) { [weak self] in
            self?.line.land(id)
        }
    }

    /// A discarded card falls over the whole screen, from where it hangs.
    private func fall(_ item: Pegged) {
        guard isPresent, isRevealed, !item.flying, let screen = panel.screen,
              let card = cardFrame(for: item.id),
              let image = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        CaptureFlight.fall(image: image, card: card, tilt: CGFloat(item.tilt), sipit: item.sipit, on: screen)
    }

    /// Where a card will hang, in screen coordinates, using the same layout
    /// as the line view.
    private func cardFrame(for id: UUID) -> CGRect? {
        guard let index = line.items.firstIndex(where: { $0.id == id }) else { return nil }
        let width = panel.frame.width
        let x = line.x(at: index, width: width)
        let viewTop = Layout.ropeY(x: x, width: width) - Layout.pinAbove
        let cardTop = viewTop + PeggedView.cardOffsetBelowTop
        let size = PeggedView.cardSize(for: line.items[index].thumb.size)
        return CGRect(x: panel.frame.minX + x - size.width / 2,
                      y: panel.frame.maxY - cardTop - size.height,
                      width: size.width, height: size.height)
    }

    /// Decides whether the panel is ordered in at all: something to show,
    /// and no full screen app on that screen.
    private func refresh() {
        let blocked = panel.screen.map(FullScreen.isActive(on:))
            ?? LinePanel.screenUnderPointer().map(FullScreen.isActive(on:)) ?? false
        if wanted && !blocked {
            present()
        } else {
            dismiss()
        }
        // The cursor is watched while there is a line, even tucked away,
        // to notice it pushing against the top edge.
        if wanted { startMouseTracking() } else { stopMouseTracking() }
    }

    private func present() {
        guard !isPresent else { return }
        isPresent = true
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isPresent else { return }
            self.panel.orderOut(nil)
        }
    }

    private func reveal(pinned: Bool = false, peekFor seconds: TimeInterval = 0) {
        guard isPresent else { return }
        if pinned { self.pinned = true }
        if seconds > 0 { peekUntil = Date().addingTimeInterval(seconds) }
        awaySince = nil
        setRevealed(true)
        wakeTracking()
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed else { return }
        isRevealed = on
        line.revealed = on
        if !on {
            pinned = false
            peekUntil = .distantPast
            panel.ignoresMouseEvents = true
        }
    }

    @objc private func toggle() {
        if isRevealed {
            setRevealed(false)
            if line.liveCount == 0 {
                keepOpen = false
                wanted = false
                refresh()
            }
        } else {
            keepOpen = true
            wanted = true
            panel.placeOnScreen()
            updateCapacity()
            refresh()
            reveal(pinned: true)
        }
    }

    // MARK: Following the pointer

    /// The pointer is followed closely only while it matters: the line is
    /// down, or the pointer is in the menu bar where it could bring it down.
    /// The rest of the time the timer sleeps, and any mouse movement wakes it.
    private func startMouseTracking() {
        if moveMonitors.isEmpty {
            let wake: (NSEvent) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { self?.wakeTracking() }
            }
            let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: wake) {
                moveMonitors.append(global)
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { e in wake(e); return e }) {
                moveMonitors.append(local)
            }
        }
        wakeTracking()
    }

    private func wakeTracking() {
        guard wanted, mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func sleepTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
    }

    private func stopMouseTracking() {
        sleepTracking()
        moveMonitors.forEach(NSEvent.removeMonitor)
        moveMonitors.removeAll()
        panel.ignoresMouseEvents = true
    }

    /// How long the cursor rests against the top edge before the line comes
    /// down. Short enough to feel instant, long enough that a quick trip to
    /// the menu bar does not trigger it.
    private static let revealDelay: TimeInterval = 0.25

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    static func menuBarBand(of screen: NSScreen) -> NSRect {
        var h = screen.frame.maxY - screen.visibleFrame.maxY
        if h < 1 { h = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
    }

    /// A click anywhere in the top bar of any screen, a menu or an icon, puts the line away.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = NSEvent.mouseLocation
                guard NSScreen.screens.contains(where: { Self.menuBarBand(of: $0).contains(p) }) else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                if self.isRevealed {
                    self.pinned = false
                    self.setRevealed(false)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) {
            clickMonitors.append(local)
        }
    }
    /// How long the cursor is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 0.5

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let now = Date()

        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inMenuBar = screenUnderPointer.map { Self.menuBarBand(of: $0).contains(mouse) } ?? false
        if !inMenuBar { menuBarSuppressed = false }

        guard isRevealed else {
            // Resting in the menu bar brings the line down on that screen.
            // Pushing against the top edge is part of it, and it also works
            // when another display sits above and the pointer never stops.
            if let screen = screenUnderPointer, inMenuBar, !menuBarSuppressed,
               !FullScreen.isActive(on: screen) {
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= Self.revealDelay {
                    hotZoneSince = nil
                    if panel.screen != screen {
                        panel.placeOnScreen()
                        updateCapacity()
                    }
                    refresh()
                    reveal()
                }
            } else {
                hotZoneSince = nil
                // Nothing to watch until the pointer moves again.
                if !inMenuBar { sleepTracking() }
            }
            return
        }

        updateMousePassThrough(mouse)

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        if inside && pinned { pinned = false }

        let busy = pinned || GrabView.isDragging || GrabView.isSliding || line.pressedID != nil || now < peekUntil
        if inside || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// The panel spans the whole width of the screen, so it only accepts the
    /// mouse while the cursor is over a photo. Everywhere else, clicks go to
    /// whatever is underneath.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !GrabView.isDragging && !GrabView.isSliding else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        let overPhoto = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
        if panel.ignoresMouseEvents == overPhoto {
            panel.ignoresMouseEvents = !overPhoto
        }
    }

    private func updateCapacity() {
        line.width = panel.frame.width
        let usable = panel.frame.width - 200
        line.maxItems = max(3, min(12, Int(usable / Layout.spacing)))
    }

    // MARK: Shortcut

    private func registerHotKey() {
        hotKey = nil
        guard let preset = HotKey.chosen else { return }
        hotKey = HotKey(preset) { [weak self] in self?.toggle() }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "tshirt", accessibilityDescription: "Sinampay")
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggleItem = ClosureMenuItem(isRevealed ? L("Hide line", fil: "Itago ang sampayan", es: "Ocultar la cuerda")
                                                 : L("Show line", fil: "Ipakita ang sampayan", es: "Mostrar la cuerda")) { [weak self] in
            self?.toggle()
        }
        if let preset = HotKey.chosen, hotKey?.isRegistered == true {
            toggleItem.keyEquivalent = preset.key
            toggleItem.keyEquivalentModifierMask = preset.mask
        }
        menu.addItem(toggleItem)

        let clearItem = ClosureMenuItem(L("Take everything down", fil: "Hanguin lahat", es: "Descolgar todo")) { [weak self] in
            self?.line.clear()
        }
        clearItem.isEnabled = line.liveCount > 0
        menu.addItem(clearItem)

        let tidyItem = ClosureMenuItem(L("Tidy up the line", fil: "Ayusin ang sampayan", es: "Ordenar la cuerda")) { [weak self] in
            self?.line.tidy()
        }
        tidyItem.isEnabled = !line.isTidy
        menu.addItem(tidyItem)

        menu.addItem(.separator())

        let inbox = ClosureMenuItem(L("Handle screenshots", fil: "Asikasuhin ang mga screenshot", es: "Encargarse de las capturas")) { [weak self] in
            self?.setInbox(!Inbox.isEnabled)
        }
        inbox.state = Inbox.isEnabled ? .on : .off
        inbox.toolTip = L("Screenshots hang instantly and skip the Desktop",
                          fil: "Agad na isinasampay ang mga screenshot at hindi na dumadaan sa Desktop",
                          es: "Las capturas se cuelgan al instante y no pasan por el Escritorio")
        menu.addItem(inbox)

        let clips = ClosureMenuItem(L("Hang what I copy", fil: "Isampay ang kinokopya ko", es: "Colgar lo que copio")) { [weak self] in
            guard let self else { return }
            self.clipboard.isEnabled.toggle()
        }
        clips.state = clipboard.isEnabled ? .on : .off
        clips.toolTip = L("Copied text and images hang on the line. Passwords marked private by your password manager are never kept.",
                          fil: "Isinasampay ang kinopyang teksto at larawan. Hindi kailanman itinatago ang mga password na minarkahang pribado ng iyong password manager.",
                          es: "El texto y las imágenes que copias se cuelgan. Nunca se guardan las contraseñas que tu gestor marca como privadas.")
        menu.addItem(clips)

        menu.addItem(ClosureMenuItem(L("Open screenshots folder", fil: "Buksan ang folder ng screenshot", es: "Abrir carpeta de capturas")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.watcher.folder)
        })

        menu.addItem(.separator())

        let sound = ClosureMenuItem(L("Sounds", fil: "Tunog", es: "Sonidos")) { [weak self] in
            guard let self else { return }
            self.line.soundOn.toggle()
        }
        sound.state = line.soundOn ? .on : .off
        menu.addItem(sound)

        let banderitas = ClosureMenuItem(L("Fiesta banderitas", fil: "Banderitas ng pista", es: "Banderitas de fiesta")) { [weak self] in
            self?.line.banderitasOn.toggle()
        }
        banderitas.state = line.banderitasOn ? .on : .off
        menu.addItem(banderitas)

        menu.addItem(shortcutMenuItem())

        let login = ClosureMenuItem(L("Open at login", fil: "Buksan pag-login", es: "Abrir al iniciar sesión")) {
            AppDelegate.toggleLaunchAtLogin()
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Quit Sinampay", fil: "Isara ang Sinampay", es: "Salir de Sinampay"), key: "q") {
            NSApp.terminate(nil)
        })
    }

    private func shortcutMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: L("Shortcut", fil: "Shortcut", es: "Atajo"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for preset in HotKey.presets {
            let choice = ClosureMenuItem(Self.describe(preset)) { [weak self] in
                HotKey.chosen = preset
                self?.registerHotKey()
            }
            choice.state = HotKey.chosen?.id == preset.id ? .on : .off
            sub.addItem(choice)
        }
        let none = ClosureMenuItem(L("None", fil: "Wala", es: "Ninguno")) { [weak self] in
            HotKey.chosen = nil
            self?.registerHotKey()
        }
        none.state = HotKey.chosen == nil ? .on : .off
        sub.addItem(none)
        if let preset = HotKey.chosen, hotKey?.isRegistered != true {
            sub.addItem(.separator())
            let warning = NSMenuItem(
                title: L("\(Self.describe(preset)) is taken by another app",
                         fil: "Gamit na ng ibang app ang \(Self.describe(preset))",
                         es: "Otra app ya usa \(Self.describe(preset))"),
                action: nil, keyEquivalent: "")
            warning.isEnabled = false
            sub.addItem(warning)
        }
        item.submenu = sub
        return item
    }

    private static func describe(_ preset: HotKey.Preset) -> String {
        var s = ""
        if preset.mask.contains(.control) { s += "⌃" }
        if preset.mask.contains(.option) { s += "⌥" }
        if preset.mask.contains(.shift) { s += "⇧" }
        if preset.mask.contains(.command) { s += "⌘" }
        return s + (preset.key == " " ? L("Space", fil: "Space", es: "Espacio") : preset.key.uppercased())
    }

    private static func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change the login setting",
                                  fil: "Hindi mabago ang setting sa pag-login",
                                  es: "No se pudo cambiar el inicio de sesión")
            alert.informativeText = L("Move Sinampay to the Applications folder and try again.",
                                      fil: "Ilipat ang Sinampay sa Applications folder at subukan ulit.",
                                      es: "Mueve Sinampay a la carpeta Aplicaciones y vuelve a intentarlo.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
