// PadCast 錄影引擎自動測試：不需要 iPad，用合成的畫面與聲音跑過整條管線，再檢查輸出檔
// 執行：雙擊 Tests/run-tests.command，或 ./Tests/run-tests.sh
import Foundation
import AVFoundation

// MARK: - 合成樣本

let W = 1668, H = 1200          // 用接近 iPad 的比例，尺寸小一點跑比較快

func makePixelBuffer(luma: UInt8) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    let p = pb!
    CVPixelBufferLockBaseAddress(p, [])
    memset(CVPixelBufferGetBaseAddressOfPlane(p, 0), Int32(luma),
           CVPixelBufferGetBytesPerRowOfPlane(p, 0) * CVPixelBufferGetHeightOfPlane(p, 0))
    memset(CVPixelBufferGetBaseAddressOfPlane(p, 1), 128,
           CVPixelBufferGetBytesPerRowOfPlane(p, 1) * CVPixelBufferGetHeightOfPlane(p, 1))
    CVPixelBufferUnlockBaseAddress(p, [])
    CVBufferSetAttachment(p, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(p, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(p, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    return p
}

func makeVideoSample(_ pb: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer {
    var fd: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fd)
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fd!,
                                             sampleTiming: &timing, sampleBufferOut: &sb)
    return sb!
}

func makeAudioSample(channels: Int, frames: Int, pts: CMTime, freq: Double, startFrame: Int) -> CMSampleBuffer {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(2 * channels),
        mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
    var fmt: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                   magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
    var samples = [Int16](repeating: 0, count: frames * channels)
    for f in 0..<frames {
        let v = Int16(8000 * sin(2 * .pi * freq * Double(startFrame + f) / 48_000))
        for c in 0..<channels { samples[f * channels + c] = v }
    }
    let bytes = samples.count * 2
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                       customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                       flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
    samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!,
                                                                 offsetIntoDestination: 0, dataLength: bytes) }
    var sb: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: fmt!,
                                                         sampleCount: frames, presentationTimeStamp: pts,
                                                         packetDescriptions: nil, sampleBufferOut: &sb)
    return sb!
}

// MARK: - 模擬 iPad：畫面不規則送出（中間有一段靜止）、聲音連續、麥克風連續

final class Feeder {
    private let rec: Recorder
    private let staticFrom: Double, staticTo: Double, mic: Bool
    private let lock = NSLock()
    private var _running = true
    private var running: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _running }
        set { lock.lock(); _running = newValue; lock.unlock() }
    }

    /// staticFrom..<staticTo 秒之間不送畫面（模擬畫面靜止），其餘約 40fps
    init(rec: Recorder, staticFrom: Double, staticTo: Double, mic: Bool) {
        self.rec = rec
        self.staticFrom = staticFrom
        self.staticTo = staticTo
        self.mic = mic
        Thread.detachNewThread { [self] in run() }
    }

    private func run() {
        let start = hostNow()
        let frames = (0..<8).map { makePixelBuffer(luma: UInt8(30 + $0 * 25)) }
        var nextVideo = 0.0, audioFrames = 0, micFrames = 0, n = 0
        while running {
            let t = CMTimeSubtract(hostNow(), start).seconds
            if t >= nextVideo {
                if !(t >= staticFrom && t < staticTo) {
                    rec.ingest(video: makeVideoSample(frames[n % frames.count], pts: hostNow()))
                    n += 1
                }
                nextVideo += 0.025
            }
            // 聲音依樣本數排時間，確保連續
            while Double(audioFrames) / 48_000 <= t {
                let pts = CMTimeAdd(start, CMTime(value: CMTimeValue(audioFrames), timescale: 48_000))
                rec.ingest(audio: makeAudioSample(channels: 2, frames: 1024, pts: pts, freq: 440,
                                                  startFrame: audioFrames))
                audioFrames += 1024
            }
            while mic && Double(micFrames) / 48_000 <= t {
                let pts = CMTimeAdd(start, CMTime(value: CMTimeValue(micFrames), timescale: 48_000))
                rec.ingest(mic: makeAudioSample(channels: 1, frames: 960, pts: pts, freq: 660,
                                                startFrame: micFrames))
                micFrames += 960
            }
            Thread.sleep(forTimeInterval: 0.003)
        }
    }

    func stop() { running = false }
}

// MARK: - 小工具

var failures = 0
var log = ""
func report(_ s: String) { print(s); log += s + "\n" }
func check(_ ok: Bool, _ what: String) {
    report((ok ? "  ✅ " : "  ❌ ") + what)
    if !ok { failures += 1 }
}

/// 跑主執行緒的 run loop（callback 都用 DispatchQueue.main）
func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
func waitUntil(timeout: Double = 30, _ cond: () -> Bool) {
    let end = Date().addingTimeInterval(timeout)
    while !cond() && Date() < end { spin(0.05) }
}

struct FileInfo {
    var duration = 0.0
    var videoFrames = 0
    var nominalFPS: Float = 0
    var codec = ""
    var size = CGSize.zero
    var transform = CGAffineTransform.identity
    var audioTracks = 0
    var maxGap = 0.0          // 相鄰影格最大間隔（秒）
}

func inspect(_ url: URL) async throws -> FileInfo {
    let asset = AVURLAsset(url: url)
    var info = FileInfo()
    info.duration = try await asset.load(.duration).seconds
    info.audioTracks = try await asset.loadTracks(withMediaType: .audio).count
    guard let v = try await asset.loadTracks(withMediaType: .video).first else { return info }
    info.nominalFPS = try await v.load(.nominalFrameRate)
    info.size = try await v.load(.naturalSize)
    info.transform = try await v.load(.preferredTransform)
    if let fd = try await v.load(.formatDescriptions).first {
        let st = CMFormatDescriptionGetMediaSubType(fd)
        info.codec = String(bytes: [24, 16, 8, 0].map { UInt8((st >> $0) & 0xff) }, encoding: .ascii) ?? "?"
    }
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: v, outputSettings: nil)
    reader.add(out)
    reader.startReading()
    var times: [Double] = []
    while let sb = out.copyNextSampleBuffer() {
        guard CMSampleBufferGetNumSamples(sb) > 0 else { continue }
        info.videoFrames += 1
        times.append(CMSampleBufferGetPresentationTimeStamp(sb).seconds)
    }
    // 讀出來是解碼順序（有 B-frame 時會亂序），依顯示時間排序後再算間隔
    times.sort()
    for i in times.indices.dropFirst() { info.maxGap = max(info.maxGap, times[i] - times[i - 1]) }
    return info
}

func inspectSync(_ url: URL) -> FileInfo {
    var result = FileInfo()
    var done = false
    Task {
        do { result = try await inspect(url) } catch { report("  讀檔失敗：\(error)") }
        done = true
    }
    waitUntil { done }
    return result
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "test-output")
try? FileManager.default.removeItem(at: outDir)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// MARK: - 測試 1：一般錄影 H.264 60fps，含靜止段、麥克風音軌、旋轉 90°

do {
    report("【測試 1】錄影 H.264 60fps + 麥克風 + 右轉 90°（中間 1.5 秒畫面靜止）")
    let rec = Recorder()
    rec.apply(config: EncodeConfig(hevc: false, fps: 60, quality: 2))
    rec.setMic(true, useDevice: false)
    let feeder = Feeder(rec: rec, staticFrom: 2.0, staticTo: 3.5, mic: true)
    spin(0.5)
    let url = outDir.appendingPathComponent("test1.mov")
    rec.startRecording(url: url, rotation: 1)
    spin(5)
    var result: URL?? = nil
    rec.stopRecording { result = .some($0) }
    waitUntil { result != nil }
    feeder.stop()
    check(result! != nil, "錄影檔寫入成功")
    let i = inspectSync(url)
    report(String(format: "     長度 %.2fs、%d 格、標稱 %.1f fps、%@、%dx%d、音軌 %d 條、最大間隔 %.3fs",
                  i.duration, i.videoFrames, i.nominalFPS, i.codec, Int(i.size.width), Int(i.size.height),
                  i.audioTracks, i.maxGap))
    check(abs(i.duration - 5) < 0.3, "長度約 5 秒")
    check(abs(Double(i.videoFrames) - i.duration * 60) <= 3, "格數 ≈ 長度 × 60（固定幀率，靜止段有補格）")
    check(i.maxGap < 1.0 / 60 + 0.002, "沒有掉格（相鄰影格間隔都是 1/60 秒）")
    check(i.codec == "avc1", "編碼是 H.264")
    check(i.audioTracks == 2, "有 iPad 與麥克風兩條音軌")
    check(i.transform.b == 1 && i.transform.c == -1, "旋轉資訊為順時針 90°")
}

// MARK: - 測試 2：HEVC 30fps、低畫質、無麥克風

do {
    report("【測試 2】錄影 HEVC 30fps 低畫質、不錄麥克風")
    let rec = Recorder()
    rec.apply(config: EncodeConfig(hevc: true, fps: 30, quality: 0))
    let feeder = Feeder(rec: rec, staticFrom: 99, staticTo: 99, mic: true)
    spin(0.3)
    let url = outDir.appendingPathComponent("test2.mov")
    rec.startRecording(url: url, rotation: 0)
    spin(3)
    var result: URL?? = nil
    rec.stopRecording { result = .some($0) }
    waitUntil { result != nil }
    feeder.stop()
    check(result! != nil, "錄影檔寫入成功")
    let i = inspectSync(url)
    report(String(format: "     長度 %.2fs、%d 格、標稱 %.1f fps、%@、音軌 %d 條",
                  i.duration, i.videoFrames, i.nominalFPS, i.codec, i.audioTracks))
    check(i.codec == "hvc1" || i.codec == "hev1", "編碼是 HEVC")
    check(abs(Double(i.videoFrames) - i.duration * 30) <= 2, "格數 ≈ 長度 × 30")
    check(i.audioTracks == 1, "麥克風關閉時只有一條音軌")
}

// MARK: - 測試 3：重播緩衝（每段 2 秒、保留 5 秒），同時進行一般錄影

do {
    report("【測試 3】重播緩衝保留最近 5 秒（每段 2 秒），同時一般錄影")
    Recorder.segmentSeconds = 2
    let rec = Recorder()
    rec.apply(config: EncodeConfig(hevc: false, fps: 60, quality: 1))
    rec.setMic(true, useDevice: false)
    rec.setReplay(enabled: true, seconds: 5)
    let feeder = Feeder(rec: rec, staticFrom: 4.0, staticTo: 5.0, mic: true)
    spin(1)
    let recURL = outDir.appendingPathComponent("test3-recording.mov")
    rec.startRecording(url: recURL, rotation: 0)
    spin(8)
    let buffered = rec.replayBufferedSeconds()
    report(String(format: "     緩衝中 %.1f 秒", buffered))
    check(abs(buffered - 5) < 0.5, "緩衝秒數達到上限 5 秒")

    let replayURL = outDir.appendingPathComponent("test3-replay.mov")
    var saved: (URL?, String?)? = nil
    rec.saveReplay(rotation: 3, to: replayURL) { saved = ($0, $1) }
    waitUntil { saved != nil }
    check(saved?.0 != nil, "重播存檔成功\(saved?.1.map { "（\($0)）" } ?? "")")
    let r = inspectSync(replayURL)
    report(String(format: "     重播長度 %.2fs、%d 格、音軌 %d 條、最大間隔 %.3fs",
                  r.duration, r.videoFrames, r.audioTracks, r.maxGap))
    check(abs(r.duration - 5) < 0.6, "重播長度約 5 秒")
    check(r.audioTracks == 2, "重播也有兩條音軌")
    check(r.transform.b == -1 && r.transform.c == 1, "重播套用存檔當下的旋轉（左轉 90°）")
    check(r.maxGap < 1.0 / 60 + 0.002, "分段接縫沒有斷格（相鄰影格間隔都是 1/60 秒）")

    // 再存一次（連續存兩次也要正常）
    spin(2)
    let replay2 = outDir.appendingPathComponent("test3-replay2.mov")
    saved = nil
    rec.saveReplay(rotation: 0, to: replay2) { saved = ($0, $1) }
    waitUntil { saved != nil }
    check(saved?.0 != nil, "第二次重播存檔成功")

    var result: URL?? = nil
    rec.stopRecording { result = .some($0) }
    waitUntil { result != nil }
    check(result! != nil, "重播緩衝運作中，一般錄影也正常")
    let m = inspectSync(recURL)
    check(abs(Double(m.videoFrames) - m.duration * 60) <= 3, String(format: "一般錄影仍是固定 60fps（%.2fs / %d 格）", m.duration, m.videoFrames))

    rec.setReplay(enabled: false, seconds: 5)
    spin(0.5)
    feeder.stop()
    let segDir = FileManager.default.temporaryDirectory.appendingPathComponent("PadCastReplay")
    let left = (try? FileManager.default.contentsOfDirectory(atPath: segDir.path))?.count ?? 0
    check(left == 0, "關閉重播緩衝後暫存分段已清除（剩 \(left) 個）")
}

report(failures == 0 ? "\n全部通過 🎉" : "\n有 \(failures) 項失敗")
try? log.write(to: outDir.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
exit(failures == 0 ? 0 : 1)
