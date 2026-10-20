import AppKit
import SwiftUI

/// A floating card in the top-right corner that does not steal focus from the meeting app.
@MainActor
final class PromptPanel {
    private var panel: NSPanel?

    func show(symbol: String, title: String, subtitle: String, primary: String, secondary: String,
              onPrimary: @escaping () -> Void, onSecondary: @escaping () -> Void) {
        close()
        let view = PromptView(
            symbol: symbol, title: title, subtitle: subtitle, primary: primary, secondary: secondary,
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
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 16,
                                         y: frame.maxY - panel.frame.height - 16))
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
    let symbol: String
    let title: String
    let subtitle: String
    let primary: String
    let secondary: String
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 24))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).lineLimit(2)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            HStack {
                Spacer()
                Button(secondary, action: onSecondary)
                Button(primary, action: onPrimary)
                    .keyboardShortcut(.defaultAction)
                    .tint(.red)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(16)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
