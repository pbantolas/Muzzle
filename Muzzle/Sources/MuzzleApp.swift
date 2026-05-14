import AppKit
import SwiftUI

@main
struct MuzzleApp: App {
    @State private var speakerLock = SpeakerLockState()

    var body: some Scene {
        MenuBarExtra {
            SpeakerLockMenu(state: speakerLock)
        } label: {
            renderedMenuBarIcon
        }
        .menuBarExtraStyle(.menu)
    }

    private var renderedMenuBarIcon: Image {
        let renderer = ImageRenderer(
            content: MenuBarIcon(isProtectionEnabled: speakerLock.alwaysProtectionEnabled || speakerLock.roamingProtectionEnabled)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        guard let nsImage = renderer.nsImage else {
            return Image("SpeakerLockMenuBarBars").renderingMode(.template)
        }

        nsImage.isTemplate = true
        nsImage.size = NSSize(width: 30, height: 18)
        return Image(nsImage: nsImage)
    }
}

private struct MenuBarIcon: View {
    let isProtectionEnabled: Bool

    var body: some View {
        ZStack {
            Image("SpeakerLockMenuBarBars")
                .renderingMode(.template)

            Image("SpeakerLockMenuBarMuzzle")
                .renderingMode(.template)
                .opacity(isProtectionEnabled ? 1 : 0.35)
        }
        .frame(width: 30, height: 18)
    }
}
