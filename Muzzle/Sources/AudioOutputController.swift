import CoreAudio
import Foundation
import OSLog

struct AudioOutputDevice: Equatable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let transportType: UInt32?
    let dataSourceID: UInt32?
    let outputTerminalTypes: [UInt32]

    var isBuiltInSpeaker: Bool {
        builtInSpeakerDetection.isMatch
    }

    var builtInSpeakerDetectionReason: String {
        builtInSpeakerDetection.reason
    }

    private var builtInSpeakerDetection: (isMatch: Bool, reason: String) {
        guard transportType == kAudioDeviceTransportTypeBuiltIn else {
            return (false, "transport is \(transportType.map(fourCharacterCode) ?? "unknown"), not built-in")
        }

        if outputTerminalTypes.contains(kAudioStreamTerminalTypeHeadphones) {
            return (false, "built-in transport, but output terminal is headphones")
        }

        if outputTerminalTypes.contains(where: Self.isSpeakerTerminalType) {
            return (true, "built-in transport with speaker output terminal")
        }

        let searchableText = "\(name) \(uid)".lowercased()

        if searchableText.contains("speaker") {
            return (true, "built-in transport with speaker text fallback")
        }

        return (false, "built-in transport without speaker terminal/text evidence")
    }

    private static func isSpeakerTerminalType(_ terminalType: UInt32) -> Bool {
        terminalType == kAudioStreamTerminalTypeSpeaker
            || terminalType == kAudioStreamTerminalTypeLFESpeaker
            || terminalType == kAudioStreamTerminalTypeReceiverSpeaker
    }
}

final class AudioOutputController {
    private let logger = Logger(subsystem: "Muzzle", category: "AudioOutput")
    private var isObservingDefaultOutput = false

    var onDefaultOutputChanged: (@MainActor (AudioOutputDevice?) -> Void)?

    deinit {
        stopObservingDefaultOutput()
    }

    func currentDefaultOutput() -> AudioOutputDevice? {
        var deviceID = AudioDeviceID()
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr else {
            logger.error("Failed to read default output device. status=\(status)")
            return nil
        }

        let device = AudioOutputDevice(
            id: deviceID,
            name: stringProperty(kAudioObjectPropertyName, for: deviceID) ?? "Unknown Output",
            uid: stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID) ?? "",
            transportType: uint32Property(kAudioDevicePropertyTransportType, for: deviceID),
            dataSourceID: uint32Property(kAudioDevicePropertyDataSource, for: deviceID, scope: kAudioDevicePropertyScopeOutput),
            outputTerminalTypes: outputTerminalTypes(for: deviceID)
        )

        logger.info(
            "Default output: id=\(device.id), name=\(device.name, privacy: .public), uid=\(device.uid, privacy: .public), transport=\(device.transportType.map(fourCharacterCode) ?? "unknown", privacy: .public), dataSourceID=\(device.dataSourceID.map(fourCharacterCode) ?? "unknown", privacy: .public), terminals=\(device.outputTerminalTypes.map(fourCharacterCode).joined(separator: ","), privacy: .public), builtInSpeaker=\(device.isBuiltInSpeaker), reason=\(device.builtInSpeakerDetectionReason, privacy: .public)"
        )

        return device
    }

    func setMuted(_ isMuted: Bool, for device: AudioOutputDevice) -> Bool {
        guard hasMuteControl(for: device.id) else {
            logger.error("Output device does not expose a mute control: \(device.name, privacy: .public)")
            return false
        }

        var muteValue: UInt32 = isMuted ? 1 : 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            device.id,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &muteValue
        )

        guard status == noErr else {
            logger.error("Failed to set mute=\(isMuted) for \(device.name, privacy: .public). status=\(status)")
            return false
        }

        logger.info("Set mute=\(isMuted) for \(device.name, privacy: .public)")
        return true
    }

    func setVolume(_ volume: Float32, for device: AudioOutputDevice) -> Bool {
        let clampedVolume = min(max(volume, 0), 1)

        if setVolume(clampedVolume, for: device.id, element: kAudioObjectPropertyElementMain) {
            logger.info("Set main output volume=\(clampedVolume) for \(device.name, privacy: .public)")
            return true
        }

        let didSetChannelVolume = [UInt32(1), UInt32(2)].contains { element in
            setVolume(clampedVolume, for: device.id, element: element)
        }

        if didSetChannelVolume {
            logger.info("Set channel output volume=\(clampedVolume) for \(device.name, privacy: .public)")
            return true
        }

        logger.error("Output device does not expose a writable volume control: \(device.name, privacy: .public)")
        return false
    }

    func startObservingDefaultOutput() {
        guard !isObservingDefaultOutput else {
            return
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            defaultOutputChangedListener,
            Unmanaged.passUnretained(self).toOpaque()
        )

        guard status == noErr else {
            logger.error("Failed to observe default output changes. status=\(status)")
            return
        }

        isObservingDefaultOutput = true
        logger.info("Started observing default output changes")
    }

    private func stopObservingDefaultOutput() {
        guard isObservingDefaultOutput else {
            return
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            defaultOutputChangedListener,
            Unmanaged.passUnretained(self).toOpaque()
        )

        if status != noErr {
            logger.error("Failed to stop observing default output changes. status=\(status)")
        }

        isObservingDefaultOutput = false
    }

    fileprivate func handleDefaultOutputChanged() {
        let output = currentDefaultOutput()

        Task { @MainActor in
            onDefaultOutputChanged?(output)
        }
    }

    private func hasMuteControl(for deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        return AudioObjectHasProperty(deviceID, &address)
    }

    private func setVolume(_ volume: Float32, for deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        var isSettable: DarwinBoolean = false
        let settableStatus = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)

        guard settableStatus == noErr, isSettable.boolValue else {
            return false
        }

        var mutableVolume = volume
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &mutableVolume
        )

        if status != noErr {
            logger.error("Failed to set volume for device \(deviceID), element \(element). status=\(status)")
            return false
        }

        return true
    }

    private func stringProperty(_ selector: AudioObjectPropertySelector, for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?

        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }

        guard status == noErr else {
            logger.error("Failed to read string property \(selector) for device \(deviceID). status=\(status)")
            return nil
        }

        return value as String?
    }

    private func uint32Property(
        _ selector: AudioObjectPropertySelector,
        for deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)

        guard status == noErr else {
            logger.error("Failed to read UInt32 property \(selector) for device \(deviceID). status=\(status)")
            return nil
        }

        return value
    }

    private func outputTerminalTypes(for deviceID: AudioDeviceID) -> [UInt32] {
        let streamIDs = audioStreamIDs(for: deviceID)

        return streamIDs.compactMap { streamID in
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyTerminalType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var dataSize = UInt32(MemoryLayout<UInt32>.size)
            var value: UInt32 = 0

            let status = AudioObjectGetPropertyData(streamID, &address, 0, nil, &dataSize, &value)

            guard status == noErr else {
                logger.error("Failed to read terminal type for stream \(streamID). status=\(status)")
                return nil
            }

            return value
        }
    }

    private func audioStreamIDs(for deviceID: AudioDeviceID) -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)

        guard status == noErr else {
            logger.error("Failed to read output stream data size for device \(deviceID). status=\(status)")
            return []
        }

        guard dataSize > 0 else {
            return []
        }

        let streamCount = Int(dataSize) / MemoryLayout<AudioStreamID>.size
        var streamIDs = Array(repeating: AudioStreamID(), count: streamCount)

        status = streamIDs.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return kAudioHardwareBadObjectError
            }

            return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, baseAddress)
        }

        guard status == noErr else {
            logger.error("Failed to read output streams for device \(deviceID). status=\(status)")
            return []
        }

        return streamIDs
    }
}

private let defaultOutputChangedListener: AudioObjectPropertyListenerProc = { _, _, _, context in
    guard let context else {
        return noErr
    }

    let controller = Unmanaged<AudioOutputController>.fromOpaque(context).takeUnretainedValue()
    controller.handleDefaultOutputChanged()

    return noErr
}

private func fourCharacterCode(_ value: UInt32) -> String {
    let scalars = [
        UnicodeScalar((value >> 24) & 0xff),
        UnicodeScalar((value >> 16) & 0xff),
        UnicodeScalar((value >> 8) & 0xff),
        UnicodeScalar(value & 0xff),
    ]

    let string = String(String.UnicodeScalarView(scalars.compactMap(\.self)))
    return string.allSatisfy(\.isASCII) ? string : "\(value)"
}
