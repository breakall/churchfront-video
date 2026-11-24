# Camera control bridge helper

A native Swift helper and small authenticated client library for one Canon CR-N500 and one RC-IP100. Camera writes, physical priority, generations and app authorization live in the helper. Churchfront uses `CameraBridgeClient`; the helper does not import the tracking engine, SwiftUI, NDI or ATEM.

This is an offline-verified development build. Real RC-IP100/CR-N500 interoperability and packaged LaunchAgent operation require the equipment and target Mac rehearsal described in the implementation plan.

## Build and verify

From the repository root:

```sh
swift build --package-path Packages/CameraControlBridge
swift test --package-path Packages/CameraControlBridge
python3 Tools/camera-rig.py bridge-test --bridge-binary Packages/CameraControlBridge/.build/debug/camera-control-bridge
```

The Python runner launches the real helper against simulated cameras, first proving ordinary forwarding in both ownership profiles, then testing manual takeover, stale generations, independently held axes, app loss, camera faults and recovery. Its reports distinguish helper checks from Churchfront adapter and hardware evidence.

For manual operation, start the camera simulator in another terminal:

```sh
python3 Tools/camera-rig.py camera --port 18081 --clock manual
```

Then start the helper:

```sh
Packages/CameraControlBridge/.build/debug/camera-control-bridge \
  --camera-url http://127.0.0.1:18081 \
  --listen-host 127.0.0.1 --controller-port 18080 --app-port 18082 \
  --controller-address 127.0.0.1 \
  --token-file .camera-rig/bridge-token \
  --ready-file .camera-rig/bridge-ready.json \
  --diagnostics-file .camera-rig/bridge-diagnostics.jsonl
```

Connect the virtual controller to `http://127.0.0.1:18080`. The camera destination is fixed; this is not an HTTP forward proxy. The physical listener accepts only the configured controller address. The app listener always binds to `127.0.0.1`, independently of the physical listener's interface. Port `0` selects an ephemeral test port; ready metadata contains the actual addresses.

The helper creates a private token when absent. Existing tokens must be regular files owned by the current user, inaccessible to other users, and 32–256 UTF-8 bytes without line breaks. Symlinks are refused. A configuration lock prevents competing helpers from sharing the same token/configuration identity.

Before listening, the helper writes a private recovery marker beside the token (`TOKEN_PATH.recovery`). The marker remains across process exits. On subsequent helper starts, tracking admission is conservatively fenced until the RC-IP100 has sent successful explicit stops for pan, tilt, zoom and focus, followed by fresh camera information proving finite positioning/trace operations are settled. If necessary, briefly actuate and release each physical control to produce those stops. A stopped status at a travel limit cannot release this fence. `BridgeStatus.recoveryRequired` and held operations explain the condition; tracking still requires an explicit start afterward. This applies to intentional helper restarts as well as crashes. Closing/reopening Churchfront while the healthy helper continues does not introduce the recovery fence. There is no per-command disk I/O for recovery state.

## Configuration and packaging

`--config PATH` reads a JSON-encoded `BridgeConfiguration`. `--config-user` reads `~/Library/Application Support/CueVideo/CameraBridge/helper.json` through Foundation's user application-support location. The app uses this mode for its bundled LaunchAgent. Only explicit app actions reconfigure/restart or stop the registered helper; quitting the UI is not Stop Bridge.

JSON fields:

| Field | Meaning |
| --- | --- |
| `cameraURL` | Fixed `http` or `https` camera origin; no embedded credentials, query, fragment or path. |
| `listenHost`, `controllerPort`, `controllerAddress` | Physical listener interface/port and permitted source IP. |
| `appPort` | Private loopback listener port. |
| `tokenFile` | Per-user bearer credential file. |
| `readyFile` | Optional atomic ready-metadata output path. |
| `diagnosticsFile` | Optional diagnostic file path; defaults to `bridge-diagnostics.jsonl` beside the token. |
| `diagnosticsEnabled` | Detailed recording, initially `true`. CLI opt-out is `--no-diagnostics`. |
| `requestTimeout` | Bounded ordinary upstream request duration, default 2 seconds; valid 0.1–10. |
| `leaseTimeout` | App heartbeat lease duration, default 3 seconds; valid 1–30. |

The corresponding CLI flags use kebab-case: `--request-timeout`, `--lease-timeout`, and so on. `--config` and `--config-user` consume the complete shared JSON structure. The app persists the operator's diagnostic choice when creating it.

Ready metadata contains `version: 1`, `controller_url`, `app_url`, `token_file`, `configuration_id`, `helper_build`, and `pid`. It never contains the token. `BridgeConfiguration.identity` hashes routing and policy fields, excluding file paths. Authenticated status repeats that identity and an executable SHA-256 build identity. The app checks these before attaching to an existing helper.

## Typed app interface

`BridgeClient` is a Foundation actor initialized with the private `baseURL` and token. Every private request sends `Authorization: Bearer …`. Redirects are refused and cookies, shared credentials and caching are disabled. Successful requests return HTTP 200; failures return `BridgeFailure {error,status}`. Stale or unsafe requests return 409; unsupported protocol versions return 426; invalid bearer credentials return 401.

| Method and route | Input | Result |
| --- | --- | --- |
| `connect()` → POST `/bridge/connect` | `{version:1}` | `BridgeLease` with connection identity and generation. New connections begin unauthorized. |
| `start(lease)` → POST `/bridge/start` | Current lease | New authorized lease after fresh camera completion evidence and no held/pending physical controls. |
| `stop(lease)` → POST `/bridge/stop` | Current lease | Revoked lease; stop only still-app-owned movement. |
| `send(command)` → POST `/bridge/command` | Version, connection, generation, purpose, endpoint, method, parameters | `BridgeCameraReply {status,headers,body}`. |
| `status()` → GET `/bridge/status` | Bearer credential | `BridgeStatus`. |
| `heartbeat(lease)` → POST `/bridge/heartbeat` | Current lease | `BridgeStatus`, refreshing app lifetime. |
| `disconnect(lease)` → POST `/bridge/disconnect` | Current lease | `BridgeStatus`, revoking app authority while retaining physical forwarding. |

`BridgeLease` contains `version`, `connection`, and `generation`. Command purposes are `tracking`, `manual`, `manualMove` and `read`. Ordinary app `manual` adjustments preserve existing authorization, so app zoom/focus/exposure retain Churchfront's behavior. `manualMove` disables tracking and neutralizes prior app movement before software pan/preset/home/position commands; it keeps the current generation so subsequent ordered app joystick updates/stops use the same lease. Physical takeover always advances the generation. Reads accept `info.cgi`; writes accept `control.cgi`, `preset/set`, `trace/set` and `trace/control`, using GET or form POST. App callers cannot supply a camera session token. They capture the lease when creating work and must never retag obsolete queued work after takeover.

`BridgeStatus` includes authorization, generation, current connection, route health, independently held axes/operations, manual takeover, diagnostics/drop count, configuration identity, helper build identity, recovery admission state, and `nativeTrackingSupported: false`. A status poll never authorizes tracking. `unresolvedAppMotion` in held operations means a cleanup failed and an explicit restart remains blocked until the old motion is resolved.

## Ownership and forwarding

- Physical pan, tilt, zoom, focus, preset store/recall and trace record/playback actions revoke authorization at receipt. Recording/playback stops also count. Read-only information, open/claim and keepalive traffic do not count as operator movement.
- Physical actions get queue priority. Pending and in-flight physical actions prevent tracking starts. App movement carries a connection identity and generation checked again at dispatch; obsolete movement and stops are rejected.
- Held continuous axes require explicit successful stops. Silence, a closed connection, zero speed and a camera travel limit never mean release. Preset/absolute positioning and trace preparation/playback require fresh completion information before an explicit start.
- The serialized movement path neutralizes still-app-owned axes on takeover. It does not stop axes already owned by the controller. A bounded cleanup failure is diagnosed but never discards the original physical request; unresolved app motion keeps tracking blocked.
- App disconnect, heartbeat loss or route failure revokes app authority. Requests are not replayed after reconnect, errors or timeouts. Physical forwarding continues without the app. A new app connection never resumes tracking automatically.
- Controller request-targets, form bodies, authentication headers and ordinary camera replies pass through to the fixed camera. Successful physical session context is reused for app writes; a helper session is opened only when no physical context is available at an explicit tracking start.
- Physical `info.cgi` streams relay raw framing and chunks with backpressure, independently of the movement queue. They deliver first bytes without waiting for the response to finish. Up to 16 streams are admitted, using at most one 64-KiB send chunk plus bounded header/snapshot observation buffers per stream; idle streams close after 120 seconds. Snapshot observation is generation-fenced.

The normal request path bounds inbound headers to 16 KiB, bodies to 64 KiB, queued movement work to 128, listener connections to 64, and buffered ordinary camera replies to 2 MiB. Malformed framing is rejected. Each camera request has its own connection and no redirects, credential cache, automatic retry or replay layer.

## Diagnostics

Detailed diagnostics default on. Events correlate enqueue, dispatch, forwarding/failure, revocation and lifecycle using request IDs, ownership generations, wall and monotonic times, process/build/configuration identity, sanitized command fields, HTTP/Livescope status, queue depth/wait and forwarding duration. Fields are allowlisted and validated; session tokens, bearer values, authentication headers, raw request URLs, unrecognized fields and arbitrary names are not recorded.

Logging uses a separate serial utility queue capped at 256 pending events. The current file rotates at 1 MiB and retains two previous files. Files are private to the user. Slow/full/unavailable storage drops diagnostic work rather than blocking camera writes; status exposes a drop count. These are initial-build caps, not a settled production retention policy. The app can export the bounded local files; there is no automatic upload.

## Remaining hardware evidence

The test camera is a deliberately limited protocol profile. Real controller firmware, camera firmware, Digest exchanges, `s.origin` and redirect behavior, multipart stream patterns and session lifetime/priority still require equipment captures and rehearsal. A timed-out camera write can have applied; diagnostics preserve that ambiguity and the helper disarms tracking rather than replaying it. Mac/helper failure remains the accepted risk of routing through the Mac.

Native auto-tracking command/capability grammar is not guessed. Native commands pass to the camera; the optional Churchfront interception remains unavailable until real exchanges establish a supported mapping. The helper does not emulate camera storage, video, optics or tracking.
