// 擷取管線：接收 iPad 畫面/聲音與麥克風，送給預覽、一般錄影與重播緩衝
//
// 時間軸：每格畫面先複製到自己的緩衝區池（避免重複使用擷取裝置的緩衝區），
// 再由各個 SegmentWriter 以固定幀率寫出；畫面沒變時由計時器補上重複影格。
// 重播緩衝：背景每 10 秒切一段小檔，只保留最近 N 秒，存檔時再合併輸出。
import Foundation
import AVFoundation
import VideoToolbox

final class Recorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                      AVCaptureAudioDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "padcast.samples")
    let videoOutput = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()
    let micOutput = AVCaptureAudioDataOutput()
    private let micSession = AVCaptureSession()
    private var micConfigured = false            // 只在主執行緒存取

    /// 以下 callback 都在主執行緒呼叫
    var onVideoSize: ((CGSize) -> Void)?
    var onRecordingError: ((String) -> Void)?
    /// 每一格都送給預覽（在 queue 上呼叫）
    var previewSink: ((CMSampleBuffer) -> Void)?

    static var segmentSeconds = 10.0     // 重播緩衝每段長度（測試時會調短）

    // MARK: 以下只在 queue 上存取
    private var config = EncodeConfig()
    private var micOn = false
    private var ptsOffset = CMTime.invalid       // 影格時間戳 − 主機時鐘
    private var micOffset = CMTime.invalid       // 麥克風時間 → 畫面時間軸
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastSize = CGSize.zero
    private var lastFormatSig = ""
    private var current: CVPixelBuffer?          // 目前要寫出的畫面（自己的緩衝區）
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private var transfer: VTPixelTransferSession?
    private var timer: DispatchSourceTimer?

    private var mainWriter: SegmentWriter?
    private var mainPending: (url: URL, rotation: Int)?

    private var replayOn = false
    private var replaySeconds = 60
    private var replayWriter: SegmentWriter?
    private var replaySegments: [(url: URL, duration: CMTime)] = []
    private let replayGroup = DispatchGroup()
    private var exporting = 0
    private var segCounter = 0
    private let replayDir: URL

    override init() {
        replayDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PadCastReplay", isDirectory: true)
        try? FileManager.default.removeItem(at: replayDir)
        try? FileManager.default.createDirectory(at: replayDir, withIntermediateDirectories: true)
        super.init()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        audioOutput.setSampleBufferDelegate(self, queue: queue)
        micOutput.setSampleBufferDelegate(self, queue: queue)
    }

    // MARK: - 對外介面（主執行緒呼叫）

    func apply(config: EncodeConfig) { queue.async { self.config = config } }

    /// 麥克風開關；回傳是否成功開啟（useDevice: false 只切換錄音軌，給測試用）
    @discardableResult
    func setMic(_ on: Bool, useDevice: Bool = true) -> Bool {
        guard useDevice else {
            queue.async {
                if on != self.micOn { self.micOffset = .invalid }
                self.micOn = on
            }
            return true
        }
        if on && !micConfigured {
            guard let dev = findMicrophone(), let input = try? AVCaptureDeviceInput(device: dev) else {
                debugLog("找不到可用的麥克風")
                return false
            }
            micSession.beginConfiguration()
            if micSession.canAddInput(input) { micSession.addInput(input) }
            if micSession.canAddOutput(micOutput) { micSession.addOutput(micOutput) }
            micSession.commitConfiguration()
            micConfigured = true
            debugLog("麥克風：\(dev.localizedName)")
        }
        let s = micSession
        DispatchQueue.global(qos: .userInitiated).async {
            if on { if !s.isRunning { s.startRunning() } } else if s.isRunning { s.stopRunning() }
        }
        queue.async {
            if on != self.micOn { self.micOffset = .invalid }   // 只有剛打開時重新對時，避免時間倒退
            self.micOn = on
        }
        return true
    }

    func startRecording(url: URL, rotation: Int) {
        queue.async {
            self.mainPending = (url, rotation)
            self.ensureTimer()
        }
    }

    func stopRecording(_ done: @escaping (URL?) -> Void) {
        queue.async {
            self.mainPending = nil
            guard let w = self.mainWriter else {
                DispatchQueue.main.async { done(nil) }
                return
            }
            self.mainWriter = nil
            if let now = self.nowPTS() { w.emit(upTo: now, inclusive: true, frame: self.current) }
            w.finish { ok in DispatchQueue.main.async { done(ok ? w.url : nil) } }
            self.stopTimerIfIdle()
        }
    }

    func setReplay(enabled: Bool, seconds: Int) {
        queue.async {
            self.replaySeconds = seconds
            if enabled == self.replayOn { self.pruneReplay(); return }
            self.replayOn = enabled
            if enabled {
                self.ensureTimer()
            } else {
                self.resetReplay()
                self.stopTimerIfIdle()
            }
        }
    }

    /// 目前重播緩衝裡有幾秒可以存
    func replayBufferedSeconds() -> Double {
        queue.sync {
            let done = replaySegments.reduce(0.0) { $0 + $1.duration.seconds }
            return min(Double(replaySeconds), done + (replayWriter?.duration.seconds ?? 0))
        }
    }

    /// 把最近 N 秒存成影片；done 在主執行緒呼叫（成功的 URL 或錯誤訊息）
    func saveReplay(rotation: Int, to url: URL, done: @escaping (URL?, String?) -> Void) {
        queue.async {
            guard self.replayOn else {
                DispatchQueue.main.async { done(nil, "重播緩衝沒有開啟") }
                return
            }
            if let w = self.replayWriter { self.cutReplaySegment(w) }   // 把正在錄的這段也收進來
            self.exporting += 1
            self.replayGroup.notify(queue: self.queue) {
                let segs = self.replaySegments
                guard !segs.isEmpty else {
                    self.exporting -= 1
                    DispatchQueue.main.async { done(nil, "重播緩衝裡還沒有畫面") }
                    return
                }
                ReplayExporter.export(segments: segs, lastSeconds: self.replaySeconds,
                                      rotation: rotation, to: url) { result, err in
                    self.queue.async { self.exporting -= 1; self.pruneReplay() }
                    DispatchQueue.main.async { done(result, err) }
                }
            }
        }
    }

    func latestFrame() -> CVPixelBuffer? { queue.sync { lastPixelBuffer } }

    // MARK: - 擷取 callback

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === videoOutput { handleVideo(sb) }
        else if output === audioOutput { handleAudio(sb) }
        else if output === micOutput { handleMic(sb) }
    }

    /// 直接送入樣本（自動測試用；正式執行時由上面的 captureOutput 呼叫）
    func ingest(video sb: CMSampleBuffer) { queue.async { self.handleVideo(sb) } }
    func ingest(audio sb: CMSampleBuffer) { queue.async { self.handleAudio(sb) } }
    func ingest(mic sb: CMSampleBuffer) { queue.async { self.handleMic(sb) } }

    private var needsFrames: Bool { mainWriter != nil || mainPending != nil || replayOn }
    private var writers: [SegmentWriter] { [mainWriter, replayWriter].compactMap { $0 } }

    private func handleVideo(_ sb: CMSampleBuffer) {
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

        guard needsFrames else { current = nil; return }
        // 解析度變了（iPad 轉向）：沒有在錄影時重建緩衝區池與重播緩衝；錄影中則縮放進原尺寸
        if size != poolSize && mainWriter == nil {
            resetReplay()
            pool = nil
            poolSize = .zero
            current = nil
        }
        let copy = copyFrame(pb)
        for w in writers { w.emit(upTo: pts, inclusive: false, frame: current) }   // 新畫面之前用舊畫面補
        if let copy { current = copy }
        startPending(at: pts)
        for w in writers { w.emit(upTo: pts, inclusive: true, frame: current) }
        maintain()
    }

    private func handleAudio(_ sb: CMSampleBuffer) {
        mainWriter?.appendAudio(sb)
        replayWriter?.appendAudio(sb)
    }

    private func handleMic(_ sb: CMSampleBuffer) {
        guard micOn else { return }
        if !micOffset.isValid {
            guard ptsOffset.isValid else { return }
            // 麥克風與 iPad 不一定用同一個時鐘：各自量出「時間戳 − 主機時鐘」再換算。
            // 只在第一個樣本量一次就固定，避免每格抖動造成時間倒退
            let micClock = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sb), hostNow())
            micOffset = CMTimeSubtract(ptsOffset, micClock)
            debugLog(String(format: "麥克風對時：iPad 時鐘差 %.3fs、麥克風時鐘差 %.3fs、修正 %.3fs",
                            ptsOffset.seconds, micClock.seconds, micOffset.seconds))
        }
        guard let r = retimed(sb, by: micOffset) else { return }
        mainWriter?.appendMic(r)
        replayWriter?.appendMic(r)
    }

    // MARK: - 計時器（補格）

    private func nowPTS() -> CMTime? {
        ptsOffset.isValid ? CMTimeAdd(hostNow(), ptsOffset) : nil
    }

    private func tick() {
        guard let now = nowPTS() else { return }
        // 留 2 格（60fps）的緩衝，避免剛好晚到的新畫面被舊畫面搶先佔掉時間格
        let t = CMTimeSubtract(now, CMTime(value: 2, timescale: 60))
        startPending(at: t)
        for w in writers { w.emit(upTo: t, inclusive: true, frame: current) }   // emit 也會順便 drain
        maintain()
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stopTimerIfIdle() {
        guard !needsFrames else { return }
        timer?.cancel()
        timer = nil
        current = nil
    }

    // MARK: - 寫檔器管理

    private func startPending(at t: CMTime) {
        guard current != nil, poolSize != .zero else { return }
        if let p = mainPending {
            mainPending = nil
            do {
                mainWriter = try SegmentWriter(url: p.url, start: t, size: poolSize, config: config,
                                               transform: quarterTurn(p.rotation), mic: micOn)
                debugLog("開始錄影：\(config.summary) \(Int(poolSize.width))x\(Int(poolSize.height))\(micOn ? " +麥克風" : "")")
            } catch {
                debugLog("無法開始錄影：\(error)")
                let cb = onRecordingError
                DispatchQueue.main.async { cb?("無法開始錄影：\(error.localizedDescription)") }
            }
        }
        if replayOn && replayWriter == nil { replayWriter = makeReplayWriter(start: t) }
    }

    /// 檢查寫檔器狀態、重播緩衝切段
    private func maintain() {
        if let m = mainWriter, m.failed {
            mainWriter = nil
            m.cancel()
            let cb = onRecordingError
            DispatchQueue.main.async { cb?("錄影失敗，詳見 debug.log") }
        }
        if let w = replayWriter {
            if w.failed {
                replayWriter = nil      // 下一格會重開一段
                w.cancel()
            } else if w.duration.seconds >= Self.segmentSeconds {
                cutReplaySegment(w)
            }
        }
    }

    // MARK: - 重播緩衝

    private func makeReplayWriter(start: CMTime) -> SegmentWriter? {
        guard poolSize != .zero else { return nil }
        segCounter += 1
        let url = replayDir.appendingPathComponent("seg-\(segCounter).mov")
        do {
            return try SegmentWriter(url: url, start: start, size: poolSize, config: config,
                                     transform: .identity, mic: micOn)
        } catch {
            debugLog("重播緩衝無法建立分段：\(error)")
            return nil
        }
    }

    /// 結束目前這段，並從同一個時間點接著開新的一段
    private func cutReplaySegment(_ w: SegmentWriter) {
        let next = w.nextSlot
        replayWriter = makeReplayWriter(start: next)
        replayGroup.enter()
        w.finish { ok in
            self.queue.async {
                if ok {
                    self.replaySegments.append((w.url, w.duration))
                    self.pruneReplay()
                } else {
                    try? FileManager.default.removeItem(at: w.url)
                }
                self.replayGroup.leave()
            }
        }
    }

    /// 只保留足夠涵蓋最近 N 秒的分段（正在輸出時先不刪）
    private func pruneReplay() {
        guard exporting == 0 else { return }
        while replaySegments.count > 1 {
            let total = replaySegments.reduce(0.0) { $0 + $1.duration.seconds }
            guard total - replaySegments[0].duration.seconds >= Double(replaySeconds) else { break }
            let old = replaySegments.removeFirst()
            try? FileManager.default.removeItem(at: old.url)
        }
    }

    private func resetReplay() {
        if let w = replayWriter {
            replayWriter = nil
            w.cancel()
        }
        if exporting == 0 {
            for s in replaySegments { try? FileManager.default.removeItem(at: s.url) }
        }
        replaySegments.removeAll()
    }

    // MARK: - 畫面複製

    /// 複製到自己的緩衝區池（必要時縮放/轉格式），不直接重複使用擷取裝置的緩衝區
    private func copyFrame(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        if pool == nil {
            let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p
            poolSize = CGSize(width: w, height: h)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let dst = out else {
            return nil
        }
        if transfer == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) }
        guard let transfer else { return nil }
        let st = VTPixelTransferSessionTransferImage(transfer, from: src, to: dst)
        if st != noErr { debugLog("複製畫面失敗：\(st)"); return nil }
        CVBufferPropagateAttachments(src, dst)   // 保留色彩資訊
        return dst
    }

    private func logFormatIfChanged(_ pb: CVPixelBuffer) {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let fourcc = String(bytes: [24, 16, 8, 0].map { UInt8((fmt >> $0) & 0xff) }, encoding: .ascii) ?? "\(fmt)"
        func att(_ k: CFString) -> String { (CVBufferCopyAttachment(pb, k, nil) as? String) ?? "-" }
        let sig = "\(fourcc) \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) " +
            "primaries=\(att(kCVImageBufferColorPrimariesKey)) transfer=\(att(kCVImageBufferTransferFunctionKey)) " +
            "matrix=\(att(kCVImageBufferYCbCrMatrixKey))"
        if sig != lastFormatSig { lastFormatSig = sig; debugLog("畫面格式：\(sig)") }
    }
}
