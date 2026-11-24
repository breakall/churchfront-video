# Camera control bridge

The bridge gives the RC-IP100 priority over Churchfront tracking for one Canon CR-N500. Any physical joystick, zoom, focus, preset or trace action disables tracking. Tracking resumes only after an explicit operator start.

These documents are maintained with the implementation in this fork:

- [Business requirements](business-requirements.md): existing behavior, the problem, and the required operator experience.
- [Implementation plan](implementation-plan.md): architecture, milestones, current progress, and verification limited to our additions.
- [Features and settings](camera-control-settings.md): defaults, options, and remaining decisions.
- [Verification record](verification.md): completed offline checks and remaining equipment/service rehearsal.
- [Test utility](../../Tools/camera_rig/README.md): standalone camera/controller simulation and checks against the actual helper.

Run the focused offline verification from the repository root:

```sh
Tools/verify-camera-bridge.sh
```

This builds the helper, runs the standalone utility tests, exercises the actual helper process, and checks the changed app interfaces. It does not register a background service or contact real cameras. Generated builds and reports stay under `.camera-rig/`; set `CAMERA_BRIDGE_BUILD_ROOT` to reuse another scratch directory.

Supporting research records the evidence available before implementation. Current requirements and implementation status take precedence over earlier proposals:

- [Canon protocol and automatic handoff](automatic-handoff-protocol-research.md).
- [Upstream integration and helper architecture](upstream-bridge-research.md).
- [Churchfront source investigation](churchfront-source-research.md).

The native tracking button's command and capability exchanges require real-controller evidence. They are not inferred from autofocus commands or mapped onto a preset button.
