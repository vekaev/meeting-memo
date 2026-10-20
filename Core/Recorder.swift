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

/// Captures system audio and the microphone through one SCStream, so both share
/// one clock. Each source is written to its own temp file; on stop they are
/// aligned by first timestamp and mixed into a single .m4a.
final class SystemAndMicCapture: NSObject, CaptureSession, SCStreamOutput, SCStreamDelegate {
    private let finalURL: URL
    private let tempDir: URL
    private let queue = DispatchQueue(label: "MeetingMemo.capture")
    private var stream: SCStream?
    private var systemTrack: TrackWriter?
    private var micTrack: TrackWriter?
    private var failedSources = Set<String>()

    init(finalURL: URL, tempDir: URL) {
        self.finalURL = finalURL
        self.tempDir = tempDir
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw RecorderError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Video is required by SCStream but unused: keep it tiny and slow.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async throws {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        // Drain the sample queue before finishing the writers.
        let tracks: [TrackWriter] = queue.sync { [systemTrack, micTrack].compactMap { $0 } }
        for track in tracks { await track.finish() }
        try await Mixer.mix(tracks.filter(\.hasSamples), to: finalURL)
        for track in tracks { try? FileManager.default.removeItem(at: track.url) }
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
