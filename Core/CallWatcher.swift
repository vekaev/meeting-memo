import AppKit
import CoreAudio

/// A call in progress: a known meeting app is using the microphone.
struct Call: Equatable {
    /// "Zoom", "Google Chrome", "FaceTime".
    let app: String
    /// The meeting's name from the app's window, cleaned up; nil when the window says nothing useful
    /// ("Zoom Meeting", a Meet code like "abc-defg-hij").
    let title: String?
}

/// Watches which apps use the microphone and reports when a call starts and ends.
/// Only known call apps count, so Siri, dictation or a notetaker never look like a call.
@MainActor
final class CallWatcher {
    var onCallStarted: ((Call) -> Void)?
    var onCallEnded: ((Call) -> Void)?
    private(set) var current: Call?

    private var timer: Timer?
    private var seen = 0
    private var missed = 0
    private static let interval: TimeInterval = 3
    /// Polls in a row before a call counts as started (about 6 s) or ended (about 12 s), so a
    /// device switch or a short mute doesn't fire a card.
    private static let startPolls = 2, endPolls = 4

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        let app = MicUsers.callApp()
        if let app {
            missed = 0
            guard current == nil else { return }
            seen += 1
            if seen >= Self.startPolls {
                let titles = WindowTitles.titles(bundleID: app.mainBundleID)
                let call = Call(app: CallTitle.service(titles, app: app), title: CallTitle.clean(titles, app: app))
                current = call
                onCallStarted?(call)
            }
        } else {
            seen = 0
            guard let call = current else { return }
            missed += 1
            if missed >= Self.endPolls {
                current = nil
                missed = 0
                onCallEnded?(call)
            }
        }
    }
}

/// Meeting apps whose microphone use means a call. Browsers count for Meet, Teams on the web and the like.
struct CallApp {
    let name: String
    /// Audio comes from a helper process ("com.google.Chrome.helper"), so match on the prefix.
    let bundlePrefix: String
    /// The app that owns the call window.
    let mainBundleID: String
    var isBrowser = false

    static let known: [CallApp] = [
        CallApp(name: "Zoom", bundlePrefix: "us.zoom.", mainBundleID: "us.zoom.xos"),
        CallApp(name: "Microsoft Teams", bundlePrefix: "com.microsoft.teams", mainBundleID: "com.microsoft.teams2"),
        CallApp(name: "Slack", bundlePrefix: "com.tinyspeck.slackmacgap", mainBundleID: "com.tinyspeck.slackmacgap"),
        CallApp(name: "FaceTime", bundlePrefix: "com.apple.avconferenced", mainBundleID: "com.apple.FaceTime"),
        CallApp(name: "Webex", bundlePrefix: "Cisco-Systems.Spark", mainBundleID: "Cisco-Systems.Spark"),
        CallApp(name: "Discord", bundlePrefix: "com.hnc.Discord", mainBundleID: "com.hnc.Discord"),
        CallApp(name: "Google Chrome", bundlePrefix: "com.google.Chrome", mainBundleID: "com.google.Chrome", isBrowser: true),
        CallApp(name: "Arc", bundlePrefix: "company.thebrowser.", mainBundleID: "company.thebrowser.Browser", isBrowser: true),
        CallApp(name: "Microsoft Edge", bundlePrefix: "com.microsoft.edgemac", mainBundleID: "com.microsoft.edgemac", isBrowser: true),
        CallApp(name: "Brave", bundlePrefix: "com.brave.Browser", mainBundleID: "com.brave.Browser", isBrowser: true),
        CallApp(name: "Firefox", bundlePrefix: "org.mozilla.firefox", mainBundleID: "org.mozilla.firefox", isBrowser: true),
        // Safari captures in WebKit's GPU process.
        CallApp(name: "Safari", bundlePrefix: "com.apple.WebKit.GPU", mainBundleID: "com.apple.Safari", isBrowser: true),
    ]

    static func matching(bundleID: String) -> CallApp? {
        known.first { bundleID.hasPrefix($0.bundlePrefix) }
    }
}

/// Which processes are recording from an input device right now (CoreAudio process objects, macOS 14+).
enum MicUsers {
    static func callApp() -> CallApp? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return nil }
        for process in processes where value(process, kAudioProcessPropertyIsRunningInput, UInt32(0)) != 0 {
            let bundleID = bundleID(process)
            if let app = CallApp.matching(bundleID: bundleID) { return app }
        }
        return nil
    }

    private static func bundleID(_ process: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &result) == noErr, let result else { return "" }
        return result.takeRetainedValue() as String
    }

    private static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ fallback: T) -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var result = fallback
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return fallback }
        return result
    }
}

/// Titles of an app's on-screen windows, front to back. Needs Screen & System Audio Recording access;
/// without it macOS leaves the titles out and the call is matched by the calendar instead.
enum WindowTitles {
    static func titles(bundleID: String) -> [String] {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        guard !pids.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return windows.compactMap { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let name = window[kCGWindowName as String] as? String, !name.isEmpty else { return nil }
            return name
        }
    }
}

/// Turns window titles into a meeting name.
enum CallTitle {
    private static let generic: Set<String> = [
        "zoom", "zoom meeting", "zoom workplace", "meeting", "meet", "google meet", "microsoft teams",
        "teams", "facetime", "slack", "huddle", "webex", "discord", "new tab",
    ]
    private static let callHints = ["meet", "zoom", "teams", "huddle", "webex", "facetime", "call", "meeting"]

    /// The call window's title without the app's decoration; nil when nothing names the meeting.
    static func clean(_ titles: [String], app: CallApp) -> String? {
        // In a browser, prefer the window showing the call; otherwise the front window.
        let window = app.isBrowser
            ? titles.first { title in callHints.contains { title.localizedCaseInsensitiveContains($0) } } ?? titles.first
            : titles.first { !isGeneric(strip($0)) } ?? titles.first
        guard let window else { return nil }
        let name = strip(window)
        return isGeneric(name) ? nil : String(name.prefix(80))
    }

    /// The service behind a browser call when its tab says so ("Google Meet"), otherwise the app's name.
    static func service(_ titles: [String], app: CallApp) -> String {
        guard app.isBrowser else { return app.name }
        if titles.contains(where: { $0.range(of: #"^(\(\d+\)\s*)?(Google )?Meet\s[-–—]\s"#, options: .regularExpression) != nil }) {
            return "Google Meet"
        }
        if titles.contains(where: { $0.contains("| Microsoft Teams") }) { return "Microsoft Teams" }
        return app.name
    }

    /// "(2) Meet - Weekly sync - Google Chrome - Work" → "Weekly sync".
    static func strip(_ title: String) -> String {
        var name = title
        name = name.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
        for browser in ["Google Chrome", "Microsoft Edge", "Mozilla Firefox", "Brave", "Arc", "Safari"] {
            name = name.replacingOccurrences(of: #"\s[-–—]\s"# + browser + #"(\s[-–—]\s.*)?$"#, with: "", options: .regularExpression)
        }
        name = name.replacingOccurrences(of: #"\s*\|\s*Microsoft Teams$"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"^(Meet|Google Meet)\s[-–—]\s"#, with: "", options: .regularExpression)
        return name.trimmingCharacters(in: .whitespaces)
    }

    static func isGeneric(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.isEmpty || generic.contains(lower)
            || lower.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil
    }

    /// The meeting whose match text the call's title contains, or shares most words with
    /// ("Ari / Yevhenii" matches "Yevhenii <> Ari").
    static func rule(for title: String, in rules: [Rule]) -> Rule? {
        let enabled = rules.filter(\.enabled)
        if let exact = enabled.first(where: { $0.matches(title) }) { return exact }
        let titleWords = words(title)
        return enabled
            .map { rule -> (Rule, Double) in
                let needed = words(rule.matchText)
                guard !needed.isEmpty else { return (rule, 0) }
                return (rule, Double(needed.intersection(titleWords).count) / Double(needed.count))
            }
            .filter { $0.1 >= 0.6 }
            .max { $0.1 < $1.1 }?.0
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 })
    }
}
