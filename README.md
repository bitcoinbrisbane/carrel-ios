# Carrel

A native iOS client for the LBRY network — a fast, self-custodial alternative to Odysee.

- **Native and fast** — SwiftUI, AVPlayer, picture-in-picture, background audio, offline downloads, `lbry://` deep links.
- **Self-custodial** — your keys live on your phone, in an embedded light wallet. No hosted account.
- **Not dependent on Odysee** — starts on Odysee's public SDK proxy for convenience, moves to our own node.

## Status

Day-one scaffold: Discover (trending), Search (Lighthouse full-text plus pasted `lbry://` / odysee.com links), and playback via the SDK's `get` → `streaming_url`. Library is a placeholder.

## Getting started

```sh
brew install xcodegen
xcodegen            # generates Carrel.xcodeproj from project.yml
open Carrel.xcodeproj
```

`LBRYKit` is a local Swift package and can be tested on its own:

```sh
cd Packages/LBRYKit && swift test
```

## Layout

```
Carrel/                 SwiftUI app (iOS 17+)
  CarrelApp.swift       App entry, AppModel, tabs, deep-link handling
  Views/                Discover, Search, Library, claim row + detail/player
Packages/LBRYKit/       Pure-Swift LBRY client
  LBRYClient.swift      JSON-RPC client: resolve, claim_search, get, Lighthouse search
  Models.swift          Claim, ChannelRef, ClaimValue, Page, ClaimSearchParams
  LBRYURL.swift         Normalise lbry:// and odysee.com links
  ContentFilter.swift   On-device tag/channel/claim filter (App Store Guideline 1.2)
project.yml             XcodeGen spec
```

## Architecture

```
 Carrel (iOS)
 ├── LBRYKit ── JSON-RPC ──► lbrynet daemon   (Odysee proxy now → carrel-node later)
 │           └─ HTTPS ─────► Lighthouse search
 ├── AVPlayer ─ HTTP ──────► streaming_url    (Odysee CDN now → our seeding node later)
 └── CarrelChain (planned) ─ hub protocol ──► LBRY hubs
```

Things that look like "LBRY" but are really Odysee's own servers, and how we handle them:

| Piece | Today | Plan |
|---|---|---|
| Metadata (`resolve`, `claim_search`) | Odysee SDK proxy | Our lbrynet + hub (`carrel-node`) |
| Video blobs | Odysee reflectors / CDN | Seeding node that caches what our users watch |
| Search | Odysee Lighthouse | Self-hosted Lighthouse or hub search |
| Comments, reactions, view counts | Odysee comment server / API (read-only) | Own comment server, or channel-signed comments |
| Accounts / sync | Not used | Wallet import (seed or keys) instead of Odysee login |

## Wallet: an embedded light chain ("Breez for LBRY")

The idea is a wallet that feels like Breez: open the app and you already have a working, self-custodial wallet backed by a tiny chain of its own on the device — no seed-phrase ceremony up front, no server holding keys.

Downloading every LBRY header isn't practical on a phone (two-and-a-half-minute blocks for ten years adds up to hundreds of MB). Instead, **CarrelChain** keeps a rolling window:

1. **Checkpoint.** Ship a hard-coded recent header (height + hash) in each app release.
2. **Header window.** From the checkpoint, sync headers forward from hubs, verify proof-of-work and linkage on device, and keep only the last N (start with ~100, enough to handle reorgs and LBRY's per-block difficulty retarget). Older headers are discarded; their hashes stay as an accumulator.
3. **SPV wallet.** Track our own addresses via the hub's Electrum-style protocol, verify transactions with merkle proofs against headers in the window (or the checkpoint chain).
4. **Verified resolve.** LBRY headers commit to the claimtrie root, so a hub's answer to "what's at `@channel/video`" can in principle be checked against our own headers instead of trusted. *To verify:* whether current hub software still serves claimtrie proofs.
5. **Keys.** secp256k1 keys in the Keychain (Secure Enclave only does P-256). Backup via iCloud Keychain by default, with a seed export for power users.

What the wallet does: tip and support creators, receive LBC, and bridge to wLBC via lbc.exchange.

## Roadmap

1. Browse, search, channels, playback *(scaffolded)*
2. Library: local subscriptions, history, downloads, PiP, background audio
3. CarrelChain + wallet: checkpoint sync, receive, tip, support, wallet import
4. `carrel-node`: own lbrynet, hub, seeding node, comment server, moderation list
5. Publishing from the phone

## App Store notes

- **Guideline 1.2 (UGC):** report, block and filter are required. `ContentFilter` is the on-device layer; a server-side list follows.
- **Crypto:** wallet apps must ship from an organisation developer account. Tipping in LBC is the part most likely to draw in-app-purchase questions.
