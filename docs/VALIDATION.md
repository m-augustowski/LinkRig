# Validation ledger and acceptance gaps

Date: 2026-11-16. Environment: Apple Silicon Mac, Swift 6.3, Xcode 26.4; workspace execution sandbox with writable project and /tmp, denied local listening sockets and Git metadata writes. No GUI, simulator, or physical-device test was launched. No release or binary upload occurred.

## Current checked status

The latest follow-up supersedes the initial environment blockers: **eight host unit tests and three real-TCP integration tests pass**, and Xcode 27 successfully builds both the hosted unit-test bundle and the new UI-test runner. The new UI scenario has not been executed on an iPhone or simulator. Earlier blocked runs below are preserved as historical evidence; see the final unit/UI follow-up for the current build and integration details.

## Latest status — user-reported verification

The user subsequently confirmed that next-step items 1–3 work: host integration, cleanup/failure handling, and the Xcode example build. This is user-reported validation outside the agent's recorded execution; no accompanying logs, versions, or individual test results were supplied. The earlier sandbox failures below remain the historical results of the agent's own checks, not the current user-reported outcome.

The next acceptance step is an explicitly authorized physical iPhone run using the documented IP routing. Physical-device operation, USB-only routing, and real-application cart behavior remain unverified by this confirmation. The numbered next-step items are distinct from the product milestone numbers below.

## Recorded results

| Check | Actual result |
| --- | --- |
| Swift package build, host | Passed. Protocol, SDK, native agent, SwiftUI companion, example support and host test sources compiled. |
| Non-network Swift Testing suite | **8 tests passed**, 0 failures. Exact command below. Includes explicitly injected recording/failing engines and scripted SDK transports; these are unit tests, not evidence of traffic conditioning. |
| Real-socket host integration | **Not passed / environment blocked.** All three integration tests were compiled and attempted. Each failed immediately with POSIX error 1, Operation not permitted, when creating a listener. No throughput result is claimed. |
| iOS public SDK | Passed compilation for arm64-apple-ios17.0 with the installed iPhoneOS SDK. |
| iOS example source build | Passed: linked an unsigned arm64 iOS Mach-O executable and emitted DownloadLab module. Both XCTest and Swift Testing device-test sources passed typechecking. This is not a signed/installable Xcode bundle validation. |
| Full Xcode iOS build-for-testing | **Blocked** in Resolve Package Graph by sandbox_apply: Operation not permitted. Initial attempt also encountered unwritable default compiler/SPM caches; redirected-cache attempt isolated the nested-sandbox blocker. |
| macOS application bundle | Passed: development .app assembled, ad-hoc signed, codesign --verify --deep --strict succeeded. Info.plist lint passed. **Not launched or visually validated.** |
| CLI | Compiled; --help executed successfully without starting services. |
| Fixture | Python syntax compilation passed; payload's 8 MiB SHA-256 computed independently. Server not run here because listener access is denied. |
| Git milestones | Initialization attempted, denied with .git: Operation not permitted. No commits exist or are claimed. |
| GitHub CI | Workflow provided; not remotely executed. |
| Physical iPhone / USB | Not executed; no authorization was requested or assumed. Both acceptance gates remain unresolved. |

## Commands used

Host unit suite, using writable caches and avoiding nested build sandbox creation:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/connectionrig-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/connectionrig-clang \
RIG_DISABLE_BUILD_SANDBOX=1 RIG_SCRATCH_PATH=/tmp/connectionrig-build \
sh scripts/check.sh unit
```

Eight tests:

- commandRoundTripAndValidation
- signaturesRejectTamperingAndReflection
- authenticationDuplicatesCapabilitiesAndIsolation
- scheduledRestorationAndLeaseExpiry
- shutdownRestores
- failedApplicationIsNeverAcknowledgedAsApplied
- sdkRetriesIdenticalBytesAndRejectsUnsupported
- sdkMapsTimeoutUnavailableAndCancellationAndRejectsForgedReplies

Socket integration tests, compiled and attempted (all blocked at listener creation), intended for an unrestricted Mac via `sh scripts/check.sh`:

- liveTransferThrottleInterruptBlockAndRecover: one existing foreground HTTP stream, initial progress gate, live 512 →64 KB/s change, measured 64 KiB window >500 ms and <4 seconds, no restart before interruption, separate control reachability, 600 ms block, rejection of new relay requests, unaffected direct origin, restarted GET and SHA-256 completion, idempotent close, timeline.
- sdkUnavailableAuthenticationCancellationAndTimeout: actual silent/stopped TCP service, wrong pairing, and cancellation. The equivalent SDK *mapping* behavior is covered by explicit scripted unit transports, but actual URLSession transport behavior remains unverified here.
- directionalUploadPacingAndChunkDelay: 128 KiB raw upload at 64 KB/s with chunk delay, 1.5...6 second tolerance and exact response. This combines delay and pacing; standalone delay accuracy needs additional measurement.

Independent iOS compiler validation:

```sh
sh scripts/build-ios-source.sh
```

Full project attempt (blocked):

```sh
CLANG_MODULE_CACHE_PATH=/tmp/connectionrig-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/connectionrig-clang \
CFFIXED_USER_HOME=/tmp/connectionrig-home \
xcodebuild -project Examples/DownloadLab/DownloadLab.xcodeproj \
  -scheme DownloadLab -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/connectionrig-ios \
  -clonedSourcePackagesDirPath /tmp/connectionrig-packages \
  -packageCachePath /tmp/connectionrig-package-cache \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

Packaging:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/connectionrig-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/connectionrig-clang \
RIG_DISABLE_BUILD_SANDBOX=1 RIG_SCRATCH_PATH=/tmp/connectionrig-build \
sh scripts/package-companion.sh
codesign --verify --deep --strict dist/ConnectionRig.app
```

Full raw logs were kept in /tmp/connectionrig-{unit,integration,build,ios,ios-source,packaging}.log during implementation; these are local artifacts and not committed fixtures.

Final socket-only attempt reused built artifacts:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/connectionrig-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/connectionrig-clang \
swift test --disable-sandbox --disable-xctest --scratch-path /tmp/connectionrig-build \
  --skip-build --filter 'liveTransfer|sdkUnavailable|directionalUpload'
```

Local Markdown link checks, shell syntax checks, and project/plist lint also passed. The final app bundle was repackaged after the last native relay changes and its ad-hoc signature verified again.

## Milestone record

| Milestone | Implemented scope | Validation | Remaining acceptance |
| --- | --- | --- | --- |
| 1: feasibility / slice | Primary-source investigation, explicit IP topology, native TCP relay, synthetic origin, active-transfer and recovery test implementation | Host source compilation; socket attempts blocked | Green unrestricted host traffic test, authorized iPhone result, USB-only feasibility/acceptance |
| 2: protocol / agent | Pairing and signed replies, schemas/version, IDs/retries, apply acknowledgements, capabilities, single session, timed interruption, lease, shutdown, nonpersistent crash behavior | Authentication/dedup/lease/shutdown/failing-engine units pass | Confirm actual socket cancellation/pacing and real process crash behavior on host/device |
| 3: SDK | Async framework-independent API, explicit units, timeouts, cancellation, retry, heartbeat, idempotent close | Scripted transport units and iOS module compilation pass | Real URLSession/control integration and device tests |
| 4: companion | Setup/bind/pairing, applied/requested state, timeline, restore, completed summaries/JSON export, menu bar, independent CLI | Host build and signed bundle verification pass | Authorized GUI launch, interaction/accessibility and visual review, actual live session UI |
| 5: example / tests | Foreground download model, explicit endpoint/config injection, progress, bounded restart, streaming hash; iOS app/project and two framework examples; local fixture/integration tests | Units, source build/test typecheck, fixture syntax/hash pass | Full Xcode bundle build, host integration, on-device permission/recovery/throughput |
| 6: open-source delivery | README, routing/architecture, security, setup, troubleshooting/CI, contribution guide, MIT and notices, BLE plan | Local document/link/plist review; no published artifact | CI execution in unrestricted environment, acceptance records, repository initialization/commits where allowed |

This is a substantial implementation preview with incomplete traffic and physical acceptance, not a verified finished connection-conditioning product. No mocks are used as an automatic runtime fallback.

## Formatting follow-up — 2026-11-16

Reformatted all 14 Swift files, including Package.swift, application, SDK, agent, examples and tests. The checked-in `.swift-format` uses four-space indentation, a 120-character line target, consistent argument wrapping, expanded blocks, and separated declarations. SwiftUI modifier chains are placed on separate lines. Long literals were rewrapped with line continuations, and their values were checked for equivalence.

`sh scripts/format.sh check` passes in strict mode. Reapplying formatting produces identical files; no tabs or trailing whitespace remain. The existing eight host unit tests pass after formatting, and `sh scripts/build-ios-source.sh` succeeds for the iOS SDK, example executable and test-source typechecking. The GitHub Actions workflow now includes the formatting check; remote CI execution is still unverified. Traffic, GUI, physical-device and USB acceptance status above is unchanged.

## Unit and UI test support — 2026-11-16

Added a separate DownloadLabUITests target and scheme linking the same ConnectionRig product used by the hosted XCTest/Swift Testing examples. Its test launches the app and taps Download through XCUIAutomation, synchronizes on numeric accessibility progress, applies a live slowdown, waits for additional progress, interrupts the connection for 3 seconds, and asserts the UI's verified recovery, complete byte count, and increased attempt number. No manual application tap is part of the scenario. Initial device trust, consent and pairing remain setup requirements.

The existing hosted model test already starts its download directly in code; its download model is independent of the manual demo button. Hosted XCTest and Swift Testing now use their own assertion APIs rather than mixing assertions across frameworks.

Validation: strict Swift formatting passes, eight existing host unit tests pass, and independent iOS SDK/app/unit/UI test-source compiler checks pass. Xcode 27 build-for-testing succeeded for both DownloadLab and DownloadLabUITests with CODE_SIGNING_ALLOWED=NO and generic/platform=iOS, using /tmp/connectionrig-ui-xcode. No test or application was installed or launched by those builds. The UI-test runner's generated Info.plist has Apple's automated-testing local-network usage description and the platform runner's ATS configuration; the app and test bundle retain the local-network declarations.

The original DownloadLab scheme remained byte-for-byte unchanged (its local settings were not copied into the new scheme). The project generator now uses xcodeproj >=1.27.0, updates existing projects, preserves signing and schemes, and is idempotent. The new UI target inherited the app's existing local signing team. No secret was added to the new shared scheme.

The user has separately reported the hosted physical iPhone flow working; the agent observed an authenticated active session and installed initial conditions. No final physical XCTest pass or integrity report has been independently recorded here. The new UI test has been built but not executed on a physical device or simulator; that acceptance remains open. USB-only product routing remains unresolved.

Build logs: /tmp/connectionrig-ui-xcode-build.log and /tmp/connectionrig-unit-xcode-build.log. Unit/source-check logs: /tmp/connectionrig-ui-unit.log and /tmp/connectionrig-ui-source-build.log.

### Real TCP host acceptance follow-up

With an approved host-only invocation outside the restricted socket sandbox, the three integration tests were executed. Authentication/timeout/cancellation passed, as did upload pacing. The initial live-transfer assertion failed because a 64 KiB observation window included bytes buffered under the old limit (0.4375 seconds against a >0.5 second bound). The test now drains an additional 128 KiB after the change, then measures 256 KiB with a 2...8 second acceptance window. An unchanged 512 KB/s path would transfer this window in about 0.512 seconds, so the lower bound still detects ineffective conditioning. No relay implementation or limit was relaxed.

The final socket-only run passed all three tests in 12.443 seconds. It exercised an existing TCP stream, a live bandwidth change, real connection interruption, blocked new requests, separate control reachability, unaffected direct origin traffic, restarted download and SHA-256 completion. Log: /tmp/connectionrig-ui-host-integration.log. The initial failed measurement and subsequent correction are recorded here rather than treated as a passing first run.
