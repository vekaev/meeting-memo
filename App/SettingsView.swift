import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var calendar: CalendarWatcher

    var body: some View {
        Form {
            Section {
                if store.settings.rules.isEmpty {
                    Text("No meetings yet. Add one from your calendar, or add a rule by hand.")
                        .foregroundStyle(.secondary)
                }
                ForEach($store.settings.rules) { $rule in
                    RuleRow(rule: $rule) {
                        store.settings.rules.removeAll { $0.id == rule.id }
                        calendar.refresh()
                    }
                }
                HStack {
                    Menu("Add from Calendar") {
                        if calendar.eventTitles.isEmpty {
                            Text("No events in the next 2 weeks")
                        }
                        ForEach(calendar.eventTitles) { event in
                            Button("\(event.title) — \(event.nextStart.formatted(.dateTime.weekday(.abbreviated).hour().minute()))") {
                                controller.addRule(from: event.title)
                            }
                        }
                    }
                    .fixedSize()
                    Button("Add Rule") {
                        store.settings.rules.append(Rule(name: "New meeting", matchText: ""))
                    }
                }
            } header: {
                Text("Meetings to record")
            } footer: {
                Text("A calendar event matches when its title contains the text. Recordings are named “Name #N — date time”.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Recording") {
                LabeledContent("Save to") {
                    HStack {
                        Text(store.settings.outputFolder)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { controller.chooseOutputFolder() }
                    }
                }
                Picker("Ask to record", selection: $store.settings.leadMinutes) {
                    Text("When the meeting starts").tag(0)
                    Text("1 minute before").tag(1)
                    Text("5 minutes before").tag(5)
                }
                Toggle("Record call audio (other participants)", isOn: $store.settings.recordCallAudio)
                Toggle("Record the screen too (saves a .mov next to the audio)", isOn: $store.settings.recordScreen)
                Picker("Screen", selection: $store.settings.screenDisplayID) {
                    Text("Main display").tag(UInt32?.none)
                    ForEach(NSScreen.screens, id: \.self) { screen in
                        if let id = screen.displayID {
                            Text(screen.localizedName).tag(UInt32?.some(id))
                        }
                    }
                }
                .disabled(!store.settings.recordScreen)
                Toggle("Ask to stop when the meeting is scheduled to end", isOn: $store.settings.askToStopAtEnd)
                Stepper("Next quick recording: #\(store.settings.quickRecordingNumber)",
                        value: $store.settings.quickRecordingNumber, in: 1...9999)
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }
                ))
                LabeledContent("Permissions") {
                    HStack {
                        Button("Calendar") { controller.openPrivacySettings("Privacy_Calendars") }
                        Button("Microphone") { controller.openPrivacySettings("Privacy_Microphone") }
                        Button("Screen & Audio") { controller.openPrivacySettings("Privacy_ScreenCapture") }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 520)
        .onChange(of: store.settings.rules) { calendar.refresh() }
    }
}

private struct RuleRow: View {
    @Binding var rule: Rule
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("", isOn: $rule.enabled).labelsHidden()
                TextField("Name", text: $rule.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.headline)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            HStack {
                TextField("Calendar title contains…", text: $rule.matchText)
                    .textFieldStyle(.roundedBorder)
                Stepper("Next #\(rule.nextNumber)", value: $rule.nextNumber, in: 1...9999)
                    .fixedSize()
            }
            Text("Next file: \(Naming.title(name: rule.name, number: rule.nextNumber, date: Date())).m4a")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
