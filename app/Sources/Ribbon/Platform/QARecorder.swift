import AppKit
import ScreenCaptureKit

/// QA only, reached through the command fifo: records the main display to a movie at 60 fps, so a swipe in the test VM can
/// be watched frame by frame. Nothing else in Ribbon writes screen content to disk.
@MainActor
final class QARecorder {
    static let shared = QARecorder()
    private var stream: SCStream?
    private let delegate = Delegate()

    func record(seconds: Double, to path: String) {
        guard stream == nil, SnapshotStore.permitted else { NSLog("Ribbon QA: qa_record needs Screen Recording and no recording running"); return }
        Task { @MainActor in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { return }
            let cfg = SCStreamConfiguration()
            cfg.width = display.width; cfg.height = display.height
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            cfg.showsCursor = false
            let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: nil)
            let rc = SCRecordingOutputConfiguration()
            rc.outputURL = URL(fileURLWithPath: path)
            rc.outputFileType = .mov
            rc.videoCodecType = .h264
            try? FileManager.default.removeItem(atPath: path)
            do {
                try s.addRecordingOutput(SCRecordingOutput(configuration: rc, delegate: delegate))
                try await s.startCapture()
            } catch { NSLog("Ribbon QA: qa_record failed: \(error)"); return }
            stream = s
            try? await Task.sleep(for: .seconds(seconds))
            try? await s.stopCapture()
            stream = nil
        }
    }

    private final class Delegate: NSObject, SCRecordingOutputDelegate {
        func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) { NSLog("Ribbon QA: recording") }
        func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { NSLog("Ribbon QA: recording saved") }
        func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) { NSLog("Ribbon QA: recording failed: \(error)") }
    }
}
