import SwiftUI

struct SpeakerLockMenu: View {
    @Bindable var state: SpeakerLockState

    var body: some View {
        Toggle("Always protect on output changes", isOn: $state.alwaysProtectionEnabled)
        Toggle("Roaming protection", isOn: $state.roamingProtectionEnabled)

        Divider()

        statusLabel

        Divider()

        Button("Allow Built-in Speakers for 5 Minutes", systemImage: "speaker.wave.2") {
            state.allowSpeakers(for: 5 * 60)
        }

        Button("Allow Built-in Speakers for 30 Minutes", systemImage: "speaker.wave.2") {
            state.allowSpeakers(for: 30 * 60)
        }

        Button("Block Built-in Speakers Now", systemImage: "speaker.slash") {
            state.blockSpeakersNow()
        }

        Divider()

        Button("Quit", systemImage: "power") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusLabel: some View {
        Label {
            Text("Status: \(state.statusText)")
        } icon: {
            Image(systemName: state.menuBarSystemImage)
        }
    }
}

#Preview {
    SpeakerLockMenu(state: SpeakerLockState())
}
