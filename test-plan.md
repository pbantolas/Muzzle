# Manual Test Plan

## Audio Detection

1. Generate and run the app:

   ```sh
   tuist generate
   tuist xcodebuild build -scheme DontBlastMySound
   open DontBlastMySound.xcworkspace
   ```

2. Run the `DontBlastMySound` scheme from Xcode.

3. Open the menu bar item and verify:

   - `Output:` shows the current macOS default output device
   - built-in speakers show the speaker icon
   - headphones, AirPods, displays, or other outputs show the headphones icon
   - the detection reason explains the classification, preferably `built-in transport with speaker output terminal` for Mac speakers

4. Switch the system output device in Control Center or System Settings.

5. Reopen the menu bar item and verify:

   - the output name changed
   - the last audio action says `Output changed to ...`

6. Click `Refresh Current Output` and verify the same current output remains visible.

## Manual Speaker Block

1. Select the Mac's built-in speakers as the current output.

2. Open the app menu.

3. Click `Block Built-in Speakers Now`.

4. Verify:

   - macOS output is muted, if the built-in speaker device exposes a mute control
   - the menu says `Muted ...`
   - if mute is unsupported, the menu says `Could not mute ...`
   - if mute is unsupported but volume is writable, the menu says `Set ... volume to 0`

5. Select headphones, AirPods, or another external output.

6. Click `Block Built-in Speakers Now`.

7. Verify:

   - the external output is not muted
   - the menu says the current output is not detected as built-in speakers

## Logs

Stream app logs while testing:

```sh
log stream --style compact --predicate 'subsystem == "DontBlastMySound"'
```

Useful events:

- current default output metadata
- output change notifications
- whether an output was detected as built-in speakers
- CoreAudio transport, data source, terminal type, and detection reason
- mute success or failure status
- volume fallback success or failure status

## Always Protection

1. Enable `Always protect on output changes`.

2. Click `Allow Built-in Speakers for 5 Minutes`, then `Block Built-in Speakers Now` to clear any existing allowance and force protection back on.

3. Select AirPods, headphones, or another non-speaker output.

4. Start audio playback.

5. Disconnect the external output.

6. Verify:

   - playback may pause because of macOS or the media app
   - the app menu says `Muted ...` or `Set ... volume to 0`
   - resuming playback does not produce audible built-in speaker output
   - logs show an output change into built-in speakers and `reason=outputChanged`

7. Repeat while a 5-minute speaker allowance is active.

8. Verify:

   - the output change is detected
   - the app does not mute or lower volume while the allowance is active

## Known Limits Of This Pass

- Always Protection is enabled for output changes into built-in speakers.
- Roaming Protection is not enabled yet.
- Built-in speaker detection primarily uses CoreAudio built-in transport plus output stream terminal type. Device/data-source text is a fallback only.
- If a device has no CoreAudio mute control, this pass reports that instead of changing volume.
