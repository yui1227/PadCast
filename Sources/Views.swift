// 畫面相關的小元件：可旋轉的預覽、追蹤滑鼠的內容視圖、錄影指示標籤
import Cocoa
import AVFoundation

/// 用 AVSampleBufferDisplayLayer 顯示：會依影格的色彩資訊做色彩管理，
/// 亮度/色彩與 QuickTime 及錄出來的檔案一致（AVCaptureVideoPreviewLayer 中間調會偏亮）
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

/// 追蹤滑鼠移動/離開的內容視圖（自動隱藏介面用）
final class HoverView: NSView {
    var onMove: ((NSPoint) -> Void)?
    var onExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    override func mouseMoved(with e: NSEvent) { onMove?(convert(e.locationInWindow, from: nil)) }
    override func mouseEntered(with e: NSEvent) { onMove?(convert(e.locationInWindow, from: nil)) }
    override func mouseExited(with e: NSEvent) { onExit?() }
}

/// 右上角的狀態標籤（錄影中顯示時間與檔案大小，不會跟著介面隱藏）
final class BadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        layer?.cornerRadius = 7
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        addSubview(label)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 依內容調整大小，並貼齊父視圖右上角
    func show(_ text: NSAttributedString?) {
        guard let text, let sv = superview else { isHidden = true; return }
        label.attributedStringValue = text
        label.sizeToFit()
        let pad = NSSize(width: 10, height: 5)
        let size = NSSize(width: label.frame.width + pad.width * 2, height: label.frame.height + pad.height * 2)
        frame = NSRect(x: sv.bounds.width - size.width - 12, y: sv.bounds.height - size.height - 34,
                       width: size.width, height: size.height)
        label.frame.origin = NSPoint(x: pad.width, y: pad.height)
        isHidden = false
    }
}
