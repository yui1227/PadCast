// 共用工具函式
import Cocoa
import AVFoundation
import CoreMediaIO

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

/// 找系統預設的麥克風（排除 iPad 這種影音合一裝置）
func findMicrophone() -> AVCaptureDevice? {
    if let d = AVCaptureDevice.default(for: .audio), !d.hasMediaType(.muxed) { return d }
    let types: [AVCaptureDevice.DeviceType]
    if #available(macOS 14.0, *) { types = [.microphone] } else { types = [.builtInMicrophone, .externalUnknown] }
    return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified)
        .devices.first { !$0.hasMediaType(.muxed) }
}

/// 精確的 90° 倍數旋轉矩陣（數學正方向＝逆時針，k 個 90°）
func quarterTurn(_ k: Int) -> CGAffineTransform {
    let table: [(CGFloat, CGFloat)] = [(1, 0), (0, 1), (-1, 0), (0, -1)]
    let (c, s) = table[((k % 4) + 4) % 4]
    return CGAffineTransform(a: c, b: s, c: -s, d: c, tx: 0, ty: 0)
}

/// 輸出資料夾 ~/Movies/PadCast
var outputDirectory: URL {
    let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PadCast", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func outputURL(prefix: String, ext: String) -> URL {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH.mm.ss"
    return outputDirectory.appendingPathComponent("\(prefix) \(f.string(from: Date())).\(ext)")
}

func hostNow() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

/// 輸出資料夾所在磁碟的可用空間（位元組）
func freeDiskBytes() -> Int64 {
    let v = try? outputDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return v?.volumeAvailableCapacityForImportantUsage ?? 0
}

func fileSize(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
}

func formatBytes(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

func formatDuration(_ seconds: Int) -> String {
    String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
}

/// 把整個 sample buffer 的時間戳平移 offset（用來把麥克風時間對齊到 iPad 畫面的時間軸）
func retimed(_ sb: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
    var count: CMItemCount = 0
    CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
    guard count > 0 else { return nil }
    var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
    CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
    for i in 0..<count {
        timing[i].presentationTimeStamp = CMTimeAdd(timing[i].presentationTimeStamp, offset)
        if timing[i].decodeTimeStamp.isValid {
            timing[i].decodeTimeStamp = CMTimeAdd(timing[i].decodeTimeStamp, offset)
        }
    }
    var out: CMSampleBuffer?
    CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count,
                                          sampleTimingArray: &timing, sampleBufferOut: &out)
    return out
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
