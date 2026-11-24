# Camera control business requirements

November 24, 2026

## Existing behavior

The video setup uses one Canon CR-N500 PTZ camera, one Canon RC-IP100 physical controller, a Blackmagic ATEM switcher and Churchfront Video.

Churchfront provides camera tracking and the operator's software controls. The RC-IP100 provides physical pan, tilt and zoom controls, preset store and recall, and trace recording and playback. When Churchfront loses the person being tracked, the camera stops moving.

The operator may also be switching cameras, managing graphics and monitoring the stream. The physical controller is the natural way to find the person and recover the shot when tracking fails.

## The problem

Churchfront and the RC-IP100 compete for camera control. Churchfront can continue claiming control even after tracking stops, making physical recovery unreliable.

The operator needs to pick up the physical controls immediately, recover the shot and decide when to enable tracking again. That transition should be part of normal camera operation, with clear feedback about who is in control.

## The solution

Add a bridge that coordinates Churchfront and RC-IP100 commands before they reach the camera. Both control paths go through the bridge on the Mac.

Physical joystick, zoom, focus, preset store/recall and trace record/playback actions automatically give the operator control and turn Churchfront tracking off. Tracking stays off while the operator finds and frames the person. The operator deliberately enables it again when ready.

Churchfront's existing Track control remains available. An optional integration lets the RC-IP100's native Auto Tracking control start and stop Churchfront tracking instead. Its tracking indication reflects Churchfront's state when that integration is enabled.

The bridge and app ship together as one Churchfront Video application. The bridge runs as a separate helper process and continues forwarding physical controls when Churchfront is closed or fails. The Mac must remain operational for bridged control.

## Operator workflow

1. Enable tracking from Churchfront or the RC-IP100's native tracking control when configured for Churchfront.
2. If the shot needs correction, use the joystick, zoom, focus, a preset action or a trace action. Tracking turns off immediately and the physical action takes priority.
3. Find and frame the person using the controller.
4. Enable tracking again when ready. Churchfront uses its existing target selection and tracking behavior.

## Required behavior

### BR01 Automatic physical takeover

RC-IP100 joystick, zoom, focus, preset store/recall and trace record/playback actions must immediately disable Churchfront tracking. Trace actions include recording start/stop and playback/stop. Physical commands take priority over pending tracking movement and delayed software commands.

### BR02 Deliberate tracking activation

Following manual takeover, tracking remains off until the operator explicitly enables it again. The bridge handles that request for the intended camera using Churchfront's existing start and stop actions.

### BR03 Preset and trace pass through

Support preset store, preset recall, trace store and trace recall from the physical RC-IP100. Trace store includes the controller's recording start/stop sequence; trace recall means playback.

Forward each operation and the camera's corresponding replies to the correct endpoint, preserving its command data and sequence. The camera remains responsible for storing presets and traces. Every preset and trace retains its normal purpose.

Preset store/recall and trace record/playback actions all use the physical-priority path and disable Churchfront tracking.

### BR04 Optional native tracking integration

Provide one application-wide setting for the RC-IP100's native Auto Tracking control, using the single configured PTZ camera. It is off by default and can be enabled in setup. When enabled, that control starts and stops Churchfront tracking. When disabled, it operates the camera's native tracking function normally. Each action is directed to the selected tracking system.

### BR05 Clear control status

The bridge connects the RC-IP100 and Churchfront to the single configured CR-N500. When native tracking integration is enabled, its indication matches Churchfront's tracking state. Churchfront shows bridge availability, manual takeover and tracking activation failures clearly.

### BR06 One application installation

Package the bridge helper and Churchfront integration together. Churchfront manages the helper automatically. The single camera/controller connection and bridge configuration are available through setup.

### BR07 Reliable physical recovery

The bridge continues physical forwarding after an intentional Churchfront quit and if Churchfront fails. Provide a separate explicit Stop Bridge action. Bridge recovery discards obsolete commands and returns with tracking off. Physical control remains the priority throughout takeover and recovery.

### BR08 Thorough optional diagnostics

Detailed diagnostics and logging are optional and enabled by default in the initial testing build. An explicit user choice is preserved across restarts and updates.

Logs explain command sources and ordering, takeover, tracking activation, native tracking integration, errors, timing and process lifecycle. Provide a local diagnostic export using sanitized logs with bounded retention. Diagnostic recording must not delay physical control.

### BR09 Persistent bridge settings

Save the single camera/controller connection, listener configuration, native tracking integration and diagnostic preferences. Applying configuration preserves the operator's explicit control over tracking activation.

### BR10 Maintainable upstream integration

Keep bridge logic separate from Churchfront and the app integration small. Check the changed interfaces when adopting upstream updates, record the app/helper versions and retain a complete working build for rollback.

### BR11 Responsive operation

Physical control through the bridge must respond promptly, including with detailed diagnostics enabled. Measure the additional command delay and resource use during rehearsal and establish acceptable limits before release.

## Acceptance criteria

| Situation | Expected result |
| --- | --- |
| Joystick, zoom, focus, preset store/recall or trace record/playback used during tracking | Tracking turns off and the physical command takes priority. |
| RC-IP100 stores or recalls a preset, or records or plays a trace | The bridge forwards the complete controller-originated operation and returns the configured camera's replies, preserving command data and sequence. |
| Software commands remain pending at takeover | Obsolete tracking movements, stops and retries are discarded. |
| Operator releases controls after recovery | Tracking remains off until an explicit activation request. |
| Operator enables tracking through the app | The bridge authorizes and routes the existing tracking action for the intended camera, or shows why it could not start. |
| Native tracking integration is enabled | Controller tracking actions operate Churchfront for the configured camera and the controller displays its actual state. |
| Native tracking integration is disabled | Native tracking actions and status pass through to the camera. |
| Churchfront is intentionally closed or its process fails while the helper remains healthy | Physical commands continue through the helper; reconnecting the app keeps tracking off. |
| Diagnostics are enabled or disabled | The selected setting persists and physical control remains responsive. Initial test builds enable detailed capture by default. |
| A diagnostic report is exported | It provides a correlated, sanitized timeline of bridge actions, errors, settings and versions. |
| The application is installed or updated | The matching bridge helper is included and managed automatically; changed interfaces work together. |

## Implementation and configuration

The [implementation plan](implementation-plan.md) describes architecture, development phases and focused verification. The [settings register](camera-control-settings.md) records configuration choices and decisions still to be made.
