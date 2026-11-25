# Camera bridge handoff, 2026-11-25

## Checkpoint status

This branch contains work in progress from equipment testing on the Mac. The native helper owns and renews one Canon camera session. The RC-IP100 receives a separate local session. Its open, claim, yield, close and session requests terminate at the bridge. Physical input revokes tracking and takes priority. Camera session loss invalidates queued movement and requires a confirmed stop after reconnection. Tracking requires explicit reactivation.

Other changes include bounded, sanitized diagnostics, recovery from Canon status headers containing descriptive text, autofocus-aware startup recovery, automatic helper re-registration after an update, and controller status translation for fixed, chunked and multipart responses. Sessionless discovery preserves original fixed-length camera response bytes when translation is unnecessary.

## Unresolved equipment issues

1. After session virtualization, the RC-IP100 reported the camera disconnected. Logs showed repeated sessionless info.cgi probes, with no open.cgi or joystick commands. The discovery response preservation change builds and passes regression checks. Its effect on the physical controller remains unverified.
2. Tracking oscillated heavily. The tracker commanded 11 pan reversals and speeds up to 9890/10000 in one capture, and the camera accepted those commands. This branch contains no tracking stability correction. Inspect preview latency, position telemetry timing and the feedback calculation in Sources/CueVideo/Tracker.swift before live tracking tests.
3. The final discovery build was installed locally. Its deployment script timed out waiting for helper attachment and upstream session verification. Recheck the installed service before assuming it is running that build.

## Validation

The packaged discovery helper passed 69 black-box bridge scenarios in both simulated camera ownership profiles, plus 38 Python unit and diagnostics checks. Scenarios include local controller lifecycle, idle privilege renewal, expiration during release, confirmed recovery stop, stale queued movement rejection, physical takeover and explicit tracking restart. Five focused Swift test bodies were also exercised through standalone harnesses. XCTest could not run through this Mac's command-line-only developer tools. Physical controller interoperability and the app tracking feedback loop require equipment testing.

## Continue on the Mac mini

Clone https://github.com/breakall/churchfront-video.git and check out feat/camera-bridge-session-ownership-checkpoint. If already cloned, fetch origin first.

Build with ./build.sh release. The output is Churchfront Video.app in the repository root. Install that bundle on the target Mac and start its bridge from the Physical Camera Controller settings.

Run helper regression checks with

```sh
python3 Tools/camera-rig.py bridge-test --bridge-binary "$PWD/Churchfront Video.app/Contents/Helpers/camera-control-bridge" --output /tmp/camera-bridge-report.json
CAMERA_BRIDGE_TEST_BINARY="$PWD/Churchfront Video.app/Contents/Helpers/camera-control-bridge" PYTHONPATH=Tools python3 -m unittest discover -s Tools/camera_rig/tests
```

Configure the listener using the Mac mini's own LAN address and port 18080. Point the RC-IP100 camera slot at that address. The previous Mac used 192.168.1.245, the controller used 192.168.1.19, and the camera used 192.168.1.20. Verify addresses on the new machine. Helper configuration and credentials live under ~/Library/Application Support/CueVideo/CameraBridge and are machine-specific. Configure them through the app.

Start with tracking off. Verify controller discovery, local session open, movement and acknowledged releases. Startup recovery waits for pan, tilt and zoom releases. Confirmed autofocus clears the startup focus hold. Record test times and export sanitized diagnostics through the app. The helper remains running after the app closes.
