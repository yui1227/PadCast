// 偏好設定（UserDefaults）與畫質參數
import Foundation
import AVFoundation

/// 錄影編碼設定
struct EncodeConfig: Equatable {
    var hevc = false
    var fps: Int32 = 60
    var quality = 2          // 0 低、1 中、2 高

    static let qualityNames = ["低", "中", "高"]

    var codec: AVVideoCodecType { hevc ? .hevc : .h264 }

    /// 依解析度與幀率估算位元率（HEVC 同畫質約省 40%）
    func bitrate(width: Int, height: Int) -> Int {
        let bitsPerPixel: [Double] = [0.035, 0.07, 0.12]
        var b = Double(width * height) * Double(fps) * bitsPerPixel[max(0, min(2, quality))]
        if hevc { b *= 0.6 }
        return max(2_000_000, Int(b))
    }

    var summary: String {
        "\(hevc ? "HEVC" : "H.264") \(fps)fps \(EncodeConfig.qualityNames[max(0, min(2, quality))])畫質"
    }
}

/// 所有要記住的設定
enum Prefs {
    private static let d = UserDefaults.standard

    static let replayChoices = [30, 60, 120, 300]   // 秒

    static func register() {
        d.register(defaults: [
            "hevc": false, "fps": 60, "quality": 2,
            "alwaysOnTop": false,
            "micEnabled": false,          // 麥克風預設關閉
            "replayEnabled": false, "replaySeconds": 60,
            "rotation": 0,
            "monitorOn": true, "monitorVolume": 1.0,
        ])
    }

    static var encode: EncodeConfig {
        get {
            EncodeConfig(hevc: d.bool(forKey: "hevc"),
                         fps: d.integer(forKey: "fps") == 30 ? 30 : 60,
                         quality: max(0, min(2, d.integer(forKey: "quality"))))
        }
        set {
            d.set(newValue.hevc, forKey: "hevc")
            d.set(Int(newValue.fps), forKey: "fps")
            d.set(newValue.quality, forKey: "quality")
        }
    }

    static var alwaysOnTop: Bool {
        get { d.bool(forKey: "alwaysOnTop") } set { d.set(newValue, forKey: "alwaysOnTop") }
    }
    static var micEnabled: Bool {
        get { d.bool(forKey: "micEnabled") } set { d.set(newValue, forKey: "micEnabled") }
    }
    static var replayEnabled: Bool {
        get { d.bool(forKey: "replayEnabled") } set { d.set(newValue, forKey: "replayEnabled") }
    }
    static var replaySeconds: Int {
        get { let v = d.integer(forKey: "replaySeconds"); return replayChoices.contains(v) ? v : 60 }
        set { d.set(newValue, forKey: "replaySeconds") }
    }
    static var rotation: Int {
        get { ((d.integer(forKey: "rotation") % 4) + 4) % 4 } set { d.set(newValue, forKey: "rotation") }
    }
    static var monitorOn: Bool {
        get { d.bool(forKey: "monitorOn") } set { d.set(newValue, forKey: "monitorOn") }
    }
    static var monitorVolume: Double {
        get { d.double(forKey: "monitorVolume") } set { d.set(newValue, forKey: "monitorVolume") }
    }
}
