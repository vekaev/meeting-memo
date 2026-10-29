import Foundation

/// A meeting series to record, matched against calendar event titles.
struct Rule: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Name used in the recording file name, e.g. "Therapy".
    var name: String
    /// Case-insensitive text the calendar event title must contain.
    var matchText: String
    /// Number given to the next saved recording of this series.
    var nextNumber: Int = 1
    var enabled: Bool = true
    /// Also save a screen video for this meeting.
    var recordScreen: Bool = false

    func matches(_ eventTitle: String) -> Bool {
        let needle = matchText.trimmingCharacters(in: .whitespaces)
        return enabled && !needle.isEmpty && eventTitle.localizedCaseInsensitiveContains(needle)
    }
}

extension Rule {
    /// Keys missing from an older settings file keep their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        matchText = try c.decode(String.self, forKey: .matchText)
        nextNumber = try c.decodeIfPresent(Int.self, forKey: .nextNumber) ?? 1
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        recordScreen = try c.decodeIfPresent(Bool.self, forKey: .recordScreen) ?? false
    }
}

struct AppSettings: Codable {
    var rules: [Rule] = []
    var outputFolder: String = AppSettings.defaultOutputFolder
    /// Minutes before the meeting start to show the prompt (0 = at start).
    var leadMinutes: Int = 0
    var askToStopAtEnd: Bool = true
    var recordCallAudio: Bool = true
    /// Number used for recordings started without a rule.
    var quickRecordingNumber: Int = 1
    /// Calendar occurrences already prompted for, so each one asks only once.
    var handledOccurrences: [String: Date] = [:]
    /// Also save a screen video (.mov) for quick recordings and calls that match no meeting;
    /// each meeting has its own switch.
    var recordScreen: Bool = false
    /// The display to record; nil means the main display.
    var screenDisplayID: UInt32? = nil
    /// Offer to record when a call starts in Zoom, Meet, Teams…, and to stop when it ends.
    var askOnCalls: Bool = true

    init() {}

    /// Keys missing from an older settings file keep their defaults instead of resetting everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? d.rules
        outputFolder = try c.decodeIfPresent(String.self, forKey: .outputFolder) ?? d.outputFolder
        leadMinutes = try c.decodeIfPresent(Int.self, forKey: .leadMinutes) ?? d.leadMinutes
        askToStopAtEnd = try c.decodeIfPresent(Bool.self, forKey: .askToStopAtEnd) ?? d.askToStopAtEnd
        recordCallAudio = try c.decodeIfPresent(Bool.self, forKey: .recordCallAudio) ?? d.recordCallAudio
        quickRecordingNumber = try c.decodeIfPresent(Int.self, forKey: .quickRecordingNumber) ?? d.quickRecordingNumber
        handledOccurrences = try c.decodeIfPresent([String: Date].self, forKey: .handledOccurrences) ?? d.handledOccurrences
        recordScreen = try c.decodeIfPresent(Bool.self, forKey: .recordScreen) ?? d.recordScreen
        screenDisplayID = try c.decodeIfPresent(UInt32.self, forKey: .screenDisplayID)
        askOnCalls = try c.decodeIfPresent(Bool.self, forKey: .askOnCalls) ?? d.askOnCalls
    }

    static var defaultOutputFolder: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Meeting Recordings").path
    }
}

@MainActor
final class Store: ObservableObject {
    @Published var settings: AppSettings {
        didSet { save() }
    }

    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingMemo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
        pruneHandled()
    }

    var outputFolderURL: URL { URL(fileURLWithPath: settings.outputFolder, isDirectory: true) }

    func rule(id: UUID) -> Rule? { settings.rules.first { $0.id == id } }

    func firstRule(matching title: String) -> Rule? { settings.rules.first { $0.matches(title) } }

    func isHandled(_ key: String) -> Bool { settings.handledOccurrences[key] != nil }

    func markHandled(_ key: String) { settings.handledOccurrences[key] = Date() }

    /// Called after a recording is saved: the series counter moves on.
    func commitNumber(ruleID: UUID?) {
        if let ruleID, let index = settings.rules.firstIndex(where: { $0.id == ruleID }) {
            settings.rules[index].nextNumber += 1
        } else if ruleID == nil {
            settings.quickRecordingNumber += 1
        }
    }

    private func pruneHandled() {
        let cutoff = Date().addingTimeInterval(-3 * 24 * 3600)
        settings.handledOccurrences = settings.handledOccurrences.filter { $0.value > cutoff }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(settings)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("MeetingMemo: failed to save settings: \(error)")
        }
    }
}

enum Naming {
    /// "Therapy #12 — 2026-10-20 08.00" (colons are not allowed in Finder names).
    static func title(name: String, number: Int, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "\(name) #\(number) — \(formatter.string(from: date))"
    }

    /// "Weekly sync — 2026-10-20 08.00", for a call that matches no meeting.
    static func title(name: String, date: Date) -> String {
        title(name: name, number: 0, date: date).replacingOccurrences(of: " #0 — ", with: " — ")
    }

    /// A file URL in `folder` for `title`, adding " (2)", " (3)" … if the name is taken.
    static func uniqueFileURL(in folder: URL, title: String, ext: String = "m4a") -> URL {
        let safe = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
        var candidate = folder.appendingPathComponent("\(safe).\(ext)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(safe) (\(suffix)).\(ext)")
            suffix += 1
        }
        return candidate
    }
}
