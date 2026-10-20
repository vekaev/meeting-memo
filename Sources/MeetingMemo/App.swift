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
                Label(controller.elapsedText, systemImage: "record.circle.fill")
                    .labelStyle(.titleAndIcon)
            } else {
                Image(systemName: "waveform.circle")
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
