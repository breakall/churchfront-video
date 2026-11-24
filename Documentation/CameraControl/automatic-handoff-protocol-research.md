# Automatic RC-IP100 / Churchfront handoff

Current requirements are maintained in [camera-control-settings.md](camera-control-settings.md). The user has clarified that manual takeover disables tracking until an explicit new start, that native tracking interception is optional, and that preset buttons must not be repurposed. Earlier proposals for automatic resume or a manual-mode button are superseded.

Reviewed 2026-11-23. Documentation research only; the Mac is not on the equipment network. No claims below establish interoperability with the user's installed firmware.

## What the documented interfaces establish

- XC `s.control` describes **the caller's session privilege state**, not joystick activity. `s.origin` identifies the camera server, not the controller. No sender identity or joystick-touch notification was found in the reviewed information parameters. [Canon XC specification, sections 3.2.1.1–3 and appendix iii](https://output.nl/u/images/canon-xc-control-protocol-specifications-005.pdf#page=43)
- Camera telemetry includes position, per-axis moving/stopped status, and speed settings. These values alone do not identify who commanded movement. [Same specification, appendix iii](https://output.nl/u/images/canon-xc-control-protocol-specifications-005.pdf#page=154)
- The documented direction controls are `pan=left/right/stop`, `tilt=up/down/stop`, and `zoom=tele/wide/stop`; full parameter forms include `c.1.pan`, `c.1.tilt`, `c.1.zoom`. XC permits parameter abbreviations and GET or POST requests. [Same specification, sections 3.1.1, 3.1.3.2, appendix iii](https://output.nl/u/images/canon-xc-control-protocol-specifications-005.pdf#page=153)
- Sessionless ordinary remote-camera control is supported, subject to camera permissions; the specification also documents error responses. That supports a trial, not a guarantee of controller coexistence. [Same specification, sections 1.1.1 and 3.2.3.1](https://output.nl/u/images/canon-xc-control-protocol-specifications-005.pdf#page=78)
- The RC-IP100 supports manually entering a camera's IP address, port, username and password. [Canon RC-IP100 manual, printed page 16](https://gdlp01.c-wss.com/gds/5/0300041525/05/rcip130um-e.pdf)

## Recommended proof of concept: explicit XC proxy

This is an engineering inference from the interfaces above, not a Canon-certified integration.

Register the RC-IP100 camera slot to a Churchfront proxy listener on the Mac, with the real camera as the fixed upstream. Observe hardware-originated control requests **before** forwarding them. This gives a strong origin signal without attempting to infer human intent from camera motion. It requires one initial controller configuration change; operators should not have to select modes during use.

Use a separate listener or strongly defined ingress for the hardware path. Do not identify origin by the shape of a request, because Churchfront sends the same camera commands. Limit upstreams to configured cameras and avoid an unrestricted network proxy.

Suggested integration contract:

1. Hardware movement intent atomically changes that camera to manual override. Drop queued tracking motion and claims. Serialize any already-in-flight upstream movement before forwarding the hardware command, so a delayed tracking command cannot override it.
2. Disable Churchfront tracking immediately and suppress its motion and periodic control claims while overridden. Do not leave tracking armed to restart automatically. Retaining previous target information for a later explicit start is a separate undecided preference.
3. Track continuous manual motion **per axis**. An explicit stop releases only the named axis; a pan stop does not imply a zoom stop. Position moves and presets need completion telemetry rather than assuming that one request means the joystick is idle.
4. Require a fresh explicit operator start before allowing tracking again. Manual release, settlement and current command generation can be checked before accepting that start, but none of them initiates it. Reject an unsafe start instead of queuing it to activate later without another operator action.
5. If the last command requested continuous motion, mere silence or an idle TCP connection must not count as release. A dropped connection, stale telemetry or uncertain target should retain the override and display a clear status. A reconnect must not replay stale movement.
6. Stop commands from the *old* tracking generation must not be retried after hardware takes over. Likewise an old hardware stop must not interrupt tracking after ownership has changed.

Pan, tilt, zoom and ordinary presets are confirmed takeover triggers. Trace playback and focus/exposure behavior remain decisions to make. Treat information requests, session keepalives and claims as **non-activity**. Optional native Auto Tracking interception is a separate explicit start/stop path; do not repurpose a preset.

## Protocol details requiring bench validation

- Capture actual RC-IP100 request forms for continuous movement and release, including whether each axis gets an explicit stop and whether requests combine several axes. Test a held joystick at a camera travel limit: no motion does not necessarily mean the human released it.
- Forward HTTP authentication challenges and request targets correctly. Preserve the exact URI path/query and body for Digest authentication. Do not log authorization, credentials, cookies or session identifiers in diagnostic artifacts.
- Check whether the RC-IP100 follows the camera authority advertised by `s.origin` or redirects. If it reconnects directly to the real camera, a nominal proxy setup would lose visibility. Rewriting an advertised authority is a compatibility question, not an automatic assumption.
- Do not buffer a long-lived `info.cgi` stream to completion. Support independent reading and serialized movement writes. Preserve response status, headers and streaming behavior. Use a small upstream timeout for ordinary requests and deliberate long-lived behavior for event streams.
- If retaining sessions, avoid two independent clients repeatedly claiming control. A single managed upstream control context is a possible design; sessionless motion is another. The test must establish the actual camera behavior before selecting the final approach.
- Until actual controller traffic is observed, local simulations can verify proxy classification, ordering and override lifecycle, but cannot prove controller recognition, authentication, release detection or mechanical latency.

## Why passive sniffing is a fallback

An ordinary Mac Ethernet capture usually cannot see unicast traffic between two other devices on a switched network. Port mirroring, an Ethernet tap or an inline bridge is needed to make that traffic visible. [Wireshark's Ethernet capture guide](https://wiki.wireshark.org/CaptureSetup/Ethernet)

An explicit proxy is therefore a smaller initial deployment experiment than relying on packet capture. If the RC-IP100 will not operate through the proxy, use a switch mirror or transparent inline bridge to obtain a trace before designing further. A passive observer also cannot prevent an already-sent Churchfront movement command from racing the hardware request; integration must still enforce ownership.
