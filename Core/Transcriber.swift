import Foundation

/// Transcribes recordings on this Mac with Whisper (MLX) and sherpa-onnx speakers through the bundled
/// `transcribe.py`, one at a time, in the background; the audio never leaves the Mac. Then, if asked,
/// `clean.py` has Claude clean up the text and name the speakers (only the text goes out).
@MainActor
final class Transcriber {
    struct Job {
        let audio: URL
        let note: URL
        let title: String
        let meeting: String?
        let recorded: Date
        let minutes: Int
        /// Names for the cleanup: the owner, and the other main speaker if known.
        var me = "Me"
        var other: String?
        var clean = false
    }

    /// Called on the main actor with the note's URL, or nil when transcription failed.
    var onFinished: ((Job, URL?) -> Void)?
    /// Called when a job moves from transcribing to its Claude cleanup.
    var onCleaning: ((Job) -> Void)?
    private(set) var current: Job?
    private var queue: [Job] = []
    private var process: Process?
    /// True while the current job is in its Claude cleanup step.
    private(set) var isCleaning = false

    static let model = "mlx-community/whisper-large-v3-turbo"

    /// `uv` runs the script with its own Python and packages; nil means transcription can't run here.
    static var uvPath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The `claude` CLI, for the cleanup step.
    static var claudePath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The model is in the Hugging Face cache, so the run can be fully offline.
    static var modelIsCached: Bool {
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--\(model.replacingOccurrences(of: "/", with: "--"))")
        return FileManager.default.fileExists(atPath: cache.path)
    }

    /// Whisper's cached output for a recording (Application Support/MeetingMemo/cache), removed with it.
    static func cachedFiles(for audio: URL) -> [URL] {
        let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingMemo/cache")
        let prefix = audio.deletingPathExtension().lastPathComponent + "-"
        return ((try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
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
        var arguments = ["run", "--quiet", "--script", script.path, job.audio.path, job.note.path,
                         "--title", job.title, "--model", Self.model,
                         "--recorded", job.recorded.formatted(date: .abbreviated, time: .shortened),
                         "--minutes", "\(job.minutes) min"]
        if let meeting = job.meeting { arguments += ["--meeting", meeting] }
        launch(uv, arguments) { [weak self] ok in
            guard let self else { return }
            let note = ok && FileManager.default.fileExists(atPath: job.note.path) ? job.note : nil
            guard let note else {
                NSLog("MeetingMemo: transcription failed for \(job.audio.lastPathComponent)")
                return self.finish(job, note: nil)
            }
            guard job.clean, let claude = Self.claudePath,
                  let cleaner = Bundle.main.url(forResource: "clean", withExtension: "py") else {
                return self.finish(job, note: note)
            }
            // The raw transcript is already saved; a failed cleanup leaves it as it is.
            self.isCleaning = true
            self.onCleaning?(job)
            var cleanArguments = ["run", "--quiet", "--script", cleaner.path, note.path, "--me", job.me, "--claude", claude]
            if let other = job.other { cleanArguments += ["--other", other] }
            self.launch(uv, cleanArguments) { [weak self] ok in
                if !ok { NSLog("MeetingMemo: cleanup failed for \(note.lastPathComponent)") }
                self?.finish(job, note: note)
            }
        }
    }

    private func finish(_ job: Job, note: URL?) {
        current = nil
        isCleaning = false
        onFinished?(job, note)
        runNext()
    }

    /// Runs a step of the current job; `done` gets whether it exited cleanly, on the main actor.
    private func launch(_ executable: String, _ arguments: [String], done: @escaping (Bool) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        if Self.modelIsCached { environment["HF_HUB_OFFLINE"] = "1" }
        process.environment = environment
        process.qualityOfService = .utility
        process.standardOutput = FileHandle.nullDevice
        process.standardError = Self.logHandle()
        process.terminationHandler = { finished in
            let ok = finished.terminationStatus == 0
            Task { @MainActor [weak self] in
                self?.process = nil
                done(ok)
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            NSLog("MeetingMemo: cannot start \(executable): \(error)")
            done(false)
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
