// PadCast — 擷取有線連接的 iPad / iPhone 畫面（預覽、錄影、錄音、截圖、畫面旋轉）
// 建置：./build.sh   （需要 Xcode 或 Command Line Tools：xcode-select --install）
// 需求：macOS 13 以上

import Cocoa
import AVFoundation
import CoreMediaIO
import CoreImage
import VideoToolbox

// MARK: - 工具函式

/// 開啟 iOS 螢幕擷取裝置（QuickTime 也是靠這個開關讓 iPad 出現）
func enableScreenCaptureDevices() {
    var prop = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var allow: UInt32 = 1
    CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil,
                              UInt32(MemoryLayout<UInt32>.size), &allow)
}

/// 找出 iOS 裝置（影像＋聲音合一的 muxed 裝置；一般 webcam 是 .video，不會被選到）
func findIOSDevice() -> AVCaptureDevice? {
    let types: [AVCaptureDevice.DeviceType]
    if #available(macOS 14.0, *) { types = [.external] } else { types = [.externalUnknown] }
    return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .muxed,
                                            position: .unspecified).devices.first
}

/// 精確的 90° 倍數旋轉矩陣（數學正方向＝逆時針，k 個 90°）
func quarterTurn(_ k: Int) -> CGAffineTransform {
    let table: [(CGFloat, CGFloat)] = [(1, 0), (0, 1), (-1, 0), (0, -1)]
    let (c, s) = table[((k % 4) + 4) % 4]
    return CGAffineTransform(a: c, b: s, c: -s, d: c, tx: 0, ty: 0)
}

func outputURL(prefix: String, ext: String) -> URL {
    let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PadCast", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH.mm.ss"
    return dir.appendingPathComponent("\(prefix) \(f.string(from: Date())).\(ext)")
}


/// 除錯紀錄：寫到 App 旁邊的 debug.log
func debugLog(_ msg: String) {
    NSLog("%@", msg)
    let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("debug.log")
    let line = "\(Date()) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - 錄影器（AVAssetWriter）

final class Recorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                      AVCaptureAudioDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "padcast.samples")
    let videoOutput = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()
    var onVideoSize: ((CGSize) -> Void)?
    var previewSink: ((CMSampleBuffer) -> Void)?   // 每一格都送給預覽（在 queue 上呼叫）
    static let fps: Int32 = 60                       // 錄影固定幀率

    // 以下只在 queue 上存取
    private var recording = false
    private var url: URL?
    private var rotation = 0
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var startTime = CMTime.invalid
    private var recordSize = CGSize.zero
    private var frameIndex: Int64 = 0
    private var currentPB: CVPixelBuffer?            // 目前要寫進影片的畫面
    private var ptsOffset = CMTime.invalid           // 影格時間戳 − 主機時鐘
    private var timer: DispatchSourceTimer?
    private var transfer: VTPixelTransferSession?
    private var lastFormatSig = ""
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastSize = CGSize.zero

    override init() {
        super.init()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        audioOutput.setSampleBufferDelegate(self, queue: queue)
    }

    /// rotation：順時針 90° 的次數（0–3），寫進影片軌的旋轉資訊
    func start(url: URL, rotation: Int) {
        queue.async {
            self.url = url
            self.rotation = rotation
            self.resetWriter()
            self.recording = true
            // 每 4ms 檢查一次：畫面沒變時也要補上重複的影格，維持固定 60fps
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    func stop(_ done: @escaping (URL?) -> Void) {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            if self.ptsOffset.isValid {   // 把最後一段補齊
                self.emitSlots(upTo: CMTimeAdd(self.hostNow(), self.ptsOffset), inclusive: true)
            }
            self.recording = false
            guard let w = self.writer, w.status == .writing else {
                debugLog("停止時 writer 狀態：\(String(describing: self.writer?.status.rawValue)) 錯誤：\(String(describing: self.writer?.error))")
                self.resetWriter()
                DispatchQueue.main.async { done(nil) }
                return
            }
            let url = self.url
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            w.finishWriting {
                if w.status != .completed { debugLog("寫檔失敗：\(String(describing: w.error))") }
                DispatchQueue.main.async { done(w.status == .completed ? url : nil) }
            }
            self.resetWriter()
        }
    }

    func latestFrame() -> CVPixelBuffer? { queue.sync { lastPixelBuffer } }

    private func resetWriter() {
        writer = nil; videoInput = nil; adaptor = nil; audioInput = nil
        startTime = .invalid; frameIndex = 0; currentPB = nil; recordSize = .zero
    }

    private func hostNow() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    /// 把擷取到的畫面複製（必要時縮放/轉格式）到錄影專用緩衝區
    private func copyForRecording(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool = adaptor?.pixelBufferPool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let dst = out else {
            return nil
        }
        if transfer == nil {
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        }
        guard let transfer else { return nil }
        let st = VTPixelTransferSessionTransferImage(transfer, from: src, to: dst)
        if st != noErr { debugLog("複製畫面失敗：\(st)"); return nil }
        CVBufferPropagateAttachments(src, dst)   // 保留色彩資訊
        return dst
    }

    private func logFormatIfChanged(_ pb: CVPixelBuffer) {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let fourcc = String(bytes: [24, 16, 8, 0].map { UInt8((fmt >> $0) & 0xff) }, encoding: .ascii) ?? "\(fmt)"
        func att(_ k: CFString) -> String {
            (CVBufferCopyAttachment(pb, k, nil) as? String) ?? "-"
        }
        let sig = "\(fourcc) \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) " +
            "primaries=\(att(kCVImageBufferColorPrimariesKey)) transfer=\(att(kCVImageBufferTransferFunctionKey)) " +
            "matrix=\(att(kCVImageBufferYCbCrMatrixKey))"
        if sig != lastFormatSig { lastFormatSig = sig; debugLog("畫面格式：\(sig)") }
    }

    private func slotTime(_ i: Int64) -> CMTime {
        CMTimeAdd(startTime, CMTime(value: i, timescale: Recorder.fps))
    }

    /// 把時間 t 之前（含/不含 t）尚未寫出的 1/60 秒影格，全部用 currentPB 補上
    private func emitSlots(upTo t: CMTime, inclusive: Bool) {
        guard let vi = videoInput, let ad = adaptor, let pb = currentPB, startTime.isValid else { return }
        while true {
            let st = slotTime(frameIndex)
            let c = CMTimeCompare(st, t)
            if c > 0 || (c == 0 && !inclusive) { break }
            if vi.isReadyForMoreMediaData {
                if !ad.append(pb, withPresentationTime: st) {
                    debugLog("寫入影格失敗（第 \(frameIndex) 格）：\(String(describing: writer?.error))")
                    recording = false   // 寫檔器已失敗，停止再寫
                    return
                }
            }   // 編碼器忙不過來時跳過這一格，但時間軸照走
            frameIndex += 1
        }
    }

    private func tick() {
        guard recording, startTime.isValid, ptsOffset.isValid else { return }
        // 留 2 格的緩衝，避免剛好晚到的新畫面被舊畫面搶先佔掉時間格
        let now = CMTimeAdd(hostNow(), ptsOffset)
        emitSlots(upTo: CMTimeSubtract(now, CMTime(value: 2, timescale: Recorder.fps)), inclusive: true)
    }

    private func setupWriter(firstFrame sb: CMSampleBuffer) {
        guard let url, let fd = CMSampleBufferGetFormatDescription(sb) else { return }
        let dim = CMVideoFormatDescriptionGetDimensions(fd)
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .mov)

            let vi = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,     // 想要檔案小一點可改 .hevc
                AVVideoWidthKey: Int(dim.width),
                AVVideoHeightKey: Int(dim.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 30_000_000,
                    AVVideoExpectedSourceFrameRateKey: Int(Recorder.fps),
                    AVVideoMaxKeyFrameIntervalKey: Int(Recorder.fps) * 2,
                ],
            ])
            vi.expectsMediaDataInRealTime = true
            // 錄影用自己的緩衝區池（固定尺寸與格式），不直接重複使用擷取裝置的緩衝區
            let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: Int(dim.width),
                kCVPixelBufferHeightKey as String: Int(dim.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
            // 影片座標 y 軸向下，順時針旋轉＝數學正方向
            vi.transform = quarterTurn(rotation)

            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            ai.expectsMediaDataInRealTime = true

            if w.canAdd(vi) { w.add(vi) }
            if w.canAdd(ai) { w.add(ai) }
            guard w.startWriting() else {
                debugLog("無法開始寫檔：\(String(describing: w.error))")
                recording = false
                return
            }
            startTime = CMSampleBufferGetPresentationTimeStamp(sb)
            w.startSession(atSourceTime: startTime)
            writer = w; videoInput = vi; adaptor = ad; audioInput = ai
            recordSize = CGSize(width: Int(dim.width), height: Int(dim.height))
            frameIndex = 0
        } catch {
            debugLog("建立 AVAssetWriter 失敗：\(error)")
            recording = false
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === videoOutput {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            ptsOffset = CMTimeSubtract(pts, hostNow())
            lastPixelBuffer = pb
            logFormatIfChanged(pb)
            let size = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
            if size != lastSize {
                lastSize = size
                let cb = onVideoSize
                DispatchQueue.main.async { cb?(size) }
            }
            previewSink?(sb)

            guard recording else { return }
            if writer == nil {
                setupWriter(firstFrame: sb)
                currentPB = copyForRecording(pb)
                emitSlots(upTo: pts, inclusive: true)   // 第 0 格
                return
            }
            emitSlots(upTo: pts, inclusive: false)       // 新畫面之前的格子用舊畫面補
            if let copy = copyForRecording(pb) { currentPB = copy }   // 尺寸不同時會自動縮放
            emitSlots(upTo: pts, inclusive: true)
        } else if output === audioOutput {
            guard recording, startTime.isValid,
                  let ai = audioInput, ai.isReadyForMoreMediaData else { return }
            if CMSampleBufferGetPresentationTimeStamp(sb) >= startTime { ai.append(sb) }
        }
    }
}

// MARK: - 可旋轉的預覽畫面

// 用 AVSampleBufferDisplayLayer 顯示：會依影格的色彩資訊做色彩管理，
// 亮度/色彩與 QuickTime 及錄出來的檔案一致（AVCaptureVideoPreviewLayer 中間調會偏亮）
final class PreviewView: NSView {
    let previewLayer = AVSampleBufferDisplayLayer()
    var rotation = 0 { didSet { relayout() } }

    /// 可在任意執行緒呼叫（這裡由擷取 queue 呼叫）
    func enqueue(_ sb: CMSampleBuffer) {
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if #available(macOS 14.0, *) {
            let r = previewLayer.sampleBufferRenderer
            if r.status == .failed { r.flush() }
            r.enqueue(sb)
        } else {
            if previewLayer.status == .failed { previewLayer.flush() }
            previewLayer.enqueue(sb)
        }
    }

    init() {
        super.init(frame: .zero)
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspect
        root.addSublayer(previewLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    func relayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        let swap = rotation % 2 == 1
        previewLayer.setAffineTransform(.identity)
        previewLayer.bounds = CGRect(x: 0, y: 0,
                                     width: swap ? b.height : b.width,
                                     height: swap ? b.width : b.height)
        previewLayer.position = CGPoint(x: b.midX, y: b.midY)
        // 預覽圖層座標 y 軸向上，順時針旋轉要用負方向
        previewLayer.setAffineTransform(quarterTurn(-rotation))
        CATransaction.commit()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let session = AVCaptureSession()
    let recorder = Recorder()
    let audioPreview = AVCaptureAudioPreviewOutput()

    var window: NSWindow!
    var preview: PreviewView!
    let statusLabel = NSTextField(labelWithString: "等待 iPad 連線…（請解鎖並信任這台電腦）")
    var recordButton: NSButton!
    var rotateLeftButton: NSButton!
    var rotateRightButton: NSButton!
    var monitorBox: NSButton!
    var volumeSlider: NSSlider!
    let volumeLabel = NSTextField(labelWithString: "100%")

    var currentDevice: AVCaptureDevice?
    var videoSize = CGSize.zero
    var rotation = 0                // 順時針 90° 的次數
    var isRecording = false
    var recordStart = Date()
    var clockTimer: Timer?
    var pollTimer: Timer?
    let barHeight: CGFloat = 44

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()

        enableScreenCaptureDevices()

        session.beginConfiguration()
        if session.canAddOutput(recorder.videoOutput) { session.addOutput(recorder.videoOutput) }
        if session.canAddOutput(recorder.audioOutput) { session.addOutput(recorder.audioOutput) }
        // 從 Mac 喇叭監聽 iPad 聲音（跟 QuickTime 一樣）
        if session.canAddOutput(audioPreview) { session.addOutput(audioPreview) }
        session.commitConfiguration()

        applyVolume()
        recorder.onVideoSize = { [weak self] size in self?.videoSizeChanged(size) }

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
                DispatchQueue.main.async { self.connectIfNeeded() }
            }
        }
        // 開啟擷取開關後，裝置要一兩秒才會出現；保險起見定時再找
        pollTimer = Timer.scheduledTimer(timeInterval: 2, target: self,
                                         selector: #selector(pollDevice), userInfo: nil, repeats: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isRecording else { return .terminateNow }
        recorder.stop { _ in NSApp.reply(toApplicationShouldTerminate: true) }   // 先把檔案收尾
        return .terminateLater
    }

    // MARK: 裝置

    @objc func pollDevice() { connectIfNeeded() }

    func connectIfNeeded() {
        guard currentDevice == nil, let dev = findIOSDevice() else { return }
        do {
            let input = try AVCaptureDeviceInput(device: dev)
            session.beginConfiguration()
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                statusLabel.stringValue = "無法加入裝置（可能被其他 App 佔用，例如 QuickTime / OBS）"
                return
            }
            session.addInput(input)
            session.commitConfiguration()
            currentDevice = dev
            statusLabel.stringValue = "已連線：\(dev.localizedName)"
            if !session.isRunning { session.startRunning() }
        } catch {
            statusLabel.stringValue = "無法開啟裝置：\(error.localizedDescription)"
        }
    }

    func deviceGone() {
        if isRecording { toggleRecord(nil) }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.commitConfiguration()
        currentDevice = nil
        statusLabel.stringValue = "裝置已中斷，等待重新連線…"
    }

    func videoSizeChanged(_ size: CGSize) {
        let first = videoSize == .zero
        videoSize = size
        if first { fitWindow() }
    }

    // MARK: 視窗

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720 + barHeight),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "PadCast"
        window.delegate = self
        window.contentMinSize = NSSize(width: 640, height: 300)
        let content = window.contentView!

        preview = PreviewView()
        let p = preview!
        recorder.previewSink = { sb in p.enqueue(sb) }
        preview.frame = NSRect(x: 0, y: barHeight, width: content.bounds.width,
                               height: content.bounds.height - barHeight)
        preview.autoresizingMask = [.width, .height]
        content.addSubview(preview)

        rotateLeftButton = NSButton(title: "↺ 向左轉", target: self, action: #selector(rotateLeft(_:)))
        rotateRightButton = NSButton(title: "↻ 向右轉", target: self, action: #selector(rotateRight(_:)))
        recordButton = NSButton(title: "● 錄影", target: self, action: #selector(toggleRecord(_:)))
        let shot = NSButton(title: "截圖", target: self, action: #selector(screenshot(_:)))
        monitorBox = NSButton(checkboxWithTitle: "監聽聲音", target: self, action: #selector(toggleMonitor(_:)))
        monitorBox.state = .on
        // 監聽音量（只影響 Mac 喇叭播放的大小，錄進檔案的聲音維持原音）
        let saved = UserDefaults.standard.object(forKey: "monitorVolume") as? Double ?? 1.0
        volumeSlider = NSSlider(value: saved, minValue: 0, maxValue: 1,
                                target: self, action: #selector(volumeChanged(_:)))
        volumeSlider.isContinuous = true
        volumeSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true
        volumeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        volumeLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [rotateLeftButton, rotateRightButton, recordButton, shot,
                                      monitorBox, volumeSlider, volumeLabel, statusLabel])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        bar.frame = NSRect(x: 0, y: 0, width: content.bounds.width, height: barHeight)
        bar.autoresizingMask = [.width, .maxYMargin]
        content.addSubview(bar)

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 依畫面比例（含旋轉）調整視窗大小
    func fitWindow() {
        guard videoSize.width > 0, let screen = window.screen ?? NSScreen.main else { return }
        var s = rotation % 2 == 1 ? CGSize(width: videoSize.height, height: videoSize.width) : videoSize
        let vf = screen.visibleFrame
        let scale = min(vf.width * 0.85 / s.width, (vf.height * 0.85 - barHeight) / s.height, 1)
        s = CGSize(width: (s.width * scale).rounded(), height: (s.height * scale).rounded())
        let old = window.frame
        window.setContentSize(NSSize(width: max(s.width, 640), height: s.height + barHeight))
        var f = window.frame
        f.origin.x = old.midX - f.width / 2
        f.origin.y = old.midY - f.height / 2
        window.setFrame(f, display: true)
        preview.relayout()
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "結束 PadCast", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        let ctlItem = NSMenuItem()
        main.addItem(ctlItem)
        let ctl = NSMenu(title: "控制")
        func add(_ title: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            it.target = self
            ctl.addItem(it)
        }
        let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        add("開始／停止錄影", #selector(toggleRecord(_:)), "r")
        add("截圖", #selector(screenshot(_:)), "s", [.command, .shift])
        ctl.addItem(.separator())
        add("向左旋轉", #selector(rotateLeft(_:)), left)
        add("向右旋轉", #selector(rotateRight(_:)), right)
        ctl.addItem(.separator())
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        add("監聽音量 +10%", #selector(volumeUp(_:)), up)
        add("監聽音量 −10%", #selector(volumeDown(_:)), down)
        add("監聽靜音／取消靜音", #selector(toggleMute(_:)), "m", [.command, .shift])
        ctlItem.submenu = ctl
        NSApp.mainMenu = main
    }

    // MARK: 動作

    @objc func rotateLeft(_ sender: Any?) { rotate(by: -1) }
    @objc func rotateRight(_ sender: Any?) { rotate(by: 1) }

    func rotate(by delta: Int) {
        guard !isRecording else { NSSound.beep(); return }   // 錄影中鎖定方向
        rotation = ((rotation + delta) % 4 + 4) % 4
        preview.rotation = rotation
        fitWindow()
    }

    @objc func volumeChanged(_ sender: Any?) {
        UserDefaults.standard.set(volumeSlider.doubleValue, forKey: "monitorVolume")
        applyVolume()
    }
    @objc func volumeUp(_ sender: Any?) {
        volumeSlider.doubleValue = min(1, volumeSlider.doubleValue + 0.1); volumeChanged(nil)
    }
    @objc func volumeDown(_ sender: Any?) {
        volumeSlider.doubleValue = max(0, volumeSlider.doubleValue - 0.1); volumeChanged(nil)
    }
    @objc func toggleMute(_ sender: Any?) {
        monitorBox.state = monitorBox.state == .on ? .off : .on; applyVolume()
    }
    func applyVolume() {
        let v = Float(volumeSlider.doubleValue)
        // 滑桿線性 → 聽感較自然的曲線
        audioPreview.volume = monitorBox.state == .on ? v * v : 0
        volumeLabel.stringValue = "\(Int((volumeSlider.doubleValue * 100).rounded()))%"
        volumeSlider.isEnabled = monitorBox.state == .on
    }

    @objc func toggleMonitor(_ sender: Any?) {
        applyVolume()
    }

    @objc func toggleRecord(_ sender: Any?) {
        if isRecording {
            recordButton.isEnabled = false
            clockTimer?.invalidate()
            recorder.stop { [weak self] url in
                guard let self else { return }
                self.isRecording = false
                self.recordButton.title = "● 錄影"
                self.recordButton.isEnabled = true
                self.rotateLeftButton.isEnabled = true
                self.rotateRightButton.isEnabled = true
                if let url {
                    self.statusLabel.stringValue = "已儲存：\(url.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    self.statusLabel.stringValue = "錄影失敗，或期間沒有收到畫面"
                }
            }
        } else {
            guard currentDevice != nil else { NSSound.beep(); return }
            recorder.start(url: outputURL(prefix: "錄影", ext: "mov"), rotation: rotation)
            isRecording = true
            recordStart = Date()
            recordButton.title = "■ 停止"
            rotateLeftButton.isEnabled = false
            rotateRightButton.isEnabled = false
            clockTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self,
                                              selector: #selector(tick), userInfo: nil, repeats: true)
            tick()
        }
    }

    @objc func tick() {
        let t = Int(Date().timeIntervalSince(recordStart))
        statusLabel.stringValue = String(format: "錄影中 %02d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }

    @objc func screenshot(_ sender: Any?) {
        guard let pb = recorder.latestFrame() else { NSSound.beep(); return }
        var img = CIImage(cvPixelBuffer: pb).transformed(by: quarterTurn(-rotation))   // CIImage y 軸向上
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        let url = outputURL(prefix: "截圖", ext: "png")
        do {
            try CIContext().writePNGRepresentation(of: img, to: url, format: .RGBA8,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            statusLabel.stringValue = "已截圖：\(url.lastPathComponent)"
        } catch {
            statusLabel.stringValue = "截圖失敗：\(error.localizedDescription)"
        }
    }

    func windowWillClose(_ notification: Notification) {
        if isRecording { NSApp.terminate(nil) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
