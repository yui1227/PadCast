// 視窗、浮動控制列、自動隱藏、選單
import Cocoa

extension AppDelegate {

    // MARK: - 視窗

    func buildWindow() {
        // 畫面延伸到標題列底下，標題列透明，跟 QuickTime 播放時一樣
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "PadCast"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true   // 拖曳畫面就能移動視窗
        window.backgroundColor = .black
        window.acceptsMouseMovedEvents = true
        window.delegate = self
        window.contentMinSize = NSSize(width: 560, height: 300)
        let content = HoverView()
        window.contentView = content
        content.onMove = { [weak self] p in self?.mouseActivity(at: p) }
        content.onExit = { [weak self] in self?.scheduleHide(after: 0.6) }

        preview = PreviewView()
        let p = preview!
        recorder.previewSink = { sb in p.enqueue(sb) }
        preview.frame = content.bounds
        preview.autoresizingMask = [.width, .height]
        preview.rotation = rotation
        content.addSubview(preview)

        buildHUD(in: content)

        badge.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(badge)

        settingsVC.onChange = { [weak self] in self?.applySettings() }
        settingsPopover.contentViewController = settingsVC
        settingsPopover.behavior = .transient
        settingsPopover.appearance = NSAppearance(named: .darkAqua)

        // 記住視窗位置與大小
        hasSavedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame PadCastMain") != nil
        window.setFrameAutosaveName("PadCastMain")
        if !hasSavedFrame { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        scheduleHide(after: 2.5)
    }

    private func symbolButton(_ symbol: String, title: String = "", tip: String, action: Selector) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let b = title.isEmpty ? NSButton(image: img, target: self, action: action)
                              : NSButton(title: title, image: img, target: self, action: action)
        b.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        b.bezelStyle = .texturedRounded
        b.toolTip = tip
        return b
    }

    private func buildHUD(in content: NSView) {
        rotateLeftButton = symbolButton("rotate.left", tip: "向左旋轉（⌘←）", action: #selector(rotateLeft(_:)))
        rotateRightButton = symbolButton("rotate.right", tip: "向右旋轉（⌘→）", action: #selector(rotateRight(_:)))
        recordButton = symbolButton("record.circle", title: "錄影", tip: "開始／停止錄影（⌘R）",
                                    action: #selector(toggleRecord(_:)))
        recordButton.contentTintColor = .systemRed
        replayButton = symbolButton("clock.arrow.circlepath", title: "存重播", tip: "把最近一段存成影片（⇧⌘R）",
                                    action: #selector(saveReplay(_:)))
        let shot = symbolButton("camera", tip: "截圖（⇧⌘S）", action: #selector(screenshot(_:)))
        settingsButton = symbolButton("gearshape", tip: "設定（⌘,）", action: #selector(showSettings(_:)))
        monitorButton = symbolButton("speaker.wave.2.fill", tip: "監聽聲音開關（⇧⌘M）", action: #selector(toggleMute(_:)))

        volumeSlider = NSSlider(value: Prefs.monitorVolume, minValue: 0, maxValue: 1,
                                target: self, action: #selector(volumeChanged(_:)))
        volumeSlider.isContinuous = true
        volumeSlider.controlSize = .small
        volumeSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        volumeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        volumeLabel.widthAnchor.constraint(equalToConstant: 34).isActive = true
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [rotateLeftButton, rotateRightButton, recordButton, replayButton, shot,
                                      settingsButton, monitorButton, volumeSlider, volumeLabel, statusLabel])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.setCustomSpacing(14, after: rotateRightButton)
        bar.setCustomSpacing(14, after: settingsButton)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)

        // 浮在畫面上的半透明控制列
        hud = NSVisualEffectView(frame: NSRect(x: hudMargin, y: hudMargin,
                                               width: content.bounds.width - hudMargin * 2, height: hudHeight))
        hud.material = .hudWindow
        hud.blendingMode = .withinWindow
        hud.state = .active
        hud.appearance = NSAppearance(named: .vibrantDark)
        hud.wantsLayer = true
        hud.layer?.cornerRadius = 10
        hud.layer?.masksToBounds = true
        hud.autoresizingMask = [.width, .maxYMargin]
        bar.frame = hud.bounds
        bar.autoresizingMask = [.width, .height]
        hud.addSubview(bar)
        content.addSubview(hud)
    }

    @objc func showSettings(_ sender: Any?) {
        showControls()
        if settingsPopover.isShown { settingsPopover.close(); return }
        settingsVC.reload()
        settingsPopover.show(relativeTo: settingsButton.bounds, of: settingsButton, preferredEdge: .maxY)
    }

    /// 依畫面比例（含旋轉）調整視窗大小
    func fitWindow() {
        guard videoSize.width > 0, let screen = window.screen ?? NSScreen.main else { return }
        var s = rotation % 2 == 1 ? CGSize(width: videoSize.height, height: videoSize.width) : videoSize
        let vf = screen.visibleFrame
        let scale = min(vf.width * 0.85 / s.width, vf.height * 0.85 / s.height, 1)
        s = CGSize(width: (s.width * scale).rounded(), height: (s.height * scale).rounded())
        let old = window.frame
        window.setContentSize(NSSize(width: max(s.width, window.contentMinSize.width), height: s.height))
        var f = window.frame
        f.origin.x = old.midX - f.width / 2
        f.origin.y = old.midY - f.height / 2
        window.setFrame(f, display: true)
        preview.relayout()
        statusTick()   // 重新貼齊右上角標籤
    }

    func windowDidResize(_ notification: Notification) {
        statusTick()
    }

    // MARK: - 自動隱藏標題列與控制列

    private var titlebarView: NSView? { window.standardWindowButton(.closeButton)?.superview }

    func mouseActivity(at p: NSPoint) {
        showControls()
        // 滑鼠停在控制列上就不隱藏
        if hud.frame.insetBy(dx: -4, dy: -4).contains(p) { hideTimer?.invalidate() } else { scheduleHide(after: 2.0) }
    }

    func scheduleHide(after delay: TimeInterval) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(timeInterval: delay, target: self,
                                         selector: #selector(hideControls), userInfo: nil, repeats: false)
    }

    func showControls() {
        guard !controlsVisible else { return }
        controlsVisible = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            hud.animator().alphaValue = 1
            titlebarView?.animator().alphaValue = 1
        }
    }

    @objc func hideControls() {
        // 正在拖曳滑桿、設定面板開著時先不要藏
        guard controlsVisible, NSEvent.pressedMouseButtons == 0, !settingsPopover.isShown,
              let content = window.contentView else { return }
        let mouse = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let inside = content.bounds.contains(mouse)
        if inside && hud.frame.contains(mouse) { return }
        controlsVisible = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            hud.animator().alphaValue = 0
            titlebarView?.animator().alphaValue = 0
        }
        if inside { NSCursor.setHiddenUntilMouseMoves(true) }   // 游標也一起藏起來
    }

    // MARK: - 選單

    func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let settings = NSMenuItem(title: "設定…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "結束 PadCast", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        func menu(_ title: String, _ build: (NSMenu) -> Void) {
            let item = NSMenuItem()
            let m = NSMenu(title: title)
            build(m)
            item.submenu = m
            main.addItem(item)
        }
        func add(_ m: NSMenu, _ title: String, _ sel: Selector, _ key: String,
                 _ mods: NSEvent.ModifierFlags = .command) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            it.target = self
            m.addItem(it)
        }
        func arrow(_ k: Int) -> String { String(Character(UnicodeScalar(k)!)) }
        /// 一組單選的子選單（勾選狀態在 validateMenuItem 依 tag 決定）
        func submenu(_ m: NSMenu, _ title: String, _ sel: Selector, _ options: [(String, Int)]) {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            for (name, tag) in options {
                let it = NSMenuItem(title: name, action: sel, keyEquivalent: "")
                it.tag = tag
                it.target = self
                sub.addItem(it)
            }
            parent.submenu = sub
            m.addItem(parent)
        }

        menu("錄影") { m in
            add(m, "開始／停止錄影", #selector(toggleRecord(_:)), "r")
            add(m, "儲存重播", #selector(saveReplay(_:)), "r", [.command, .shift])
            add(m, "截圖", #selector(screenshot(_:)), "s", [.command, .shift])
            m.addItem(.separator())
            add(m, "重播緩衝", #selector(toggleReplay(_:)), "")
            submenu(m, "重播長度", #selector(selectReplayLength(_:)),
                    Prefs.replayChoices.map { ($0 < 60 ? "\($0) 秒" : "\($0 / 60) 分鐘", $0) })
            add(m, "錄麥克風", #selector(toggleMic(_:)), "")
            m.addItem(.separator())
            submenu(m, "編碼", #selector(selectCodec(_:)), [("H.264（相容性最好）", 0), ("HEVC（檔案約小一半）", 1)])
            submenu(m, "幀率", #selector(selectFPS(_:)), [("30 fps", 30), ("60 fps", 60)])
            submenu(m, "畫質", #selector(selectQuality(_:)),
                    EncodeConfig.qualityNames.enumerated().map { ($1, $0) })
            m.addItem(.separator())
            add(m, "打開輸出資料夾", #selector(openOutputFolder(_:)), "o", [.command, .shift])
        }
        menu("顯示") { m in
            add(m, "向左旋轉", #selector(rotateLeft(_:)), arrow(NSLeftArrowFunctionKey))
            add(m, "向右旋轉", #selector(rotateRight(_:)), arrow(NSRightArrowFunctionKey))
            m.addItem(.separator())
            add(m, "視窗置頂", #selector(toggleAlwaysOnTop(_:)), "t")
            let fs = NSMenuItem(title: "全螢幕", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            fs.keyEquivalentModifierMask = [.command, .control]
            m.addItem(fs)
        }
        menu("聲音") { m in
            add(m, "監聽音量 +10%", #selector(volumeUp(_:)), arrow(NSUpArrowFunctionKey))
            add(m, "監聽音量 −10%", #selector(volumeDown(_:)), arrow(NSDownArrowFunctionKey))
            add(m, "監聽靜音", #selector(toggleMute(_:)), "m", [.command, .shift])
        }
        NSApp.mainMenu = main
    }
}
