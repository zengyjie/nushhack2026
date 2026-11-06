# MESH: field hospital app (MVP)

An Android app for field hospital operators. It shows three of the four selling points from the ideation deck:

| | What it does here |
|---|---|
| **OFF** | Every action is a signed event stored in SQLite on the phone, so the app works with no network. |
| **LC** | Events spread over a Bluetooth LE mesh using the engine from `ble_lab/`, hopping from phone to phone. |
| **ON** | A phone with **Uplink** switched on forwards the cluster's events to a *mock* HQ store and floods back an HQ-signed acknowledgement. |
| **SEC** | Ed25519 signatures, HQ-signed certificates, per-device hash chains and role checks, all verified offline. |

There's no real certificate authority and no cloud backend. Both are simulated, as described below.

## Roles

| Role | Can sign |
|---|---|
| Triage | Register a patient, change priority, add clinical observations |
| Diagnosis & treatment | Diagnosis, remediation performed, recommended follow-up |
| Admin | Announcements, messages to everyone, a role or a person (read-only on clinical records) |

A person can hold more than one role. Their certificate lists every role they hold, and they can sign anything any of those roles allows. Every phone checks the roles again when an event arrives. An event whose author doesn't hold a role that allows it is rejected and not forwarded.

## Simplified auth (no CA)

- A demo HQ Ed25519 key is compiled in (`lib/core/crypto.dart`). Its public key is the trust root.
- At enrolment the phone generates its own key and stores the seed in `flutter_secure_storage`, which is encrypted with an Android Keystore key and unlocked with a PIN. The phone then issues itself a certificate `{uid, name, roles, dev, pk, iat, exp}` signed with the demo HQ key. `roles` lists one or more roles. This stands in for HQ or a delegate. **In production only HQ would hold that seed.**
- Each event carries `uid, dev, seq, prev, ts, type, data`. Its `id` is the SHA-256 of the canonical JSON, and the author signs the same bytes.
- On receipt (`lib/core/ledger.dart`), a phone checks:
  1. the hash,
  2. the HQ signature on the certificate, and that it was valid when the event was signed,
  3. the author's signature,
  4. the role permission,
  5. the hash chain and sequence for that device.

  Events that arrive before their predecessor wait until it arrives.

## Mesh (LC)

- `android/.../BleEngine.kt` is `ble_lab`'s `BleLab.kt`, with the capability tests removed and the node ID set to the signed device ID.
- New events are flooded with `ble_lab`'s forwarding: dedupe by blob ID, then push to every live peer except the origin and the sender. Unlike `ble_lab`, events are only forwarded after they pass verification.
- Catch-up: each beacon advertises a hash of the events that phone holds. When a neighbour's hash differs, the phone pushes it a bundle of its events every 12 s until the two match. This lets a phone that was out of range catch up.

## Run

Use Android 8.0 or later (API 26) and 2 or more phones.

```bash
flutter run -d <device-id>
```

Grant **Nearby devices** when asked. The screen stays on because there's no foreground service yet.

1. Enrol each phone with one or more roles.
2. On the triage phone, register a patient and add an observation. It appears on the other phones within a few seconds.
3. On the diagnosis & treatment phone, record a diagnosis, remediation and follow-up.
4. On the admin phone, post an announcement.
5. On any one phone, open Mesh and switch on **Uplink to HQ**. Every phone then shows records as synced to HQ.

## Known limits

- The HQ private key ships in the app (demo only), and the mock HQ is a local SQLite file on the uplink phone.
- Catch-up sends every event held, which is fine at field-cluster scale but not optimised.
- Messages are flooded to every phone and only filtered on display. They aren't encrypted to the recipient.
- Revocation and the peer challenge-response handshake are not implemented yet.
- Raleway is fetched by `google_fonts` the first time the app has internet. Without it the app uses the default font.
