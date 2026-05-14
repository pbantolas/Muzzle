import SwiftUI

struct SpeakerLockMenu: View {
    @Bindable var state: SpeakerLockState

    var body: some View {
        statusRow

        Divider()

        Button("Allow for 5 minutes", systemImage: "speaker.wave.2") {
            state.allowSpeakers(for: 5 * 60)
        }

        Button("Allow for 30 minutes", systemImage: "speaker.wave.2") {
            state.allowSpeakers(for: 30 * 60)
        }

        Divider()

        Toggle("Block when headphones disconnect", isOn: $state.alwaysProtectionEnabled)
        Toggle("Block when changing location", isOn: $state.roamingProtectionEnabled)

        Divider()

        Menu("Network info") {
            Label(state.networkInfoSummary, systemImage: "wifi")
            Label(state.networkDebugState.locationAuthorizationSummary, systemImage: "location.circle")

#if DEBUG
            Divider()
            Label(state.networkDebugState.wifiIdentitySummary, systemImage: "network")
            Label(state.networkDebugState.pathSummary, systemImage: "point.3.connected.trianglepath.dotted")
            Label(state.networkDebugState.triggerSummary, systemImage: "arrow.triangle.branch")

            if let currentOutput = state.currentOutput {
                Label(currentOutput.builtInSpeakerDetectionReason, systemImage: "info.circle")
            }

            if let lastAudioActionMessage = state.lastAudioActionMessage {
                Label(lastAudioActionMessage, systemImage: "waveform")
            }
#endif
        }

        Button("Refresh Status", systemImage: "arrow.clockwise") {
            state.refreshCurrentOutput()
        }

        Button("Copy Diagnostics", systemImage: "doc.on.doc") {
            state.copyDiagnosticsToClipboard()
        }

#if DEBUG
        Button("Block Built-in Speakers Now", systemImage: "speaker.slash") {
            state.blockSpeakersNow()
        }
#endif

        Divider()

        Button("Quit", systemImage: "power") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusRow: some View {
        Label {
            Text(state.statusMenuTitle)
                .fontWeight(.semibold)
        } icon: {
            Image(systemName: state.statusMenuIcon)
        }
    }
}

#Preview {
    SpeakerLockMenu(state: SpeakerLockState())
}
