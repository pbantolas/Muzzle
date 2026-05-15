import AppKit
import SwiftUI

@main
struct MuzzleApp: App {
    @State private var speakerLock = SpeakerLockState()

    var body: some Scene {
        MenuBarExtra {
            SpeakerLockMenu(state: speakerLock)
        } label: {
            MenuBarIconRenderer.image(for: menuBarIconState)
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarIconState: MenuBarIconState {
        guard speakerLock.alwaysProtectionEnabled || speakerLock.roamingProtectionEnabled else {
            return .off
        }

        if speakerLock.isProtectionPauseActive {
            return .paused
        }

        return .active
    }
}

private enum MenuBarIconState: Hashable {
    case off
    case paused
    case active

    var muzzleOpacity: Double {
        switch self {
        case .off:
            0.35
        case .paused:
            0.55
        case .active:
            1
        }
    }
}

@MainActor
private enum MenuBarIconRenderer {
    private static var cache: [MenuBarIconState: NSImage] = [:]

    static func image(for state: MenuBarIconState) -> Image {
        if let cachedImage = cache[state] {
            return Image(nsImage: cachedImage)
        }

        let renderer = ImageRenderer(
            content: MenuBarIcon(state: state)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        guard let nsImage = renderer.nsImage else {
            return Image("SpeakerLockMenuBarBars").renderingMode(.template)
        }

        nsImage.isTemplate = true
        nsImage.size = NSSize(width: 30, height: 18)
        cache[state] = nsImage

        return Image(nsImage: nsImage)
    }
}

private struct MenuBarIcon: View {
    let state: MenuBarIconState

    var body: some View {
        ZStack {
            Image("SpeakerLockMenuBarBars")
                .renderingMode(.template)

            Image("SpeakerLockMenuBarMuzzle")
                .renderingMode(.template)
                .opacity(state.muzzleOpacity)
        }
        .frame(width: 30, height: 18)
    }
}
