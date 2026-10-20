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

    func matches(_ eventTitle: String) -> Bool {
        let needle = matchText.trimmingCharacters(in: .whitespaces)
        return enabled && !needle.isEmpty && eventTitle.localizedCaseInsensitiveContains(needle)
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
