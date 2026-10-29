import AppKit
import AVFoundation
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case noDisplay
    case noAudioCaptured
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display available for audio capture."
        case .noAudioCaptured: "No audio was captured."
        case .exportFailed(let reason): "Could not save the recording: \(reason)"
        }
    }
}

/// Something that records audio until stopped, then leaves one .m4a at `finalURL`.
protocol CaptureSession: AnyObject {
    func start() async throws
    func stop() async throws
}

// MARK: - Mic + call audio (ScreenCaptureKit)

/// What to do with the screen while recording.
struct ScreenVideo {
    /// The display to record; nil or a disconnected display means the main one.
    var displayID: CGDirectDisplayID?
    /// Where the .mov goes once the recording stops.
    var finalURL: URL
}

/// Captures system audio and the microphone through one SCStream, so both share
/// one clock. Each source is written to its own temp file; on stop they are
/// aligned by first timestamp and mixed into a single .m4a. With `screen`, the
/// same stream also records the display to a .mov (video, call audio and mic).
final class SystemAndMicCapture: NSObject, CaptureSession, SCStreamOutput, SCStreamDelegate, SCRecordingOutputDelegate {
    private let finalURL: URL
    private let tempDir: URL
    private let callAudio: Bool
    private let screen: ScreenVideo?
    private let queue = DispatchQueue(label: "MeetingMemo.capture")
    private var stream: SCStream?
    private var systemTrack: TrackWriter?
    private var micTrack: TrackWriter?
    private var failedSources = Set<String>()
    private var videoTempURL: URL?
    private var recordingOutput: SCRecordingOutput?
    private var videoFinished: CheckedContinuation<Void, Never>?
    private var videoDone = false

    init(finalURL: URL, tempDir: URL, callAudio: Bool = true, screen: ScreenVideo? = nil) {
        self.finalURL = finalURL
        self.tempDir = tempDir
        self.callAudio = callAudio
        self.screen = screen
    }

    /// The display's name as macOS shows it, e.g. "Studio Display".
    @MainActor static func displayName(_ id: CGDirectDisplayID) -> String? {
        NSScreen.screens.first { $0.displayID == id }?.localizedName
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let wanted = screen?.displayID ?? CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == wanted })
            ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? content.displays.first else { throw RecorderError.noDisplay }
        // Keep the app's own prompt card out of the video.
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = callAudio
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = true
        config.sampleRate = 48_000
        config.channelCount = 2
        if screen != nil {
            // The display's size in points: sharp enough to read, a fraction of the Retina file size.
            config.width = display.width
            config.height = display.height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.showsCursor = true
        } else {
            // Video is required by SCStream but unused: keep it tiny and slow.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if callAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        if screen != nil {
            let url = tempDir.appendingPathComponent("screen-\(UUID().uuidString).mov")
            let recording = SCRecordingOutputConfiguration()
            recording.outputURL = url
            recording.outputFileType = .mov
            recording.videoCodecType = .hevc
            let output = SCRecordingOutput(configuration: recording, delegate: self)
            try stream.addRecordingOutput(output)
            recordingOutput = output
            videoTempURL = url
        }
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async throws {
        if let stream {
            try? await stream.stopCapture()
        }
        // Drain the sample queue before finishing the writers.
        let tracks: [TrackWriter] = queue.sync { [systemTrack, micTrack].compactMap { $0 } }
        for track in tracks { await track.finish() }
        try await Mixer.mix(tracks.filter(\.hasSamples), to: finalURL)
        for track in tracks { try? FileManager.default.removeItem(at: track.url) }
        try await saveVideo()
        // Released only now: the .mov is finalized after stopCapture returns.
        stream = nil
        recordingOutput = nil
    }

    /// Waits (briefly) for the .mov to be finalized, then moves it next to the audio.
    private func saveVideo() async throws {
        guard let screen, let temp = videoTempURL else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.videoDone { return continuation.resume() }
                self.videoFinished = continuation
                self.queue.asyncAfter(deadline: .now() + 10) { self.finishVideo() }
            }
        }
        guard FileManager.default.fileExists(atPath: temp.path) else {
            throw RecorderError.exportFailed("the screen video was not written")
        }
        try FileManager.default.moveItem(at: temp, to: screen.finalURL)
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        queue.async { self.finishVideo() }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        NSLog("MeetingMemo: screen recording failed: \(error)")
        queue.async { self.finishVideo() }
    }

    private func finishVideo() {
        videoDone = true
        videoFinished?.resume()
        videoFinished = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        switch type {
        case .audio: append(sampleBuffer, source: "system", track: &systemTrack)
        case .microphone: append(sampleBuffer, source: "mic", track: &micTrack)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("MeetingMemo: capture stream stopped: \(error)")
    }

    private func append(_ buffer: CMSampleBuffer, source: String, track: inout TrackWriter?) {
        if track == nil, !failedSources.contains(source) {
            do {
                track = try TrackWriter(url: tempDir.appendingPathComponent("\(source)-\(UUID().uuidString).m4a"), first: buffer)
            } catch {
                failedSources.insert(source)
                NSLog("MeetingMemo: cannot write \(source) audio: \(error)")
            }
        }
        track?.append(buffer)
    }
}

/// Writes one audio source to AAC, remembering the timestamp it started at.
final class TrackWriter {
    let url: URL
    let firstTime: CMTime
    private(set) var hasSamples = false
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput

    init(url: URL, first buffer: CMSampleBuffer) throws {
        guard let format = buffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else {
            throw RecorderError.noAudioCaptured
        }
        let channels = max(1, min(Int(asbd.mChannelsPerFrame), 2))
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: asbd.mSampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.noAudioCaptured
        }
        firstTime = buffer.presentationTimeStamp
        writer.startSession(atSourceTime: firstTime)
        self.url = url
    }

    func append(_ buffer: CMSampleBuffer) {
        guard writer.status == .writing, input.isReadyForMoreMediaData,
              buffer.presentationTimeStamp >= firstTime else { return }
        if input.append(buffer) { hasSamples = true }
    }

    func finish() async {
        guard writer.status == .writing else { return }
        input.markAsFinished()
        await writer.finishWriting()
    }
}

enum Mixer {
    /// Mix tracks into one .m4a, placing each at its offset from the earliest start.
    static func mix(_ tracks: [TrackWriter], to output: URL) async throws {
        guard let earliest = tracks.map(\.firstTime).min() else { throw RecorderError.noAudioCaptured }
        if tracks.count == 1, let only = tracks.first {
            try FileManager.default.moveItem(at: only.url, to: output)
            return
        }
        let composition = AVMutableComposition()
        for track in tracks {
            let asset = AVURLAsset(url: track.url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let duration = try await asset.load(.duration)
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source,
                                       at: CMTimeSubtract(track.firstTime, earliest))
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecorderError.exportFailed("export session unavailable")
        }
        try await export.export(to: output, as: .m4a)
    }
}

// MARK: - Mic only fallback

/// Used when call audio is off or Screen & System Audio Recording is not allowed.
final class MicOnlyCapture: NSObject, CaptureSession {
    private let finalURL: URL
    private var recorder: AVAudioRecorder?

    init(finalURL: URL) { self.finalURL = finalURL }

    func start() async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw RecorderError.exportFailed("microphone access is not allowed") }
        let recorder = try AVAudioRecorder(url: finalURL, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ])
        guard recorder.record() else { throw RecorderError.exportFailed("could not start the microphone") }
        self.recorder = recorder
    }

    func stop() async throws {
        recorder?.stop()
        recorder = nil
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
