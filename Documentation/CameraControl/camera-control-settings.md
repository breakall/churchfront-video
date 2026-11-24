# Camera control features and settings

Updated 2026-11-24. This is the current requirements and settings register. It supersedes earlier design proposals for automatic tracking resumption or repurposing preset buttons. The native helper and app adapters now implement the offline control contract. Native tracking translation and target-equipment validation remain pending.

## Existing Churchfront behavior outside our delivery scope

Tracking, target selection, target-loss stopping, existing Track/keyboard controls, camera preset behavior, saved shots, previews, graphics and ATEM operation are reused. They are not new settings/features to implement or independently validate. Test only bridge routing, arbitration, translated commands/status and the app interfaces we actually change. The [business requirements](business-requirements.md) and [implementation plan](implementation-plan.md) define this change-only acceptance scope.

Retain existing target-selection semantics on an explicit start. There is no new previous-person retention or target-choice setting unless separately requested.

## Confirmed bridge requirements
- The bridge serves one CR-N500 and one RC-IP100. Use one connection configuration and one application-wide native tracking setting.
- Physical RC-IP100 joystick, zoom, focus, preset store/recall and trace record/playback actions immediately disable Churchfront tracking. Trace recording start/stop and playback/stop are included; read-only polls are not physical actions.
- Pass through physical RC-IP100 preset store/recall and trace store/recall (record/playback), including recording start/stop sequences and the camera's replies. The camera owns the stored data. This forwarding support is required, not a tracking-interception option.
- Tracking remains disabled until the operator explicitly enables it again. Joystick release, subject reacquisition, an elapsed delay, reconnects, or process restarts must not automatically enable tracking.
- Physical control is the recovery path and takes priority over tracking. Old queued tracking commands and delayed stop/retry requests must not interfere with the operator's movement.
- Routing the controller through the Mac is accepted, including the risk that a Mac failure interrupts that route.
- All preset buttons retain their camera-position purpose. Do not reserve or repurpose a preset as a tracking command.
- Ship the helper and integration in one application bundle with process isolation. The helper continues physical forwarding after an intentional Churchfront quit or app failure. Reopening the app attaches to the running helper. Provide a separate explicit Stop Bridge action.
- The primary operator may also be switching cameras, managing graphics and monitoring the stream, so tracking status and explicit activation must be clear.

Helper restart recovery is a fixed safety rule: a new helper process with an existing recovery marker keeps tracking blocked until successful physical pan, tilt, zoom and focus stops, followed by fresh finite-operation completion information and a new explicit tracking start. A healthy app quit/reconnect leaves the helper running and does not require this recovery sequence.

## Settings and options register

| Feature or setting | Required behavior or choices | Scope and default | Decision status |
| --- | --- | --- | --- |
| Native RC-IP100 Auto Tracking interception | One optional application-wide setting: Use RC-IP100 tracking control for Churchfront. Off passes native commands/status through; on translates them to Churchfront. | One configured PTZ camera; no per-camera setting. Off by default for a fresh configuration; preserve the saved choice across restarts and updates. | Optionality, single-camera scope and default off are confirmed. Exact controller interaction still needs hardware verification. |
| Bridge route | Configure the single camera's helper route. Do not silently fall back to competing direct app writes if the helper is unavailable. | One camera/controller route. | Single-camera design. |
| Real camera and controller connection | Real CR-N500 address/port, RC-IP100 source address and the existing app camera identity. Native tracking actions use that configured camera. | One connection configuration. | Required setup; no multi-camera mapping UI. |
| Bridge listener | Mac listening address/interface and port entered in the RC-IP100's camera registration. | Per ingress; exact allocation and defaults pending. | Required connection configuration. |
| Background helper operation | Continue forwarding after Churchfront quits or fails; reconnect the app to the running helper. Display registration/status and provide explicit Stop Bridge. | Application-wide fixed lifecycle, not a continue-after-quit preference. | Confirmed by the user. |
| Detailed diagnostics and logging | Optional thorough event logging and diagnostic capture with bounded retention. Provide an explicit on/off setting; never record credentials, authorization headers or session IDs. | Enabled by default in the initial testing/proving build. Honor a saved user choice on restart and upgrade. Installation-level scope is proposed; later production default remains undecided. | Optionality and initial enabled default confirmed by the user. Capture details and retention limits below are proposed implementation requirements. |

## Optional native tracking interception

When the application-wide interception setting is enabled, consume its RC-IP100 native tracking start/stop request and translate it into the corresponding explicit Churchfront action. Do not also forward that same request to enable Canon's tracker. Reflect Churchfront's actual state through whatever tracking-status interface the controller requires. Joystick, zoom, focus, preset store/recall and trace record/playback still disable Churchfront tracking and must be reflected as tracking off.

When interception is disabled, leave native tracking commands and status on their original camera path. They do not control Churchfront tracking. Disabling this option does not disable the separate physical-manual-takeover behavior for a bridge-managed camera. Define and test the interlock against accidentally running native Canon tracking and Churchfront tracking simultaneously.

The controller may require tracking capability/status replies before it offers its native control. Do not advertise a working Churchfront interception mode until that interaction has been validated on the actual RC-IP100/CR-N500. The app's existing Track control and keyboard action remain explicit activation paths.

Changing the interception option is setup work, not an instruction to start either tracker. The safe transition behavior when changing this option during tracking must be defined before implementation.

## Detailed diagnostics for the initial build

The user requires thorough diagnostics and logging to be optional, with detailed capture enabled by default in the initial build used to test and prove the system. Disabling it must not change control priority, tracking activation rules, or camera behavior. The helper implements bounded, correlated logging and the app exports the current and two rotated files. Logging/storage failures are covered by the offline helper checks; target-booth retention and overhead policy remain to be settled.

Reuse existing Churchfront state for diagnostic correlation. This does not introduce a new target-loss, preview-health or tracking-quality monitoring/validation project.

Proposed event coverage:

- App/helper startup, shutdown, crashes, restarts, connection loss/recovery, registration state, build revisions, protocol agreement and effective settings. Record settings changes and whether native tracking interception is enabled for the affected camera.
- A timeline of controller-originated joystick, zoom, focus, preset store/recall and trace recording/playback commands, app tracking commands, and explicit tracking start/stop requests. Distinguish store, recall, recording start/stop and playback/stop operations and record the camera's result. Record the resolved camera, command source and sanitized command fields, including direction, speed and preset number where relevant.
- Tracking state transitions, subject-lost events, manual takeover and explicit re-enablement, including the reason for each transition. Distinguish losing sight of a person from losing camera-control ownership.
- Native tracking interception: the native action received, whether it was passed through or translated, the Churchfront action/result, and the tracking state returned to the RC-IP100.
- Command acceptance, rejection, queueing, replacement, cancellation and forwarding; dropped stale commands/stops/retries; ownership generations; camera response/error codes; request duration, queue delay and takeover latency. Correlate the hardware command, tracking disablement, pending-command invalidation and actual forwarding order.
- Freshness of camera telemetry and preview frames, camera movement/settlement state, timeouts, malformed/unrecognized protocol messages, and authentication failures without authentication material.
- Resource and logging health: queue high-water marks, connection counts, log volume, dropped-log counters, rotation and disk-write failures. Include enough periodic health information to diagnose stalls without writing every video frame.

Proposed recording and export behavior:

- Use structured events with wall-clock and monotonic timestamps plus generated correlation IDs. Use local aliases to correlate sessions/connections; never copy real session tokens into logs.
- Keep app and helper events correlated so a report shows which process acted and in what order. Preserve useful recent helper history when the UI crashes; include available process crash reports in a diagnostic export when permitted.
- Provide an explicit diagnostic export containing the selected time window, sanitized relevant settings, app/helper/upstream versions, event timeline and available crash information. Do not upload it automatically.
- Keep logs local, rotate them, and cap total size/retention. Exact caps and duration remain to be selected; do not interpret 'thorough' as unlimited storage or unfiltered packet dumps.
- Write asynchronously through a bounded logging queue. A slow/full disk, logging exception or exhausted log queue must not block physical control, trigger movement or crash the bridge. Count dropped events and surface reduced diagnostic coverage when possible. Test this failure behavior.
- Do not capture video, subject images/appearance data, passwords, authorization headers, cookies or real session identifiers as part of ordinary detailed diagnostics. Any future image/raw capture would be a separate explicitly scoped feature.
- The initial testing build starts with detailed capture on unless the user has explicitly turned it off. Restarts and testing-build updates preserve that preference. A later production default is still a separate decision.

Proof expectations: use diagnostics during rehearsal to establish that every confirmed manual trigger disables tracking before further tracking writes, that tracking stays off until an explicit start, and that no stale movement or stop crosses a takeover. Add fault tests for malformed messages, disconnects, helper/app failure, slow/full log storage and diagnostic toggling. Passing simulator/logging tests does not replace testing the physical controller and camera.

## Decisions and remaining details

These decision IDs are referenced by the implementation plan.

| Decision | Choice to settle |
| --- | --- |
| D01 Intentional app quit | Decided: helper continues forwarding; explicit Stop Bridge is separate. Reopening Churchfront attaches to the running helper. |
| D02 Takeover triggers | Decided: joystick, zoom, preset store/recall, trace record start/stop and playback/stop, and focus actions disable tracking. Read-only polls do not. No added exposure-trigger policy has been selected. |
| D03 Native tracking configuration | Decided: one application-wide on/off setting for the single camera, off by default. Preserve the saved value; changing the option does not start tracking. |
| D04 Diagnostics policy | Initial implementation: 256 pending events, 1 MiB active log and two rotated files; local sanitized export. These bounded defaults are implemented and tested. Final retention policy and the later production default remain open. Detailed capture is on by default in the initial testing build. |
| D05 Added overhead limits | Acceptable bridge takeover/command delay and diagnostic overhead after measurement. |
| D06 Bridge equipment baseline | Camera/controller firmware, macOS and network configuration needed for bridge implementation and interoperability. |

## Settings discipline

Keep fixed safety requirements separate from user preferences. Do not add an automatic-resume option or preset-repurposing option: both contradict the current requirements. Mark unconfirmed defaults and future settings as proposals, and record new decisions here as they are made.
