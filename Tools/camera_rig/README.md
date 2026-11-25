# Camera control test rig

A standalone, loopback-only test utility for developing the Canon camera bridge without the physical RC-IP100 or CR-N500. It uses Python 3.10 or newer and the standard library. It does not import, launch, or modify Churchfront Video.

The utility provides:

- A scriptable virtual controller and an interactive controller shell.
- An HTTP camera simulator with sessions, continuous pan/tilt/zoom, focus, camera-owned presets, and recorded traces.
- A deterministic scenario runner that can target a separately running bridge.
- Camera fault injection, bounded request history, and JSON verification reports.

All commands below run from the Churchfront Video repository root.

## Run the baseline

```sh
python3 Tools/camera-rig.py selftest
python3 Tools/camera-rig.py selftest --ownership exclusive --output .camera-rig/exclusive-report.json
```

Each command starts a temporary simulated camera, exercises it over real HTTP, saves a report, and shuts it down. The six scenarios cover held joystick motion and independent axis stops; zoom and focus; UTF-8 preset store/recall using POST; trace record/prepare/play/stop; trace cancellation; and propagation of a camera error without movement.

Reports include individual results, timings, camera request history, an explicit scope, and the camera run ID. Reports and other generated files under `.camera-rig/` are ignored by Git.

Exit codes: `0` means all scenarios passed; `1` means a scenario or controller command failed; `2` means setup or execution failed. Ctrl-C returns `130`.

## Operate the simulators separately

In one terminal, start a simulated camera:

```sh
python3 Tools/camera-rig.py camera --port 18081 --clock manual
```

In another terminal, open the virtual controller:

```sh
python3 Tools/camera-rig.py controller --target http://127.0.0.1:18081 shell
```

Example shell commands:

```text
pan right --speed 100
tilt up --speed 100
pan stop
tilt stop
zoom tele --speed 10
zoom stop
focus manual
focus far
focus stop
preset-store 7 --name "Lectern α"
preset-recall 7
trace-record start --number 2 --name "Stage walk"
trace-record stop
trace-play prepare --number 2
trace-play start --number 2
trace-play stop
info
quit
```

With `--clock manual`, advance simulated time from a third terminal while a movement or trace is active:

```sh
python3 Tools/camera-rig.py advance --camera http://127.0.0.1:18081 2
python3 Tools/camera-rig.py inspect --camera http://127.0.0.1:18081 state
python3 Tools/camera-rig.py inspect --camera http://127.0.0.1:18081 events
```

Pan speed `100` advances the simulated pan position by `100` units per simulated second. Movement continues until an explicit stop or a travel limit; silence from the controller is never interpreted as joystick release. Reaching a limit can produce a stopped movement status while `commanded_axes` still shows a held command.

For manual exploration without advancing time yourself, start the camera with `--clock realtime` instead. It computes elapsed motion whenever it receives a request. Automated scenarios require `manual`.

Every controller action is also a one-shot command:

```sh
python3 Tools/camera-rig.py controller --target http://127.0.0.1:18081 pan right
python3 Tools/camera-rig.py controller --target http://127.0.0.1:18081 pan stop
```

The shell holds one session; one-shot commands open, claim, and close their own session. Closing a session or quitting the shell does not send a motion stop. This makes it possible to test loss of the controller while a command remains active. `claim`, `release`, and `raw` are available for session and parameter experiments. `--sessionless` skips automatic session creation. For example:

```sh
python3 Tools/camera-rig.py controller --target http://127.0.0.1:18081 --sessionless raw control.cgi --param c.1.pan=right --param c.1.pan.speed=100
```

`--actor software` labels a second test client in diagnostics. This is a test label, not authentication or a production method of identifying physical-controller activity.

## Optional preview for the actual app

To exercise Churchfront's real tracking state and indicator with a deterministic person image:

```sh
python3 Tools/camera-rig.py camera --port 18081 --clock manual --preview-image Tools/camera_rig/fixtures/public-domain-person.jpg
```

With this explicit option, `/-wvhttp-01-/video.cgi` supplies a multipart JPEG preview at 10 frames per second, matching the endpoint used by the app's existing Canon preview reader. Input is limited to a regular JPEG of at most 2 MiB, loaded once. Up to four preview clients are accepted. Each connection adds one journal entry; frames do not evict control-command evidence. Camera control remains independent of the preview stream, and stopping the simulator closes preview streams.

The default simulator still has no preview. The [photo provenance](fixtures/README.md) records its public-domain source and fixture limits. The image stays static when simulated camera coordinates change; this adds input for the actual tracking/manual-takeover UI test, not a model of optics or a tracking-quality benchmark.

### Actual app tracking takeover evidence

Use an isolated test app/service identity and temporary app profile; preserve any existing profile and tracking log before running the actual app. Configure its Canon camera to the preview simulator, enable bridge routing, and point the simulated controller at the helper's physical port. To supply ATEM Next/Live state locally, run the existing simulator bound to loopback:

```sh
PYTHONPATH=Tools python3 -c "from fake_atem import Switcher; Switcher(host='127.0.0.1').run()"
```

It listens on UDP 9910, with input 1 on Live and input 2 on Next. Configure the app's ATEM host as `127.0.0.1` and map the Canon camera to input 2. Start tracking through the actual app's Track button. Observe TRACKING, FOLLOWING and the tracking-control message before recording the baseline:

```sh
PYTHONPATH=Tools python3 -m camera_rig.tracking_ui_backend --phase before --camera http://127.0.0.1:18081 --helper-ready "$HOME/Library/Application Support/CueVideo/CameraBridge/ready.json" --control-token-file "$HOME/Library/Application Support/CueVideo/control-token" --output .camera-rig/tracking-before.json
```

Send a physical joystick command through the helper using the controller utility. Observe TRACK, disappearance of FOLLOWING and **Manual control. Tracking is off.** in the actual app. Then run the same verifier with `--phase after --baseline .camera-rig/tracking-before.json --output .camera-rig/tracking-after.json` and the same camera/ready/token arguments. Explicitly stop all physical axes and confirm tracking remains off afterward.

The verifier only reads the actual app's authenticated loopback `get_status`, helper status and camera journal. It never starts/stops tracking, replaces the app's connection or generates camera commands. Its after checks require the actual session to stop, helper authorization to be revoked, generation to advance, the app connection to remain attached, and a new physical command to reach the camera. Connection identities are hashed and tokens omitted from its reports. UI observation remains separate; backend success alone is not UI evidence.

Afterward, unregister the isolated service, quit the test app and simulators, restore the original profile/log state and verify cleanup. The completed rehearsal is recorded in [verification.md](../../Documentation/CameraControl/verification.md#actual-app-tracking-takeover-rehearsal--passed).

## Test the bridge as it is implemented

For the native Swift helper, `bridge-test` starts the actual executable, temporary cameras, and independent controller/app test clients. Pass the path to an already built helper:

```sh
python3 Tools/camera-rig.py bridge-test --bridge-binary /absolute/path/to/camera-control-bridge --transport-only --output .camera-rig/helper-transport.json
python3 Tools/camera-rig.py bridge-test --bridge-binary /absolute/path/to/camera-control-bridge --output .camera-rig/helper-ownership.json
```

The first command checks all six transport scenarios in both camera ownership profiles. The full run adds checks at the helper's authenticated app interface: manual takeover and stale command/stop rejection, explicit restart, independently held axes and travel limits, zoom speed zero, control connection closure, each focus/preset/trace trigger, read-only traffic, app disconnection and lease expiry, camera failure without replay, interface authentication/version checks, and diagnostics defaults/redaction/opt-out. It also checks in-flight writes, pending physical actions, ambiguous movement outcomes, malformed messages, streaming information, concurrent stop/disconnect, cleanup failures and unavailable diagnostic storage. Each policy case gets a fresh helper and camera. The exclusive-profile cases verify that the helper holds one camera session and gives the controller its own session ID. They exercise idle renewal, controller open/yield/close, and expiration while physical movement and release commands are in flight. The camera journal must show a confirmed stop before fresh movement resumes. A queued movement from the expired session must never reach the camera. The runner owns and shuts down only the helper processes it launches.

These checks observe the real helper and simulated camera, using an independent Python app client rather than the Swift client library. Reports include the executable's SHA-256, camera requests and sanitized app-interface observations, including authorization generations and rejected command statuses. `helper_ownership_verified` reports that focused result; `tracking_handoff_verified` remains false because the running Churchfront adapter and UI are a separate integration milestone. Native tracking grammar and physical-camera interoperability are not inferred from these tests.

Software-purpose checks preserve Churchfront's existing distinction between software zoom/focus and manual camera movement. Ordinary software controls keep tracking authorization; an explicit software pan, position, home or preset movement disables it atomically and accepts subsequent software release commands with the same lease. The exposure case checks forwarding and authorization against an intentional unsupported-parameter camera reply; it does not validate exposure behavior. A separate crash/restart case reuses the same helper configuration and credentials while a physical joystick is held at a travel limit. Fresh telemetry alone must not clear that recovery fence; explicit physical stops and a later tracking start are required.

The intended arrangement is:

```text
Virtual RC-IP100  →  bridge controller endpoint  →  simulated camera
Scenario runner  ──────────────────────────────→  camera inspection endpoint
```

Start the camera in manual mode, configure the bridge's camera destination as `http://127.0.0.1:18081`, and configure its controller-facing test listener on a different loopback port. Then run:

```sh
python3 Tools/camera-rig.py verify --target http://127.0.0.1:18080 --camera http://127.0.0.1:18081 --output .camera-rig/bridge-report.json
```

`--target` is the bridge; `--camera` is the simulator's direct inspection address. The runner resets simulated motion, stores, and fault queues between scenarios, while preserving any bridge sessions. Run it against an isolated development bridge with other test clients idle. Controller commands go through the target; clock advancement, fault injection, and evidence collection go directly to the simulated camera.

The current suite verifies transport and the simulated command outcomes. Its reports explicitly set `tracking_handoff_verified` to `false`. As the bridge and Churchfront adapter are built, add scenarios at their public interfaces for immediate manual takeover, rejection of subsequent tracking commands, explicit tracking re-enable, optional native tracking interception, and helper/app failure behavior. Those scenarios must observe actual bridge/app state rather than an imitation of their arbitration logic inside the camera simulator.

## Inject failures

Arm a one-shot error on the next movement request:

```sh
python3 Tools/camera-rig.py fault --camera http://127.0.0.1:18081 livescope --endpoint control.cgi --code 408
```

Available modes:

| Mode | Behavior |
| --- | --- |
| `livescope` | HTTP 200 with an error in `Livescope-Status`; command is not applied. |
| `http` | HTTP error, default 503; command is not applied. |
| `disconnect` | Close the connection before applying the command. |
| `malformed` | Send an invalid HTTP response without applying the command. |
| `delay` | Wait before applying the command and replying. |
| `delay_after` | Apply the command, then wait before replying. |
| `stream` | Send a snapshot HTTP chunk immediately, wait, then send a synthetic second chunk and terminate. This is a streaming transport fixture, not a claim about Canon event grammar. |

Use `--seconds` for delays, `--count` for repeated faults, and `--endpoint` to restrict the fault. Delays are limited to 3 seconds, counts to 20 per fault, and queued fault rules to 32. For example:

```sh
python3 Tools/camera-rig.py fault --camera http://127.0.0.1:18081 delay_after --endpoint control.cgi --seconds 1
python3 Tools/camera-rig.py controller --target http://127.0.0.1:18081 --timeout 0.1 --sessionless pan right
python3 Tools/camera-rig.py inspect --camera http://127.0.0.1:18081 state
```

That controller request times out even though the movement has started. The controller never automatically retries a timed-out or disconnected command. The bridge must handle that ambiguity safely.

History retains the last 2,000 camera requests, including endpoint, method, allowlisted parameters, simulated time, fault type, and response status. A dropped or malformed response has no HTTP status in the journal. Session tokens and HTTP authorization headers are not exported. A SHA-256 request fingerprint can help correlate wire-preserving forwarding without recording the full request. Names and camera positions are included in diagnostic reports.

## Verify the utility itself

```sh
PYTHONPATH=Tools PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tools/camera_rig/tests -v
```

The suite uses real loopback HTTP, including camera and controller launched as independent programs. Independent test relays establish that the runner accepts working forwarding and rejects deliberately dropped preset storage and swallowed joystick stops. Other cases exercise ambiguous timeouts, malformed replies, disconnections, bounded/redacted history, repeated runs without session leaks, and a held joystick at the camera travel limit. These tests cover the utility and new bridge-facing test behavior, not Churchfront's existing tracking algorithm or image processing.

## Protocol profile and boundaries

The simulator models selected operations from [Canon's XC Control Protocol Specifications, version 005](https://output.nl/u/images/canon-xc-control-protocol-specifications-005.pdf), using the `/-wvhttp-01-/` HTTP endpoints. It implements:

- `open.cgi`, `claim.cgi`, `yield.cgi`, `close.cgi`, and snapshot `info.cgi`.
- `control.cgi` with pan, tilt, zoom, their speeds/stops, focus mode/action, and preset recall. Supported `c.1.` parameter aliases are normalized.
- `preset/set` for complete preset storage with `all=enabled`, including UTF-8 names, slots 1–100.
- `trace/set` for start, stop/save, and cancel, slots 1–10; `trace/control` for prepare, start, and stop. Saved traces replay command timing against the deterministic clock.
- GET and form-encoded POST, HTTP status and `Livescope-Status`, and explicit errors for unsupported operations.

Two ownership profiles are provided:

| Profile | Purpose |
| --- | --- |
| `documented` (default) | Allows supported sessionless camera commands and models control claims separately. Canon's documented remote-camera behavior does not make every ordinary command contingent on holding exclusive control. |
| `exclusive` | Deliberately adversarial profile: another session can steal control, and writes from a nonowner return status 301. This exercises contention handling; it is not a claim that every real Canon camera behaves this way. |

Motion and optics are simplified. Preset recall and trace preparation move instantly; trace playback requires preparation in this profile. Trace focus actions are recorded, but lens physics are not simulated. Stores are in memory and disappear on reset or exit. Stored preset/trace deletion and selective preset content are unsupported. This version does not model HTTP authentication, Canon-specific streaming event semantics, discovery, or ATEM behavior. The optional preview repeats a fixed JPEG without modeling camera motion. The `stream` fault supplies synthetic chunked HTTP solely to verify incremental forwarding and concurrent control.

The virtual controller generates the supported request subset; it is not a firmware clone. Exact RC-IP100 request sequences, controller timeouts, and the native auto-tracking button's wire commands still require captures from the real equipment. No guessed native tracking endpoint is presented as Canon behavior. Captured, sanitized fixtures can be added to this profile when available.

The camera binds only to `127.0.0.1`. Controller and scenario targets must be loopback HTTP addresses. The utility refuses real camera/network targets and follows no redirects. Use it as development infrastructure; it is not the production bridge.

## Files

| File | Responsibility |
| --- | --- |
| `../camera-rig.py` | Standalone launcher. |
| `controller.py` | Network-only controller client; no camera-model access. |
| `camera.py` | HTTP server, inspection API, faults, and request journal. |
| `model.py` | Simulated camera state and deterministic clock. |
| `scenarios.py` | Reusable network verification scenarios and report scope. |
| `bridge_scenarios.py` | Launch the actual helper and exercise its controller/app interfaces independently. |
| `tracking_ui_backend.py` | Read-only before/after evidence for actual app tracking takeover; UI is observed separately. |
| `fixtures/` | Documented public-domain person JPEG for opt-in preview. |
| `cli.py` | Commands, interactive shell, and atomic report writing. |
| `tests/` | Utility tests and independent healthy/broken relay fixtures. |
