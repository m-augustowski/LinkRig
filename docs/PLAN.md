# ConnectionRig implementation plan

Repository assessment: empty workspace, no AGENTS.md, source, dependencies, or existing license. No unrelated application touched. Git initialization denied by workspace permissions; milestones will be recorded here instead of committed.

1. Feasibility and vertical slice: primary-source evidence, controlled TCP relay, synthetic HTTP server, live throttling and interruption tests.
2. Agent/protocol: HMAC pairing, versioning, deduplication, sessions, leases, restoration, bounded reports.
3. SDK: framework-independent async API, timeouts, cancellation, capability errors, heartbeat and close.
4. Companion: SwiftUI setup, applied state and timeline, completed report export; headless agent.
5. Example: iOS download with explicit restart recovery and integrity verification; XCTest and Swift Testing; reproducible unsigned build.
6. Delivery: routing, security, device acceptance, CI, license, BLE roadmap and validation ledger.

Engine decision: evaluated Toxiproxy (MIT), which provides TCP toxics and per-connection decimal KB/s. No binary was acquired. The user explicitly ruled out using Toxiproxy; implement a deliberately small public-Network-framework TCP relay with explicit, narrower semantics: per-direction, per-connection pacing; per-chunk delivery delay; TCP cancellation and rejection while blocked. This is real byte-stream manipulation, not radio or packet conditioning. Native Swift is the sole execution engine. Toxiproxy integration is not shipped or claimed tested.

USB acceptance is unresolved. The implemented control and data path uses explicitly configured IP networking. USB for Xcode deployment does not imply IP routing through this relay.

Implementation and validation records for every milestone are in [VALIDATION.md](VALIDATION.md). All locally available compiler/unit/packaging checks are complete; traffic, full Xcode project, GUI and physical acceptance gaps remain explicitly open there.
