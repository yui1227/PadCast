// App 主流程：裝置連線、錄影/重播/截圖動作、設定套用、狀態顯示
// 視窗與控制列的建立、自動隱藏、選單在 MainWindow.swift
import Cocoa
import AVFoundation
import CoreImage

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let session = AVCaptureSession()
    let recorder = Recorder()
    let audioPreview = AVCaptureAudioPreviewOutput()

    // 介面元件（在 MainWindow.swift 建立）
    var window: NSWindow!
    var preview: PreviewView!
    var hud: NSVisualEffectView!
    let badge = BadgeView()
    let statusLabel = NSTextField(labelWithString: "")
    var recordButton: NSButton!
    var replayButton: NSButton!
    var rotateLeftButton: NSButton!
    var rotateRightButton: NSButton!
    var monitorButton: NSButton!
    var settingsButton: NSButton!
    var volumeSlider: NSSlider!
    let volumeLabel = NSTextField(labelWithString: "100%")
    let settingsPopover = NSPopover()
    let settingsVC = SettingsViewController()

    // 狀態
    var currentDevice: AVCaptureDevice?
    var videoSize = CGSize.zero
    var rotation = 0                // 順時針 90° 的次數
    var isRecording = false
    var isSavingReplay = false
    var recordStart = Date()
    var recordURL: URL?
    var freeBytes: Int64 = 0
    var statusMessage: (text: String, until: Date)?
    var statusTimer: Timer?
    var pollTimer: Timer?
    var hideTimer: Timer?
    var controlsVisible = true
    var hasSavedFrame = false

    let hudHeight: CGFloat = 40
    let hudMargin: CGFloat = 12
    static let lowSpaceWarn: Int64 = 5_000_000_000      // 5 GB 以下警告
    static let lowSpaceStop: Int64 = 500_000_000        // 500 MB 以下自動停止錄影

    // MARK: - 啟動

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        rotation = Prefs.rotation
        buildMenu()
        buildWindow()

        enableScreenCaptureDevices()
        session.beginConfiguration()
        if session.canAddOutput(recorder.videoOutput) { session.addOutput(recorder.videoOutput) }
        if session.canAddOutput(recorder.audioOutput) { session.addOutput(recorder.audioOutput) }
        if session.canAddOutput(audioPreview) { session.addOutput(audioPreview) }   // 從 Mac 喇叭監聽
        session.commitConfiguration()

        recorder.onVideoSize = { [weak self] size in self?.videoSizeChanged(size) }
        recorder.onRecordingError = { [weak self] msg in self?.recordingFailed(msg) }
        applyVolume()
        applySettings()   // 視窗置頂、畫質、重播緩衝馬上套用（麥克風等權限確認後再套用一次）

        let nc = NotificationCenter.default
        nc.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil,
                       queue: .main) { [weak self] _ in self?.connectIfNeeded() }
        nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil,
                       queue: .main) { [weak self] note in
            guard let self, let dev = note.object as? AVCaptureDevice,
                  dev.uniqueID == self.currentDevice?.uniqueID else { return }
            self.deviceGone()
        }

        AVCaptureDevice.requestAccess(for: .video) { _ in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async {
                    self.connectIfNeeded()
                    self.applySettings()
                }
            }
        }
        // 開啟擷取開關後，裝置要一兩秒才會出現；保險起見定時再找
        pollTimer = Timer.scheduledTimer(timeInterval: 2, target: self,
                                         selector: #selector(pollDevice), userInfo: nil, repeats: true)
        statusTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self,
                                           selector: #selector(statusTick), userInfo: nil, repeats: true)
        freeBytes = freeDiskBytes()
        statusTick()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isRecording else { return .terminateNow }
        recorder.stopRecording { _ in NSApp.reply(toApplicationShouldTerminate: true) }   // 先把檔案收尾
        return .terminateLater
    }

    func windowWillClose(_ notification: Notification) {
        if isRecording { NSApp.terminate(nil) }
    }

    // MARK: - 設定

    /// 把 Prefs 套用到錄影引擎與視窗
    func applySettings() {
        recorder.apply(config: Prefs.encode)
        if Prefs.micEnabled && !recorder.setMic(true) {
            Prefs.micEnabled = false
            setStatus("找不到可用的麥克風，已關閉麥克風錄音")
        } else if !Prefs.micEnabled {
            recorder.setMic(false)
        }
        recorder.setReplay(enabled: Prefs.replayEnabled, seconds: Prefs.replaySeconds)
        window.level = Prefs.alwaysOnTop ? .floating : .normal
        replayButton.isEnabled = Prefs.replayEnabled
        settingsVC.reload()
        statusTick()
    }

    // MARK: - 裝置

    @objc func pollDevice() { connectIfNeeded() }

    func connectIfNeeded() {
        guard currentDevice == nil, let dev = findIOSDevice() else { return }
        do {
            let input = try AVCaptureDeviceInput(device: dev)
            session.beginConfiguration()
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                setStatus("無法加入裝置（可能被其他 App 佔用，例如 QuickTime / OBS）", seconds: 10)
                return
            }
            session.addInput(input)
            session.commitConfiguration()
            currentDevice = dev
            setStatus("已連線：\(dev.localizedName)")
            if !session.isRunning { session.startRunning() }
        } catch {
            setStatus("無法開啟裝置：\(error.localizedDescription)", seconds: 10)
        }
    }

    func deviceGone() {
        if isRecording { toggleRecord(nil) }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.commitConfiguration()
        currentDevice = nil
        setStatus("裝置已中斷，等待重新連線…")
    }

    func videoSizeChanged(_ size: CGSize) {
        let first = videoSize == .zero
        videoSize = size
        if first && !hasSavedFrame { fitWindow() }   // 有記住的視窗位置就不動它
    }

    // MARK: - 旋轉

    @objc func rotateLeft(_ sender: Any?) { rotate(by: -1) }
    @objc func rotateRight(_ sender: Any?) { rotate(by: 1) }

    func rotate(by delta: Int) {
        guard !isRecording else {      // 錄影中鎖定方向（旋轉資訊在開始錄影時寫入）
            NSSound.beep()
            setStatus("錄影中不能旋轉")
            return
        }
        rotation = ((rotation + delta) % 4 + 4) % 4
        Prefs.rotation = rotation
        preview.rotation = rotation
        fitWindow()
    }

    // MARK: - 監聽音量

    @objc func volumeChanged(_ sender: Any?) {
        Prefs.monitorVolume = volumeSlider.doubleValue
        applyVolume()
    }
    @objc func volumeUp(_ sender: Any?) {
        volumeSlider.doubleValue = min(1, volumeSlider.doubleValue + 0.1); volumeChanged(nil)
    }
    @objc func volumeDown(_ sender: Any?) {
        volumeSlider.doubleValue = max(0, volumeSlider.doubleValue - 0.1); volumeChanged(nil)
    }
    @objc func toggleMute(_ sender: Any?) {
        Prefs.monitorOn.toggle()
        applyVolume()
    }
    func applyVolume() {
        let v = Float(volumeSlider.doubleValue)
        audioPreview.volume = Prefs.monitorOn ? v * v : 0     // 滑桿線性 → 聽感較自然的曲線
        volumeLabel.stringValue = "\(Int((volumeSlider.doubleValue * 100).rounded()))%"
        volumeSlider.isEnabled = Prefs.monitorOn
        let name = !Prefs.monitorOn ? "speaker.slash.fill" : (v < 0.34 ? "speaker.wave.1.fill" : "speaker.wave.2.fill")
        monitorButton.image = NSImage(systemSymbolName: name, accessibilityDescription: "監聽聲音")
    }

    // MARK: - 錄影

    @objc func toggleRecord(_ sender: Any?) {
        if isRecording {
            recordButton.isEnabled = false
            recorder.stopRecording { [weak self] url in
                guard let self else { return }
                self.setRecordingUI(false)
                if let url {
                    self.setStatus("已儲存：\(url.lastPathComponent)（\(formatBytes(fileSize(url)))）", seconds: 8)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    self.setStatus("錄影失敗，或期間沒有收到畫面", seconds: 8)
                }
            }
        } else {
            guard currentDevice != nil else { NSSound.beep(); setStatus("還沒有連上 iPad"); return }
            freeBytes = freeDiskBytes()
            guard freeBytes > Self.lowSpaceStop else { NSSound.beep(); setStatus("磁碟空間不足，無法錄影"); return }
            let url = outputURL(prefix: "錄影", ext: "mov")
            recordURL = url
            recorder.startRecording(url: url, rotation: rotation)
            recordStart = Date()
            setRecordingUI(true)
            setStatus("開始錄影（\(Prefs.encode.summary)\(Prefs.micEnabled ? "＋麥克風" : "")）")
        }
    }

    func setRecordingUI(_ on: Bool) {
        isRecording = on
        recordButton.isEnabled = true
        recordButton.title = on ? "停止" : "錄影"
        recordButton.image = NSImage(systemSymbolName: on ? "stop.circle.fill" : "record.circle",
                                     accessibilityDescription: nil)
        rotateLeftButton.isEnabled = !on
        rotateRightButton.isEnabled = !on
        statusTick()
    }

    func recordingFailed(_ msg: String) {
        if isRecording {
            recorder.stopRecording { _ in }
            setRecordingUI(false)
        }
        setStatus(msg, seconds: 10)
    }

    // MARK: - 重播緩衝

    @objc func toggleReplay(_ sender: Any?) {
        Prefs.replayEnabled.toggle()
        applySettings()
        setStatus(Prefs.replayEnabled ? "重播緩衝已開啟（最近 \(replayLengthText)）" : "重播緩衝已關閉")
    }

    var replayLengthText: String {
        let s = Prefs.replaySeconds
        return s < 60 ? "\(s) 秒" : "\(s / 60) 分鐘"
    }

    @objc func saveReplay(_ sender: Any?) {
        guard Prefs.replayEnabled else { NSSound.beep(); setStatus("重播緩衝沒有開啟（在設定裡打開）"); return }
        guard !isSavingReplay else { return }
        isSavingReplay = true
        replayButton.isEnabled = false
        setStatus("正在儲存重播…", seconds: 30)
        let url = outputURL(prefix: "重播", ext: "mov")
        recorder.saveReplay(rotation: rotation, to: url) { [weak self] result, err in
            guard let self else { return }
            self.isSavingReplay = false
            self.replayButton.isEnabled = Prefs.replayEnabled
            if let result {
                self.setStatus("已儲存重播：\(result.lastPathComponent)（\(formatBytes(fileSize(result)))）", seconds: 8)
                NSWorkspace.shared.activateFileViewerSelecting([result])
            } else {
                self.setStatus(err ?? "重播儲存失敗", seconds: 8)
            }
        }
    }

    // MARK: - 截圖

    @objc func screenshot(_ sender: Any?) {
        guard let pb = recorder.latestFrame() else { NSSound.beep(); return }
        var img = CIImage(cvPixelBuffer: pb).transformed(by: quarterTurn(-rotation))   // CIImage y 軸向上
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        let url = outputURL(prefix: "截圖", ext: "png")
        do {
            try CIContext().writePNGRepresentation(of: img, to: url, format: .RGBA8,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            setStatus("已截圖：\(url.lastPathComponent)")
        } catch {
            setStatus("截圖失敗：\(error.localizedDescription)")
        }
    }

    // MARK: - 選單開關

    @objc func toggleAlwaysOnTop(_ sender: Any?) {
        Prefs.alwaysOnTop.toggle()
        applySettings()
    }

    @objc func toggleMic(_ sender: Any?) {
        Prefs.micEnabled.toggle()
        applySettings()
        if Prefs.micEnabled { setStatus("麥克風已開啟（下一次錄影起生效）") }
    }

    // 選單裡的畫質選項（tag 存選項值）
    @objc func selectCodec(_ sender: NSMenuItem) {
        var e = Prefs.encode; e.hevc = sender.tag == 1; Prefs.encode = e
        applySettings(); setStatus("已改為 \(Prefs.encode.summary)（下一次錄影起生效）")
    }
    @objc func selectFPS(_ sender: NSMenuItem) {
        var e = Prefs.encode; e.fps = Int32(sender.tag); Prefs.encode = e
        applySettings(); setStatus("已改為 \(Prefs.encode.summary)（下一次錄影起生效）")
    }
    @objc func selectQuality(_ sender: NSMenuItem) {
        var e = Prefs.encode; e.quality = sender.tag; Prefs.encode = e
        applySettings(); setStatus("已改為 \(Prefs.encode.summary)（下一次錄影起生效）")
    }
    @objc func selectReplayLength(_ sender: NSMenuItem) {
        Prefs.replaySeconds = sender.tag
        applySettings(); setStatus("重播緩衝改為最近 \(replayLengthText)")
    }

    @objc func openOutputFolder(_ sender: Any?) {
        NSWorkspace.shared.open(outputDirectory)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleAlwaysOnTop(_:)): item.state = Prefs.alwaysOnTop ? .on : .off
        case #selector(toggleMic(_:)): item.state = Prefs.micEnabled ? .on : .off
        case #selector(toggleReplay(_:)): item.state = Prefs.replayEnabled ? .on : .off
        case #selector(toggleMute(_:)): item.state = Prefs.monitorOn ? .off : .on
        case #selector(selectCodec(_:)): item.state = (Prefs.encode.hevc ? 1 : 0) == item.tag ? .on : .off
        case #selector(selectFPS(_:)): item.state = Int(Prefs.encode.fps) == item.tag ? .on : .off
        case #selector(selectQuality(_:)): item.state = Prefs.encode.quality == item.tag ? .on : .off
        case #selector(selectReplayLength(_:)): item.state = Prefs.replaySeconds == item.tag ? .on : .off
        case #selector(saveReplay(_:)): return Prefs.replayEnabled && !isSavingReplay
        case #selector(rotateLeft(_:)), #selector(rotateRight(_:)): return !isRecording
        default: break
        }
        return true
    }

    // MARK: - 狀態顯示

    func setStatus(_ text: String, seconds: TimeInterval = 5) {
        statusMessage = (text, Date().addingTimeInterval(seconds))
        statusTick()
    }

    @objc func statusTick() {
        // 磁碟空間（錄影中每次都看，平常約 5 秒看一次）
        if isRecording || Int(Date().timeIntervalSince1970 * 2) % 10 == 0 { freeBytes = freeDiskBytes() }
        if isRecording && freeBytes < Self.lowSpaceStop {
            toggleRecord(nil)
            setStatus("磁碟空間不足，已自動停止錄影", seconds: 15)
        }

        // 右上角標籤：錄影中/儲存重播中，不跟著介面隱藏
        if isRecording, let url = recordURL {
            let t = Int(Date().timeIntervalSince(recordStart))
            let s = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: NSColor.systemRed])
            s.append(NSAttributedString(string: "REC \(formatDuration(t))  \(formatBytes(fileSize(url)))"))
            if freeBytes < Self.lowSpaceWarn {
                s.append(NSAttributedString(string: "  剩 \(formatBytes(freeBytes))",
                                            attributes: [.foregroundColor: NSColor.systemOrange]))
            }
            badge.show(s)
        } else if isSavingReplay {
            badge.show(NSAttributedString(string: "⟲ 儲存重播中…"))
        } else {
            badge.show(nil)
        }

        // 控制列文字：暫時訊息優先，否則顯示一般資訊
        if let m = statusMessage, Date() < m.until {
            statusLabel.stringValue = m.text
            statusLabel.textColor = .labelColor
            return
        }
        statusMessage = nil
        var parts: [String] = []
        parts.append(currentDevice.map { $0.localizedName } ?? "等待 iPad 連線…（請解鎖並信任這台電腦）")
        if Prefs.replayEnabled {
            parts.append("重播 \(Int(recorder.replayBufferedSeconds()))/\(Prefs.replaySeconds) 秒")
        }
        if Prefs.micEnabled { parts.append("🎙") }
        parts.append("剩 \(formatBytes(freeBytes))")
        statusLabel.stringValue = parts.joined(separator: " · ")
        statusLabel.textColor = freeBytes > 0 && freeBytes < Self.lowSpaceWarn ? .systemOrange : .secondaryLabelColor
    }
}
