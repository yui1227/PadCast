// 寫入單一影片檔：固定幀率（畫面沒變時補上重複影格）、iPad 音軌、可選的麥克風音軌
// 一般錄影與重播緩衝的每一段都用這個類別。只能在 Recorder 的 queue 上使用。
import Foundation
import AVFoundation

final class SegmentWriter {
    let url: URL
    let startTime: CMTime
    let fps: Int32
    let hasMic: Bool
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput
    private let micInput: AVAssetWriterInput?
    private(set) var frameIndex: Int64 = 0
    private(set) var failed = false

    // 編碼器暫時忙碌（例如剛啟動）時先排隊，等它準備好再寫，避免掉格／掉聲音
    private var pendingFrames: [(CVPixelBuffer, CMTime)] = []
    private var pendingAudio: [CMSampleBuffer] = []
    private var pendingMic: [CMSampleBuffer] = []
    private static let maxPendingFrames = 45
    private static let maxPendingAudio = 100
    private(set) var droppedFrames = 0

    /// - transform: 寫進影片軌的旋轉資訊（重播片段用 identity，輸出時才套用）
    init(url: URL, start: CMTime, size: CGSize, config: EncodeConfig,
         transform: CGAffineTransform, mic: Bool) throws {
        self.url = url
        self.startTime = start
        self.fps = config.fps
        self.hasMic = mic
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let w = Int(size.width), h = Int(size.height)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: config.codec,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: config.bitrate(width: w, height: h),
                AVVideoExpectedSourceFrameRateKey: Int(config.fps),
                AVVideoMaxKeyFrameIntervalKey: Int(config.fps) * 2,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        videoInput.transform = transform
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,
                                                       sourcePixelBufferAttributes: nil)

        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ])
        audioInput.expectsMediaDataInRealTime = true

        if mic {
            let m = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ])
            m.expectsMediaDataInRealTime = true
            micInput = m
        } else {
            micInput = nil
        }

        for input in [videoInput, audioInput] + (micInput.map { [$0] } ?? []) where writer.canAdd(input) {
            writer.add(input)
        }
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "PadCast", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "無法開始寫檔"])
        }
        writer.startSession(atSourceTime: start)
    }

    var duration: CMTime { CMTime(value: frameIndex, timescale: fps) }
    var nextSlot: CMTime { CMTimeAdd(startTime, duration) }
    var bytesWritten: Int64 { fileSize(url) }

    /// 把時間 t 之前（含/不含 t）尚未寫出的影格，全部用 frame 補上
    func emit(upTo t: CMTime, inclusive: Bool, frame: CVPixelBuffer?) {
        guard !failed, let frame else { return }
        while true {
            let slot = nextSlot
            let c = CMTimeCompare(slot, t)
            if c > 0 || (c == 0 && !inclusive) { break }
            pendingFrames.append((frame, slot))
            frameIndex += 1
        }
        drain()
    }

    func appendAudio(_ sb: CMSampleBuffer) {
        guard !failed, CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sb), startTime) >= 0 else { return }
        pendingAudio.append(sb)
        drain()
    }

    func appendMic(_ sb: CMSampleBuffer) {
        guard !failed, micInput != nil,
              CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sb), startTime) >= 0 else { return }
        pendingMic.append(sb)
        drain()
    }

    /// 把排隊中的資料寫進去（編碼器準備好多少就寫多少）
    func drain() {
        guard !failed else { return }
        while let next = pendingFrames.first, videoInput.isReadyForMoreMediaData {
            pendingFrames.removeFirst()
            let (pb, t) = next
            if !adaptor.append(pb, withPresentationTime: t) {
                debugLog("寫入影格失敗（\(url.lastPathComponent) \(t.seconds)）：\(String(describing: writer.error))")
                failed = true
                return
            }
        }
        while let sb = pendingAudio.first, audioInput.isReadyForMoreMediaData {
            pendingAudio.removeFirst()
            audioInput.append(sb)
        }
        if let micInput {
            while let sb = pendingMic.first, micInput.isReadyForMoreMediaData {
                pendingMic.removeFirst()
                micInput.append(sb)
            }
        }
        // 真的忙不過來時才丟掉最舊的，避免記憶體無限增加
        if pendingFrames.count > Self.maxPendingFrames {
            let n = pendingFrames.count - Self.maxPendingFrames
            pendingFrames.removeFirst(n)
            droppedFrames += n
        }
        if pendingAudio.count > Self.maxPendingAudio { pendingAudio.removeFirst(pendingAudio.count - Self.maxPendingAudio) }
        if pendingMic.count > Self.maxPendingAudio { pendingMic.removeFirst(pendingMic.count - Self.maxPendingAudio) }
    }

    /// 收尾；done 會在任意執行緒被呼叫
    func finish(_ done: @escaping (Bool) -> Void) {
        guard !failed, frameIndex > 0, writer.status == .writing else {
            if writer.status == .failed { debugLog("寫檔失敗：\(String(describing: writer.error))") }
            cancel()
            done(false)
            return
        }
        // 收尾前把排隊中的資料寫完（最多等 1 秒）
        let deadline = Date().addingTimeInterval(1)
        drain()
        while !(pendingFrames.isEmpty && pendingAudio.isEmpty && pendingMic.isEmpty) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
            drain()
        }
        if droppedFrames > 0 { debugLog("\(url.lastPathComponent)：編碼器忙碌，丟棄 \(droppedFrames) 格") }
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        micInput?.markAsFinished()
        writer.endSession(atSourceTime: nextSlot)   // 以影像長度為準，切齊多出來的聲音
        writer.finishWriting { [writer] in
            if writer.status != .completed { debugLog("寫檔失敗：\(String(describing: writer.error))") }
            done(writer.status == .completed)
        }
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}
