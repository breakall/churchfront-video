# Camera control implementation plan

Date: November 24, 2026

Status: Development bridge/app build implemented and verified offline; equipment rehearsal pending

Requirements: [Business requirements](business-requirements.md)

Settings: [Features and settings register](camera-control-settings.md)

## Objective and scope rule

Add a bridge helper and small Churchfront adapters that give physical RC-IP100 commands priority, disable tracking on takeover and require a fresh operator action before tracking writes resume. Native translation uses one application-wide on/off setting; detailed diagnostics are optional and on by default in the initial test build. The bridge serves one CR-N500 and one RC-IP100, with one endpoint/ingress configuration. Reuse the existing Churchfront camera identity to attach it; no per-camera option set, additional camera registry or multi-camera routing layer is needed.

Reuse Churchfront's tracking engine, target selection, target-loss handling, Track control/shortcut, presets, saved shots, previews, graphics and ATEM behavior. Do not rebuild or independently test/validate those features. Existing actions can supply inputs for tests, but tests cover only new bridge behavior and integration contracts we change. They are not end-to-end qualifications of the original features.

The implementation repository is the [breakall/churchfront-video fork](https://github.com/breakall/churchfront-video). Its `origin` remote points to the fork and `upstream` to `Churchfront/churchfront-video`. The selected upstream baseline is Churchfront 0.1.2 at `9892525d2a624af82c5fb8eaed6655179472b399`. The standalone test rig is committed and pushed on `main` in [`fbc9544`](https://github.com/breakall/churchfront-video/commit/fbc9544d0cc93d4195e1000c1c36025e4794efd8).

## Current delivery status

| Deliverable | Status and evidence |
| --- | --- |
| Fork and upstream relationship | Complete. Fork created, upstream baseline retained, and test utility pushed to `main`. |
| Standalone controller/camera test rig | Complete. All 30 utility tests pass, including independently launched camera/controller programs and opt-in preview streaming. All six baseline scenarios pass in both simulator ownership profiles. |
| External-target verification | Complete for the supported simulated transport profile. A separate healthy relay passes; deliberately dropped preset stores and swallowed joystick stops fail the corresponding checks. JSON reports retain request evidence. |
| Production Swift bridge helper | Implemented as a native development helper. Its signed bundled executable passes 57 process-level transport, ownership, streaming and failure/recovery checks. |
| Ownership arbitration and Churchfront adapters | Implemented. Fourteen app contract checks and two PTZ routing/fence checks pass. Helper checks remain distinct from live tracking behavior and equipment interoperability. |
| Native tracking translation and app/helper packaging | Development bundle builds and signature/plist checks pass. An isolated SMAppService owner passed ten service checks on this Mac, including quit/crash, automatic restart and cleanup. Production app/profile activation on the booth Mac remains untested. Native translation remains unavailable pending real request/capability evidence. |
| Physical camera/controller interoperability and rehearsal | Pending equipment access. No real-camera interoperability has been established by the simulator. |

Actual unavailable-message/Start bridge UI rehearsal passed on this Mac with a simulator. The routing option remained enabled during service loss; the visible message, enabled Start bridge button, actual click/reconnection, camera forwarding and cleanup were verified. The cold-start dependency-resource packaging check also passes.

Actual tracking takeover and indicator rehearsal also passed with loopback camera/controller/ATEM simulators. A physical joystick command stopped an existing `following` session in the real app, changed TRACKING to TRACK, removed FOLLOWING and displayed the manual-control message. The same app connection remained attached, physical forwarding succeeded, and tracking stayed off after explicit release. Temporary service, app, profile and log changes were cleaned up.

Detailed evidence, exact helper build identity, reproduction commands and remaining target-Mac checks are in the [verification record](verification.md). Camera-preset deletion from the app is unavailable in bridge mode until its separate privileged session path can be mediated safely; physical controller preset/trace operations are implemented.

## Standalone test bench

Use the [test rig guide](https://github.com/breakall/churchfront-video/blob/fbc9544d0cc93d4195e1000c1c36025e4794efd8/Tools/camera_rig/README.md) and `Tools/camera-rig.py` in the implementation repository. The utility uses Python's standard library, operates only on loopback HTTP, and is independent of Churchfront and the production helper.

The virtual controller sends session, movement, focus, preset store/recall and trace record/playback requests over HTTP. The camera provides deterministic time, simulated state, preset/trace storage, bounded sanitized request history and injected failures. The runner can send commands through a separately running bridge while inspecting and advancing the simulated camera directly. It supplies both a documented sessionless-command profile and an explicitly adversarial exclusive-control profile; neither is a complete firmware clone.

Baseline command:

```sh
python3 Tools/camera-rig.py selftest
```

First bridge verification, with a manual-clock camera on port 18081 and the development bridge on port 18080:

```sh
python3 Tools/camera-rig.py camera --port 18081 --clock manual
# In another terminal, start the bridge with the simulated camera as its destination.
python3 Tools/camera-rig.py verify --target http://127.0.0.1:18080 --camera http://127.0.0.1:18081 --output .camera-rig/bridge-report.json
```

The existing utility covers six transport scenarios and targeted fault tests. Its reports explicitly set `tracking_handoff_verified` to `false`. They do not verify app integration, helper lifetime, production diagnostics or actual RC-IP100 behavior. Authentication, streaming information and native tracking command/capability exchanges are not modeled in the current profile; add independently sourced fixtures and tests when those bridge features are implemented. Do not infer the native tracking wire grammar from autofocus commands.

Extend this bench at the real helper and app-adapter interfaces as each capability is added. Test the bridge's authorization state, actual camera request order and actual adapter stop/start calls. Keep arbitration out of the simulator so a copied implementation cannot become its own proof. These additions test our bridge and integration contracts, not Churchfront's existing tracking algorithm.

Use the standalone rig for offline development and the bridge diagnostics for equipment request evidence. Keep captured fixtures sanitized and record their firmware baseline.

## Proposed architecture

Ship one app bundle with a separate native Swift bridge helper. Own its helper executable, typed message/client module and tests in `Packages/CameraControlBridge`, consumed as a local Swift package and pinned with the fork revision.

```text
RC-IP100 commands ---------> Bridge helper ---------> Canon CR-N500
                                  ^
                                  |
Churchfront camera adapter -------+
Existing tracker actions/state <---> small tracking adapter

Existing video and ATEM paths remain outside the bridge.
```

The helper enforces ownership before notifying the app, so a frozen UI cannot allow further tracking commands after takeover. Use a bundled per-user LaunchAgent through `SMAppService` for UI-independent lifetime. The implemented app interface is typed, versioned loopback HTTP with a private per-user bearer token; the physical controller has a separate listener and a configured source address. The shared `CameraBridgeClient` module owns the message types and client. This supplies the same process separation without coupling tracker code to helper transport. Do not substitute an embedded XPC service whose lifetime ends with its client. Keep the agent registered and forwarding on intentional app quit. On the next launch, reconnect to the existing helper rather than start a competing listener. Provide a separate explicit Stop Bridge action; closing the app is not that action.

The bridge owns new ingress/routing, session coordination, classification, arbitration, ordering, reconnect handling and diagnostics. Keep it independent of tracker structs, Vision, SwiftUI, NDI and ATEM state. Forward real camera replies and reuse existing command representations wherever practical; add only address/capability/status adaptation proven necessary. Do not build a full camera emulator or new preset/video/tracking implementations.

Use the existing `PTZLink` seam for a bridge camera adapter and a small tracker adapter for existing start/stop/state. Mediate relevant writes/session claims for managed cameras, including separate privileged claim paths. Keep existing preview reads/routes and target-selection semantics unchanged.

## Ownership and ordering

Maintain app authorization, movement owner and route health for the single configured camera. These are bridge facts, not a replacement for Churchfront's tracking/search state machine.

| Input | New integration behavior |
| --- | --- |
| New/restarted app connection | Start tracking writes unauthorized and discard obsolete requests. |
| Existing explicit start | Authorize the mapped camera only for a current connection/generation after manual movement ends; otherwise reject visibly. Delegate tracking start to Churchfront. |
| RC joystick, zoom, focus, preset store/recall or trace record/playback | Revoke tracking authorization, advance generation, invalidate queued tracking work and forward the physical action with priority. Invoke existing tracking stop through the adapter. |
| Hardware movement ends | Keep authorization off; no automatic-resume timer. |
| Existing app movement/stop | Admit/reject according to purpose and generation; old stops cannot interrupt hardware movement. |
| App quit, disconnect or crash | Revoke app authority, stop still-app-owned movement when appropriate, retain healthy helper forwarding and registration. |
| Helper/camera route failure | Report bridge failure; prevent replay and silent direct-app fallback. Recovery does not authorize tracking. |

An existing tracker-generated stop, including one caused by subject loss, is an input to the bridge. Test its ownership/order handling with representative commands; do not add subject-loss detection or stopping as a new feature/test target.

Use fresh app-connection identities and ownership generations through queues, retries and callbacks. Reject stale results. Serialize upstream movement writes. Hardware takeover invalidates queued app work immediately; conclusively resolve any bounded in-flight write before dispatching the physical action and measure the delay. Long information streams must not hold the movement queue.

Observe axes independently so a new explicit start cannot interrupt a held joystick/zoom. Silence, a TCP close, `speed=0` or no movement at a travel limit does not prove release. Use position/preset completion only for the bridge's admission decision, not to qualify positioning accuracy. Info/keepalive/claim traffic is not operator movement. Focus actions and all preset/trace store, record, recall, playback and stop actions are takeover triggers. Focus information/status reads are not operator actions. No additional exposure-trigger rule has been selected. Reject unsafe starts rather than defer them to activate later.

## Physical preset and trace pass through

Support all four RC-IP100-originated operations: preset store, preset recall, trace store/record and trace recall/playback. Preserve the full recording start/stop and playback/stop request sequences, camera/slot identifiers, operation parameters, authentication/session exchanges and camera replies. The real camera owns preset/trace storage; the app does not need to originate these operations for the physical path to work.

Classify store/record separately from recall/playback for forwarding and diagnostics, but all of them disable tracking and use the physical-priority takeover path. Include trace recording start/stop and playback/stop, as well as physical focus adjustments, focus mode changes and one-shot autofocus. Keep read-only focus/status queries distinct from these actions. Native tracking interception applies only to the selected native tracking actions and does not consume preset/trace commands.

Verify the bridge with simulated RC-IP100 requests for each operation, including recording start/stop, matching camera response/error forwarding, correct target/slot, ordering and reconnect/no-replay behavior. Confirm actual controller interoperability in rehearsal. These checks prove transport and arbitration, not the camera's storage implementation, preset accuracy or trace-motion fidelity.

## Optional native tracking translation

Use one application-wide setting labelled Use RC-IP100 tracking control for Churchfront. The bridge has one camera, so it needs no camera selector or per-camera override. Default this setting to off for a fresh configuration and preserve the saved choice across restarts and updates. Enabling the setting does not itself start tracking. This option is independent of physical takeover.

Enabled: consume the native action, use the configured camera and invoke the corresponding existing Churchfront action. Do not also enable Canon tracking. Reflect existing app state through the controller's required replies and handle duplicate explicit starts idempotently. Do not invent a second tracker state machine.

Disabled: forward native action/status unchanged and issue no Churchfront action. Check that at the bridge interface, not by independently evaluating Canon tracking. Define an interlock against integration-induced double activation and test option changes without starting either tracker.

Establish the controller's capability/license/status expectations on actual hardware and implement only the necessary adaptation. If unsupported, keep the option unavailable with an explanation and retain existing app controls. Never substitute a preset button or introduce custom target selection.

## Interface and source edits

Use a small typed interface with one supported version. A mismatch refuses app tracking writes, never triggers direct-camera fallback, and may leave healthy configured physical forwarding independent. Include the single camera/controller connection, protocol/build agreement, app identity, command purpose/request/generation, explicit authorization/revocation, and bridge/reflected status. Authenticate local peers; ingress accepts configured controller sources and forwards only to its fixed camera.

| Location | Added work and focused check |
| --- | --- |
| `PTZ.swift` and a new bridge adapter | Route configured cameras and carry command purpose/generation. Verify representative requests and separate changed privileged claim paths cannot bypass the helper. Do not test original feature semantics behind those requests. |
| Small tracking adapter and necessary `Tracker.swift` hooks | Call existing stop/start and relay existing state. Verify hardware events disarm tracking and explicit starts cross authorization. No tracking algorithm tests. |
| `App.swift` | Register/connect helper and ownership-aware lifecycle handling. Verify disconnect/shutdown callbacks cannot send stale stops into hardware movement. |
| `Config.swift` and `SettingsView.swift` | Add only bridge/interception/diagnostic settings and health. Test new setting persistence/validation and no activation side effects. |
| `Package.swift` and `build.sh` | Pin/build/embed/sign helper and metadata. Check only new artifacts, identity, launch and interface agreement. |

Keep bridge policy out of calling app features. A tracker `send()` flag is insufficient because delayed stops and the existing separate authenticated preset-deletion session can bypass it. Test the shared new seam and separately changed paths with simulated requests, rather than exercising every preset/editing/automation workflow end to end.

## Diagnostics and settings

Implement diagnostics early, on by default in the first test build and preserving opt-out. Production default/retention remain D04. Record structured wall-clock/monotonic timestamps, process/build identity, camera aliases, correlation IDs, generations, sanitized command origin/purpose/fields, routing/ordering decisions, errors, delays, lifecycle and new settings changes. Subscribe to existing tracking state for correlation; do not add preview/subject monitoring solely for logging.

Use connection/session aliases, not actual tokens. Exclude credentials, auth headers, cookies, routine video and appearance data. Export local selected-window reports with sanitized configuration, versions and available crash information; no automatic upload.

Use bounded asynchronous logging, rotation and storage caps. Slow/full/unavailable storage or log drops must not block forwarding or crash the helper. Count drops and expose reduced coverage where possible. Test these new paths with capture on/off. Persist only new settings in the [register](camera-control-settings.md); no automatic-resume or preset-repurposing option is included.

## Delivery phases and exit criteria

### Phase 0 Standalone test rig — complete

The utility, usage guide and 28 tests are pushed in `fbc9544`. The six baseline scenarios run directly and through a separate target. Negative-control relays prove detection of dropped preset storage and swallowed stops. Fault cases include camera errors, dropped/malformed replies and a timeout after a command has already applied; held movement at a travel limit remains distinguishable from an explicit release.

**Exit achieved:** an independent, repeatable offline bench exists for subsequent helper development. This is test-infrastructure completion, not bridge or hardware acceptance.

### Phase 1 Establish controller route interoperability — hardware gate

Hardware access is currently unavailable. Offline helper/app implementation has proceeded using the test rig; Phase 1 evidence remains required before claiming equipment compatibility or releasing the bridge. Implement uncertain behavior from documented protocol requirements or captured fixtures, and resolve differences on the equipment before deployment.

Record D06: bridge-relevant camera/controller firmware, macOS and network details; the ATEM model is not a prerequisite. Route representative joystick/zoom/focus, preset store/recall, trace record/playback and native tracking requests through the bridge with diagnostics enabled. Distinguish focus actions from read-only focus/status polls. Observe release/connection behavior, authentication, streaming, `s.origin`/redirect bypass and native capability/status requirements.

Compare a direct timing sample with bridged timing to measure added overhead, not to qualify direct-camera functionality. Evaluate sessionless app requests with the controller session; if insufficient, select/document a managed session strategy and required adaptation.

**Exit:** verified new route, session strategy and native-translation feasibility. Offline work can proceed, but equipment interoperability cannot be claimed without equipment.

### Phase 2 Build helper and diagnostics — implemented and checked offline

Start with the production Swift helper running independently and forwarding the supported test-controller requests to the simulated camera. Configure one fixed camera destination and a loopback development listener. Run the existing `verify` scenarios through the actual helper; require all six to pass with camera request evidence and correct errors. This first working bridge milestone has been achieved in both simulated ownership profiles. Continue with the remaining phase work and independent safety review before release.

Then add the typed app interface, independent lifetime/registration, exclusive listener ownership, authenticated app access and initial optional diagnostics. Extend the bench for authentication, streaming and session/address adaptation as those paths are added; use captured or documented exchanges rather than guessed controller behavior. Use simulated peers to test our parsing/transport/logging, not camera feature semantics. The focused helper and logging checks now pass; the isolated host service now passes ten native registration/lifecycle checks; the booth Mac and equipment interoperability still require rehearsal.

Keep the test rig standalone and reusable. The test-only reference relay is not the production bridge and its code is not the basis for shipping the Swift helper. On helper process restart, a private recovery marker requires explicit physical stops and fresh finite-operation completion before a new tracking start. Healthy app reconnects retain the existing helper and do not require that sequence.

**Exit:** new helper builds/runs independently, forwards all four physical preset/trace operations and representative movement requests, authenticates its client and retains forwarding independently of the UI. Logging faults do not block it.

### Phase 3 Implement arbitration and recovery — implemented and checked offline

Implement authorization, purpose/generation checks, bounded queues, physical priority, release/completion admission and recovery without replay. Extend the standalone bench with separate software and physical-control clients at the helper's public interfaces. Check that a physical trigger revokes authorization before any later software movement can pass, invalidates queued work, handles bounded in-flight work, and leaves tracking unauthorized after release. Add explicit re-enable, stale stop/retry, timeout/disconnect and restart cases. Include preset store/recall, trace record start/stop and playback/stop, and focus takeover while preserving their request sequences. Observe actual helper decisions and camera requests rather than adding a simulated tracker or copying the helper's state machine into the rig.

**Exit:** focused ownership tests prove revocation, stale rejection, physical priority and no automatic reauthorization. Measure overhead against D05 limits.

### Phase 4 Integrate minimally with Churchfront — focused contracts, recovery UI and tracking takeover checked

Attach adapters to actual app code. Extend the bench with adapter contract checks showing that representative requests cross the new seam, hardware events invoke the existing stop immediately, existing starts cross authorization, and existing state reaches the new status interface. Include separate changed claim/stop paths and shutdown. The transport report alone cannot establish that Churchfront tracking is disabled; this milestone needs evidence from the actual changed adapter.

**Exit:** no changed path bypasses arbitration; takeover/activation contracts work for the mapped camera. No broad tracking, preset/saved-shot, preview, graphics, ATEM or untouched non-bridge regression suite is added to acceptance.

### Phase 5 Add optional native translation — awaiting equipment evidence

Implement only proven native command/status/capability adaptation. Test the single configured camera, duplicates, failures, takeover, enabled/disabled routing and option transitions. Apply the confirmed D03 default and verify that option changes do not start tracking. Keep target selection unchanged.

**Exit:** native actions invoke existing Churchfront actions through the new adapter when enabled, pass unchanged when disabled, and reflect actual app state. No double activation or preset interception is introduced.

### Phase 6 Package and exercise new failures — bundle and isolated host service checked

Embed/sign helper/metadata before signing the whole app. Check helper presence, identity, registration, supported interface/startup and initial logging default/opt-out. Inject app loss, helper restart, route failure, reordered callbacks, malformed bridge input, mismatch and log/storage exhaustion. Test our isolation mechanisms, not causes of upstream crashes. Coordinate helper replacement and whole-build rollback.

**Exit:** new failure paths have repeatable evidence, stale work is discarded and healthy-helper forwarding survives app loss. Helper/Mac outage remains an accepted route risk.

### Phase 7 Rehearse the added workflow — pending target equipment

Use physical controls during an existing tracking session, check tracking disablement, and deliberately re-enable through the new route. A representative real tracking-loss situation can provide context for recovery, not qualification of loss detection/quality. Check new native mapping and bridge diagnostics under normal booth workload.

**Exit:** only the change-specific acceptance criteria pass on target equipment, added overhead meets D05 and a complete working build is retained. Do not separately sign off Churchfront tracking, camera positioning, previews or ATEM behavior.

## Verification coverage

| Requirement | Evidence limited to our additions |
| --- | --- |
| BR01 Takeover | Hardware input revokes authorization and gets priority; queued/in-flight/stale app work cannot override it. |
| BR02 Reactivation | Release/target-state/time/reconnect/restart do not authorize; a new valid existing start does. |
| BR03 Preset and trace routing | All RC-IP100 preset store/recall and trace record/playback sequences and camera replies pass through correctly and trigger takeover, including recording/playback start and stop. |
| BR04 Translation | Native mapping, enabled/disabled routing, idempotency and double-activation prevention. |
| BR05 Control status | The configured camera invokes the right app action; reflected state matches upstream; bridge failures are visible. |
| BR06 Installation | New helper ships/registers/launches in the app bundle without separate operator deployment. |
| BR07 Isolation/recovery | Intentional app quit and app failure preserve healthy-helper forwarding/registration; reopening attaches without replay or duplicate listeners; explicit Stop Bridge ends forwarding. |
| BR08 Diagnostics | New default, opt-out, export, redaction, rotation and logging-failure checks. |
| BR09 Configuration | New settings persist/map correctly without activation side effects. |
| BR10 Upstream compatibility | Changed adapters, helper interface and new bundle artifacts pass focused checks after updates. |
| BR11 Added overhead | Focused rehearsal evidence and routing/diagnostic measurements. |

Test through the app's actual changed interfaces, not copied old internals. Reuse upstream behavior/fixtures when useful. Existing upstream suites remain upstream's responsibility; running or expanding them is not a project acceptance requirement. Add a focused check only where our change needs evidence.

## Upstream updates and release management

Maintain the fork with `origin` pointing to `breakall/churchfront-video` and `upstream` pointing to `Churchfront/churchfront-video`. Keep bridge code in its owned package, the standalone test rig in `Tools/camera_rig`, and integration edits in focused commits. Pin the consumed revision and record resolution. Do not inject files into an already signed upstream app.

For an update candidate, build it, run new bridge tests and focused changed-interface checks, verify helper/bundle artifacts and repeat the relevant bridge rehearsal. Do not turn the update into full-app qualification. A clean merge does not prove our adapter compatibility.

Record upstream/bridge/adapter/interface revisions, build identity, toolchain and bridge-relevant firmware. Retain the prior complete app/helper build and coordinate replacement/rollback. Upstream acceptance of small integration seams may reduce maintenance but is not assumed.

## Decisions and supporting material

D01 through D06 are tracked in the [settings register](camera-control-settings.md). D01 through D03 record the confirmed helper lifetime, takeover actions and single-camera native setting, which defaults off. Finish retention/overhead limits and verify safe setting transitions before release. Equipment access and actual session/native interoperability remain bridge-specific dependencies.

See the [settings register](camera-control-settings.md), [protocol investigation](automatic-handoff-protocol-research.md), [upstream research](upstream-bridge-research.md) and the [test rig guide](../../Tools/camera_rig/README.md). Earlier research suggestions for automatic resume, previous-person retention or broad app validation do not expand this plan.
