# BLE Lab: Phase 0 feasibility test

A throwaway Flutter app with a native Kotlin BLE engine, for answering one question
before building anything else: **can our actual demo phones do GATT server + client,
swap a 5 KB blob, and relay it through a middle hop?**

- `android/app/src/main/kotlin/sg/nushhack/ble_lab/BleLab.kt`: the BLE engine (GATT server and client, beacon, scan, chunked transfer, capability tests)
- `android/.../MainActivity.kt`: method and event channels (`ble_lab/methods`, `ble_lab/events`) plus runtime permissions
- `lib/ble_bridge.dart`: the Dart side of the channels
- `lib/main.dart`: a single test screen

Flutter's BLE packages can't run a GATT server, which is why the BLE code is in Kotlin.
Phase 3 can reuse this engine behind the real transport interface.

## Run

```bash
flutter run -d <device-id>      # repeat on each phone; `flutter devices` lists ids
```

Android 8.0+ (API 26). Grant **Nearby devices** when asked; on Android 11 or lower, grant Location
and turn location services on.

## What each phone does when "Run node" is on

| Piece | Detail |
|---|---|
| GATT server | Service `7e1a0001-…`, one write and write-without-response characteristic `7e1a0002-…` |
| Beacon | Legacy connectable advert with the service UUID; the scan response carries `[nodeId:4][stateHash:4]` |
| Scan | One scan filtered on the service UUID, in low-latency mode |
| Transfer | Connect → request MTU 517 → discover → write `START`, `DATA×n`, `END` frames. The server checks the length and CRC32 on `END`. 3 attempts with backoff |
| Relay | With auto-forward on, a received blob is pushed to every live peer except its origin and sender, and duplicates are dropped by blob ID |

`stateHash` is a digest of the blobs a node holds, so you can see on the peer list when two nodes are **in sync**.
That's the version-vector beacon idea from Phase 3 in its smallest form.

## Test checklist (record the results per phone model)

1. **Capabilities.** Open the app and press the copy button at the top right to save the capability chips and log. Note
   `extendedAdvertising`, `multipleAdvertisement` and `maxAdvDataLength`.
2. **Ext adv test.** Does a non-legacy advertising set with about 200 bytes start?
3. **Multi adv test.** With the node running, how many *extra* advertisers start alongside the beacon?
4. **Pairwise 5 KB.** Phones A and B, node running on both. Tap **Send 5K** on A. Record MTU, setup time and transfer time.
   Repeat with *write without response* and with 20 KB and 100 KB.
5. **Connect-all.** With 3 or more phones, tap **Connect-all test**. How many simultaneous outbound links hold
   while still serving inbound ones?
6. **Middle hop.** Put A and C out of range of each other (check that neither shows the other in Peers) with B between them.
   Auto-forward on for all three. Send from A and check that C logs `rx blob … origin <A> via <B>`.
7. **Role swap.** Repeat step 6 with a different phone as B. Some chipsets handle server and client at the same time worse than others.

**Fallback rule:** if a phone can't advertise, can't host a GATT server, or step 6 fails on it,
plan to use Nearby Connections for that device behind the same transport interface.

## Known limits (fine for Phase 0)

- Foreground only: there's no foreground service yet (that's Phase 3), and the screen is kept on.
- No security: frames are unsigned and unencrypted. Phases 1 and 2 add signed events and the handshake.
- The advertised MAC rotates, so `nodeId` from the scan response is the stable identity.
