import AppKit
import EventKit

/// One calendar event occurrence that matches a rule.
struct Occurrence: Identifiable, Hashable {
    /// Stable per occurrence: event identifier plus its start time.
    let id: String
    let title: String
    let start: Date
    let end: Date
    let ruleID: UUID
}

/// Upcoming event offered in "Add from calendar".
struct CalendarEventSummary: Identifiable, Hashable {
    var id: String { title }
    let title: String
    let nextStart: Date
}

@MainActor
final class CalendarWatcher: ObservableObject {
    enum Access { case unknown, granted, denied }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var upcoming: [Occurrence] = []
    @Published private(set) var eventTitles: [CalendarEventSummary] = []

    /// Fired once per occurrence when it reaches its prompt time.
    var onOccurrenceDue: ((Occurrence) -> Void)?
    /// Fired every tick so the controller can check meeting ends.
    var onTick: ((Date) -> Void)?

    private let eventStore = EKEventStore()
    private let store: Store
    private var timer: Timer?

    init(store: Store) {
        self.store = store
        updateAccess()
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: eventStore, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func start() {
        if access == .unknown {
            Task { await requestAccess() }
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func requestAccess() async {
        do {
            _ = try await eventStore.requestFullAccessToEvents()
        } catch {
            NSLog("MeetingMemo: calendar access error: \(error)")
        }
        updateAccess()
        tick()
    }

    func tick() {
        refresh()
        let now = Date()
        let lead = TimeInterval(store.settings.leadMinutes * 60)
        for occurrence in upcoming where now >= occurrence.start.addingTimeInterval(-lead) && now < occurrence.end {
            guard !store.isHandled(occurrence.id) else { continue }
            store.markHandled(occurrence.id)
            onOccurrenceDue?(occurrence)
        }
        onTick?(now)
    }

    func refresh() {
        guard access == .granted else {
            upcoming = []
            eventTitles = []
            return
        }
        let now = Date()
        let predicate = eventStore.predicateForEvents(
            withStart: now.addingTimeInterval(-6 * 3600),
            end: now.addingTimeInterval(14 * 24 * 3600),
            calendars: nil
        )
        let events = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }

        upcoming = events.compactMap { event in
            let title = event.title ?? ""
            guard let rule = store.firstRule(matching: title) else { return nil }
            let key = "\(event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? title)|\(Int(event.startDate.timeIntervalSince1970))"
            return Occurrence(id: key, title: title, start: event.startDate, end: event.endDate, ruleID: rule.id)
        }

        var seen = Set<String>()
        eventTitles = events.compactMap { event in
            guard let title = event.title, !title.isEmpty, seen.insert(title).inserted else { return nil }
            return CalendarEventSummary(title: title, nextStart: event.startDate)
        }
    }

    private func updateAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .notDetermined: access = .unknown
        default: access = .denied
        }
    }
}
