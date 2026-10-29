import Foundation

/// Transcribes recordings on this Mac with Whisper (MLX) through the bundled `transcribe.py`, one at a time,
/// in the background. The audio never leaves the Mac.
@MainActor
final class Transcriber {
    struct Job {
        let audio: URL
        let note: URL
        let title: String
        let meeting: String?
        let recorded: Date
        let minutes: Int
    }

    /// Called on the main actor with the note's URL, or nil when transcription failed.
    var onFinished: ((Job, URL?) -> Void)?
    private(set) var current: Job?
    private var queue: [Job] = []
    private var process: Process?

    static let model = "mlx-community/whisper-large-v3-turbo"

    /// `uv` runs the script with its own Python and packages; nil means transcription can't run here.
    static var uvPath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The model is in the Hugging Face cache, so the run can be fully offline.
    static var modelIsCached: Bool {
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--\(model.replacingOccurrences(of: "/", with: "--"))")
        return FileManager.default.fileExists(atPath: cache.path)
    }

    /// The note next to a recording: "Ari #2 — 2026-11-04 13.30.md".
    static func noteURL(for audio: URL) -> URL {
        audio.deletingPathExtension().appendingPathExtension("md")
    }

    func enqueue(_ job: Job) {
        queue.append(job)
        runNext()
    }

    func isPending(_ audio: URL) -> Bool {
        current?.audio == audio || queue.contains { $0.audio == audio }
    }

    /// Drops a job (its recording was deleted), stopping it if it is running.
    func cancel(audio: URL) {
        queue.removeAll { $0.audio == audio }
        if current?.audio == audio {
            process?.terminate()
        }
    }

    private func runNext() {
        guard current == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        guard let uv = Self.uvPath, let script = Bundle.main.url(forResource: "transcribe", withExtension: "py") else {
            NSLog("MeetingMemo: transcription unavailable (uv or script missing)")
            onFinished?(job, nil)
            return runNext()
        }
        current = job

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uv)
        var arguments = ["run", "--quiet", "--script", script.path, job.audio.path, job.note.path,
                         "--title", job.title, "--model", Self.model,
                         "--recorded", job.recorded.formatted(date: .abbreviated, time: .shortened),
                         "--minutes", "\(job.minutes) min"]
        if let meeting = job.meeting { arguments += ["--meeting", meeting] }
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if Self.modelIsCached { environment["HF_HUB_OFFLINE"] = "1" }
        process.environment = environment
        process.qualityOfService = .utility
        process.standardOutput = FileHandle.nullDevice
        process.standardError = Self.logHandle()
        process.terminationHandler = { [weak self] finished in
            let ok = finished.terminationStatus == 0
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                self.current = nil
                let note = ok && FileManager.default.fileExists(atPath: job.note.path) ? job.note : nil
                if note == nil { NSLog("MeetingMemo: transcription failed for \(job.audio.lastPathComponent)") }
                self.onFinished?(job, note)
                self.runNext()
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            NSLog("MeetingMemo: cannot start transcription: \(error)")
            current = nil
            onFinished?(job, nil)
            runNext()
        }
    }

    /// Whisper's and uv's messages go to Application Support/MeetingMemo/transcribe.log.
    private static func logHandle() -> FileHandle {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingMemo/transcribe.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return .nullDevice }
        handle.seekToEndOfFile()
        return handle
    }
}
