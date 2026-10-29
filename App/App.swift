import AppKit
import SwiftUI

@main
struct MeetingMemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = AppController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(controller)
                .environmentObject(controller.store)
                .environmentObject(controller.calendar)
        } label: {
            if controller.active != nil {
                Image(nsImage: MenuBarLabel.recording(controller.elapsedText.isEmpty ? "00:00" : controller.elapsedText))
            } else if controller.pendingOffer != nil || controller.pendingCall != nil {
                Image(nsImage: MenuBarLabel.pending)
            } else {
                Image(nsImage: MenuBarLabel.idle)
            }
        }
        .menuBarExtraStyle(.window)

        Window("MeetingMemo Settings", id: "settings") {
            SettingsView()
                .environmentObject(controller)
                .environmentObject(controller.store)
                .environmentObject(controller.calendar)
        }
        .windowResizability(.contentSize)
    }
}

extension AppController {
    static let shared = AppController()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppController.shared.active != nil else { return .terminateNow }
        Task { @MainActor in
            await AppController.shared.prepareToQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
