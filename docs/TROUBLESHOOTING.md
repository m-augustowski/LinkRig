# Troubleshooting and CI

| Symptom | Check |
| --- | --- |
| Agent unavailable | Correct Mac IP and **control** port 49170; actual listener running; correct bind interface; host firewall; LAN client isolation; privacy consent. USB does not establish a route. |
| Authentication failure | Pairing secret is current Base64 from this agent instance. Stop/restart rotates it. A response signed with a different key is rejected as well. |
| Expired command | Synchronize host/device clocks within 60 seconds. SDK retries use the same ID/body; after the validity window, inspect and decide on a fresh operation. |
| Busy / sessionBusy | Await related commands sequentially. Run one physical example test at a time. Close the existing session or wait for its lease; do not silently steal it. |
| Capacity | Replay cache holds at most 256 command IDs for their 60-second window. Reduce command frequency and wait for entries to expire. Cached valid IDs still return historical acknowledgements. |
| No traffic effect | App endpoint must use port 49171. Direct backend URLs, alternate DNS routes, QUIC/UDP, and other connections bypass the relay. Verify one known foreground HTTP download first. |
| More throughput than the limit | Limit is per TCP connection/direction and counts headers; inspect concurrent connections. Allow a small buffering transient. Aggregate bandwidth is not implemented. |
| Latency does not match RTT | The current capability is **chunk delay**, not precise propagation latency. It can also reduce throughput. Chunk boundaries are OS/stream dependent. |
| Download cannot recover | Broken streams need a retry strategy. Sample restarts from byte zero and limits retries to 30. Integrity mismatches are terminal. Agent must remain running or be restarted. |
| Agent crashed; pairing file remains | Confirm the old agent is gone, remove that specific file, restart and pair again. CLI refuses to overwrite credentials. Old pairings are invalid. |
| Empty history after restart | Reports are memory-only, capped at 10 completed sessions / 200 events each. Export JSON before quitting. |
| ATS / privacy denial | Review test host Info.plist and Apple's local networking guidance. NSAllowsLocalNetworking and local-network consent serve different purposes. Avoid production-wide insecure exceptions. |
| Listener returns Operation not permitted | Execution environment denies local sockets. Run the integration suite on an unrestricted Mac; unit-only passing does not satisfy traffic acceptance. |

## Local and CI checks

```sh
sh scripts/check.sh
xcodebuild -project Examples/DownloadLab/DownloadLab.xcodeproj \
  -scheme DownloadLab -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/rig-ios CODE_SIGNING_ALLOWED=NO build-for-testing
sh scripts/package-companion.sh
```

These commands build/test on the host and build unsigned iOS bundles. They do not run the iPhone or simulator, open GUI windows, publish, or install anything. The GitHub Actions workflow runs these steps on macOS. It is checked in but has not been executed remotely. CI needs permission to bind loopback sockets. Default ports in tests are allocated dynamically to avoid conflicts. Shipping binaries requires a separate explicit signing/notarization/release process.

## Restricted build environments

SwiftPM and Clang default to caches outside the workspace. In this workspace, compilation succeeds with writable caches and SwiftPM's supported `--disable-sandbox` option, which avoids nested compiler/manifest sandbox creation. This does not grant access beyond the outer execution sandbox:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/connectionrig-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/connectionrig-clang \
swift test --disable-sandbox --disable-xctest \
  --scratch-path /tmp/connectionrig-build -j 4 \
  --skip 'liveTransfer|sdkUnavailable|directionalUpload'
```

`RIG_DISABLE_BUILD_SANDBOX=1` adds this SwiftPM option to check.sh and package-companion.sh when needed. It is a build-only option, not a product runtime dependency. The SDK and engine use public APIs.

The initial restricted full Xcode project build in this workspace could not resolve its local package because Xcode's nested manifest sandbox is denied, even after redirecting caches to /tmp. No unsupported Xcode preference is required by the product. `sh scripts/build-ios-source.sh` provides an independent compiler path: it builds SDK modules for arm64 iOS, compiles an unsigned example executable/module, and typechecks both device test frameworks using the Xcode-provided macro plugin. Its direct compiler invocations use the toolchain's `-disable-sandbox` option for the same nested-sandbox restriction. It does **not** validate Xcode bundle assembly, signing, installation or device execution.

The first SwiftPM test invocation also attempted XCTest discovery and emitted an architecture/bundle-loading diagnostic from this host configuration. Host test targets exclusively use Swift Testing, so subsequent commands use `--disable-xctest`. The iOS examples still demonstrate both frameworks and are typechecked independently.

The later unit/UI follow-up successfully built both iOS test bundles with Xcode 27 outside the nested build sandbox. The host TCP suite also passed outside the socket restriction. Those newer results are recorded in VALIDATION.md; they do not constitute execution of the UI test on a device.

For UI tests, use the separate DownloadLabUITests scheme and configure its own test-runner environment. Its programmatic app launch forwards the data endpoint; its XCTest code performs the taps. An unchanged manual demo screen during a hosted model test is expected: that test owns a separate model instance and never waits for a human to tap Download.
