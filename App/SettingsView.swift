import SwiftUI

/// Settings in the style of a calm preferences window: a sidebar of pages, and rows with a title,
/// a grey description and the control on the right.
struct SettingsView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var calendar: CalendarWatcher
    @State private var page: Page

    init(page: Page = .meetings) {
        _page = State(initialValue: page)
    }

    enum Page: String, CaseIterable, Identifiable {
        case meetings = "Meetings", recording = "Recording", reminders = "Reminders", general = "General"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .meetings: "calendar"
            case .recording: "waveform"
            case .reminders: "bell"
            case .general: "gearshape"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(page.rawValue).font(.system(size: 22, weight: .semibold))
                    switch page {
                    case .meetings: MeetingsPage()
                    case .recording: RecordingPage()
                    case .reminders: RemindersPage()
                    case .general: GeneralPage()
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 720, height: 540)
        .onChange(of: store.settings.rules) { calendar.refresh() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Page.allCases) { item in
                Button { page = item } label: {
                    Label(item.rawValue, systemImage: item.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(page == item ? 0.09 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fontWeight(page == item ? .medium : .regular)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        // Room for the window's traffic lights in the hidden title bar.
        .padding(.top, 44)
        .frame(width: 180)
        .background(.background.secondary)
    }
}

// MARK: - Pages

private struct MeetingsPage: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var calendar: CalendarWatcher
    @State private var expanded: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Meeting Memo offers to record these when they start on your calendar, or when you join their call.")
                .foregroundStyle(.secondary)
            Card {
                if store.settings.rules.isEmpty {
                    Text("No meetings yet. Add one from your calendar.")
                        .foregroundStyle(.secondary)
                        .padding(14)
                }
                ForEach($store.settings.rules) { $rule in
                    if rule.id != store.settings.rules.first?.id { Divider().padding(.leading, 14) }
                    MeetingRow(rule: $rule, isExpanded: expanded == rule.id) {
                        withAnimation(.easeOut(duration: 0.15)) { expanded = expanded == rule.id ? nil : rule.id }
                    } onDelete: {
                        store.settings.rules.removeAll { $0.id == rule.id }
                    }
                }
            }
            HStack(spacing: 8) {
                Menu {
                    if calendar.eventTitles.isEmpty {
                        Text("No events in the next 2 weeks")
                    }
                    ForEach(calendar.eventTitles) { event in
                        Button("\(event.title) — \(event.nextStart.formatted(.dateTime.weekday(.abbreviated).hour().minute()))") {
                            controller.addRule(from: event.title)
                            expanded = store.settings.rules.last?.id
                        }
                    }
                } label: {
                    Label("Add from Calendar", systemImage: "plus")
                }
                .fixedSize()
                Button("Add by Hand") {
                    store.settings.rules.append(Rule(name: "New meeting", matchText: ""))
                    expanded = store.settings.rules.last?.id
                }
            }
        }
    }
}

/// One meeting: a summary line; click to edit its details in place.
private struct MeetingRow: View {
    @Binding var rule: Rule
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.name.isEmpty ? "Untitled" : rule.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if rule.recordScreen {
                    Image(systemName: "display")
                        .foregroundStyle(.secondary)
                        .help("Records the screen too")
                }
                Toggle("", isOn: $rule.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(rule.enabled ? "On" : "Off: never asks for this meeting")
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)

            if isExpanded {
                VStack(spacing: 0) {
                    Divider().padding(.leading, 14)
                    SettingRow("Name", detail: "Used in the file name.") {
                        TextField("", text: $rule.name, prompt: Text("Therapy"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                    }
                    SettingRow("Calendar title contains", detail: "Also matched against the call's window title.") {
                        TextField("", text: $rule.matchText, prompt: Text("Text in the event title"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                    }
                    SettingRow("Speaker name", detail: "The other person in transcripts, e.g. Therapist.") {
                        TextField("", text: $rule.speakerName, prompt: Text("Speaker 2"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                    }
                    SettingRow("Record the screen", detail: "Saves a .mov next to the audio. You can also switch it on the card.") {
                        Toggle("", isOn: $rule.recordScreen).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    SettingRow("Next number", detail: "Next file: \(Naming.title(name: rule.name, number: rule.nextNumber, date: Date())).m4a") {
                        Stepper("#\(rule.nextNumber)", value: $rule.nextNumber, in: 1...9999)
                            .monospacedDigit()
                            .fixedSize()
                    }
                    HStack {
                        Spacer()
                        Button("Remove Meeting", role: .destructive, action: onDelete)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .padding(.top, 4)
                }
                .background(Color.primary.opacity(0.025))
            }
        }
    }

    private var summary: String {
        let match = rule.matchText.trimmingCharacters(in: .whitespaces)
        let matching = match.isEmpty ? "Matches nothing yet" : "Title contains “\(match)”"
        return "\(matching) · next #\(rule.nextNumber)"
    }
}

private struct RecordingPage: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var store: Store

    var body: some View {
        Card {
            SettingRow("Save to", detail: (store.settings.outputFolder as NSString).abbreviatingWithTildeInPath) {
                Button("Choose…") { controller.chooseOutputFolder() }
            }
            Divider().padding(.leading, 14)
            SettingRow("Call audio", detail: "Records the other people in the call, not only your mic.") {
                Toggle("", isOn: $store.settings.recordCallAudio).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
        SectionTitle("Transcripts")
        Card {
            SettingRow("Transcribe on this Mac", detail: transcribeDetail) {
                Toggle("", isOn: $store.settings.transcribe).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(Transcriber.uvPath == nil)
            }
            Divider().padding(.leading, 14)
            SettingRow("Clean up with Claude", detail: cleanDetail) {
                Toggle("", isOn: $store.settings.cleanWithClaude).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(Transcriber.claudePath == nil || !store.settings.transcribe)
            }
            Divider().padding(.leading, 14)
            SettingRow("Your name", detail: "How you appear in transcripts. Each meeting can name the other speaker.") {
                TextField("", text: $store.settings.ownerName, prompt: Text("Me"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
        }
        SectionTitle("Screen")
        Card {
            SettingRow("Record the screen in quick recordings",
                       detail: "Also for calls that match no meeting. Each meeting has its own switch.") {
                Toggle("", isOn: $store.settings.recordScreen).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Divider().padding(.leading, 14)
            SettingRow("Display", detail: "Falls back to the main display when this one is unplugged.") {
                Picker("", selection: $store.settings.screenDisplayID) {
                    Text("Main display").tag(UInt32?.none)
                    ForEach(NSScreen.screens, id: \.self) { screen in
                        if let id = screen.displayID {
                            Text(screen.localizedName).tag(UInt32?.some(id))
                        }
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        SectionTitle("Quick recordings")
        Card {
            SettingRow("Next number", detail: "Next file: Recording #\(store.settings.quickRecordingNumber).m4a") {
                Stepper("#\(store.settings.quickRecordingNumber)", value: $store.settings.quickRecordingNumber, in: 1...9999)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
    }
}

private extension RecordingPage {
    var transcribeDetail: String {
        guard Transcriber.uvPath != nil else { return "Needs uv (astral.sh/uv) to run Whisper on this Mac." }
        let model = Transcriber.modelIsCached ? "" : " The Whisper model (1.6 GB) downloads once on first use."
        return "Whisper and speaker detection on Apple Silicon; the audio never leaves this Mac. "
            + "Saves a .md next to the recording." + model
    }

    var cleanDetail: String {
        guard Transcriber.claudePath != nil else { return "Needs the claude command-line tool (Claude Code)." }
        return "Fixes punctuation and misheard words, and names who's speaking. Sends the transcript's text, "
            + "never the audio, to Anthropic through the claude app."
    }
}

private struct RemindersPage: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        Card {
            SettingRow("Ask to record", detail: "A card in the top-right corner when a meeting starts.") {
                Picker("", selection: $store.settings.leadMinutes) {
                    Text("When it starts").tag(0)
                    Text("1 minute before").tag(1)
                    Text("5 minutes before").tag(5)
                }
                .labelsHidden()
                .fixedSize()
            }
            Divider().padding(.leading, 14)
            SettingRow("Ask to stop at the scheduled end", detail: "Stop & Save or Keep Recording.") {
                Toggle("", isOn: $store.settings.askToStopAtEnd).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Divider().padding(.leading, 14)
            SettingRow("Ask when I join or leave a call",
                       detail: "Zoom, Google Meet, Teams, Slack, FaceTime and other calls, even outside the scheduled time.") {
                Toggle("", isOn: $store.settings.askOnCalls).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
        Text("Nothing is ever recorded without your click.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

private struct GeneralPage: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        Card {
            SettingRow("Launch at login", detail: "Keeps the reminders working after a restart.") {
                Toggle("", isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }
                ))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
        SectionTitle("Permissions")
        Card {
            SettingRow("Calendar", detail: "To know when your meetings start.") {
                Button("Open…") { controller.openPrivacySettings("Privacy_Calendars") }
            }
            Divider().padding(.leading, 14)
            SettingRow("Microphone", detail: "To record your voice.") {
                Button("Open…") { controller.openPrivacySettings("Privacy_Microphone") }
            }
            Divider().padding(.leading, 14)
            SettingRow("Screen & System Audio Recording", detail: "For call audio, the screen video and call names.") {
                Button("Open…") { controller.openPrivacySettings("Privacy_ScreenCapture") }
            }
        }
    }
}

// MARK: - Building blocks

/// A rounded group of rows.
private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.headline).padding(.top, 6)
    }
}

/// Title and grey description on the left, the control on the right.
private struct SettingRow<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
