# HeartRate local room protocol

**Version:** 1 (`v: 1`)  
**Transport:** one WebSocket per member to one Relay, `/ws?room=XXXXXX`.  
**Status:** `ws://` is cleartext and development-only. The client accepts
`wss://` (default port 443) using the platform's standard TLS certificate
validation; no custom pinning or bypass is implemented, so self-signed
certificates are not supported by default. Join-token authentication remains a
production prerequisite. Short codes are discovery IDs, not credentials. No
payload, token, pairing key, or secret may be logged.

## Envelope

Every text frame is JSON: `{ "v": 1, "type": "...", ...fields }`. Unknown
versions/types are rejected. Maximum room size is 20 members.

## Client → Relay

- `hello`: `memberId` (opaque ID), `displayName` (maximum 32 characters).
  Since 0.4.0 the client derives `memberId` from a **persisted install id** (UUID v4,
  created on first launch), so relaunching the app rejoins the same member instead of
  creating a new one. It identifies an **install**, not a person: reinstalling or
  clearing app data yields a new member, and two phones are always two members.
  Cross-device identity would require an account system and is out of scope.
  The server keys member state by `memberId`, so v1 is unchanged: old clients keep
  sending random IDs and behave exactly as before.
- `heartRate`: `memberId`, `displayName`, `bpm` integer, `rrMs` integer array,
  `sensorContact` true/false/null, `sequence` positive monotonically increasing
  integer, `measuredAt` UTC ISO-8601.
- `ping`: optional `displayName`; Relay answers `pong`. When present and the
  sender already exists in the room, a Relay may update that member's display
  name and broadcast a normal `memberDelta`. Relays that do not implement this
  optional field ignore it; no new message type is introduced and `v` stays 1.

`sequence` prevents stale packets from replacing newer state. HRS contact null
means the strap does not support contact detection; false means no contact.
RR values are converted from 1/1024-second units to rounded milliseconds.

## Relay → clients

- `welcome`: connection accepted by this development relay.
- `snapshot`: `members` array; sent every 1 second.
- `memberDelta`: `member` object; sent on new/changed samples and online changes.
- `pong`: heartbeat response.
- `error`: `code`, currently `BAD_MESSAGE` or connection-level rejection.

Member object = heartRate fields plus `lastSeen` UTC ISO-8601 and `online` bool.

## Thresholds and flow

- Client heart-rate report: at most 1 Hz, only when a new sample exists.
- WebSocket application ping: every 3 seconds.
- Member online → offline after 5 seconds without an accepted report.
- Member removed after 2 minutes without an accepted report.
- Relay sends full snapshots every 1 second and deltas after accepted reports.
- Maximum members: 20. Further members get `ROOM_FULL` internally; production
  must expose a stable protocol error code before closing.

## Discovery and fallback

Preferred discovery is mDNS/Bonjour `_heartrate._tcp`; the short code maps to a
Relay address. This skeleton contains an explicit unimplemented discovery
boundary, not fake results. Manual input accepts a domain or IP with optional
port, plus `ws://` or `wss://`. Missing port defaults to 8765 for `ws` and 443
for `wss`.

UDP multicast is not on the data path. mDNS failure does not affect manual join.
A Relay restart creates a new room epoch in production; sequence/epoch semantics
remain a pre-production task to prevent stale clients joining the wrong room.
