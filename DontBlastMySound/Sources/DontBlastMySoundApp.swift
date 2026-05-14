import SwiftUI

@main
struct DontBlastMySoundApp: App {
    @State private var speakerLock = SpeakerLockState()

    var body: some Scene {
        MenuBarExtra {
            SpeakerLockMenu(state: speakerLock)
        } label: {
            Label("Speaker Lock", systemImage: speakerLock.menuBarSystemImage)
        }
        .menuBarExtraStyle(.menu)
    }
}
