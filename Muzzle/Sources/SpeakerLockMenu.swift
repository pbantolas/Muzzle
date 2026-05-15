import SwiftUI

struct SpeakerLockMenu: View {
    @Bindable var state: SpeakerLockState

    var body: some View {
        statusRow

        Divider()

        Button("Pause protection for 5 minutes", systemImage: "pause.circle") {
            state.pauseProtection(for: 5 * 60)
        }

        Button("Pause protection for 30 minutes", systemImage: "pause.circle") {
            state.pauseProtection(for: 30 * 60)
        }

        if state.isProtectionPauseActive {
            Button("Resume protection now", systemImage: "play.circle") {
                state.resumeProtectionNow()
            }
        }

        Divider()

        Toggle("Block when headphones disconnect", isOn: $state.alwaysProtectionEnabled)
        Toggle("Block when changing location", isOn: $state.roamingProtectionEnabled)
        Toggle("Start at Login", isOn: $state.startAtLoginEnabled)

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
