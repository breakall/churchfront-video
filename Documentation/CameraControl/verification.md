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

The Mac is not connected to the camera/controller network. Rehearsal must establish actual RC-IP100 request/release forms, camera authentication/session behavior, advertised server addresses, native tracking capability/commands, added latency, and the new workflow on the real equipment. An isolated service was registered and exercised on this Mac through `SMAppService.agent`, then fully unregistered. The production service and settings were untouched. Target-booth approval, the full live-tracking workflow, and behavior after logout/reboot remain rehearsal checks; the actual unavailable-message/Start bridge UI workflow is verified below.

Native tracking interception is unavailable until those exchanges are verified. Existing app tracking controls remain the explicit activation path. Camera-preset deletion from the app is unavailable in bridge mode until its privileged session path can be mediated safely; the physical controller's preset store/recall and trace record/playback are supported and covered by the helper checks.

After a helper process restart, the conservative recovery fence requires successful physical pan/tilt/zoom/focus stops and fresh completion information before a new explicit tracking start. Closing or reopening the app while its helper stays healthy does not trigger this recovery requirement.

## Background-service evidence

The reusable bench copied the signed helper into an isolated owner application and supplied a loopback-only simulator configuration. Native registration returned `enabled`. Physical forwarding survived both normal exit and SIGKILL of an actual fixture app holding a production-client heartbeat lease. Launchd automatically relaunched the killed helper; the new process required the explicit physical-release recovery sequence before tracking could authorize. No manual bootstrap or kickstart was used.

A launchd-specific executable-identity bug was reproduced and fixed. The service now hashes its actual loaded executable rather than relative `argv[0]`; readiness is checked against the signed image. The updated bundled helper also passes all 57 existing helper checks.

Evidence: `.camera-rig/background-service-verification.json`. All ten checks passed, and cleanup was independently confirmed with `notRegistered`, no test launchd job, and no surviving helper. This verifies the service fixture and real helper, not an end-to-end Churchfront UI/tracking session.

## Actual app UI recovery rehearsal — passed

On November 24, 2026, the actual Churchfront interface was exercised on this unlocked Mac using an isolated copy of the production app, a unique service identity and a loopback camera simulator. The production profile was originally absent and was restored to that state afterward.

Observed sequence in Setup → Cameras → Physical camera controller:

1. The enabled bridge initially showed **Bridge ready. Tracking is off.** Start bridge was disabled and Stop bridge was enabled.
2. The isolated helper was externally unregistered while the routing option remained checked. The actual interface displayed **Bridge connection unavailable. Retrying with tracking off. Could not connect to the server.** Start bridge became enabled and Stop bridge became disabled.
3. Clicking the actual **Start bridge** button registered a new helper process and reconnected the app. Start bridge became disabled, Stop bridge became enabled, and the interface displayed the restart recovery guidance. The helper PID changed and native service status was enabled.
4. Four independent camera-side checks passed: the actual app lease was attached with tracking off, physical control moved the simulator by exactly 100 units through the restarted helper, explicit release stopped it, and the original app lease remained connected with tracking unauthorized. The UI then displayed **Manual control. Tracking is off.** The verifier did not replace the app's lease.
5. Clicking **Stop bridge** displayed **Bridge stopped. Physical forwarding is off.** The app was quit normally. Native checks confirmed the isolated service was unregistered and its launchd job was absent; the simulator, test preferences, temporary profile and fixture were removed.

Reports: `.camera-rig/ui-recovery-report.json` and `.camera-rig/ui-recovery-backend.json`. Both the visible message and the button action are verified; the backend report retains its separate scope flag so it cannot be mistaken for UI evidence on its own. The Mac's original service/profile state was restored.

The earlier cold-start resource packaging defect is fixed: the complete dependency resource bundle is embedded, and the build checks that Foundation resolves its matching font from inside the app. This rehearsal verifies the requested unavailable-message/start-button workflow, not real equipment, tracking image processing, or every application workflow.
