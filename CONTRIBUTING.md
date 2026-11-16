# Contributing

ConnectionRig is an implementation preview with explicit acceptance gaps. Read docs/VALIDATION.md and docs/FEASIBILITY.md first. Keep claims aligned with executed evidence.

Use Swift 6, macOS 14+, Xcode 16+ and an isolated test network. Run `sh scripts/check.sh` for unit plus host TCP tests, then an unsigned `xcodebuild build-for-testing` as documented below. The fixture uses synthetic data only; tests never need external servers. Unit-only mode does not validate throughput or interruption. Do not run simulators, GUI apps, or physical-device tests as part of an unattended change unless explicitly authorized by the operator.

Prefer small patches with a concrete trigger, final behavior, relevant tests and remaining limitations. Preserve unrelated changes. Do not add global network changes, implicit engine fallbacks, private Apple APIs, SDK dependencies on test frameworks, or app-owned singletons. Network engine and transport injection should reflect real interchangeable boundaries, not speculative scenario frameworks.

Tests changing conditions at transfer points must synchronize on measured progress. Use reasonable timing tolerance but require a lower bound that detects absent pacing. On failure, cancel transfer tasks, close sessions, stop listeners, and preserve a token-free diagnostic report. Public APIs use decimal KB/s and explicit delay semantics. Acknowledgements must follow actual engine application. Add a new capability before adding a new execution mode.

Report validation separately: units, host TCP integration, iOS compiler checks, Xcode bundle build, physical iPhone, and USB. Never turn a sandbox failure into a passing integration test or an absent environment into a passing device test. Actual device records require operator authorization and the topology used.

The Xcode project is checked in. To regenerate after project structure changes, install the development-only `xcodeproj` Ruby gem version 1.27.0 or later and run `ruby scripts/generate-example.rb`; inspect the generated diff. No generator is needed to consume the SDK.

Source contributions are offered under the project's MIT license. Never submit pairing secrets, personal endpoints, signing material, device payloads, or generated local schemes containing credentials. No release, binary upload, or publication is part of normal validation.

## Swift source style

Use the Swift toolchain's `swift-format` with the checked-in `.swift-format` configuration. Run `sh scripts/format.sh fix` to format all package, application, example, and test sources; run `sh scripts/format.sh check` to check them without modifying files. CI runs the same check.

Use four spaces, no tabs, one statement per line, and a 120-character line-length target. Expand function and control-flow bodies onto separate lines. Separate methods, initializers, computed properties, and types with one blank line; keep related stored properties together. Put each enum case on its own line. Wrap long argument lists vertically, and keep SwiftUI view hierarchies and modifier chains readable. Preserve string contents and public API behavior during formatting-only changes. Swift's [API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) guide naming and clarity; the project configuration specifies whitespace and layout.

The project generator updates existing targets and adds missing test targets without replacing existing shared schemes, local environment values, bundle identifiers or signing teams. UI tests have a separate DownloadLabUITests scheme to avoid concurrent sessions. Keep UI actions and application event detection in the UI tests; the public SDK stays independent of XCTest/XCUIAutomation and Swift Testing.
