# Keeping a Churchfront bridge maintainable across upstream updates

Current requirements are maintained in [camera-control-settings.md](camera-control-settings.md). The user has clarified that manual takeover disables tracking until an explicit new start, that native tracking interception is optional, and that preset buttons must not be repurposed. Earlier proposals for automatic resume or a manual-mode button are superseded.

Research date: 2026-11-23. Inspected Churchfront Video `main` at commit `9892525d2a624af82c5fb8eaed6655179472b399` (version 0.1.2); `git ls-remote origin HEAD refs/heads/main` confirmed that the public branch still matched the local checkout during this review. This report combines repository inspection with official Apple, Swift and GitHub documentation. Recommendations are engineering inferences, not guarantees of compatibility with future upstream releases. No production helper, app integration, remote fork, pull request or update pipeline has been implemented.

## Conclusion

Use an independently owned bridge package and helper, a narrow Churchfront adapter at the existing camera-connection seam, a small tracker pause/readiness interface, and an update process that validates the whole merged application. Continue shipping one application bundle. If the helper must outlive the UI, give the bundled helper an independent per-user LaunchAgent lifecycle.

This reduces the amount of code affected by upstream updates and makes failures detectable before deployment. It cannot eliminate maintenance of the app adapter. The best eventual outcome would be upstream acceptance of the transport and tracker-pause seams; until then a small maintained fork is required for the full automatic handoff.

## Recommended ownership split

Keep the bridge implementation in its own Swift module/package, with its helper executable, protocol types and tests owned together. Churchfront should contain a small adapter that translates its camera/tracking operations into the bridge interface. Do not import Churchfront's internal tracker/UI types into the helper. This limits the change surface when upstream refactors tracking or UI.

SwiftPM supports dependencies on local packages, or remote packages constrained by versions/revisions. A separate package does not require a separate user installation: the application build still embeds the helper. A local path uses whatever source exists there and has no version constraint; a released package plus the top-level app's committed `Package.resolved` gives a recorded dependency revision. A dependency library's own `Package.resolved` does not pin the consuming app. [SwiftPM dependency documentation](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/addingdependencies/), [SwiftPM dependency resolution](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/ResolvingPackageVersions.md).

Use one explicit interface version between application adapter and helper. Initially require an exact supported protocol version rather than maintaining speculative compatibility layers. Include command generation/epoch fencing and ownership state in the interface. Unknown versions must disable tracking writes; they must never silently fall back to Churchfront driving the camera directly while the helper forwards RC-IP100 traffic. A helper already configured and validated for hardware forwarding may continue that manual path independently; without a validated route it cannot promise manual control.

## Same application bundle, independently managed lifetime

**An embedded XPC service is not sufficient if the bridge must survive the application exiting/crashing.** Apple's current XPC overview says an embedded XPC Service process is tied to the client lifetime and exits when its client exits. XPC gives process isolation and `launchd` management, but those facts do not imply independent survival. [Apple XPC overview](https://developer.apple.com/documentation/XPC).

For independent per-user lifetime while shipping in the same app, investigate a bundled **LaunchAgent registered through `SMAppService`**. This is supported from macOS 13, keeps helper executables inside the main app bundle, and registration is subject to user approval. It does not require a systemwide root LaunchDaemon for ordinary LAN networking. Check and display registration/background-item status; a disabled helper must not be treated as active. [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice).

Apple's modern bundle layout places the agent plist in `Contents/Library/LaunchAgents`, and uses a `BundleProgram` path relative to the app bundle for the helper. This avoids copying a second independently managed executable into a system directory. The chosen executable location and final signed layout still need to follow the applicable code-signing requirements. [Apple helper migration/layout documentation](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos).

A LaunchAgent provides an independent lifecycle, but restart policy, exclusive ownership of a camera/listener, IPC reconnects and upgrade shutdown are application design work. It must not replay stale movement after launch. If it keeps running after an intentional app quit, expose a way to stop it and explain the lost functionality if background execution is disabled. [Apple ongoing background-process guidance](https://developer.apple.com/documentation/appkit/managing-ongoing-background-processes-in-your-mac).

## Packaging and upgrades

Build, embed and sign the helper before signing the enclosing app. Nested executables are separate code items; signing must proceed from inner code outward. Do not modify an installed vendor-signed application bundle after signing as an update strategy: modifying bundle contents breaks its signature seal. Instead, produce a complete custom build from upstream source plus the small integration patch, with our helper included before final signing/notarization. [Apple distribution signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac), [Apple bundle modification guidance](https://developer.apple.com/documentation/xcode/embedding-nonstandard-code-structures-in-a-bundle).

An upstream replacement `.app` that lacks the helper will not preserve a locally injected helper. This is a packaging consequence, not evidence that Churchfront currently has an automatic updater. Release and roll back the **whole tested application/helper pair**, recording upstream commit, bridge revision, interface version and build identity. On update, coordinate the running LaunchAgent so an old process does not silently keep controlling cameras from a replaced bundle. Do not update during use.

## Upstream maintenance workflow

Maintain a clean upstream tracking branch and a small integration branch. Bring upstream changes into a candidate integration branch, then test before release; do not put an untested upstream `main` directly onto the booth Mac. GitHub documents fork synchronization and explicitly notes that upstream conflicts may require a pull request. [GitHub fork synchronization](https://docs.github.com/en/pull-requests/how-tos/work-with-forks/syncing-a-fork).

Use pull-request CI as the release gate. GitHub branch protection can require status checks before merging; workflow events include pull requests, pushes, schedules and manual triggers. Scheduled compatibility runs can give early notice of upstream churn, while the actual release candidate needs checks attached to that candidate. [GitHub protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches), [GitHub workflow events](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows).

Proposed checks, derived from this bridge's requirements:

- Independent bridge tests: protocol parsing, manual priority, releases per axis, stale command fencing, disconnects and authentication/stream handling.
- Adapter integration tests using the **actual newly merged Churchfront camera/tracker code**, so a renamed or bypassed hook fails rather than the helper tests giving false reassurance.
- Application/helper contract tests: version mismatch, app crash/reconnect, helper restart, no replay of old motion, and manual forwarding with tracking unavailable.
- Packaging checks on the final app: helper/plist presence, correct signatures, advertised interface agreement, launch/register behavior and clean upgrade/rollback.
- Rehearsal hardware check before promoting a release, since fake cameras cannot establish RC-IP100 behavior or mechanical latency.

The best reduction in long-term maintenance would be upstream acceptance of the small camera-transport/tracking-pause seams. That can reduce fork-only edits, but it is not authorization to contact the maintainer or evidence they will accept the change.

## Repository evidence and exact integration points

Links below are fixed to the inspected commit so that later upstream changes do not change the evidence.

| Observed location | What exists now | Recommended integration |
| --- | --- | --- |
| `Sources/CueATEM/PTZ.swift`, `PTZLink` and `PTZController.restart()` | A camera-connection protocol with real Canon and VISCA adapters; the controller constructs concrete adapters internally. `PTZLink` is internal, not a public plug-in interface. | Add a bridge adapter in `CueATEM` and select it for bridge-configured Canon cameras. Keep actual bridge behavior in the owned package. Avoid a generic plug-in system or exposing all camera internals just for this use. |
| `Sources/CueVideo/Tracker.swift`, `AutoTracker` | Target appearance, framing and movement history live in the app. Manual movement currently invokes `stop()`, deleting that tracking session. | Add an explicit pause/readiness interface that preserves identity and framing, prevents learning from manually driven movement, and resets movement/filter history on re-entry. Keep Vision and identity internals in upstream's tracker. |
| `Sources/CueVideo/App.swift` | Application lifecycle and shutdown currently stop tracking and manual movement. | Have one owned app-side adapter coordinate helper registration/connection, protocol agreement and bridge status. Ensure shutdown stops only app-owned motion, never interrupts hardware-owned movement. |
| `Package.swift`, `build.sh` | SwiftPM already builds a shared camera library and a second executable (`cuevideo-mcp`). The shell script builds and copies named executables into a complete `.app`. | Add a pinned bridge package dependency and an explicit build/embed step for its executable, client library and LaunchAgent metadata. Keep packaging changes small and directly reviewable. |
| `Config.swift`, `SettingsView.swift` | Camera configuration and setup UI exist but contain no bridge registration/control-route settings. | Add the minimum endpoint/helper status configuration. Keep bridge-owned settings typed and avoid having the helper scrape the entire app JSON or Keychain internals. |

Sources: [camera connection protocol](https://github.com/Churchfront/churchfront-video/blob/9892525d2a624af82c5fb8eaed6655179472b399/Sources/CueATEM/PTZ.swift#L183-L224), [adapter construction](https://github.com/Churchfront/churchfront-video/blob/9892525d2a624af82c5fb8eaed6655179472b399/Sources/CueATEM/PTZ.swift#L990-L1013), [tracker manual callback and start](https://github.com/Churchfront/churchfront-video/blob/9892525d2a624af82c5fb8eaed6655179472b399/Sources/CueVideo/Tracker.swift#L195-L239), [tracker stop](https://github.com/Churchfront/churchfront-video/blob/9892525d2a624af82c5fb8eaed6655179472b399/Sources/CueVideo/Tracker.swift#L255-L268), [application shutdown](https://github.com/Churchfront/churchfront-video/blob/9892525d2a624af82c5fb8eaed6655179472b399/Sources/CueVideo/App.swift#L155-L164), [package](https://github.com/Churchfront/churchfront-video/blob/9892525d2a624af82c5fb8eaed6655179472b399/Package.swift), [bundle construction](https://github.com/Churchfront/churchfront-video/blob/9892525d2a624af82c5fb8eaed6655179472b399/build.sh), [configuration](https://github.com/Churchfront/churchfront-video/blob/9892525d2a624af82c5fb8eaed6655179472b399/Sources/CueVideo/Config.swift), [setup](https://github.com/Churchfront/churchfront-video/blob/9892525d2a624af82c5fb8eaed6655179472b399/Sources/CueVideo/SettingsView.swift).

The current tracker has a centralized `send()` for most tracking output, but `stop()` also emits stops through `PTZController`. Therefore checking a flag only in `send()` is insufficient: the camera adapter/helper must enforce ownership for every app-originated command, including delayed stops. The helper also needs command origins/generations rather than assuming every pan/tilt command is tracking. [Tracker output](https://github.com/Churchfront/churchfront-video/blob/9892525d2a624af82c5fb8eaed6655179472b399/Sources/CueVideo/Tracker.swift#L699-L710), [other stop path](https://github.com/Churchfront/churchfront-video/blob/9892525d2a624af82c5fb8eaed6655179472b399/Sources/CueVideo/Tracker.swift#L255-L268).

Privileged camera operations require particular care. Canon preset deletion creates a separate authenticated URLSession and claims a higher-priority session. A bridge adapter that forwards only joystick movements while leaving this route intact could reintroduce the original control conflict. Include these claim/write paths in the adapter contract and tests. Preview-only reads can remain direct where appropriate. [Privileged operation](https://github.com/Churchfront/churchfront-video/blob/9892525d2a624af82c5fb8eaed6655179472b399/Sources/CueATEM/PTZ.swift#L882-L932), [camera preview selection](https://github.com/Churchfront/churchfront-video/blob/9892525d2a624af82c5fb8eaed6655179472b399/Sources/CueVideo/CameraPicture.swift#L5-L15).

Git history provides a concrete reason to isolate these edits: tracking behavior changed in several commits on November 10–13 and again November 22. A large forked copy of `Tracker.swift` would share an active edit surface with upstream. Source inspection found no `.github` workflow directory in this revision, so the proposed compatibility pipeline is new work, not an existing protection.

## Interface to own and test

The bridge module should hide Canon sessions, authentication, controller request interpretation, queue ordering and restart behavior behind a small interface. The tracker adapter should translate existing app state rather than expose `AutoTracker.Session` to the helper.

Suggested concepts (design, not existing callable methods):

- Configure a camera with a stable camera identifier and validated real endpoint; bind its hardware ingress separately.
- Establish application/helper protocol agreement and a fresh application connection identity before app writes are accepted.
- Send app-originated commands labelled by purpose (tracking, app manual, setup), camera and ownership generation. Reject commands from an obsolete generation even if their socket or callback completes late.
- Report hardware override, release/settlement state, helper health and the current generation.
- Report fresh same-subject readiness from the app, tied to the same generation. Do not send images or upstream tracker structs to the helper.

The helper's final decision to admit tracking motion requires both valid hardware release/settlement and fresh app-side target readiness. It must not implement target identity by guessing from telemetry. The app-side pause must reset the tracker's own sent-value bookkeeping so it does not mistakenly suppress the first resumed command because it equals an old value.

Keep the helper buildable without `CueVideo`, `CueATEM`, SwiftUI, Apple's Vision processing, ATEM state, or NDI. Put only the small message/command model and client communication in the shared bridge-owned library. This ownership split lets a UI or tracker refactor require adapter changes while leaving the networking/priority implementation unchanged.

## Alternatives assessed

| Approach | Upstream maintenance | Fit for this request |
| --- | --- | --- |
| External script using existing localhost start/stop tools | Very few source edits, but depends on app tool behavior | Inadequate: stop destroys target session and does not release Canon ownership; restarting may choose a new person. |
| Standalone camera-emulating proxy with no app edits | Avoids a source fork but pushes more Canon emulation into proxy | Can arbitrate transport, but has no trustworthy same-person readiness or tracker-history reset interface. Does not by itself meet seamless recovery. |
| Put all bridge/session/identity logic in existing app files | Fast initial access to internals | Larger shared edit surface and weaker process isolation; reject for long-term maintenance. |
| Owned package/helper plus narrow maintained app adapters | Some deliberate source integration remains | Recommended; most bridge code can remain unchanged when upstream UI/tracking changes. |
| Upstream accepts the small integration seams | Least long-term fork-only work | Preferred end state, subject to maintainer review; do not depend on acceptance. |

The localhost tools have no preserving pause/ownership contract in the reviewed version. `start_tracking` calls `AutoTracker.start()`, and `stop_tracking` calls `stop()`. The latter deletes the tracking session, while the camera connection has its own claiming lifecycle. [Tool implementation](https://github.com/Churchfront/churchfront-video/blob/9892525d2a624af82c5fb8eaed6655179472b399/Sources/CueVideo/ControlTools.swift#L268-L278), [stop tool](https://github.com/Churchfront/churchfront-video/blob/9892525d2a624af82c5fb8eaed6655179472b399/Sources/CueVideo/ControlTools.swift#L352-L355), [connection lifecycle](https://github.com/Churchfront/churchfront-video/blob/9892525d2a624af82c5fb8eaed6655179472b399/Sources/CueATEM/PTZ.swift#L640-L709).

## Concrete update and compatibility plan

1. Record a release tuple: upstream commit, bridge package revision, adapter revision, protocol version, macOS/toolchain and signing identity. Pin the bridge dependency to the selected revision/version and commit the consuming application's dependency resolution.
2. Keep upstream history clean. Maintain the adapter, lifecycle/configuration and packaging edits as a few focused integration commits. Store bridge implementation/tests in its package rather than interleave them with upstream files.
3. For each desired upstream release, merge it into an integration candidate and build the complete application/helper pair. An optional early-warning check against upstream `main` is useful, but does not replace the release candidate's tests.
4. Run independent bridge tests and the actual newly merged app's tests. Add integration tests at the app-to-helper interface, not tests of copied old app behavior. A merge with no textual conflict is not evidence of compatibility.
5. In the camera simulator, deny app ownership, then exercise the actual tracker, app joystick/zoom, presets/home/saved shots, automation, stage scan, privileged session claims and shutdown. Assert that none can bypass the arbiter or send a stale stop during hardware override. Test that same-person tracking resumes with reset dynamics only after release/settlement/readiness for the current generation.
6. Fault tests must include protocol mismatch, stale readiness, app crash, heartbeat loss, helper crash, camera disconnect and upgrade/reconnect. On app death, stop any app-owned continuous movement as needed, reject later app commands, and preserve validated hardware forwarding without replaying app commands. A UI crash must not terminate the LaunchAgent. A helper failure still interrupts its own route; process isolation cannot eliminate that failure mode.
7. Inspect and verify the final bundle: the right helper exists, registration metadata targets it, signatures validate, both executables agree on protocol, and only one helper owns the camera listener. Replace the entire tested app at a controlled downtime; coordinate the old running helper and roll back the entire pair if necessary.
8. Rehearse on the real CR-N500/RC-IP100 before promotion. Unit/loopback tests cannot establish that the controller follows the proxy, that authentication/session choices interoperate, or that mechanical handoff latency is acceptable.

No live-camera reproduction was possible because this Mac is not on the equipment network. Research and source inspection were performed; the compatibility pipeline above is a proposed implementation plan. The earlier Python diagnostic's eleven passing tests validate its request observation/forwarding only and are not evidence that an upstream-integrated bridge or crash-surviving helper already works.
