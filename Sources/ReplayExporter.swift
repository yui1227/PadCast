// 把重播緩衝的分段合併，裁出最近 N 秒，套用旋轉後輸出成一個 .mov（不重新編碼）
import Foundation
import AVFoundation

enum ReplayExporter {
    /// done 會在任意執行緒呼叫
    static func export(segments: [(url: URL, duration: CMTime)], lastSeconds: Int, rotation: Int,
                       to url: URL, done: @escaping (URL?, String?) -> Void) {
        Task.detached(priority: .userInitiated) {
            do {
                let comp = try await compose(segments)
                guard let videoTrack = comp.tracks(withMediaType: .video).first,
                      comp.duration > .zero else {
                    done(nil, "重播緩衝裡還沒有畫面"); return
                }
                videoTrack.preferredTransform = quarterTurn(rotation)
                let end = comp.duration
                let want = CMTime(seconds: Double(lastSeconds), preferredTimescale: 600)
                let start = CMTimeMaximum(.zero, CMTimeSubtract(end, want))

                guard let session = AVAssetExportSession(asset: comp,
                                                         presetName: AVAssetExportPresetPassthrough) else {
                    done(nil, "無法建立輸出工作"); return
                }
                try? FileManager.default.removeItem(at: url)
                session.outputURL = url
                session.outputFileType = .mov
                session.timeRange = CMTimeRange(start: start, end: end)
                session.exportAsynchronously {
                    if session.status == .completed {
                        done(url, nil)
                    } else {
                        debugLog("重播輸出失敗：\(String(describing: session.error))")
                        done(nil, "重播輸出失敗：\(session.error?.localizedDescription ?? "未知錯誤")")
                    }
                }
            } catch {
                debugLog("重播合併失敗：\(error)")
                done(nil, "重播合併失敗：\(error.localizedDescription)")
            }
        }
    }

    /// 依序把各段的影像與音軌接起來（音軌 [0] 是 iPad、[1] 是麥克風）
    private static func compose(_ segments: [(url: URL, duration: CMTime)]) async throws -> AVMutableComposition {
        let comp = AVMutableComposition()
        guard let videoTrack = comp.addMutableTrack(withMediaType: .video,
                                                    preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return comp
        }
        var audioTracks: [AVMutableCompositionTrack] = []
        var cursor = CMTime.zero

        for seg in segments {
            let asset = AVURLAsset(url: seg.url)
            let range = CMTimeRange(start: .zero, duration: seg.duration)
            if let v = try await asset.loadTracks(withMediaType: .video).first {
                try videoTrack.insertTimeRange(range, of: v, at: cursor)
            }
            for (i, a) in try await asset.loadTracks(withMediaType: .audio).enumerated() {
                while audioTracks.count <= i,
                      let t = comp.addMutableTrack(withMediaType: .audio,
                                                   preferredTrackID: kCMPersistentTrackID_Invalid) {
                    audioTracks.append(t)
                }
                guard i < audioTracks.count else { continue }
                let r = CMTimeRangeGetIntersection(range, otherRange: try await a.load(.timeRange))
                if r.duration > .zero {
                    try? audioTracks[i].insertTimeRange(r, of: a, at: CMTimeAdd(cursor, r.start))
                }
            }
            cursor = CMTimeAdd(cursor, seg.duration)
        }
        return comp
    }
}
