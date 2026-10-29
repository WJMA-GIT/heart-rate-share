# HeartRate local room protocol

**Version:** 1 (`v: 1`)  
**Transport:** one WebSocket per member to one Relay, `/ws?room=XXXXXX`.  
**Status:** development `ws://` only. WSS, certificate validation, and join-token
authentication are mandatory before production. Short codes are discovery IDs,
not credentials. No payload, token, pairing key, or secret may be logged.

## Envelope

Every text frame is JSON: `{ "v": 1, "type": "...", ...fields }`. Unknown
versions/types are rejected. Maximum room size is 20 members.

## Client → Relay

- `hello`: `memberId` (random opaque ID), `displayName` (maximum 32 characters).
- `heartRate`: `memberId`, `displayName`, `bpm` integer, `rrMs` integer array,
  `sensorContact` true/false/null, `sequence` positive monotonically increasing
  integer, `measuredAt` UTC ISO-8601.
- `ping`: no fields; Relay answers `pong`.

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
boundary, not fake results. Manual `host:port`, `ws://host:port`, or
`wss://host:port` is always available. Default port: 8765.

UDP multicast is not on the data path. mDNS failure does not affect manual join.
A Relay restart creates a new room epoch in production; sequence/epoch semantics
remain a pre-production task to prevent stale clients joining the wrong room.
