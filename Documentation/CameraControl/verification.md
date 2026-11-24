# Offline bridge verification

Verified November 24, 2026 against the development application bundle and its actual signed helper.

| Check | Result |
| --- | --- |
| Standalone camera/controller utility | 28 tests passed. |
| Helper configuration guards | 3 Swift tests passed. |
| Actual helper process | 57 checks passed: 12 transport checks and 45 ownership, recovery, streaming, diagnostics and failure checks. |
| App client, settings, export and tracking hooks | 14 focused tests passed. |
| PTZ adapter routing and queued-command fencing | 2 focused tests passed. |
| Isolated macOS background service | 10 actual `SMAppService`/launchd simulator checks passed, including app quit/crash, automatic helper restart, image identity and verified cleanup. |
| Complete development bundle | `./build.sh debug` succeeded. |
| Signatures and metadata | `codesign --verify --deep --strict` and both embedded plist checks passed. |

The helper checks were repeated against `Churchfront Video.app/Contents/Helpers/camera-control-bridge` after signing. Its SHA-256 was `d030ad4cc6197b00070af700e357fcbe61ec590178ef332eba584ca43fa2cb08`. The report was generated at `2026-11-24T17:15:03.829526+00:00`. Helper ownership was verified through the authenticated helper interface and independent camera observations. These checks do not establish real-camera interoperability or an end-to-end live tracking result.

## Reproduce

From the repository root:

```sh
Tools/verify-camera-bridge.sh
./build.sh debug
python3 Tools/camera-rig.py bridge-test --bridge-binary 'Churchfront Video.app/Contents/Helpers/camera-control-bridge' --output .camera-rig/bundled-helper-verification.json
codesign --verify --deep --strict 'Churchfront Video.app'
python3 Tools/service-bench.py
```

Generated reports stay under `.camera-rig/`. The report includes the exact helper executable hash, sanitized app-interface observations, and camera-side request evidence. The scenario runner explicitly distinguishes helper authorization checks from actual Churchfront tracking behavior.

The safety review reproduced a concurrent stop/disconnect helper crash in an earlier binary and added a passing regression. Other cases cover stale movement/stops, physical focus/store takeover while tracking is moving, failed cleanup that must still forward physical input, session recovery without stealing controller ownership, information streaming during motion, malformed input, ambiguous timeouts, diagnostic storage failure, and helper restart while a joystick remains held at a travel limit.

## Target equipment checks still required

The Mac is not connected to the camera/controller network. Rehearsal must establish actual RC-IP100 request/release forms, camera authentication/session behavior, advertised server addresses, native tracking capability/commands, added latency, and the new workflow on the real equipment. An isolated service was registered and exercised on this Mac through `SMAppService.agent`, then fully unregistered. The production service and settings were untouched. Target-booth approval, full Churchfront UI lifecycle, and behavior after logout/reboot remain rehearsal checks.

Native tracking interception is unavailable until those exchanges are verified. Existing app tracking controls remain the explicit activation path. Camera-preset deletion from the app is unavailable in bridge mode until its privileged session path can be mediated safely; the physical controller's preset store/recall and trace record/playback are supported and covered by the helper checks.

After a helper process restart, the conservative recovery fence requires successful physical pan/tilt/zoom/focus stops and fresh completion information before a new explicit tracking start. Closing or reopening the app while its helper stays healthy does not trigger this recovery requirement.

## Background-service evidence

The reusable bench copied the signed helper into an isolated owner application and supplied a loopback-only simulator configuration. Native registration returned `enabled`. Physical forwarding survived both normal exit and SIGKILL of an actual fixture app holding a production-client heartbeat lease. Launchd automatically relaunched the killed helper; the new process required the explicit physical-release recovery sequence before tracking could authorize. No manual bootstrap or kickstart was used.

A launchd-specific executable-identity bug was reproduced and fixed. The service now hashes its actual loaded executable rather than relative `argv[0]`; readiness is checked against the signed image. The updated bundled helper also passes all 57 existing helper checks.

Evidence: `.camera-rig/background-service-verification.json`. All ten checks passed, and cleanup was independently confirmed with `notRegistered`, no test launchd job, and no surviving helper. This verifies the service fixture and real helper, not an end-to-end Churchfront UI/tracking session.
