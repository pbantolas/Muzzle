import SwiftUI

struct SpeakerLockMenu: View {
    @Bindable var state: SpeakerLockState

    var body: some View {
        Toggle("Always protect on output changes", isOn: $state.alwaysProtectionEnabled)
        Toggle("Roaming protection", isOn: $state.roamingProtectionEnabled)

        Divider()

        statusLabel
        outputLabel

        if let lastAudioActionMessage = state.lastAudioActionMessage {
            Label(lastAudioActionMessage, systemImage: "waveform")
        }
        if let lastDiagnosticsCopyMessage = state.lastDiagnosticsCopyMessage {
            Label(lastDiagnosticsCopyMessage, systemImage: "doc.on.clipboard")
        }
        if let currentOutput = state.currentOutput {
            Label(currentOutput.builtInSpeakerDetectionReason, systemImage: "info.circle")
        }

        Divider()

        Label(state.networkDebugState.wifiSummary, systemImage: "wifi")
        Label(state.networkDebugState.wifiIdentitySummary, systemImage: "location")
        Label(state.networkDebugState.locationAuthorizationSummary, systemImage: "location.circle")
        Label(state.networkDebugState.pathSummary, systemImage: "point.3.connected.trianglepath.dotted")
        Label(state.networkDebugState.triggerSummary, systemImage: "arrow.triangle.branch")

        Divider()

        Button("Refresh Current Output", systemImage: "arrow.clockwise") {
            state.refreshCurrentOutput()
        }

        Button("Copy Diagnostics", systemImage: "doc.on.doc") {
            state.copyDiagnosticsToClipboard()
        }

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

    private var outputLabel: some View {
        Label {
            Text("Output: \(state.currentOutput?.name ?? "Unknown")")
        } icon: {
            Image(systemName: state.currentOutput?.isBuiltInSpeaker == true ? "speaker" : "headphones")
        }
    }
}

#Preview {
    SpeakerLockMenu(state: SpeakerLockState())
}
