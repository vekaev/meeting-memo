import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var calendar: CalendarWatcher
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let recording = controller.active {
                recordingSection(recording)
            } else {
                startSection
            }
            if controller.lastSaved != nil || controller.lastMessage != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let saved = controller.lastSaved {
                        Button { controller.revealLastSaved() } label: {
                            HStack(spacing: 6) {
                                Text("Saved “\(saved.lastPathComponent)”").lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Image(systemName: "magnifyingglass")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(MenuRowButtonStyle())
                        .help("Show in Finder")
                    }
                    if let message = controller.lastMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Divider()
            HStack {
                Button("Settings…") {
                    openWindow(id: "settings")
                    NSApp.activate()
                }
                Button("Open Folder") { controller.openOutputFolder() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private func recordingSection(_ recording: ActiveRecording) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
                Text("Recording").font(.headline)
                Spacer()
                Text(controller.elapsedText).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(recording.title).font(.callout).lineLimit(2)
            Text(recording.includesCallAudio ? "Mic + call audio" : "Mic only")
                .font(.caption).foregroundStyle(.secondary)
            if let meeting = recording.occurrence, store.settings.askToStopAtEnd {
                Text("Will ask to stop when “\(meeting.title)” ends at \(meeting.end.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Button {
                Task { await controller.stopRecording() }
            } label: {
                Label("Stop & Save", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(controller.isBusy)
        }
    }

    private var startSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Start recording now").font(.headline).padding(.bottom, 4)
            ForEach(store.settings.rules.filter(\.enabled)) { rule in
                MeetingRow(
                    title: "\(rule.name) #\(rule.nextNumber)",
                    next: calendar.upcoming.first { $0.ruleID == rule.id },
                    onStart: {
                        Task { await controller.startRecording(ruleID: rule.id, occurrence: currentOccurrence(for: rule)) }
                    },
                    onOpen: { calendar.openInCalendar($0) }
                )
            }
            Button {
                Task { await controller.startRecording(ruleID: nil) }
            } label: {
                Label("Quick recording", systemImage: "mic")
            }
            .buttonStyle(MenuRowButtonStyle())
            calendarNotes.padding(.top, 4)
        }
        .disabled(controller.isBusy)
    }

    @ViewBuilder
    private var calendarNotes: some View {
        switch calendar.access {
        case .granted:
            if store.settings.rules.isEmpty {
                Text("Add a meeting in Settings to see its next date here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .unknown:
            Button("Allow Calendar Access") { Task { await calendar.requestAccess() } }
        case .denied:
            Text("Calendar access is off.").font(.caption).foregroundStyle(.secondary)
            Button("Open Privacy Settings") { controller.openPrivacySettings("Privacy_Calendars") }
        }
    }

    /// The occurrence happening now for a rule, so a manual start still uses the meeting's date.
    private func currentOccurrence(for rule: Rule) -> Occurrence? {
        let now = Date()
        return calendar.upcoming.first {
            $0.ruleID == rule.id && $0.start.addingTimeInterval(-15 * 60) <= now && now < $0.end
        }
    }
}

/// Date and start time of a meeting, e.g. "Tue, Oct 21 · 8:00 AM", or "Now" while it is on.
private struct MeetingTime: View {
    let occurrence: Occurrence

    var body: some View {
        let now = Date()
        Group {
            if occurrence.start <= now && now < occurrence.end {
                Text("Now · until \(occurrence.end.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.red)
            } else {
                Text("\(occurrence.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(occurrence.start.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }
}

/// A meeting row: clicking the name starts recording, clicking the date opens the event in Calendar.
private struct MeetingRow: View {
    let title: String
    let next: Occurrence?
    let onStart: () -> Void
    let onOpen: (Occurrence) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    @State private var isDateHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onStart) {
                Label(title, systemImage: "record.circle")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Start recording")
            if let next {
                Button { onOpen(next) } label: {
                    MeetingTime(occurrence: next).underline(isDateHovered)
                }
                .buttonStyle(.plain)
                .onHover { isDateHovered = $0 }
                .help("Open in Calendar")
            }
        }
        .foregroundStyle(.primary)
        .menuRowHighlight(isHovered && isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovered = $0 }
    }
}

private extension View {
    /// Full-width row padding with a rounded highlight; the text stays aligned with the section headers.
    func menuRowHighlight(_ isOn: Bool, pressed: Bool = false) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(pressed ? 0.16 : 0.08))
                    .opacity(isOn ? 1 : 0)
            )
            .padding(.horizontal, -8)
            .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

/// A full-width menu row that highlights while the pointer is over it.
struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(.primary)
                .menuRowHighlight(isHovered && isEnabled, pressed: configuration.isPressed)
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { isHovered = $0 }
        }
    }
}
