# Background-service bench: Apple interface review

Reviewed November 24, 2026. Host observation: `sw_vers` reports macOS 27.0.1, build 26A434. This note describes the registration mechanism and proposed evidence; it does not assert that service registration or simulator checks have run.

## Registration and bundle layout

Use `SMAppService.agent(plistName:)` from the owning application bundle. The named plist belongs in that bundle's `Contents/Library/LaunchAgents` directory. Apple describes LaunchAgents as user-session processes managed by `launchd`, rather than root daemons. [Apple: agent initializer](https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:)), [Service Management overview](https://developer.apple.com/documentation/servicemanagement/).

The helper can remain inside the app. Set `BundleProgram` to its bundle-relative location, such as `Contents/Helpers/camera-control-bridge`, and place the arguments in `ProgramArguments`. Apple's migration guide specifies that bundle-relative arrangement. The Apple-provided `launchd.plist` manual on this Mac confirms that `BundleProgram` is reserved for jobs installed through `SMAppService`. Manually bootstrapping a rewritten absolute-path plist would test another installation mechanism. [Apple: bundle migration](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos); local primary documentation: `man launchd.plist`.

A GUI is not a prerequisite for the registrar. Apple's GUI-less sample invokes its app's `Contents/MacOS` executable directly with registration, status, test and removal commands. Fresh invocations reconstruct the service object. That supports a small isolated registrar executable inside a fixture app, without starting the real Churchfront UI or reading its settings. [Apple: GUI-less Service Management sample](https://developer.apple.com/documentation/servicemanagement/updating-your-app-package-installer-to-use-the-new-service-management-api).

## Authorization, signing and removal

Registration can bootstrap a LaunchAgent immediately and records it for later logins, subject to authorization. A successful registration call alone does not prove that the helper is running or serving camera requests. Check service status and exercise its actual endpoints. [Apple: register](https://developer.apple.com/documentation/servicemanagement/smappservice/register()).

`enabled` describes an eligible registered service. `requiresApproval` means registration exists but the user must allow it in System Settings; revoking consent also produces that status. Treat `notFound` as a setup/error result rather than a running service. [Apple: status cases](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum), [approval status](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum/requiresapproval).

Apple DTS recommends signing the embedded helper and its app with the same Apple-issued identity and identifies ad-hoc signing as a source of authorization/persistence problems. Our development build's ad-hoc signature validates integrity locally, but is not evidence that macOS will accept this registration path. Inspect available signing identities and report the observed result without weakening system security or substituting manual bootstrap. [Apple DTS: signing and persistent service authorization](https://developer.apple.com/forums/thread/799910).

Use `unregister` for cleanup: Apple documents termination of the running LaunchAgent and removal of future automatic launches. Confirm both the registration result and endpoint/process disappearance before removing fixture files. [Apple: unregister](https://developer.apple.com/documentation/servicemanagement/smappservice/unregister()).

## Proposed isolated test sequence

The following is a project-specific test design inferred from those interfaces:

1. Build a uniquely identified fixture app containing the actual helper. Give it a distinct service label, private token/configuration/log paths and loopback-only camera/controller endpoints. Keep the production bundle, configuration and label untouched.
2. Capture pre-test absence, register through `SMAppService`, and record status plus launch evidence. If approval is required, leave the precise pending step visible; do not claim the test passed.
3. Run forwarding and takeover checks against the service-managed helper and simulated camera.
4. Let the registrar app exit, and separately test app-client disconnect. Verify the helper PID stays alive and physical commands still work.
5. Kill only the owned service's helper, without requesting a manual restart. Verify `KeepAlive` relaunches it, its PID changes, tracking stays off and the recovery fence works. The installed plist's 10-second `ThrottleInterval` makes an immediate restart an invalid expectation; allow a bounded interval beyond that policy. The Apple-provided local `launchd.plist` manual documents both keys.
6. Unregister through the fixture app. Confirm the test job and endpoints are gone and are not relaunched. Retain a sanitized report and leave no active test registration behind.

Use the helper's ready metadata for PID and endpoint identity. `launchctl print` is useful corroborating diagnostic evidence, but Apple's local `launchctl` manual explicitly disclaims a stable output format. Do not turn its formatting into the production control interface.

## Observed result on this Mac

The isolated bench subsequently registered successfully through `SMAppService.agent` with status `enabled`, using development ad-hoc signatures and no installed Apple signing identity. Launchd identified the job as managed by `com.apple.xpc.ServiceManagement`. This establishes acceptance on this host, not a general signing guarantee for other Macs or releases.

All ten simulator-backed service checks passed: six transport checks plus takeover/disconnect, fixture-app quit, fixture-app crash, and automatic helper restart with the recovery fence. The helper PID stayed the same across app disconnect/quit/crash and changed after its own forced termination. Cleanup returned `notRegistered` and confirmed both the launchd job and helper process were absent. The production service and profile were untouched.

This test found and fixed an actual launchd-specific defect: `ProgramArguments[0]` is a relative name, so it cannot identify the executable for the app/helper build agreement. The helper now uses `_NSGetExecutablePath` and rejects an unreadable image instead of hashing empty data. The bench validates the ready identity against the actual signed helper file.

See the [reusable bench](../../Tools/service_bench/README.md) and [verification record](verification.md).
