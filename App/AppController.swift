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
    /// The screen video saved next to the audio, and the display it shows.
    let videoURL: URL?
    let screenName: String?
    /// False for a call recording named after the call: it doesn't use up a quick-recording number.
    let numbered: Bool
    /// The call this recording overlaps, so its end can ask to stop.
    var call: Call?
    var askedToStop = false
    var askedOnCallEnd = false
}

/// The last saved recording, for the saved card and the menu.
struct SavedRecording {
    let title: String
    let audio: URL
    let video: URL?
    let ruleID: UUID?
    /// The number it took, or nil for a call recording named after the call.
    let number: Int?
    let minutes: Int
    var note: URL?
    var transcribing = false
    /// Transcribed on this Mac; Claude is cleaning up the text.
    var cleaning = false
    var transcriptFailed = false

    var files: [URL] { [audio, video, note].compactMap { $0 } }
}

@MainActor
final class AppController: ObservableObject {
    let store = Store()
    lazy var calendar = CalendarWatcher(store: store)
    private let prompt = PromptPanel()
    private let calls = CallWatcher()
    private let transcriber = Transcriber()

    @Published private(set) var active: ActiveRecording?
    @Published private(set) var isBusy = false
    @Published var lastMessage: String?
    /// The most recently saved recording, shown in the menu so it can be revealed in Finder.
    @Published private(set) var lastSaved: URL?
    @Published private(set) var saved: SavedRecording?
    @Published private(set) var elapsedText = ""
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// A meeting whose "Start Recording?" card is waiting for an answer; the menu-bar icon shows it.
    @Published private(set) var pendingOffer: Occurrence?
    /// A call whose "Start Recording?" card is waiting for an answer.
    @Published private(set) var pendingCall: Call?
    /// What the call card's Start Recording does, so the menu can do the same.
    private var startPendingCall: (() -> Void)?
    /// The Screen switch on the card showing now.
    private var cardScreen = false

    private var elapsedTimer: Timer?

    init() {
        calendar.onOccurrenceDue = { [weak self] occurrence in self?.offerRecording(for: occurrence) }
        calendar.onTick = { [weak self] now in self?.checkMeetingEnd(now) }
        calendar.start()
        calls.onCallStarted = { [weak self] call in self?.callStarted(call) }
        calls.onCallEnded = { [weak self] call in self?.callEnded(call) }
        calls.start()
        transcriber.onFinished = { [weak self] job, note in self?.transcriptFinished(job, note: note) }
        transcriber.onCleaning = { [weak self] job in
            guard let self, self.saved?.audio == job.audio else { return }
            self.saved?.cleaning = true
        }
    }

    // MARK: Prompts

    private func offerRecording(for occurrence: Occurrence) {
        guard active == nil, let ruleID = occurrence.ruleID, let rule = store.rule(id: ruleID) else { return }
        let fileTitle = Naming.title(name: rule.name, number: rule.nextNumber, date: occurrence.start)
        var options: [(title: String, action: () -> Void)] = [
            ("Remind Me in 5 Minutes", { [weak self] in self?.remindAgain(occurrence) }),
        ]
        if occurrence.calendarItemID != nil {
            options.append(("Open in Calendar", { [weak self] in
                self?.calendar.openInCalendar(occurrence)
                self?.pendingOffer = nil
            }))
        }
        pendingOffer = occurrence
        pendingCall = nil
        cardScreen = rule.recordScreen
        prompt.show(
            PromptContent(
                title: occurrence.title,
                when: Self.relativeStart(occurrence.start),
                people: occurrence.attendees,
                fallbackDetail: "Saves as “\(fileTitle)”",
                primary: "Start Recording",
                primarySymbol: "record.circle.fill",
                secondary: "Ignore",
                options: options,
                screen: cardScreen,
                onScreenChange: { [weak self] in self?.setCardScreen($0, ruleID: rule.id) }
            ),
            onPrimary: { [weak self] in
                guard let self else { return }
                self.pendingOffer = nil
                Task { await self.startRecording(ruleID: rule.id, occurrence: occurrence, screen: self.cardScreen) }
            },
            onSecondary: { [weak self] in self?.pendingOffer = nil }
        )
    }

    /// Shows the prompt again in 5 minutes if the meeting is still on and nothing is recording.
    private func remindAgain(_ occurrence: Occurrence) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5 * 60))
            guard let self, self.active == nil, Date() < occurrence.end else { return }
            self.offerRecording(for: occurrence)
        }
    }

    /// "in 5 min", "now", "12 min ago".
    private static func relativeStart(_ start: Date) -> String {
        let minutes = Int((start.timeIntervalSinceNow / 60).rounded())
        if minutes >= 1 { return "in \(minutes) min" }
        if minutes <= -2 { return "\(-minutes) min ago" }
        return "now"
    }

    private func checkMeetingEnd(_ now: Date) {
        guard store.settings.askToStopAtEnd, var recording = active,
              let occurrence = recording.occurrence, !recording.askedToStop, now >= occurrence.end else { return }
        recording.askedToStop = true
        active = recording
        prompt.show(
            PromptContent(
                title: occurrence.title,
                when: "ended",
                fallbackDetail: "Still recording · \(elapsedText)",
                primary: "Stop & Save",
                primarySymbol: "stop.fill",
                secondary: "Keep Recording"
            ),
            onPrimary: { [weak self] in Task { await self?.stopRecording() } },
            onSecondary: {}
        )
    }

    // MARK: Calls

    /// A call started in Zoom, Meet, Teams…: offer to record it, even outside the meeting's scheduled time.
    private func callStarted(_ call: Call) {
        if var recording = active {
            // Already recording: remember the call so its end can ask to stop.
            recording.call = call
            active = recording
            return
        }
        guard store.settings.askOnCalls, pendingOffer == nil, !isBusy else { return }
        let hour: TimeInterval = 3600
        var rule = call.title.flatMap { CallTitle.rule(for: $0, in: store.settings.rules) }
        var occurrence = rule.flatMap { calendar.nearestMeeting(to: Date(), within: hour, ruleID: $0.id) }
        // A window that names nothing ("Zoom Meeting"): the chosen meeting on the calendar around now.
        if rule == nil, call.title == nil, let nearest = calendar.nearestMeeting(to: Date(), within: hour) {
            occurrence = nearest
            rule = nearest.ruleID.flatMap(store.rule(id:))
        }
        offerCall(call, rule: rule, occurrence: occurrence)
    }

    private func offerCall(_ call: Call, rule: Rule?, occurrence: Occurrence?) {
        let quickName = call.title ?? "\(call.app) call"
        let fileTitle = rule.map { Naming.title(name: $0.name, number: $0.nextNumber, date: occurrence?.start ?? Date()) }
            ?? Naming.title(name: quickName, date: Date())
        let start = { [weak self] (ruleID: UUID?, occurrence: Occurrence?, name: String?) in
            guard let self else { return }
            self.pendingCall = nil
            // The card's switch applies to its own guess; another choice from the chevron uses that one's setting.
            let screen = ruleID == rule?.id ? self.cardScreen : nil
            Task { await self.startRecording(ruleID: ruleID, occurrence: occurrence, name: name, screen: screen) }
        }
        // The chevron offers the other choices, in case the guess is wrong.
        var options: [(title: String, action: () -> Void)] = []
        if rule != nil {
            options.append(("Record as “\(quickName)”", { start(nil, nil, quickName) }))
        }
        for other in store.settings.rules where other.enabled && other.id != rule?.id {
            options.append(("Record as \(other.name)", { start(other.id, nil, nil) }))
        }
        pendingCall = call
        cardScreen = rule?.recordScreen ?? store.settings.recordScreen
        startPendingCall = { start(rule?.id, occurrence, rule == nil ? quickName : nil) }
        prompt.show(
            PromptContent(
                title: occurrence?.title ?? rule?.name ?? quickName,
                when: "on \(call.app)",
                people: occurrence?.attendees ?? [],
                fallbackDetail: "Saves as “\(fileTitle)”",
                primary: "Start Recording",
                primarySymbol: "record.circle.fill",
                secondary: "Ignore",
                options: options,
                screen: cardScreen,
                onScreenChange: { [weak self] in self?.setCardScreen($0, ruleID: rule?.id) }
            ),
            onPrimary: { start(rule?.id, occurrence, rule == nil ? quickName : nil) },
            onSecondary: { [weak self] in self?.pendingCall = nil }
        )
    }

    /// The card's Screen switch; for a meeting it is remembered as that meeting's setting.
    private func setCardScreen(_ on: Bool, ruleID: UUID?) {
        cardScreen = on
        if let ruleID, let index = store.settings.rules.firstIndex(where: { $0.id == ruleID }) {
            store.settings.rules[index].recordScreen = on
        }
    }

    /// The menu's "start recording" row for a waiting call card.
    func acceptPendingCall() {
        prompt.close()
        startPendingCall?()
    }

    /// The call is over: drop its unanswered card, or ask to stop the recording that overlaps it.
    private func callEnded(_ call: Call) {
        if pendingCall != nil {
            prompt.close()
            pendingCall = nil
        }
        guard store.settings.askOnCalls, var recording = active, recording.call != nil, !recording.askedOnCallEnd else { return }
        recording.askedOnCallEnd = true
        recording.askedToStop = true
        active = recording
        prompt.show(
            PromptContent(
                title: recording.occurrence?.title ?? recording.call?.title ?? recording.title,
                when: "call ended",
                fallbackDetail: "Still recording · \(elapsedText)",
                primary: "Stop & Save",
                primarySymbol: "stop.fill",
                secondary: "Keep Recording"
            ),
            onPrimary: { [weak self] in Task { await self?.stopRecording() } },
            onSecondary: {}
        )
    }

    // MARK: Recording

    /// Start recording for a rule, or a quick recording when `ruleID` is nil (named `name` when given).
    /// `screen` overrides the meeting's (or, for a quick recording, the default) screen setting.
    func startRecording(ruleID: UUID?, occurrence: Occurrence? = nil, name: String? = nil, screen: Bool? = nil) async {
        guard active == nil, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        if pendingOffer != nil || pendingCall != nil {
            prompt.close()
            pendingOffer = nil
            pendingCall = nil
        }

        let title: String
        if let ruleID, let rule = store.rule(id: ruleID) {
            title = Naming.title(name: rule.name, number: rule.nextNumber, date: occurrence?.start ?? Date())
        } else if let name {
            title = Naming.title(name: name, date: Date())
        } else {
            title = Naming.title(name: "Recording", number: store.settings.quickRecordingNumber, date: Date())
        }

        do {
            let folder = store.outputFolderURL
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = Naming.uniqueFileURL(in: folder, title: title)
            let wantsScreen = screen ?? ruleID.flatMap(store.rule(id:))?.recordScreen ?? store.settings.recordScreen
            let (session, withScreenCapture, video) = try await makeSession(finalURL: url, screen: wantsScreen)
            let withCallAudio = withScreenCapture && store.settings.recordCallAudio
            // Manual and quick recordings still follow the meeting on the calendar, so we can ask to stop at its end.
            let meeting = occurrence ?? calendar.meetingInProgress(at: Date())
            active = ActiveRecording(title: title, ruleID: ruleID, occurrence: meeting, startedAt: Date(),
                                     url: url, session: session, includesCallAudio: withCallAudio,
                                     videoURL: video?.finalURL,
                                     screenName: video.map { screenName(for: $0.displayID) },
                                     numbered: ruleID != nil || name == nil, call: calls.current)
            let wantsCapture = store.settings.recordCallAudio || wantsScreen
            lastMessage = withScreenCapture || !wantsCapture
                ? nil
                : "Recording mic only — allow Screen & System Audio Recording to include call audio and the screen."
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
            let number = recording.numbered ? store.currentNumber(ruleID: recording.ruleID) : nil
            if recording.numbered { store.commitNumber(ruleID: recording.ruleID) }
            lastSaved = recording.videoURL ?? recording.url
            lastMessage = nil
            let video = recording.videoURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            var done = SavedRecording(title: recording.title, audio: recording.url, video: video,
                                      ruleID: recording.ruleID, number: number,
                                      minutes: max(1, Int(Date().timeIntervalSince(recording.startedAt) / 60)))
            if store.settings.transcribe, Transcriber.uvPath != nil {
                done.transcribing = true
                let speaker = recording.ruleID.flatMap(store.rule(id:))?.speakerName.trimmingCharacters(in: .whitespaces)
                transcriber.enqueue(Transcriber.Job(
                    audio: recording.url, note: Transcriber.noteURL(for: recording.url), title: recording.title,
                    meeting: recording.occurrence?.title ?? recording.call?.title,
                    recorded: recording.startedAt, minutes: done.minutes,
                    me: store.settings.ownerName, other: speaker?.isEmpty == false ? speaker : nil,
                    clean: store.settings.cleanWithClaude && Transcriber.claudePath != nil))
            }
            saved = done
            showSavedCard(done)
        } catch {
            lastMessage = "Recording failed: \(error.localizedDescription)"
            NSLog("MeetingMemo: stop failed: \(error)")
        }
        active = nil
    }

    // MARK: Saved

    /// "Saved" with Delete, Open and Show in Finder; closes by itself.
    private func showSavedCard(_ recording: SavedRecording) {
        var parts = ["\(recording.minutes) min", recording.video == nil ? "audio" : "audio + screen"]
        if recording.transcribing { parts.append("transcribing on this Mac") }
        prompt.show(
            PromptContent(
                title: recording.title.components(separatedBy: " — ").first ?? recording.title,
                when: "saved",
                fallbackDetail: parts.joined(separator: " · "),
                primary: "Show in Finder",
                primarySymbol: "",
                secondary: "Delete",
                middle: ("Open", { [weak self] in self?.openSaved() }),
                secondaryConfirm: "Move to Trash?",
                autoClose: 10
            ),
            onPrimary: { [weak self] in self?.revealLastSaved() },
            onSecondary: { [weak self] in self?.deleteSaved() }
        )
    }

    /// Opens the video if there is one, otherwise the audio.
    func openSaved() {
        guard let recording = saved else { return }
        NSWorkspace.shared.open(recording.video ?? recording.audio)
    }

    func openTranscript() {
        if let note = saved?.note { NSWorkspace.shared.open(note) }
    }

    /// Moves the recording, its video and transcript to the Trash (recoverable), and gives its number back.
    func deleteSaved() {
        guard let recording = saved else { return }
        transcriber.cancel(audio: recording.audio)
        let note = Transcriber.noteURL(for: recording.audio)
        for url in Set(recording.files + [note]) where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                NSLog("MeetingMemo: cannot move \(url.lastPathComponent) to the Trash: \(error)")
            }
        }
        for cached in Transcriber.cachedFiles(for: recording.audio) { try? FileManager.default.removeItem(at: cached) }
        if let number = recording.number { store.uncommitNumber(ruleID: recording.ruleID, number: number) }
        saved = nil
        lastSaved = nil
        lastMessage = "Moved “\(recording.title)” to the Trash."
    }

    private func transcriptFinished(_ job: Transcriber.Job, note: URL?) {
        guard var recording = saved, recording.audio == job.audio else { return }
        // A recording deleted while it was being transcribed may still leave a note behind.
        guard FileManager.default.fileExists(atPath: recording.audio.path) else {
            if let note { try? FileManager.default.trashItem(at: note, resultingItemURL: nil) }
            return
        }
        recording.transcribing = false
        recording.cleaning = false
        recording.note = note
        recording.transcriptFailed = note == nil
        saved = recording
    }

    /// The capture session, whether it goes through ScreenCaptureKit, and the screen video it will save.
    private func makeSession(finalURL: URL, screen: Bool) async throws -> (CaptureSession, Bool, ScreenVideo?) {
        let settings = store.settings
        if settings.recordCallAudio || screen {
            let tempDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MeetingMemo/In Progress", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let video = screen ? ScreenVideo(displayID: chosenDisplayID, finalURL: videoURL(for: finalURL)) : nil
            let capture = SystemAndMicCapture(finalURL: finalURL, tempDir: tempDir,
                                              callAudio: settings.recordCallAudio, screen: video)
            do {
                try await capture.start()
                return (capture, true, video)
            } catch {
                NSLog("MeetingMemo: screen capture unavailable, falling back to mic only: \(error)")
            }
        }
        let mic = MicOnlyCapture(finalURL: finalURL)
        try await mic.start()
        return (mic, false, nil)
    }

    /// The chosen display while it is connected, otherwise the main one.
    private var chosenDisplayID: CGDirectDisplayID {
        if let id = store.settings.screenDisplayID, NSScreen.screens.contains(where: { $0.displayID == id }) {
            return id
        }
        return CGMainDisplayID()
    }

    private func screenName(for id: CGDirectDisplayID?) -> String {
        id.flatMap(SystemAndMicCapture.displayName) ?? "Main display"
    }

    /// "Therapy #12 — 2026-10-20 08.00.mov" next to the .m4a.
    private func videoURL(for audioURL: URL) -> URL {
        let sibling = audioURL.deletingPathExtension().appendingPathExtension("mov")
        guard FileManager.default.fileExists(atPath: sibling.path) else { return sibling }
        return Naming.uniqueFileURL(in: audioURL.deletingLastPathComponent(),
                                    title: audioURL.deletingPathExtension().lastPathComponent, ext: "mov")
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
