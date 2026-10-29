import AppKit
import SwiftUI

/// What the prompt card says and offers.
struct PromptContent {
    var title: String
    /// Grey text after the title: "now", "in 5 min", "ended".
    var when: String
    /// Other attendees, shown as initials and names.
    var people: [String] = []
    /// Shown instead of the attendees when there are none.
    var fallbackDetail: String
    var primary: String
    var primarySymbol: String
    var secondary: String
    /// Extra actions under the chevron.
    var options: [(title: String, action: () -> Void)] = []
    /// The Screen switch on the card; nil hides it.
    var screen: Bool? = nil
    var onScreenChange: (Bool) -> Void = { _ in }
}

/// A floating card in the top-right corner that does not steal focus from the meeting app.
@MainActor
final class PromptPanel {
    private var panel: NSPanel?
    var isShowing: Bool { panel != nil }

    func show(_ content: PromptContent, onPrimary: @escaping () -> Void, onSecondary: @escaping () -> Void) {
        close()
        var content = content
        content.options = content.options.map { option in
            (option.title, { [weak self] in self?.close(); option.action() })
        }
        let view = PromptView(
            content: content,
            onPrimary: { [weak self] in self?.close(); onPrimary() },
            onSecondary: { [weak self] in self?.close(); onSecondary() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above normal floating windows, so full-screen meeting apps and Stage Manager don't hide it.
        panel.level = .statusBar
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false

        // The screen the pointer is on is the one being looked at; NSScreen.main follows the key window instead.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 12,
                                         y: frame.maxY - panel.frame.height - 12))
        }
        panel.orderFrontRegardless()
        NSSound(named: "Glass")?.play()
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct PromptView: View {
    let content: PromptContent
    let onPrimary: () -> Void
    let onSecondary: () -> Void
    @State private var screen: Bool

    init(content: PromptContent, onPrimary: @escaping () -> Void, onSecondary: @escaping () -> Void) {
        self.content = content
        self.onPrimary = onPrimary
        self.onSecondary = onSecondary
        _screen = State(initialValue: content.screen ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(content.title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Text(content.when)
                    .font(.system(size: 17))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 8)
                if !content.options.isEmpty {
                    Menu {
                        ForEach(content.options.indices, id: \.self) { index in
                            Button(content.options[index].title, action: content.options[index].action)
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }

            HStack(spacing: 8) {
                if content.people.isEmpty {
                    Image(systemName: "waveform")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(content.fallbackDetail)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Avatars(names: content.people)
                    Text(PeopleText.summary(content.people))
                        .lineLimit(1).truncationMode(.tail)
                }
                if content.screen != nil {
                    Spacer(minLength: 8)
                    Toggle(isOn: $screen) {
                        Text("Screen").font(.system(size: 13))
                    }
                    .toggleStyle(CardSwitchStyle())
                    .fixedSize()
                    .help("Also save a screen video")
                    .onChange(of: screen) { content.onScreenChange(screen) }
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(.secondary)

            HStack {
                Button(content.secondary, action: onSecondary)
                    .buttonStyle(CardButtonStyle(prominent: false))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: onPrimary) {
                    HStack(spacing: 7) {
                        Image(systemName: content.primarySymbol).foregroundStyle(.red)
                        Text(content.primary)
                    }
                }
                .buttonStyle(CardButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(width: 400)
        .background(CardColors.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(CardColors.rim, lineWidth: 1.5)
        )
        .padding(2)
    }
}

/// Overlapping initials for the first three attendees.
private struct Avatars: View {
    let names: [String]
    private static let tints: [Color] = [.blue, .orange, .purple, .teal, .pink, .green, .indigo]

    var body: some View {
        HStack(spacing: -6) {
            ForEach(Array(names.prefix(3).enumerated()), id: \.offset) { _, name in
                Text(PeopleText.initials(name))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Self.tint(for: name), in: Circle())
                    .overlay(Circle().strokeBorder(CardColors.background, lineWidth: 1.5))
            }
        }
    }

    private static func tint(for name: String) -> Color {
        tints[abs(name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % tints.count]
    }
}

enum PeopleText {
    /// "Ari Korin", "Brian Johnson, Roey Paz-Priel and 18 more".
    static func summary(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]) and \(names[2])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    static func initials(_ name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return String(letters).uppercased()
    }
}

private enum CardColors {
    static let background = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.16, alpha: 1)
            : NSColor(white: 0.955, alpha: 1)
    })

    /// The soft multicolour rim around the card.
    static let rim = AngularGradient(
        colors: ([.blue, .purple, .pink, .orange, .yellow, .green, .teal, .blue] as [Color]).map { $0.opacity(0.55) },
        center: .center
    )
}

/// A small switch that reads clearly on a card that is never the key window
/// (the system switch turns grey there, on or off).
private struct CardSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 7) {
                configuration.label
                Capsule()
                    .fill(configuration.isOn ? Color.primary : Color.primary.opacity(0.14))
                    .frame(width: 28, height: 16)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(configuration.isOn ? CardColors.background : Color.white)
                            .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
                            .padding(2)
                    }
                    .animation(.easeOut(duration: 0.12), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CardButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? Color(nsColor: .windowBackgroundColor) : .primary)
            .padding(.horizontal, prominent ? 18 : 16)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(prominent ? Color.primary : Color.primary.opacity(0.06))
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
