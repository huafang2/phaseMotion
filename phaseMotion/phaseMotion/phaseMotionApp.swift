//
//  phaseMotionApp.swift
//  phaseMotion
//
//  Created by Chiu Hau Hwa on 2026/1/4.
//

import SwiftUI
#if os(macOS)
import AppKit

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#endif

@main
struct phaseMotionApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
