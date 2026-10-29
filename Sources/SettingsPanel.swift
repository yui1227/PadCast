// 設定面板（從控制列的齒輪按鈕彈出）：畫質、重播緩衝、麥克風、視窗置頂
import Cocoa

final class SettingsViewController: NSViewController {
    /// 任何設定改變時呼叫（設定已寫進 Prefs）
    var onChange: (() -> Void)?

    private let codec = NSPopUpButton()
    private let fps = NSPopUpButton()
    private let quality = NSPopUpButton()
    private let replayBox = NSButton(checkboxWithTitle: "開啟（背景持續保留最近一段）", target: nil, action: nil)
    private let replayLen = NSPopUpButton()
    private let micBox = NSButton(checkboxWithTitle: "同時錄 Mac 麥克風（獨立音軌）", target: nil, action: nil)
    private let topBox = NSButton(checkboxWithTitle: "視窗置頂", target: nil, action: nil)

    override func loadView() {
        codec.addItems(withTitles: ["H.264（相容性最好）", "HEVC（檔案約小一半）"])
        fps.addItems(withTitles: ["30 fps", "60 fps"])
        quality.addItems(withTitles: EncodeConfig.qualityNames)
        replayLen.addItems(withTitles: Prefs.replayChoices.map { $0 < 60 ? "最近 \($0) 秒" : "最近 \($0 / 60) 分鐘" })
        for c in [codec, fps, quality, replayLen, replayBox, micBox, topBox] as [NSControl] {
            c.target = self
            c.action = #selector(changed(_:))
        }

        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            return l
        }
        let grid = NSGridView(views: [
            [label("編碼"), codec],
            [label("幀率"), fps],
            [label("畫質"), quality],
            [label("重播緩衝"), replayBox],
            [NSGridCell.emptyContentView, replayLen],
            [label("麥克風"), micBox],
            [label("視窗"), topBox],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.rowAlignment = .firstBaseline

        let note = NSTextField(wrappingLabelWithString:
            "畫質與麥克風設定會在下一次開始錄影（重播緩衝則是下一段）時生效。按 ⇧⌘R 或「存重播」把最近這段存成影片。")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 320

        let stack = NSStackView(views: [grid, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        view = stack
        reload()
    }

    /// 從 Prefs 重新讀取（選單改了設定時也會呼叫）
    func reload() {
        guard isViewLoaded else { return }
        let e = Prefs.encode
        codec.selectItem(at: e.hevc ? 1 : 0)
        fps.selectItem(at: e.fps == 30 ? 0 : 1)
        quality.selectItem(at: e.quality)
        replayBox.state = Prefs.replayEnabled ? .on : .off
        replayLen.selectItem(at: Prefs.replayChoices.firstIndex(of: Prefs.replaySeconds) ?? 1)
        replayLen.isEnabled = Prefs.replayEnabled
        micBox.state = Prefs.micEnabled ? .on : .off
        topBox.state = Prefs.alwaysOnTop ? .on : .off
    }

    @objc private func changed(_ sender: Any?) {
        Prefs.encode = EncodeConfig(hevc: codec.indexOfSelectedItem == 1,
                                    fps: fps.indexOfSelectedItem == 0 ? 30 : 60,
                                    quality: quality.indexOfSelectedItem)
        Prefs.replayEnabled = replayBox.state == .on
        Prefs.replaySeconds = Prefs.replayChoices[max(0, replayLen.indexOfSelectedItem)]
        Prefs.micEnabled = micBox.state == .on
        Prefs.alwaysOnTop = topBox.state == .on
        replayLen.isEnabled = Prefs.replayEnabled
        onChange?()
    }
}
