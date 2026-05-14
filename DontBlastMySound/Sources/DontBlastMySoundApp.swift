import SwiftUI

@main
struct DontBlastMySoundApp: App {
    @State private var speakerLock = SpeakerLockState()

    var body: some Scene {
        MenuBarExtra {
            SpeakerLockMenu(state: speakerLock)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "waveform")
                if let badge = speakerLock.menuBarBadgeSystemImage {
                    Image(systemName: badge)
                        .font(.system(size: 6.5, weight: .bold))
                        .offset(x: 4, y: 3)
                }
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
