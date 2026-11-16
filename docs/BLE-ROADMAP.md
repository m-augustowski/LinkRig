# Next milestone: one programmable BLE accessory

After the TCP host and physical acceptance gates, add support for a **Nordic nRF52840 DK (PCA10056)** running a version-pinned Zephyr application. Zephyr documents the [board](https://docs.zephyrproject.org/latest/boards/nordic/nrf52840dk/doc/index.html), a [GATT peripheral sample](https://docs.zephyrproject.org/latest/samples/bluetooth/peripheral/README.html), and [connection management including bt_conn_disconnect](https://docs.zephyrproject.org/apidoc/latest/group__bt__conn.html). This is a planned supported test accessory, not implemented functionality.

Implement a fixed vendor GATT service with a sequence-numbered transfer characteristic, notifications, and a profile/version characteristic. Flash a known profile through the board's supported programming interface. A dedicated Mac serial driver will speak a small versioned, acknowledged command protocol over the board's USB CDC interface; this is the board's supported serial interface, not an arbitrary iPhone USB transport. Keep that driver separate from the TCP engine, reuse command IDs and timeline event values only where they fit, and add a BLE capability only after board-level tests exist.

Operations and confirmations:

1. Read firmware/profile identity and verify the known GATT profile before testing.
2. Start sequence-numbered application notifications; confirm actual sent sequence numbers.
3. Pause application data while preserving the BLE connection; demonstrate stalled transfer separately from disconnection.
4. Request `bt_conn_disconnect` for the test phone's connection and wait for the firmware's disconnected callback. Stopping advertising alone is insufficient.
5. Resume advertising and application availability; permit a new connection, then record the connected/subscribed callbacks alongside iPhone test helper events.
6. Use a board-owned watchdog to restore test availability after control loss, and correlate monotonic board events with Mac timeline timestamps.

Acceptance: one supported firmware/board/phone combination; explicit transfer progress synchronization; confirmed intentional disconnect; rejected/unavailable reconnect window; successful reconnection and ordered payload integrity; Mac-command loss recovery; no claims based only on command issuance.

No universal peripheral emulation, arbitrary RSSI control, accurate interference, control of unrelated iPhone connections, or equivalence between an intentional disconnect and a supervision timeout. Pausing notifications tests application behavior, not RF loss. A supervision-timeout experiment would require separate firmware behavior and measurement. No BLE code or fabricated capability implementation ships in the network preview.
