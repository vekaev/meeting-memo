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
            Divider()
            upcomingSection
            if let message = controller.lastMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        .frame(width: 320)
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Start recording now").font(.headline)
            ForEach(store.settings.rules.filter(\.enabled)) { rule in
                Button {
                    Task { await controller.startRecording(ruleID: rule.id, occurrence: currentOccurrence(for: rule)) }
                } label: {
                    Label("\(rule.name) #\(rule.nextNumber)", systemImage: "record.circle")
                }
            }
            Button {
                Task { await controller.startRecording(ruleID: nil) }
            } label: {
                Label("Quick recording", systemImage: "mic")
            }
        }
        .buttonStyle(.borderless)
        .disabled(controller.isBusy)
    }

    @ViewBuilder
    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Upcoming").font(.headline)
            switch calendar.access {
            case .granted:
                if calendar.upcoming.isEmpty {
                    Text(store.settings.rules.isEmpty
                         ? "Add a meeting in Settings to get reminders."
                         : "No matching meetings in the next 2 weeks.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(calendar.upcoming.prefix(5)) { occurrence in
                        HStack {
                            Text(occurrence.title).lineLimit(1)
                            Spacer()
                            Text(occurrence.start, format: .dateTime.weekday(.abbreviated).hour().minute())
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            case .unknown:
                Button("Allow Calendar Access") { Task { await calendar.requestAccess() } }
            case .denied:
                Text("Calendar access is off.").font(.callout).foregroundStyle(.secondary)
                Button("Open Privacy Settings") { controller.openPrivacySettings("Privacy_Calendars") }
            }
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
