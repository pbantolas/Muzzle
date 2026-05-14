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
            content: MenuBarStatusIcon(badgeSystemImage: speakerLock.menuBarBadgeSystemImage)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        guard let nsImage = renderer.nsImage else {
            return Image(systemName: "waveform")
        }

        nsImage.isTemplate = true
        return Image(nsImage: nsImage)
    }
}

private struct MenuBarStatusIcon: View {
    let badgeSystemImage: String?

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 18, weight: .regular))
            .overlay(alignment: .bottomTrailing) {
                if let badgeSystemImage {
                    Image(systemName: badgeSystemImage)
                        .foregroundStyle(.red)
                        .font(.system(size: 10, weight: .bold))
//                        .alignmentGuide(.bottom) { dimensions in
//                            dimensions[.bottom] - 1
//                        }
                }
            }
    }
}
