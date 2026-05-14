# Muzzle MVP Brief

## Problem

When using a Mac in public or shared spaces, audio can unexpectedly play through the built-in speakers. The common failure cases are:

- headphones, AirPods, or another external output disconnects and macOS falls back to speakers
- the laptop wakes in a public place with speakers already selected
- the network environment changes, suggesting the user may have moved locations

This is not the same as mute. Mute relies on the user remembering to set it. The app should enforce a temporary safety policy around built-in speakers.

## Product Shape

The app is a tiny macOS menu bar utility called, for now, **Speaker Lock**.

Core rule:

> Built-in speakers are blocked in risky moments unless the user explicitly allows them.

Trusted outputs such as headphones, AirPods, Bluetooth audio, USB audio, and displays are allowed by default. The risky output is the built-in speaker device.

## MVP Modes

### Always Protection

Protects against audio falling back to built-in speakers after an output change.

Trigger:

- default output device changes

Policy:

```text
if always protection is enabled
and new output is built-in speakers
and previous output was not built-in speakers
and no temporary speaker allowance is active:
  mute/block built-in speakers
```

This means that if the Mac was already using built-in speakers, Always Protection does not immediately block them. It only reacts to a transition into speakers.

### Roaming Protection

Protects against opening or using the laptop in a likely new environment.

Triggers:

- wake from sleep
- Wi-Fi network identity changed
- Wi-Fi unavailable or disconnected
- material network path changed when Wi-Fi identity is unavailable

Policy:

```text
if roaming protection is enabled
and current output is built-in speakers
and no temporary speaker allowance is active:
  mute/block built-in speakers
```

Roaming Protection may block speakers even if they were already selected, because the risky event is the environment change, not an audio-device transition.

Network-change detection should treat Wi-Fi association as the primary 80/20 environment signal, not raw IP address churn.

Preferred MVP network signal:

```text
on broad network/path event:
  read current Wi-Fi identity

  if SSID changed:
    run roaming protection
  else if Wi-Fi changed between associated and not associated:
    run roaming protection
  else if Wi-Fi identity is unavailable and the material network path changed:
    run roaming protection
  else:
    ignore
```

SSID is the main signal because it usually represents a different environment. BSSID is useful diagnostic context, but a BSSID-only change should not trigger roaming protection by default. Large office, school, airport, and campus networks commonly use one SSID across many access points, and normal in-building roaming can change BSSID without meaning the user has entered a new environment.

Plain IP address changes are too noisy to use as the primary signal. DHCP renewal, VPN changes, IPv6 churn, captive portals, and sleep/wake transitions can change IP-related state while the user remains in the same place.

On current macOS, SSID and BSSID are location-sensitive. CoreWLAN is still the macOS-native API for Wi-Fi interface state, but SSID/BSSID may be unavailable unless Location Services is enabled and the user has authorized the app. The MVP should handle missing Wi-Fi identity gracefully and fall back to broader Network framework path changes instead of requiring location permission for the basic protection model.

## Temporary Speaker Allowance

The user can explicitly allow built-in speakers for a short period.

MVP options:

- allow built-in speakers for 5 minutes
- allow built-in speakers for 30 minutes
- block built-in speakers now

When the allowance expires, the next relevant policy check can block speakers again.

## Menu Bar UI

Initial menu:

```text
Speaker Lock

[x] Always protect on output changes
[x] Roaming protection

Status: Speakers blocked

Allow Built-in Speakers for 5 Minutes
Allow Built-in Speakers for 30 Minutes
Block Built-in Speakers Now

Quit
```

Status examples:

- `Speakers blocked`
- `Speakers allowed, 4m left`
- `AirPods allowed`
- `External output allowed`
- `Protection idle`

No settings window is required for MVP.

## State

Persist:

```text
alwaysProtectionEnabled: Bool
roamingProtectionEnabled: Bool
speakerAllowanceUntil: Date?
lastKnownOutputDeviceID: AudioDeviceID?
lastProtectionReason: outputChanged | wake | networkChanged | manual
```

## Out Of Scope

Not in the MVP:

- trusted Wi-Fi networks
- location detection
- calendar detection
- trusted places
- per-device approval rules
- pausing media
- complex volume restoration
- "allow until sleep"
- onboarding
- notifications, unless needed for debugging
- launch at login, unless it is trivial to add

## Implementation Direction

Target modern macOS 26.0.

Likely stack:

- Swift
- SwiftUI menu bar app
- Tuist project later
- CoreAudio for output device observation and muting
- AppKit or NSWorkspace notifications for wake/sleep
- Network framework for broad path-change observation
- CoreWLAN for Wi-Fi identity when Location Services authorization allows it
- UserDefaults for MVP state

The first useful build should:

1. run as a menu bar app
2. observe default audio output changes
3. identify the built-in speakers
4. mute/block when Always Protection sees a transition into speakers
5. mute/block when Roaming Protection fires while speakers are selected
6. support 5-minute and 30-minute temporary speaker allowances
