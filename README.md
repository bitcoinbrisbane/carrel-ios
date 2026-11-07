# Carrel

A native iOS client for the LBRY network — a fast, self-custodial alternative to Odysee.

- **Native and fast** — SwiftUI, AVPlayer, picture-in-picture, background audio, offline downloads, `lbry://` deep links.
- **Self-custodial** — your keys live on your phone, in an embedded light wallet. No hosted account.
- **Not dependent on Odysee** — starts on Odysee's public SDK proxy for convenience, moves to our own node.

## Status

Day-one scaffold: Discover (trending), Search (Lighthouse full-text plus pasted `lbry://` / odysee.com links), and playback via the SDK's `get` → `streaming_url`. Library is a placeholder.

## Screens

Mock-ups from the design canvas ("Carrel mock screens"). Real screenshots will go in [`docs/screenshots/`](docs/screenshots/) as the app comes together.

| Home · For you | Shorts | Not for me | Your taste |
|:---:|:---:|:---:|:---:|
| <img src="docs/mocks/home-for-you.png" width="200" alt="Home screen with a featured video and recommendation rows"> | <img src="docs/mocks/shorts.png" width="200" alt="Full-screen Shorts clip with like, not for me, tip, comments and share"> | <img src="docs/mocks/shorts-not-for-me.png" width="200" alt="Not for me sheet: skip, less from channel, less of tag, hide channel"> | <img src="docs/mocks/your-taste.png" width="200" alt="Your taste screen with topic weights, channels and ranking controls"> |

## Getting started

```sh
brew install xcodegen
xcodegen            # generates Carrel.xcodeproj from project.yml
open Carrel.xcodeproj
```

To build and (re)launch in a simulator from the terminal:

```sh
scripts/run-phone.sh                 # iPhone simulator (booted one, else the first available)
scripts/run-tv.sh                    # Apple TV simulator
scripts/run-tv.sh "Apple TV 4K (3rd generation)" --fresh   # a named device; --fresh deletes the app (and its data) first
PULL=1 scripts/run-phone.sh          # git pull first
```

`LBRYKit` is a local Swift package and can be tested on its own:

```sh
cd Packages/LBRYKit && swift test
```

## Layout

```
Carrel/                 SwiftUI app (iOS 17+)
  CarrelApp.swift       App entry, AppModel, tabs, deep-link handling
  Model/                Taste persistence, streaming-URL prefetch cache
  Views/                Home (For you), Shorts, Search, Library, Wallet, channel page, video page, tip sheet
CarrelTV/               Apple TV app (tvOS 17+): Home, Discover, Library, Search, player, tip-by-QR
Packages/LBRYKit/       Pure-Swift LBRY client
  LBRYClient.swift      JSON-RPC client: resolve, claim_search, get, Lighthouse search
  Models.swift          Claim, ChannelRef, ClaimValue, Page, ClaimSearchParams
  LBRYURL.swift         Normalise lbry:// and odysee.com links
  ContentFilter.swift   On-device tag/channel/claim filter (App Store Guideline 1.2)
  Recommend/            TasteProfile (signals → weights), FeedRanker (scoring + exploration), ShortsFeed, HomeFeed
  Library/              UserLibrary: follows, watch history, Continue watching, resume points
  Search/               SearchQuery (links, @channels, text), SearchFeed (Lighthouse paging, filtering, sections), RecentSearches
  Chain/                CarrelChain: headers, LBRY PoW, retarget, rolling window, hub client, sync
  Wallet/               Phrases, BIP32, addresses, transactions, signing, scan, iCloud Keychain vault
  Ethereum/             Keccak, ETH account from the same phrase, balances over RPC, lbc.exchange client
  Text/                 Linkifier for descriptions (URLs, X, Reddit, LBRY channels)
scripts/
  make_checkpoint.py    Generates the shipped mainnet checkpoint from a live hub
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

## Recommendations (on device)

Shorts is ranked by `FeedRanker` against a `TasteProfile` that never leaves the phone:

```
score = 1.0·topicMatch + 0.8·channelAffinity + 0.4·freshness
```

- **Signals:** like +0.25 topics / +0.30 channel, watched to the end +0.10, skipped within 2 s −0.06, "not interested" −0.15 / −0.10. Explicit "less of" choices push −0.6; "hide channel" mutes it. Weights are clamped to ±1, and a topic push is spread over the clip's tags.
- **Exploration:** every *n*-th slot (default 10%, "Surprise me" slider 0–40%) is a random clip the viewer has no opinion on yet, so the feed doesn't narrow.
- **Candidates:** up to three `claim_search` queries per page (trending, top liked channels, top topics), all filtered to `duration <=180` (the same cutoff and filter Odysee's Shorts uses). Videos whose metadata has no length are indexed as 0, so the phone also requires a known length of 1–180 s; Home keeps only lengths over 180 s. Only these broad interests reach the server; ranking and the profile stay local.
- **Your taste** (Library tab) shows topics and channels with their weights, lets you hide or unmute them, change the surprise share, pause learning or reset.

The mock screens are on the "Carrel mock screens" design canvas.

## Home and Library

The Home tab is the "For you" mock made real. `HomeFeed` asks `claim_search` for up to four candidate sets (trending, channels you follow, your top channel, your top topic; videos over 3 minutes, since Shorts has the rest), then ranks everything on the phone with the same `FeedRanker` as Shorts. The best match becomes the featured video (with its "% match" when it's 70% or more), and each video appears in at most one row. Chips switch to Following, or to your top topics.

**Downloads.** *Download* on a video page saves it for offline viewing; Library › Downloads lists them with progress, storage used and a Wi-Fi-only switch (on by default). Plain MP4 streams download with a background `URLSession` (they carry on with the app closed, and pause keeps resume data); HLS streams download as `.movpkg` packages with `AVAssetDownloadURLSession`. Files live in Application Support, excluded from iCloud backup, and a downloaded video plays from the file with no network (resume position included). Apple TV has no downloads (tvOS has no lasting file storage).

Following and history live in `UserLibrary`, saved on the phone. The player saves your place every 10 seconds; videos between 5% and 95% watched show in Continue watching and resume where you stopped, and finishing a long video counts as a "watched to the end" taste signal.

## Search

Lighthouse full-text search, through `SearchFeed` in LBRYKit (shared with Apple TV): a row of channels (the exact `@name` first, with Follow), videos from channels you follow, then everything else in Lighthouse's order, loading more as you scroll. `@name` searches channels; `lbry://` and odysee.com links open directly. Every request sends `nsfw=false`, muted channels are dropped before resolving and muted topics after, and recent searches stay on the phone (not in the iCloud backup). Design, findings about Lighthouse and the next phases: [docs/SEARCH.md](docs/SEARCH.md).

### Encrypted backup

Taste, follows and watch history are backed up to iCloud key-value storage, encrypted with AES-256-GCM under a key derived (HKDF) from the wallet's recovery phrase, so Apple stores the blob but can't read it. Backups happen 20 seconds after the last change; restoring the wallet on a new phone restores them automatically, and Library › Your taste has "Back up now" and "Restore from iCloud". History drops video descriptions (and the oldest entries if needed) to stay under the 1 MB limit.

To sync between devices, enable the iCloud key-value storage capability: uncomment the `entitlements` block in `project.yml`, set your team in Xcode, and run `xcodegen`.

## Wallet

Self-custodial LBC, built into LBRYKit (`Sources/LBRYKit/Wallet`, `Chain`).

**Keys.** A new wallet gets a 12-word BIP39 phrase. The seed is derived the LBRY SDK way (PBKDF2, salt `lbryum`) with receive addresses at `m/0/i` and change at `m/1/i`, so a phrase from LBRY Desktop or Odysee restores here and vice versa. xprv and xpub (watch-only) import work too.

**Backup.** `SeedVault` keeps the phrase in the Keychain as a synchronizable item, so iCloud Keychain carries it end-to-end encrypted to a new iPhone with nothing to write down (Breez-style). "Show recovery phrase" stays available for an offline copy. Trade-off: whoever controls the Apple ID can restore the wallet, so larger balances should get a nudge towards the offline copy.

**Balance and history.** `Wallet.scan()` walks addresses until a gap of 20 unused receive (6 change), fetches each transaction once from a hub (`blockchain.address.get_history`, `transaction.get_batch`), and works out coins as outputs paying us minus those our own transactions spend. Support and tip outputs paying us are kept apart from spendable coins.

**Verification (CarrelChain).** The app keeps a rolling window of the last 100 headers, checked from a shipped checkpoint (`Checkpoint+Mainnet.swift`, regenerate with `scripts/make_checkpoint.py`): prev-hash linkage, LBRY's per-block retarget and LBRY's proof of work. When a wallet transaction's block is inside that window, its merkle proof must match our own header or the scan fails; older history is taken from the hub. Headers also commit to the claimtrie root, so verified `resolve` is possible later.

**Spending.** Sends, tips (a support output paying the creator) and supports (paying yourself) use the same coin selection, fees (50 dewies/byte), legacy P2PKH signing and pre-broadcast signature self-check as lbc.exchange. Signing goes through Bitcoin Core's libsecp256k1 (RFC 6979, low-S). The tests check the Swift output byte-for-byte against transactions built by the bridge's TypeScript wallet.

**Screens.** Wallet tab: create or restore (LBRY Desktop / Odysee phrases), balance with pending and supported amounts, receive with QR code, send with a fee review, activity with a shield on transactions verified against our own headers, and "Show recovery phrase". Tip button in Shorts and on every video page (1, 5, 10, 25 LBC or a custom amount, fee shown before sending).

**Still to do:** the encrypted taste-profile backup keyed from the wallet seed, withdrawing your own supports, and a nudge to make an offline copy of the phrase once the balance grows.

## Apple TV

`CarrelTV` is a tvOS 17 app built on the same LBRYKit, with a 10-foot UI: run `xcodegen`, pick the **CarrelTV** scheme and an Apple TV simulator.

- **Home:** the same `HomeFeed` as the iPhone: a featured best match with its "% match", then Continue watching (with progress), New from channels you follow, Because you liked, More #topic, Trending and Fresh rows of focusable cards, then Discover shelves that load as you scroll: Top this week and Top this month (most supported with LBC), a shelf per topic, and an endless More to watch grid. Each video appears once per page.
- **Discover:** pick Trending, New, Top this week, Top this month or a topic (yours first, then popular ones like news, technology, science, gaming and music) along the top, and page through an endless grid below. Muted or turned-down topics and channels stay out.
- **Video page:** backdrop, details, Play / Resume / From the start, Like, Follow, Tip. Playback is the system player (scrubbing, info panel with title and channel), saving your place every 10 seconds.
- **Search:** the system TV keyboard, searching as you type, with the iPhone's engine: a Channels row, videos from channels you follow, then a grid that loads more as you scroll; `lbry://` and odysee.com links open directly.
- **Library:** Continue watching, channels you follow, recently watched; channel pages with banner, Follow and a grid of their videos.
- **Tipping without keys on the TV:** Tip shows a QR code for `carrel://tip?uri=lbry://…`. Scanning it with the iPhone camera opens Carrel there with the tip sheet ready, so the fee review and signing stay on the phone.

Shorts isn't a tab on the TV (portrait clips waste the screen); `TVShortsView` stays in the project for a possible lean-back "play one after another" mode.

**Syncing with the iPhone.** Library › *Link iPhone* shows a QR code and a six-character code. Scanning it with the iPhone camera opens Carrel, which (after you check the code) encrypts the backup key to the TV's one-off X25519 key and leaves it in iCloud key-value storage; the TV picks it up, keeps it in its own Keychain and deletes the entry. From then on both devices read and write the same encrypted backup, merging rather than overwriting: follows and history are combined, and for each topic or channel the stronger opinion wins, with mutes and likes combined. The TV never holds the recovery phrase and can't touch the wallet. Needs the iCloud key-value entitlement on both targets (commented out in `project.yml` until you set a team) and the same iCloud account on both devices. Unfollowing or unmuting on one device can be undone by the other's copy for now; tombstones for removals are a follow-up.

The TV keeps its taste and library in Caches (tvOS's only file storage, which the system can clear), so linking also means a cleared TV refills itself from iCloud.

## Ethereum and lbc.exchange

The same recovery phrase also gives an Ethereum account, on the standard path `m/44'/60'/0'/0/0`, so importing the phrase into MetaMask shows the same address. (LBC keeps the LBRY SDK's seed scheme; Ethereum uses the plain BIP39 seed, so each side matches its own ecosystem's wallets.)

The Wallet tab shows ETH, USDC, USDT and wLBC balances from the public RPC lbc.exchange uses, and a Receive screen for the Ethereum address.

**Wrap LBC → wLBC.** Carrel asks [lbc.exchange](https://lbc.exchange) for this wallet's deposit address, then trusts it only if the bridge's signed statement names exactly that LBC address, this Ethereum address, the bridge and chain 1, *and* the signature recovers to `Bridge.signer()` read from Ethereum, not from the API (the same check the website does). LBC goes from the Carrel wallet to that address, and the deposit shows as pending → ready → minted.

**Mint.** Once a deposit has 6 LBC confirmations, *Mint* asks the bridge for a mint approval (`POST wrap`), recomputes `Bridge.wrapMessageHash` on the phone and checks the approval mints to this wallet and was signed by `Bridge.signer()`, then shows the gas cost and submits `Bridge.wrap` itself. No MetaMask needed.

**Unwrap.** `Bridge.unwrap(amount, lbcAddress)` burns wLBC, paying LBC to this wallet's next receive address by default. Carrel follows the burn and, after 12 Ethereum confirmations, asks the bridge to pay (`POST unwrap`, safe to repeat) until the LBC arrives. Open unwraps are saved, so this resumes if the app was closed.

**Send.** ETH, USDC, USDT and wLBC to any Ethereum address, with a review showing the likely and worst-case fee. USDT's `transfer` returns nothing rather than `true`, so a successful receipt is the success signal for every token.

**Signing.** EIP-1559 (type 2) transactions: RLP, ABI encoding (static and dynamic arguments), nonce from the pending pool, `eth_estimateGas` + 20% (an estimation revert stops the send before anything is signed), max fee = 2 × base fee + tip, and a check that the wallet holds value plus worst-case fee in ETH. Signatures use libsecp256k1's recoverable ECDSA (RFC 6979, low-S).

Keccak-256, EIP-55 checksums, address derivation and EIP-191 recovery are tested against eth-account (`Fixtures/eth_vectors.json`); RLP, calldata, signing hashes, raw signed transactions and hashes for an ETH send, a USDC transfer, `Bridge.wrap` and `Bridge.unwrap` match eth-account and pyrlp byte for byte (`Fixtures/eth_tx_vectors.json`).

## Roadmap

1. Browse, search, channels, playback *(built)*
2. Library: follows, watch history, Continue watching and resume, offline downloads *(built)*; picture-in-picture and background audio next
3. **Shorts-style feed** *(built)* — full-screen vertical clips ≤3 min, swipe for more, like / not for me, next two prefetched
4. **"For you" home** *(built)* — chips, a featured video with "% match", and rows: Continue watching, New from channels you follow, Because you liked @channel, More #topic, Trending, Fresh on LBRY

5. CarrelChain + wallet: checkpoint sync, keys, scan, tip/support/send *(core built)*; screens next
6. `carrel-node`: own lbrynet, hub, seeding node, comment server, moderation list
7. Publishing from the phone
8. **lbc.exchange bridge and Ethereum** *(built)* — ETH address from the same phrase (MetaMask-compatible), ETH/USDC/USDT/wLBC balances, wrap LBC → wLBC with a verified deposit address, mint (`Bridge.wrap`) and unwrap (`Bridge.unwrap`) in the app, and ETH/token sends

## App Store notes

- **Guideline 1.2 (UGC):** report, block and filter are required. `ContentFilter` is the on-device layer; a server-side list follows.
- **Crypto:** wallet apps must ship from an organisation developer account. Tipping in LBC is the part most likely to draw in-app-purchase questions.
