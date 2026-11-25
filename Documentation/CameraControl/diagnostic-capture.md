# Capturing a controller connection failure

These diagnostics observe forwarding and admission decisions. They do not change control priority, replay requests, move the camera, or disable recovery safeguards. A successful build or simulated test is not proof of RC-IP100 hardware compatibility.

The helper owns one upstream Canon session and renews its control privilege while running. Controller session commands terminate at the Mac. The helper issues separate controller-facing IDs and translates control requests to the upstream session. A camera-session loss disarms tracking and invalidates queued movement. The helper must claim a replacement session and confirm an all-axis stop before resuming control. The operator can then enable tracking after releasing the physical controls.

## One rehearsal capture

1. Install the diagnostic build and leave **Detailed bridge diagnostics** enabled in Setup → Cameras → Physical camera controller. Record the helper build identity and the test time. Installing a new helper requires a restart; do not restart repeatedly during capture.
2. Keep the controller's direct-to-camera slot disabled. Select its bridge slot, configured with the Mac listener address/port, camera credentials, and the controller address permitted in Setup.
3. With tracking off, briefly actuate and release pan/tilt, zoom, and focus. Physical forwarding does not require tracking authorization. Observe whether the camera moves and stops; note the times.
4. Try a small app manual movement only after physical releases are confirmed. After a helper restart, `recovery_required` blocks app writes until the controller has successfully sent explicit stops for pan, tilt and zoom and fresh camera information confirms settlement. Confirmed autofocus resolves the startup focus check. Manual focus movement requires an acknowledged focus stop. Do not delete the recovery marker to bypass this gate.
5. Use **Export diagnostics…** in the same panel. The default bounded files are `~/Library/Application Support/CueVideo/CameraBridge/diagnostics.jsonl`, `.1`, and `.2`. Keep all three because rotation may divide a connection across files. Do not share `app-token`, `ready.json`, camera credentials, or packet/body dumps.

## Reading schema version 2

- `listener_request` shows an accepted HTTP request before bridge routing. `listener_rejected` explains parse/framing/source/limit failures, such as `invalid_request_line`, `unsupported_framing`, or `pipelining`. Listener events use generation zero because the bridge actor has not assigned one; correlate by time, origin, and endpoint. Stream events share the bridge request ID.
- `information_response` records the camera's HTTP status, normalized numeric Livescope result, content-type category, and time to first bytes. It is emitted as soon as bounded headers arrive, even for a long-lived information stream.
- `information_snapshot` classifies session privilege (`enabled`, `disabled`, `waiting`, `none`, `missing`, or `other`) and whether the advertised origin points at the configured camera, listener, another origin, or is absent. The privilege duration and advertised URL are never logged. Ordinary `forwarded` events include the same safe classifications, making open/claim failures visible.
- `information_stream_finished` gives the close reason (`upstream_eof`, `downstream_eof`, errors, timeouts, or malformed/oversized headers), whether headers were sent, and bounded byte counts. An opened/closed pair alone does not establish that the controller accepted a camera status response.
- `request_failed` adds a stable reason such as `recovery_required`, `held_controls`, `stale_lease`, or `tracking_disabled`. Its booleans describe the gate at failure time. `health: ready` alone does not imply movement authorization.

Snapshot inspection reuses the existing 64-KiB observer bound and parser; it does not decode arbitrary multipart parts or promise complete classification for indefinite streams. Missing snapshot metadata is not evidence that the camera omitted the field. Unknown or sensitive values become `other`; request bodies, raw URLs/headers, session IDs, session hashes, passwords, bearer tokens, and authentication challenges are excluded.

Logging remains off the movement queue, with a maximum of 256 pending events, 1-MiB rotation and two previous files. A busy or failed log sink drops diagnostic events rather than blocking forwarding; check `droppedDiagnosticEvents` before drawing conclusions from an absent command. High-frequency status polling can rotate the files quickly, so export promptly after a short capture.
