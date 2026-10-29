// PadCast — 擷取有線連接的 iPad / iPhone 畫面（預覽、錄影、重播緩衝、截圖、畫面旋轉）
// 建置：./build.sh   （需要 Xcode 或 Command Line Tools：xcode-select --install）
// 需求：macOS 13 以上
import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
