# Second Screen protocol (v1)

File Foundry (Mac host) creates a virtual display, captures it, encodes it with
VideoToolbox and streams it to the File Foundry Screen Android app (client), which
decodes with MediaCodec and sends touch input back.

## Transport

- One TCP connection, port **47321**, `TCP_NODELAY` on both sides.
- **USB:** the host runs `adb reverse tcp:47321 tcp:47321` for each authorised device
  (`adb devices`), the client connects to `127.0.0.1:47321`.
- **Wi-Fi:** the host advertises Bonjour `_ffscreen._tcp` (TXT: `v=1`, `name=<Mac name>`);
  the client discovers it with Android NSD, or the user types `host:port`.
- The host accepts one client at a time. A second connection is refused with `BYE`.

## Framing

Every message: `u32 length (big-endian, of what follows)` · `u8 type` · `payload`.
Maximum length 8 MiB; anything larger closes the connection.

After authentication every payload is encrypted (see Security); `length` and `type`
stay in clear.

| Type | Name | Dir | Payload |
| --- | --- | --- | --- |
| 0x01 | HELLO | C→H | UTF-8 JSON `{"v":1,"deviceId":"<uuid>","name":"Pixel Tablet","width":2560,"height":1600,"densityDpi":276,"codecs":["hevc","avc"],"maxFps":120,"clientNonce":"<base64 32B>"}` |
| 0x02 | CHALLENGE | H→C | JSON `{"hostNonce":"<base64 32B>","mode":"pair"\|"known"}` |
| 0x03 | AUTH | C→H | JSON `{"proof":"<base64 HMAC>"}` |
| 0x04 | WELCOME | H→C | encrypted JSON `{"deviceKey":"<base64 32B>"}` (only after `pair`), else `{}` |
| 0x05 | CONFIG | H→C | encrypted JSON `{"codec":"hevc","width":2560,"height":1600,"fps":60,"bitrate":40000000}` |
| 0x06 | VIDEO | H→C | encrypted: `u64 ptsMicros` · `u8 flags` (bit0 keyframe, bit1 codec-config) · Annex-B bytes |
| 0x07 | INPUT | C→H | encrypted: `u8 kind` (0 down, 1 move, 2 up, 3 scroll, 4 right-click, 5 cancel) · `u8 pointerId` · `f32 x` · `f32 y` (0…1 of the stream) · `f32 dx` · `f32 dy` (scroll, points) — all big-endian |
| 0x08 | KEYFRAME_REQ | C→H | encrypted, empty |
| 0x09 | PING | both | encrypted `u64 sentMicros` |
| 0x0A | PONG | both | encrypted `u64 echoedMicros` |
| 0x0B | STATS | C→H | encrypted JSON `{"decodedFps":59.8,"dropped":0,"latencyMs":18}` |
| 0x0F | BYE | both | UTF-8 reason (clear before auth, encrypted after) |

The first VIDEO after CONFIG is a keyframe with the codec-config flag (VPS/SPS/PPS in Annex-B).
The client requests a keyframe after any decode error or resume.

## Security

- Nothing is accepted before AUTH succeeds; unauthenticated peers get `BYE` within 5 s.
- **Pairing (first time, or Wi-Fi without a stored key):** the host shows an 8-character code
  from the alphabet `23456789ABCDEFGHJKMNPQRSTUVWXYZ` (≈40 bits), valid for 2 minutes,
  max 5 attempts, then a new code. `secret = UTF-8(code)`.
- **Known device:** the host stored `deviceKey` (32 random bytes) for `deviceId` in the Keychain;
  the client stored it in Android Keystore-backed EncryptedSharedPreferences. `secret = deviceKey`.
- USB connections still authenticate. The host may auto-approve pairing over USB only after the user
  clicks "Allow" on a prompt that names the device.
- `prk = HKDF-SHA256(ikm: secret, salt: clientNonce ‖ hostNonce, info: "ffscreen v1")`
  → 96 bytes: `authKey(32) ‖ h2cKey(32) ‖ c2hKey(32)`.
- `proof = HMAC-SHA256(authKey, "auth" ‖ deviceId ‖ clientNonce ‖ hostNonce)`, compared in constant time.
- Encrypted payload = `AES-256-GCM(key, nonce = 4 zero bytes ‖ u64 counter, plaintext)` →
  `ciphertext ‖ tag(16)`. Each direction keeps its own counter starting at 0; a counter that does
  not increase by exactly 1 closes the connection. Keys never repeat across sessions because nonces do not.
- The host never opens files, runs commands or accepts anything beyond INPUT events from the client.
  INPUT is clamped to the virtual display bounds.

## Host behaviour

- Virtual display via `CGVirtualDisplay` (private API, bridged in a C module) sized to the client's
  aspect ratio, HiDPI when the client density allows; removed on disconnect.
- Capture with ScreenCaptureKit (`SCStream`, the virtual display only, BGRA or 420v, `queueDepth 3`,
  `minimumFrameInterval` = 1/fps), encode with `VTCompressionSession`: real-time, no B-frames,
  `MaxKeyFrameInterval` 2 s, HEVC Main if the client supports it else H.264 High, data-rate limits.
- Back-pressure: if the socket send queue holds more than ~3 frames, drop non-key frames.
- Input: `CGEvent` mouse moved/down/up/dragged and scroll wheel at the virtual display's global
  coordinates. Needs Accessibility permission; the UI explains and links to it.

## Client behaviour

- Fullscreen immersive `SurfaceView`, `MediaCodec` low-latency (`KEY_LOW_LATENCY`), render on release.
- Single-finger tap = click, drag = drag, two-finger drag = scroll, long-press = right-click.
- Reconnects automatically while the host is visible; screen stays on while streaming.

## Clarifications (v1)

1. The pairing secret is the 8 code characters without any separator (the UI may show `ABCD-EFGH`).
2. AES-GCM counters start at 0 in each direction and count every encrypted message of any type:
   WELCOME is host→client 0, CONFIG is host→client 1; the client's first encrypted message is client→host 0.
3. HELLO, CHALLENGE and AUTH are sent in clear and consume no counter. A failed AUTH gets a clear BYE.
4. A keyframe VIDEO carries VPS/SPS/PPS and the IDR together in one Annex-B payload, flags `0b11`.
   The client feeds every VIDEO payload as an ordinary sample.
5. Scroll `dx`/`dy` are finger deltas in dp (≈ points); the host applies them so content follows the finger.
   `pointerId` is 0; `x`/`y` are 0 for scroll. Long-press sends kind 4 only. CANCEL releases any held button.
6. PONG echoes the received `u64` verbatim. Both sides send PING every second and answer PINGs.
   The host sends a PING at least every second even when no video flows; the client closes after 8 s of silence.
7. BYE is encrypted once WELCOME has been sent. Unknown message types are ignored.

## Clarifications (agreed host/client)

- `length` counts the type byte plus the payload (`length = 1 + payload.size`).
- The pairing secret is the 8 code characters without any dash (the UI shows `ABCD-EFGH`).
- Nonces in HKDF salt and HMAC input are the raw 32 bytes, not their base64 text.
- GCM nonce counter is a big-endian u64; no AAD. The counter is implicit (not transmitted) and is
  shared by all encrypted messages of one direction: WELCOME is h2c 0, CONFIG h2c 1, and so on.
  HELLO, CHALLENGE and AUTH are clear and consume no counter. Auth failure gives a clear BYE;
  BYE after WELCOME is encrypted. Unknown types are ignored.
- A keyframe VIDEO message carries VPS/SPS/PPS and the IDR slice together in one Annex-B buffer
  (flags bit0 | bit1); the client feeds every VIDEO as a normal sample.
- INPUT scroll `dx`/`dy` are finger deltas (points); the host applies them as content-follows-finger.
  `pointerId` is 0, `x`/`y` are 0 on scroll; kind 4 (right-click) arrives without a preceding down.
- PONG echoes the PING `u64` verbatim. Both sides PING at least every 1 s; the host pings even when
  no video flows, and the client closes after 8 s without any frame.

## Test vector

```
secret       = UTF-8("ABCD2345")                       (pairing code, no dash)
deviceId     = "00000000-0000-4000-8000-000000000001"  (UTF-8 in the HMAC input)
clientNonce  = bytes 00 01 02 ... 1f                    (32 bytes)
hostNonce    = bytes 20 21 22 ... 3f                    (32 bytes)
salt         = clientNonce || hostNonce (64 bytes), info = UTF-8("ffscreen v1")

authKey = 1e86ac6c3e2d47cd46f9cc3b3daa3a0610e4f5054d637e4679487937abf2ab45
h2cKey  = 67ed13d600a187dc47a5f0cb7d7871e42318a60e55766ab61891a6f4ee326aba
c2hKey  = 3ce1749534e0b212e3979c8cea6d568e47dcb685b057610bee0bbd6e26bef419
proof   = 15af705c4ef63f3f28d2987b7ab7d2c375b0912ceee38822c3c687c084f17cd7
          (HMAC-SHA256(authKey, "auth" || deviceId || clientNonce || hostNonce))

AES-256-GCM with h2cKey, plaintext UTF-8("hello"), output = ciphertext || tag(16):
  counter 0 (nonce 000000000000000000000000): 2db00061e59f50b2f691aaf1ad68fbaca2c7446c08
  counter 1 (nonce 000000000000000000000001): 34481b716daab2b5c44b4b12b04e89572aca456b22
```

(HKDF output was cross-checked against an independent Python implementation.)

## Version 2 (supersedes the Security section and the test vector above)

v1 let anyone who saw one pairing handshake brute-force the 8-character code offline (≈40 bits)
and then decrypt WELCOME to steal the long-term `deviceKey`. v2 fixes that. Hosts and clients speak
only v2; a HELLO with `"v" != 2` gets a clear `BYE "version"`.

**Handshake**

- HELLO adds `"v":2` and `"clientPub":"<base64 32B X25519 public key>"` (fresh per connection).
- CHALLENGE becomes `{"v":2,"hostNonce":"<b64 32B>","hostPub":"<b64 32B X25519>","hostId":"<uuid>","hostName":"<≤64 B>","mode":"pair"|"known"}`.
  `hostId` is a random UUID the Mac creates once and keeps (Keychain); the client stores keys per `hostId`, never per address.
- `shared = X25519(ownPrivate, peerPublic)` (32 raw bytes). Reject an all-zero shared secret.
- `secret` is the 12-character pairing code without separators (mode `pair`) or the 32-byte `deviceKey` (mode `known`).
- `okm = HKDF-SHA256(ikm: shared ‖ secret, salt: clientNonce ‖ hostNonce ‖ clientPub ‖ hostPub, info: "ffscreen v2", 96)`
  → `authKey ‖ h2cKey ‖ c2hKey` (32 bytes each).
- `proof = HMAC-SHA256(authKey, "auth" ‖ deviceId ‖ clientNonce ‖ hostNonce ‖ clientPub ‖ hostPub)`.
- The client treats a WELCOME that fails to decrypt as a failed authentication of the host (it proves the host knew the secret).

**Pairing code:** 12 characters from `23456789ABCDEFGHJKMNPQRSTUVWXYZ` (≈59 bits), shown as `XXXX-XXXX-XXXX`,
single use, valid 2 minutes. Wrong proofs: 5 per code, then a new code, and the host adds 2 s, 4 s, 8 s… (cap 60 s)
delay before answering further pairing attempts. The code is checked against the live code at AUTH time.
Random bytes come from `SecRandomCopyBytes`/`SecureRandom`; a failure aborts the session.

**Encryption:** AES-256-GCM as before (implicit big-endian counters per direction, starting at 0 with WELCOME / the
client's first encrypted message), plus **AAD = the 1-byte message type**. After WELCOME every frame must decrypt;
a clear BYE is then ignored.

**Limits:** before AUTH succeeds a frame may be at most 4 KiB. HELLO: `name` ≤ 64 UTF-8 bytes (longer is truncated),
`codecs` ≤ 8 entries from `hevc`/`avc`, `maxFps` 1…240, `width`/`height` 320…8192, `densityDpi` 72…1000; anything
else gets `BYE "hello"`. After AUTH the 8 MiB limit applies.

**Sessions:** the host accepts up to 4 connections in the handshake at once (max 2 per remote address) with a 5 s
deadline each; only one may stream. If one is streaming, a newly authenticated client gets encrypted `BYE "busy"` and
retries every 2 s. The host ends a session after 8 s without any inbound frame (the client pings every second).
The client never deletes a stored key because of a host message; it asks for a code and replaces the key only after
a successful new pairing.

### Test vector (v2)

Asserted by `MediaOrganizerTests/SecondScreenProtocolTests.swift` (`testFixedVectorV2`, `testSealVectorAndCounters`);
X25519, HKDF and HMAC were cross-checked against an independent pure-Python computation (RFC 7748 ladder, `hmac`/`hashlib`).

```
clientPriv   = 32 bytes of 0x01
hostPriv     = 32 bytes of 0x02
secret       = UTF-8("ABCD2345EFGH")                    (pairing code, no dashes)
deviceId     = "00000000-0000-4000-8000-000000000001"  (UTF-8 in the HMAC input)
clientNonce  = bytes 00 01 02 ... 1f                    (32 bytes)
hostNonce    = bytes 20 21 22 ... 3f                    (32 bytes)
ikm          = shared || secret
salt         = clientNonce || hostNonce || clientPub || hostPub (128 bytes), info = UTF-8("ffscreen v2")

clientPub = a4e09292b651c278b9772c569f5fa9bb13d906b46ab68c9df9dc2b4409f8a209
hostPub   = ce8d3ad1ccb633ec7b70c17814a5c76ecd029685050d344745ba05870e587d59
shared    = 2ed76ab549b1e73c031eb49c9448f0798aea81b698279a0c3dc3e49fbfc4b953
authKey   = 703ec539264404eaf80ed3b2c5b009a012e7ea336e79fdb7806e11606f5cb93c
h2cKey    = 822c5aa09d804fc6305cd53f97219d3acc6f78da2e2bbbd899cd58d834fa4a7d
c2hKey    = 425aefb1080c777a1f470049655664636ac3cb726112904f6688327c9fd05f1e
proof     = 66c5310a6cbef2a3b3506d5596ea229d0e0f5241e56fa3832401bf959c497b7c
            (HMAC-SHA256(authKey, "auth" || deviceId || clientNonce || hostNonce || clientPub || hostPub))

AES-256-GCM with h2cKey, AAD = 0x05, plaintext UTF-8("hello"), output = ciphertext || tag(16):
  counter 0 (nonce 000000000000000000000000): 9c7473a61b41ab14fc5a770634f2124c7b48a1a5b1
  counter 1 (nonce 000000000000000000000001): c1c0af1522757cbd3f4e96b758cb75fac1713b3c98
```

Host notes (v2): while the wrong-proof back-off is running, the host answers a pairing AUTH with a clear
`BYE "wait"` without evaluating the proof (it does not count as an attempt). A code that rotated between CHALLENGE
and AUTH gets `BYE "expired"`. Other reasons seen by clients: `"version"`, `"hello"`, `"busy"`, `"timeout"`, `"Authentication failed"`.
