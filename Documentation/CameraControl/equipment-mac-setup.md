# Install the camera bridge test build on the equipment Mac

The app and background helper ship in one application bundle. This is an equipment-rehearsal prerelease from the fork: simulator checks passed; real CR-N500/RC-IP100 interoperability remains to establish.

## Download and install

1. Use **macOS 14 or later**. The universal download contains Apple silicon (`arm64`) and Intel (`x86_64`) executables. Runtime verification was performed on Apple silicon; Intel execution still needs confirmation on an Intel Mac.
2. Open the [camera bridge equipment test release](https://github.com/breakall/churchfront-video/releases/tag/camera-bridge-bench-2). Under **Assets**, download `Churchfront-Video-Camera-Bridge-macOS-universal.zip`. The automatic **Source code** downloads do not contain a built app. Xcode, Python and a separate helper installation are unnecessary for the app download.
3. Quit Churchfront Video. If replacing an older bridge build, use its **Setup → Cameras → Stop bridge** first. Keep the previous application in a backup location.
4. In Finder, use **Go → Go to Folder** to open `~/Library/Application Support/`. If `CueVideo` exists, copy that folder to a local backup before launching this build. It uses the existing Churchfront settings location and bundle identity. Record the RC-IP100 camera slot's original camera IP, port and credential configuration as well.
5. Unzip the download and move **Churchfront Video.app** into **Applications**. Open that copy and leave it there while its helper is registered.
6. This build is ad hoc signed and **not Apple notarized**. If macOS blocks launch, review the downloaded build and follow Apple's per-app **Privacy & Security → Open Anyway** process yourself. [Apple's guidance](https://support.apple.com/en-us/102445). Do not disable system-wide Gatekeeper protections.
7. Allow local-network access if prompted. If background execution requires approval, allow Churchfront Video in **System Settings → General → Login Items** (called **Login Items & Extensions** on some macOS versions), then use **Start bridge**. If the firewall prompts for the app/helper's incoming network access, allow the connection needed for this equipment test.

The release supplies `SHA256SUMS.txt` to compare the ZIP after download. A checksum detects accidental file differences; it does not replace notarization.

## Connect and configure

Connect the Mac, CR-N500 and RC-IP100 to the equipment network. Prefer wired Ethernet and a stable Mac address. Prevent sleep during the rehearsal. Keep the existing camera video and ATEM wiring.

Collect the Mac, camera and controller IP addresses, the camera's HTTP control port, both device firmware versions, and the Mac model/macOS version.

In Churchfront **Setup → Cameras**, configure the one real camera as **Canon (HTTP)** with its actual IP and control port. Keep this camera entry pointing at the real camera. Map it to its existing ATEM input and confirm the app's ATEM configuration for this Mac.

In **Physical camera controller**, set:

| Setting | Equipment value |
| --- | --- |
| Route the Canon camera through the controller bridge | On |
| Mac listener address | Mac's equipment-network IP, not `127.0.0.1` |
| Listener port | `18080`, or another available port |
| RC-IP100 address | Actual controller IP |
| Detailed bridge diagnostics | On for the initial rehearsal |
| Use RC-IP100 tracking control for Churchfront | Unavailable in this build; use the app's Track button |

Choose **Apply bridge settings**, then **Start bridge** if needed. Check its status message before continuing. The app's private authenticated helper connection uses loopback port `18082` by default; enter only the physical listener port on the controller.

On the RC-IP100, edit the camera slot's manual registration: change its camera destination to **the Mac listener IP and port**. Keep the camera credentials configured locally on the controller. Canon documents manual IP/port/user/password registration in its [RC-IP100 manual](https://gdlp01.c-wss.com/gds/5/0300041525/05/rcip130um-e.pdf). The controller's own IP and other switcher/controller connections retain their existing configuration.

```text
RC-IP100 → Mac equipment IP:18080 → helper → real CR-N500 IP:control port
Churchfront tracking → 127.0.0.1:18082 → same helper → same camera
```

Preview stays on Churchfront's existing camera-preview path. The helper does not emulate video or ATEM.

## First equipment rehearsal

Run outside a live service, with room for camera movement and unused preset/trace slots for store tests.

1. Confirm **Detailed bridge diagnostics** is enabled. With tracking off, check physical joystick movement and release, zoom, focus, preset store/recall, and trace recording/playback start/stop. Check for delayed stops, unexpected continued motion or control loss.
2. Put the camera on Next and start tracking through the app. Confirm **TRACKING / FOLLOWING**.
3. Move the RC-IP100 joystick. Confirm physical movement takes effect, the app returns to **TRACK**, FOLLOWING disappears, and **Manual control. Tracking is off.** appears. Release the control; tracking must stay off.
4. Explicitly start tracking again once controls are released. Repeat takeover separately with zoom, focus, preset actions and trace actions. These check the added forwarding/handoff, not tracking accuracy or camera positioning quality.
5. Hold a slow physical pan and turn detailed diagnostics off in Setup. Release the joystick and confirm the camera stops and tracking stays off. Turn diagnostics back on.
6. With tracking off, quit Churchfront and confirm physical forwarding continues. Reopen it and confirm it reconnects with tracking off.
7. Use **Export diagnostics…**. Record the release tag, device/OS versions, action sequence, approximate times and results alongside the local export.

The first pass must establish real authentication/session behavior, request/release forms, and that the RC-IP100 stays routed through the Mac. If direct control works but bridge control fails, save diagnostics and stop at that stage to resolve the protocol difference.

If the helper restarts, tracking stays fenced until successful physical pan/tilt, zoom and focus stops, fresh completion information, and a new explicit start. If the app shows unavailable status, use **Start bridge** and follow its recovery guidance.

## Restore the original route

1. Stop tracking and release physical controls.
2. Restore the RC-IP100 camera slot's original camera IP and port.
3. Turn off bridge routing and choose **Apply bridge settings**. Confirm the helper stops. **Stop bridge** also stops forwarding; quitting the app alone deliberately leaves it running.
4. Quit the test app before replacing it with the saved original. Restore the saved `CueVideo` folder while the app is closed if you want the exact pre-test settings.

## Source build

The source is on [`feat/camera-control-bridge`](https://github.com/breakall/churchfront-video/tree/feat/camera-control-bridge); the release tag fixes the source for this download. Developers with Xcode's Swift toolchain can build it:

```sh
git clone --branch camera-bridge-bench-2 https://github.com/breakall/churchfront-video.git
cd churchfront-video
./build.sh release universal
```

This writes `Churchfront Video.app` beside `build.sh`.
