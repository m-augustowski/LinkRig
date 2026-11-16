# Physical iPhone setup and acceptance

These are instructions, **not recorded device results**. Do not execute device tests, launch the app, or change device settings as part of unattended setup without the operator's explicit authorization.

## Preparation

1. On a Mac with Xcode and Swift 6, run `sh scripts/check.sh` outside a sandbox that denies TCP listeners. Require a green host integration suite first.
2. Connect a physical iPhone by USB for Xcode deployment/debugging, trust the Mac if prompted, and configure Developer Mode/signing through Xcode. The cable establishes no product control/data tunnel.
3. Join the iPhone and Mac to the same trusted test LAN, without client isolation. Record the Mac's actual LAN IP, for example `192.168.1.20`. This is the implemented alternative to unresolved USB-only operation. Do not use `127.0.0.1` on the phone to mean the Mac.
4. Run `python3 scripts/fixture-server.py` on the Mac. It serves exactly 8 MiB of bytes `i % 251` at loopback `/file`. Expected SHA-256: `bdf23837181f5808331800c1ae2b4f7d7a839536b10d58491471c50dde23833a`.
5. Build the companion using `sh scripts/package-companion.sh`, then launch it yourself. Setup: Listen IP = Mac LAN IP; upstream = `127.0.0.1`, upstream port = `8080`. Start and permit local network/firewall access as needed. Alternatively use the headless command in the README. Run only one agent instance on these ports.
6. Copy the pairing secret. Do not paste it into a checked-in file, launch argument, URL, screenshot, or issue report.

## Configure Xcode

Open `Examples/DownloadLab/DownloadLab.xcodeproj`, choose the DownloadLab scheme and a physical iPhone, set your own development team and a unique bundle identifier as needed. Link ConnectionRig to a new project's test target if adapting the example.

Set these **local, unshared** test scheme environment variables:

| Variable | Example / value |
| --- | --- |
| `RIG_CONTROL_URL` | `http://192.168.1.20:49170` |
| `RIG_DOWNLOAD_URL` | `http://192.168.1.20:49171/file` |
| `RIG_PAIRING_SECRET` | Current secret copied from the Mac |

Do not put the control URL on the relay port. The application's own download endpoint must use the relay port. This injects networking configuration explicitly, not a URLSession mock. App and test-host Info.plists include local-network usage and local ATS intent. If testing another app, declare these in its test configuration too. First-run local network permission may require allowing the app and rerunning; consult [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy). No Bonjour discovery is used.

Run **one** of `DeviceXCTests/testRecovery` or `DeviceSwiftTests/recovery` at a time; the agent explicitly allows only one active session. The test helper executes a real foreground download in the hosted application process. It is not an XCUITest of taps, nor proof that all third-party app networking is intercepted. The standalone UI uses the same DownloadModel and also accepts a manually entered relay URL. The hosted model test starts its own download in code; it does not require tapping the visible app button.

## Acceptance record

Record date, device model/iOS, Mac/macOS/Xcode, control/data IP topology, SDK revision, and the following observations. Never include the pairing secret or application payloads in the report.

- Download is routed through the relay, initially 1000 decimal KB/s. At measured 50% progress, a live command sets 100 KB/s on the existing stream. The sample immediately interrupts afterwards; for an independent on-device throughput acceptance, insert a progress-window measurement between set and interrupt, as in the host integration test. A command timeline alone is not throughput evidence.
- A 3-second interrupt closes that TCP stream. Capture the attempt counter rising and the application entering retry state; do not interpret this as Wi-Fi disassociation.
- Inspect commands remain reachable during the interruption. In a second app helper request with a short timeout, verify new relay requests fail while blocked, while the fixture is still reachable directly on the Mac.
- Agent timer restores unpaced forwarding; SDK cleanup is not required for the timer. The retry completes with the exact expected length and SHA-256. Record attempt count and session JSON export.
- Repeat with test runner termination after setting a limit: after the last heartbeat +15 seconds (plus scheduling tolerance), the companion shows lease closure and normal forwarding.
- Terminate the agent while forwarding: sockets close, no global settings remain modified, but the routed endpoint is unavailable. Restart with a new secret and confirm a new download works. This requires restart; agent crash does not magically keep the relay available.
- Stop/close a session twice; ensure cleanup is idempotent. Check unrelated direct traffic is unaffected.

**USB-only acceptance remains a separate unresolved milestone.** Repeat none of the above over USB and call it verified unless actual control and data routing over that interface is established and recorded. A successful Wi-Fi run with a USB debugging cable is still the IP/LAN path.

## Fully automated UI-test scenario

Choose the **DownloadLabUITests** scheme and configure the same three test-runner environment variables listed above in its Test action. The existing DownloadLab scheme and any local values are preserved; the new shared scheme intentionally contains no pairing secret. Run only `DownloadFlowUITests/testDownloadRecoversAfterSlowdownAndInterruption`. Unit and UI scenarios use the agent's single session exclusively; run them separately.

The UI test launches the application, injects only `RIG_DOWNLOAD_URL` into its launch environment, and taps the Download button using XCUIAutomation. The pairing secret and control URL remain in the test runner. It waits for the app's numeric accessibility progress to reach 2 MiB, changes the live limit from 512 to 64 decimal KB/s, observes another 128 KiB, checks that the first attempt is still active, then interrupts for 3 seconds. Finally it waits for the UI's Verified state and asserts the full length and a retry attempt. The app sets Verified only after the SHA-256 check succeeds. All scenario taps are executed by the test; do not tap Download yourself.

Initial device trust, developer provisioning, pairing, and OS local-network consent are setup requirements. The UI-test runner is a separate process/bundle from the hosted unit-test app and may need its own initial consent. The sample does not silently grant arbitrary OS permissions or claim that first-run system dialogs are automated. Once setup is complete, the scenario requires no manual taps. Physical execution of this new UI scenario remains to be validated separately from the hosted test.

For another application, give the test access to a genuine application event (for example, a cart request starting or a transfer-progress element), then call `setNetwork` or `interrupt` from the test at that event. The SDK does not decide application events or perform UI taps itself. Pure unit tests that mock HTTP responses do not produce real relay traffic; use the real networking implementation when asserting actual connection degradation.
