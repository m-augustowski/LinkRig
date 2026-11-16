# Third-party notices

No third-party runtime source or binaries are linked, vendored, downloaded at startup, or redistributed. The Swift package has no external package dependencies. Foundation, Network, CryptoKit, SwiftUI, Observation and the Swift runtime are platform/toolchain components subject to their respective upstream distribution terms.

The development-only optional project generator uses the separately installed Ruby `xcodeproj` gem version 1.27.0 or later (MIT). The generated project is checked in; consumers do not need the gem. Python's standard library is used for the synthetic fixture server. Neither a Python runtime nor the gem is bundled by the companion packaging script. GitHub Actions checkout runs in CI only.

Evaluated but **not used**: Shopify Toxiproxy (MIT), and libusbmuxd (LGPL-2.1 library, GPL-2.0 iproxy/inetcat utilities). No source code was copied from those projects; no obligations from their redistribution arise in this tree. Toxiproxy is explicitly excluded at the user's request. Research links are in [feasibility](docs/FEASIBILITY.md).

The BLE roadmap's Zephyr/Nordic software and board tools are not included. Any future firmware distribution must separately inventory its licenses and notices.

This new, previously empty workspace uses the permissive MIT license for ConnectionRig source. Contributors retain ownership of their contributions and grant the rights in LICENSE; no ownership transfer is asserted.
