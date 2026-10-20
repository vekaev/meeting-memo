import AppKit
import ScreenCaptureKit
import ServiceManagement

/// The recording in progress.
struct ActiveRecording {
    let title: String
    let ruleID: UUID?
    let occurrence: Occurrence?
    let startedAt: Date
    let url: URL
    let session: CaptureSession
    let includesCallAudio: Bool
    var askedToStop = false
}

@MainActor
final class AppController: ObservableObject {
    let store = Store()
    lazy var calendar = CalendarWatcher(store: store)
    private let prompt = PromptPanel()

    @Published private(set) var active: ActiveRecording?
    @Published private(set) var isBusy = false
    @Published var lastMessage: String?
    /// The most recently saved recording, shown in the menu so it can be revealed in Finder.
    @Published private(set) var lastSaved: URL?
    @Published private(set) var elapsedText = ""
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var elapsedTimer: Timer?

    init() {
        calendar.onOccurrenceDue = { [weak self] occurrence in self?.offerRecording(for: occurrence) }
        calendar.onTick = { [weak self] now in self?.checkMeetingEnd(now) }
        calendar.start()
    }

    // MARK: Prompts

    private func offerRecording(for occurrence: Occurrence) {
        guard active == nil, let ruleID = occurrence.ruleID, let rule = store.rule(id: ruleID) else { return }
        let startsIn = occurrence.start.timeIntervalSinceNow
        let when = startsIn > 60
            ? "starts in \(Int((startsIn / 60).rounded())) min"
            : "is starting"
        prompt.show(
            symbol: "record.circle",
            title: "\(occurrence.title) \(when)",
            subtitle: "Save as “\(Naming.title(name: rule.name, number: rule.nextNumber, date: occurrence.start))”",
            primary: "Start Recording",
            secondary: "Not Now",
            onPrimary: { [weak self] in
                Task { await self?.startRecording(ruleID: rule.id, occurrence: occurrence) }
            },
            onSecondary: {}
        )
    }

    private func checkMeetingEnd(_ now: Date) {
        guard store.settings.askToStopAtEnd, var recording = active,
              let occurrence = recording.occurrence, !recording.askedToStop, now >= occurrence.end else { return }
        recording.askedToStop = true
        active = recording
        prompt.show(
            symbol: "stop.circle",
            title: "\(occurrence.title) was scheduled to end",
            subtitle: "Still recording “\(recording.title)” · \(elapsedText)",
            primary: "Stop & Save",
            secondary: "Keep Recording",
            onPrimary: { [weak self] in Task { await self?.stopRecording() } },
            onSecondary: {}
        )
    }

    // MARK: Recording

    /// Start recording for a rule (or a quick recording when `ruleID` is nil).
    func startRecording(ruleID: UUID?, occurrence: Occurrence? = nil) async {
        guard active == nil, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let title: String
        if let ruleID, let rule = store.rule(id: ruleID) {
            title = Naming.title(name: rule.name, number: rule.nextNumber, date: occurrence?.start ?? Date())
        } else {
            title = Naming.title(name: "Recording", number: store.settings.quickRecordingNumber, date: Date())
        }

        do {
            let folder = store.outputFolderURL
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = Naming.uniqueFileURL(in: folder, title: title)
            let (session, withCallAudio) = try await makeSession(finalURL: url)
            // Manual and quick recordings still follow the meeting on the calendar, so we can ask to stop at its end.
            let meeting = occurrence ?? calendar.meetingInProgress(at: Date())
            active = ActiveRecording(title: title, ruleID: ruleID, occurrence: meeting, startedAt: Date(),
                                     url: url, session: session, includesCallAudio: withCallAudio)
            lastMessage = withCallAudio || !store.settings.recordCallAudio
                ? nil
                : "Recording mic only — allow Screen & System Audio Recording to include call audio."
            startElapsedTimer()
        } catch {
            lastMessage = "Could not start recording: \(error.localizedDescription)"
            NSLog("MeetingMemo: start failed: \(error)")
        }
    }

    func stopRecording() async {
        guard let recording = active, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        prompt.close()
        stopElapsedTimer()
        do {
            try await recording.session.stop()
            store.commitNumber(ruleID: recording.ruleID)
            lastSaved = recording.url
            lastMessage = nil
        } catch {
            lastMessage = "Recording failed: \(error.localizedDescription)"
            NSLog("MeetingMemo: stop failed: \(error)")
        }
        active = nil
    }

    private func makeSession(finalURL: URL) async throws -> (CaptureSession, Bool) {
        if store.settings.recordCallAudio {
            let tempDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MeetingMemo/In Progress", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let capture = SystemAndMicCapture(finalURL: finalURL, tempDir: tempDir)
            do {
                try await capture.start()
                return (capture, true)
            } catch {
                NSLog("MeetingMemo: call audio unavailable, falling back to mic only: \(error)")
            }
        }
        let mic = MicOnlyCapture(finalURL: finalURL)
        try await mic.start()
        return (mic, false)
    }

    private func startElapsedTimer() {
        updateElapsed()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateElapsed() }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        elapsedText = ""
    }

    private func updateElapsed() {
        guard let start = active?.startedAt else { return }
        let seconds = Int(Date().timeIntervalSince(start))
        elapsedText = seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: Settings helpers

    func addRule(from title: String) {
        store.settings.rules.append(Rule(name: title, matchText: title))
        calendar.refresh()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastMessage = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = store.outputFolderURL
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            store.settings.outputFolder = url.path
        }
    }

    func openOutputFolder() {
        try? FileManager.default.createDirectory(at: store.outputFolderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.outputFolderURL)
    }

    /// Selects the last saved recording in Finder (or opens the folder if it has been moved).
    func revealLastSaved() {
        guard let url = lastSaved, FileManager.default.fileExists(atPath: url.path) else {
            openOutputFolder()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Finish any recording before the app quits.
    func prepareToQuit() async {
        if active != nil { await stopRecording() }
    }
}
