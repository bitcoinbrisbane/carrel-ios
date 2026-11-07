# Search

Design for search on iPhone and Apple TV. Status: proposed, not built. Tracking issue: [#25](https://github.com/bitcoinbrisbane/carrel-ios/issues/25).

## Today

- **iPhone** (`Carrel/Views/SearchView.swift`): one Lighthouse query when you press return, 20 videos, no paging. Pasted `lbry://` and odysee.com links and `@name` resolve directly.
- **Apple TV** (`CarrelTV/TVBrowseViews.swift`): searches as you type, after a 600 ms pause. It has its own copy of the routing, which doesn't recognise odysee.com links.
- `LBRYClient.search` asks Lighthouse for hits (`name`, `claimId`), then resolves them all through the SDK proxy.

Problems:

1. "No results for …" shows while you're still typing, before any search has run (`SearchView.swift:23`).
2. Hidden channels and muted topics still show. Search applies `ContentFilter` but not the taste mutes.
3. The Lighthouse call doesn't send `nsfw=false`. A search for "nsfw" returned 12 mature-tagged hits in 30, which the phone then drops, so the page comes back short. With `nsfw=false` it was 0 in 30.
4. On iPhone a slower, older search can overwrite a newer one. The TV version checks for this; the iPhone one doesn't.
5. Channels only appear for an exact `@name`.

## What the servers support

Checked against `lighthouse.odysee.tv/search` on 7 November 2026. Lighthouse rejects unknown parameters ("Extraneous params"), so a normal response means the parameter is real.

| Parameter | Result | Use |
|---|---|---|
| `s`, `size`, `from` | works | Query and paging |
| `mediaType=video` | works | Videos only (today's default) |
| `claimType=channel` | works | Channel results |
| `nsfw=false` | works | Mature content filtered on the server |
| `sort_by=release_time`, `^release_time`, `effective_amount` | works | Newest, Oldest, Most supported |
| `time_filter`: `lasthour`, `today`, `thisweek`, `thismonth`, `thisyear` | works | Upload date |
| `max_duration`, `min_duration` (seconds) | works | Short, Long |
| `channel_id`, `channel` | works | Search within a channel |
| `related_to` (claim id) | works | "More like this" |
| `free_only`, `exclude_shorts` | accepted | Not needed yet |
| `resolve=true` | works | Adds `title`, `thumbnail_url`, `duration`, `release_time`, `channel` and `fee`, but no tags, description or address |
| `duration`, `exact`, `include_channels` | rejected | |
| `sort_by=trending_mixed` | Elasticsearch error | |
| `/autocomplete?s=` | works | Returns claim-name slugs (`bitcash-review-bitc-undervalued-mineable`), so not usable as suggestions |

Every hit carries `channel_claim_id`, even without `resolve=true`.

The SDK's `claim_search` also takes `text` (the comment in `LBRYClient` says it has no text search), but its relevance is poor: "eric voskuil" matched videos tagged `eric`, and the results included `c:unlisted` claims. So Lighthouse handles typed text, and `claim_search` handles structured listings (`#tag`, a channel's videos).

Timing from one quick test: Lighthouse about 1.5 s, the SDK `resolve` of 20 hits about 1.3 s, `claim_search` with `text` about 2.2 s.

## Design

### One search engine, shared by both apps

A new `Packages/LBRYKit/Sources/LBRYKit/Search/`, next to `HomeFeed` and `ShortsFeed`, testable with `swift test`:

- **`SearchQuery`** works out what was typed:
  - `lbry://…`, odysee.com links and `@channel:id/video:id` open directly (`LBRYURL.normalise`, then `resolve`).
  - A bare `@name` is a channel search, with the exact name (`lbry://@name`) pinned first if it resolves.
  - `#tag` lists that topic with `claim_search` (`any_tags`), sorted Trending, New or Top.
  - Anything else is a text search.
- **`SearchOptions`** holds sort, upload date, length and type, and turns them into Lighthouse parameters. It always sends `nsfw=false`, plus `mediaType=video` or `claimType=channel`.
- **`SearchFeed`** runs a query page by page (`from`) and drops duplicates across pages. It removes muted channels by `channel_claim_id` *before* resolving, so no resolve is spent on them, then applies `ContentFilter` and muted topics after. If filtering leaves a page nearly empty, it fetches the next one.
- **`RecentSearches`** keeps the last 20 queries, newest first.

`SearchView` and `TVSearchView` become thin views over these.

### Before typing

- Recent searches: tap to run, swipe to delete, Clear all.
- Topic chips: yours first, then popular ones (`HomeFeed.browseTopics`). A chip runs a `#tag` search.

### While typing

On iPhone, instant suggestions from the phone only, with no network:

- Recent searches that match
- Channels you follow (by name or title)
- Your topics, as `#tag`
- **In your library:** titles from watch history and downloads. Works offline.

The network search runs when you press return or tap a suggestion. Apple TV keeps searching as you type (600 ms pause), since typing with a remote is slow.

### Results

1. **Channels:** a row of up to 5 (`claimType=channel`, `size=5`, run alongside the video query), with avatar, title, `@name` and Follow. An exact `@name` match goes first. For an `@` query the channels are the whole result.
2. **From channels you follow:** videos in the results from channels you follow, lifted into their own short section.
3. **Videos:** the rest, in Lighthouse's order, loading more as you scroll (20 per page).

Results aren't re-ranked with `FeedRanker`, because search should be predictable. Videos opened from search still feed taste through the usual watch signals.

### Filters

Chips under the search field, with a sheet for the full set:

| Filter | Options | Lighthouse |
|---|---|---|
| Sort | Relevance, Newest, Most supported | default, `sort_by=release_time`, `sort_by=effective_amount` |
| Upload date | Any, Today, This week, This month, This year | `time_filter` |
| Length | Any, Short (≤3 min), Long (≥20 min) | `max_duration=180` (the Shorts cutoff), `min_duration=1200` |
| Type | Videos, Channels | `mediaType=video`, `claimType=channel` |

### Search within a channel

A search field on the channel page (iPhone and Apple TV), using Lighthouse's `channel_id`. With the field empty, the page shows the channel's latest videos as now.

### Faster first paint

Today each search is two round trips: Lighthouse, then `resolve`. With `resolve=true`, Lighthouse returns enough for `ClaimRow` (title, thumbnail, length, channel name, date) in one. The plan:

1. Show the rows from Lighthouse's data straight away, as a partial `Claim` built inside LBRYKit, so `ClaimRow` doesn't change.
2. Resolve the page in the background for tags, description, tip address and channel details, and swap the full claims in.
3. Drop anything a muted topic or blocked tag catches at that point. With `nsfw=false` on the server this should be rare.
4. A tap before the full claim arrives waits for it.

### Privacy

- Queries go to Odysee's Lighthouse until carrel-node runs its own ([#9](https://github.com/bitcoinbrisbane/carrel-ios/issues/9)). `LBRYClient.searchURL` is already configurable.
- Recent searches and suggestions stay on the phone.
- Search queries don't change the taste profile.

## Phases

1. **Core:** `SearchQuery`, `SearchOptions` and `SearchFeed`; `nsfw=false`; paging; the channels row; mutes applied; recent searches; problems 1–5 fixed; Apple TV on the same engine. Tests for parsing, parameters, paging, de-duplication and filtering.
2. **Refinement:** filters, `#tag` search, search within a channel, "In your library" suggestions, faster first paint.
3. **Later:** "More like this" on video pages (`related_to`), and self-hosted Lighthouse on carrel-node.

## Open questions

- **Recent searches across devices.** Proposed: on the device only. The alternative is to include them in the encrypted backup so they reach Apple TV (20 queries fit easily in the backup's 1 MB limit).
- **Learning from searches.** Proposed: no. One search doesn't mean you want that topic in your feed.
- **Faster first paint.** Proposed: yes, in phase 2. It adds a partial-claim state that the views have to handle.
