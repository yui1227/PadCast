<p align="center"><img src="icon.png" width="160" alt="PadCast"></p>

# PadCast

用 USB 線連接 iPad / iPhone，在 Mac 上即時預覽、錄影、錄音與截圖——跟 QuickTime 的「新增影片錄製」一樣，**再加上畫面旋轉**。

適合直式畫面的遊戲：iPad 實際輸出是橫的，但遊戲把畫面直著呈現，用 PadCast 轉 90° 就能直接看、直接錄成直式影片。

## 功能

- 即時預覽 iPad 畫面，色彩與 QuickTime 一致
- 從 Mac 喇叭監聽 iPad 聲音，可調整監聽音量（不影響錄進檔案的音量）
- 錄影：H.264 + AAC 的 `.mov`，**固定 60 fps**，原生解析度
- 畫面旋轉：左轉／右轉 90°，錄影與截圖都會照旋轉後的方向輸出
- 截圖：轉正後的 PNG

檔案儲存在 `~/影片/PadCast/`。

## 快捷鍵

| 動作 | 快捷鍵 |
|---|---|
| 開始／停止錄影 | ⌘R |
| 截圖 | ⇧⌘S |
| 向左／向右旋轉 | ⌘← ／ ⌘→ |
| 監聽音量 ±10% | ⌘↑ ／ ⌘↓ |
| 監聽靜音 | ⇧⌘M |

## 建置

需要 macOS 13 以上，以及 Xcode 或 Command Line Tools（`xcode-select --install`）。

```bash
./build.sh
open PadCast.app
```

或直接在 Finder 雙擊 `建置並開啟.command`。

也可以到 [Releases](../../releases) 下載 GitHub Actions 自動建置好的 `PadCast.zip`（universal，Apple Silicon／Intel 都能用）。這個 App 沒有經過 Apple 公證，第一次開啟請在 App 上按右鍵 →「打開」，或執行：

```bash
xattr -dr com.apple.quarantine PadCast.app
```

第一次開啟時請允許「相機」與「麥克風」權限，iPad 要解鎖並信任這台電腦。

## 自動建置

`.github/workflows/build.yml`：每次 push 到 `main` 都會在 macOS runner 上編譯，結果在該次 Actions 的 Artifacts。推送 `v` 開頭的 tag（例如 `git tag v1.0 && git push --tags`）會自動發佈 Release 並附上 `PadCast.zip`；直接在 GitHub 網頁上發佈 Release 也會自動建置並附上 zip。

## 注意事項

- 同一時間只能有一個程式擷取 iPad 畫面，使用前請先關閉 QuickTime、OBS 等。
- 錄影中不能旋轉（旋轉資訊在開始錄影時寫入檔案）。
- 受 DRM 保護的內容（如部分串流影片）會是黑畫面，這是系統限制。
- 除錯紀錄寫在 App 旁邊的 `debug.log`。

## 原理

macOS 的 CoreMediaIO 有一個開關 `kCMIOHardwarePropertyAllowScreenCaptureDevices`，打開後已連線的 iOS 裝置會以 `AVCaptureDevice`（影音合一的 muxed 裝置）出現。之後就是標準的 AVFoundation：`AVCaptureSession` 取得畫面與聲音，`AVSampleBufferDisplayLayer` 預覽，`AVAssetWriter` 寫檔，固定 60 fps 由計時器在畫面沒變時補上重複影格；旋轉則寫在影片軌的 transform 裡，畫面本身不需要轉向。

## 授權

[The Unlicense](LICENSE)——公眾領域，可任意使用、修改、散布，不需標示出處。
