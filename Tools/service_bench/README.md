# macOS background-service bench

Run from the repository root on a Mac with the Swift toolchain:

```sh
./build.sh debug
python3 Tools/service-bench.py
```

This exercises the actual `SMAppService.agent` registration path using a uniquely identified test application, the signed production helper, and the standalone camera simulator. It never registers the production service or edits Churchfront's settings.

The fixture's bundle, token, configuration and logs live in a private temporary directory. Background processes have their own filesystem permissions, so the fixture does not store runtime data in protected Documents. Production uses Application Support. The plist retains the production `BundleProgram`, `KeepAlive` and ten-second throttle; only its label, isolated configuration arguments and log destinations change.

The bench verifies six transport scenarios and four service/lifecycle scenarios:

- Movement, focus, preset store/recall, trace recording/playback/cancellation, and camera error replies through the service-managed helper.
- Authenticated tracking authorization, physical takeover, and app-client disconnect.
- A real fixture-app process using the production Swift client quits normally or is killed; physical forwarding continues with the same helper PID, and its app lease ends.
- The owned helper is killed; launchd restarts it automatically without `kickstart`. The new process remains unauthorized and enforces physical-release recovery before a new explicit start.

Ready metadata is checked against the actual signed helper image hash. This catches relative-`argv[0]` identity failures that do not appear when a shell starts the helper by absolute path.

Every registered test service is unregistered in cleanup. The report passes only after the registration is `notRegistered`, the launchd job is absent, and the helper process is gone. SIGTERM/SIGINT interruption also enters cleanup. An emergency bootout, if needed, targets only the unique test label and does not substitute for verifying registration removal.

The default report is `.camera-rig/background-service-verification.json`; choose another path with `--output`. It contains service and app-process PIDs, registration results, camera requests, sanitized app-interface evidence, and cleanup results. It never contains the bearer credential or real camera session tokens.

This is a real macOS service test with a registrar fixture. It does not launch the Churchfront UI or its tracking engine, use real equipment, or prove operation across logout/reboot. Other Macs may require background-item approval or a suitable signing identity; the bench records such a block and removes the pending test registration rather than claiming success.
