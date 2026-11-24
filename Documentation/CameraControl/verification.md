# Offline bridge verification

Verified November 24, 2026 against the development application bundle and its actual signed helper.

| Check | Result |
| --- | --- |
| Standalone camera/controller utility | 28 tests passed. |
| Helper configuration guards | 3 Swift tests passed. |
| Actual helper process | 57 checks passed: 12 transport checks and 45 ownership, recovery, streaming, diagnostics and failure checks. |
| App client, settings, export and tracking hooks | 14 focused tests passed. |
| PTZ adapter routing and queued-command fencing | 2 focused tests passed. |
| Complete development bundle | `./build.sh debug` succeeded. |
| Signatures and metadata | `codesign --verify --deep --strict` and both embedded plist checks passed. |

The helper checks were repeated against `Churchfront Video.app/Contents/Helpers/camera-control-bridge` after signing. Its SHA-256 was `1368b0f9fc7f3f71dd2a7d841a512b73c759c85f8858702142ede9faceeeaaaa`. The report was generated at `2026-11-24T16:31:27.805058+00:00`. Helper ownership was verified through the authenticated helper interface and independent camera observations. These checks do not establish real-camera interoperability or an end-to-end live tracking result.

## Reproduce

From the repository root:

```sh
Tools/verify-camera-bridge.sh
./build.sh debug
python3 Tools/camera-rig.py bridge-test --bridge-binary 'Churchfront Video.app/Contents/Helpers/camera-control-bridge' --output .camera-rig/bundled-helper-verification.json
codesign --verify --deep --strict 'Churchfront Video.app'
```

Generated reports stay under `.camera-rig/`. The report includes the exact helper executable hash, sanitized app-interface observations, and camera-side request evidence. The scenario runner explicitly distinguishes helper authorization checks from actual Churchfront tracking behavior.

The safety review reproduced a concurrent stop/disconnect helper crash in an earlier binary and added a passing regression. Other cases cover stale movement/stops, physical focus/store takeover while tracking is moving, failed cleanup that must still forward physical input, session recovery without stealing controller ownership, information streaming during motion, malformed input, ambiguous timeouts, diagnostic storage failure, and helper restart while a joystick remains held at a travel limit.

## Target equipment checks still required

The Mac is not connected to the camera/controller network. Rehearsal must establish actual RC-IP100 request/release forms, camera authentication/session behavior, advertised server addresses, native tracking capability/commands, added latency, and the new workflow on the real equipment. Background-item registration, approval and launch/relaunch behavior must be exercised on the target Mac; no service was registered during these tests.

Native tracking interception is unavailable until those exchanges are verified. Existing app tracking controls remain the explicit activation path. Camera-preset deletion from the app is unavailable in bridge mode until its privileged session path can be mediated safely; the physical controller's preset store/recall and trace record/playback are supported and covered by the helper checks.

After a helper process restart, the conservative recovery fence requires successful physical pan/tilt/zoom/focus stops and fresh completion information before a new explicit tracking start. Closing or reopening the app while its helper stays healthy does not trigger this recovery requirement.
