# Token Widget

A macOS desktop widget that charts what you spend on LLM coding agents, read straight from the transcripts they already write to disk. No API keys, no account linking. Reads Claude Code, Codex, and Pi.

The only network request it makes is a once-a-day fetch of OpenRouter's public price list, which carries no identifier and nothing about your usage. Everything else stays on the machine.

![The Token Widget app showing a week of usage](docs/screenshot.png)

## Install

```sh
git clone https://github.com/EricBriscoe/token-widget.git
cd token-widget
./install.sh
```

The script checks for Xcode, installs XcodeGen with Homebrew if it's missing, detects your Apple Developer team from your keychain, makes a clean Release build, verifies its signature, installs it to `~/Applications`, registers the widget extension, and launches it. Reinstalling preserves usage history and preferences. It takes about a minute on a clean checkout.

You need macOS 14 or later and an Apple ID added to Xcode under Settings > Accounts. A free account works. Signing is required because the app and the widget exchange data through an App Group, and App Group IDs are prefixed with a team ID.

Adding the Apple ID does not by itself create a signing certificate. Xcode mints one only when something asks it to. The script builds with `-allowProvisioningUpdates` so that happens automatically. If signing still fails, open Settings > Accounts, select the account, click **Manage Certificates**, and add an **Apple Development** certificate.

### Adding the widget

1. Control-click an empty area of the desktop and choose **Edit Widgets**, or click the clock in the menu bar and scroll to the bottom
2. Search for **Token Widget**
3. Drag out Small, Medium, Large, or Extra Large
4. Control-click the placed widget and choose **Edit Widget** to set the range and whether it shows cost or tokens

Four ranges are available, each bucketed so the bar count stays readable: week by day, month by day, quarter by week, year by month. The arrows on the widget step backwards through periods.

The widget shows cost or tokens. The token count is `output_tokens` only, what the model generated; cost prices every lane: input, cache writes, cache reads, and output.

The app runs as a menu bar item (bar-chart icon) with no Dock presence. Launching it from Finder or Spotlight opens the dashboard; closing the dashboard leaves the scanner running. A one-minute incremental rescan catches writes missed by filesystem notifications. Widget reload requests are coalesced to at most once per 15 minutes when usage or prices change; macOS controls the actual refresh timing. Tick "Open at login" so it comes back after a restart, and untick "Show the menu bar icon" in the dashboard if you want nothing visible at all. The widget is sandboxed and only reads the aggregated snapshot, so it shows whatever the app last recorded.

## Where the numbers come from

Claude Code writes one JSONL file per session under `~/.claude/projects/`. Every assistant message carries a `usage` block with input, output, cache-write and cache-read token counts, the model, and a timestamp. Token Widget reads those files and nothing else.

Three details make the difference between a plausible number and a correct one.

**Deduplication.** Claude Code writes one JSONL line per content block and repeats the full `usage` block on each. One message in my own logs appears 15 times. On a 340-file corpus the raw logs held 44,470 usage lines for 19,001 distinct messages, so counting lines instead of messages inflates every figure by about 2.3x. Records are keyed on `messageId` plus `requestId`, which is also what deduplicates a session that gets resumed or forked into a sidechain.

**Cache tiers priced separately.** A cache write bills at 1.25x the input rate on the 5-minute TTL and 2x on the 1-hour TTL; a cache read bills at 0.1x. The transcripts record `ephemeral_5m_input_tokens` and `ephemeral_1h_input_tokens` separately, so the two are never merged. On a cache-heavy workload the cache lines dominate the bill: in the screenshot above, 352.7M cache-read tokens account for most of Fable 5's $645.

**Thinking tokens aren't added twice.** `output_tokens_details.thinking_tokens` is a subset of `output_tokens`. It's tracked for display and excluded from the billed total.

Two kinds of entry are deliberately excluded or zeroed. Messages with the model `<synthetic>` are placeholders the CLI writes when an API call fails, so they never reach the cost math. Models served locally chart their tokens but cost nothing.

If a model has no published rate, its cost reads as zero and the app names it in the footer and the breakdown table. A missing rate is never quietly rendered as free usage.

### Prices

Rates come from [OpenRouter's public model list](https://openrouter.ai/api/v1/models), fetched at most once a day and cached to `prices.json` beside the history. It is an unauthenticated endpoint and the request says nothing about you. Using a live feed is what keeps a model released after the last build from charting as $0: it prices itself with no code change.

The feed carries what the cost math needs: input, output, cached-read, both Anthropic cache-write tiers, and per-request web search. Two things it can't supply are compiled in as fallbacks, and the lookup order reflects that:

1. **A built-in tier with explicit dates wins.** The feed reports today's rate only. Sonnet 5 ran on introductory pricing through 2026-08-31, so pricing a day in July at today's rate would silently rewrite history.
2. **Otherwise the feed wins**, which is the path almost every model takes.
3. **Otherwise a built-in rate fills the gap.** OpenRouter does not list every model these harnesses run. As of 2026-08-14 that is `claude-haiku-4-5`, `claude-sonnet-4-6`, `claude-mythos-5`, `claude-mythos-preview`, and `claude-opus-4-8` / `-4-7` / `-4-6`.
4. **Otherwise the model is unpriced**, reported as $0 and named in the footer. A guess is never substituted for a missing rate.

Leaf model names are not unique across vendors on OpenRouter, so entries are keyed by the full `vendor/model` ID and resolved using the harness that produced the record. A name that stays ambiguous resolves to unpriced rather than to another vendor's rate.

If the fetch fails, the cached copy stands rather than dropping every model to unpriced. The widget never makes the request itself; it reads the cache the app writes.

### Codex

Codex writes rollout transcripts to `~/.codex/sessions` and `~/.codex/archived_sessions`, one JSONL file per session. The `token_count` events carry OpenAI-style counts, where `cached_input_tokens` and `cache_write_input_tokens` are subsets of `input_tokens` and `reasoning_output_tokens` a subset of `output_tokens`. Those get unpacked into the same lanes as Claude's so the two chart together and one total means one thing.

Codex-specific details:

**Forked sessions.** Resuming or forking a session writes a *new* rollout file that replays the earlier turns verbatim. Keying dedup on the file path counted those turns once per file; on a 537-file corpus 122 turn identities appear in two files each. The key is now the millisecond timestamp plus the exact token split, with no path in it.

**Repeated usage updates.** A rate-limit update can repeat the previous token counts with a new timestamp. Repeated cumulative totals are ignored, including after the app restarts. When only cumulative usage is available, the reader subtracts its saved baseline.

**Web searches.** Counted from the `web_search_call` response item, not the `web_search_end` UI event that reports the same search; counting both would bill each one twice. A call that fans out into several queries counts once, matching how the rate card is quoted.

Models served locally cost nothing per token and are charted but not billed. They are recognised by a Hugging Face repo path (`unsloth/Qwen3.6-27B-GGUF`) or an Ollama `name:tag` (`gpt-oss:20b`); no hosted model ID from either vendor uses `/` or `:`.

### Pi

Pi assistant usage is read from `~/.pi/agent/sessions/`, including nested native child sessions. Forked copies are deduplicated by entry identity and timestamp. Input, cache reads, cache writes, and output are already separate lanes; reasoning is not added to output again. At display time, usage for the same model is combined across Pi and the CLIs, including fast/standard tiers; each source is still priced separately before summing.

Native assistant message records are counted, plus `external-usage` custom entries: model calls that Pi extensions make outside the transcript (for example pi-condense's context summaries) are invisible to Pi's own usage, so the [.rcs](https://github.com/EricBriscoe/.rcs) efficiency extension records them as custom entries with the model and token lanes, and those are priced like any other Pi usage. Compaction summaries, tool-result usage, external-agent artifact formats, and sessions outside this directory are not included. Costs are estimates: Pi does not retain cache TTL or priority-tier details in these usage records. Unknown vendors/models remain unpriced, not free.

## History outlives the transcripts

Claude Code deletes its own transcripts after a retention period, 30 days by default. Token Widget folds each scan into a stored snapshot and keeps the aggregated days after their source files are gone, so the chart keeps reaching further back the longer the app stays installed. A year of history is roughly 100 KB.

Because those days often become the only surviving record, a few things are deliberate:

- Every save rolls the current snapshot to `snapshot.previous.json` first
- A snapshot the app can't parse, including one written by a newer version, stops the scan instead of being replaced by whatever transcripts remain
- **Rebuild History from Transcripts** asks for confirmation and names how many days it will discard, and **Restore Previous History** undoes it
- **Export History** and **Import History** move the record between machines; importing keeps the fuller record for any day both files describe rather than summing them

The one gap this can't close: the app has to scan at least once inside the retention window to capture a given day. Ticking "Open at login" is what keeps that true.

## Performance

A first scan reads every transcript. On 340 files and 404 MB that takes 2.5 seconds. After that each file's size, modification date, inode, and byte offset are recorded, so a rescan opens only files that grew and reads only the bytes appended since. A rescan with nothing new takes 0.04 seconds.

Files being written to right now usually end mid-line. The reader stops at the last complete newline and leaves the fragment for the next pass, so a half-written JSON object is never parsed.

The dedup index stores 64-bit hashes rather than the identity strings: 8 bytes per message, about 150 KB for 19,000 messages, against roughly 3 MB for the same identities as text.

## Layout

```
Core/     Swift package: parsing, pricing, aggregation, storage, charts
App/      Menu bar app: dashboard window, FSEvents watching, scan driver
Widget/   WidgetKit extension and its configuration intents
```

The app is not sandboxed because it reads `~/.claude`. The widget is sandboxed and can only reach the App Group container. Everything they both need, including the chart itself, lives in `Core` so the two can't disagree about a total.

`Core` also builds a command-line tool:

```sh
cd Core && swift run tokenusage week
```

It prints the same figures with an ASCII bar chart, which is the quickest way to check the engine against your raw logs. It carries no entitlements, so it keeps its own store under `~/Library/Application Support/TokenWidget` and can't disturb the app's history.

### Building without the install script

```sh
xcodegen generate
xcodebuild -project TokenWidget.xcodeproj -scheme TokenWidget -destination 'platform=macOS' build
cd Core && swift test
```

To build under your own Apple Developer team, change `DEVELOPMENT_TEAM` in `project.yml`. The entitlements use `$(TeamIdentifierPrefix)`, which Xcode expands at build time, and the Swift code reads its App Group from its own entitlements at runtime, so there's no team ID hardcoded in source.

## Chart design

Each model has one series and one colour, regardless of harness. Colours are generated in OKLCH and chosen to maximize separation in OKLab, with additional scoring under protanopia, deuteranopia, and tritanopia simulation. Light/dark variants share a hue and each meets 3:1 contrast against its chart surface. There is no model-name list, eight-colour limit, or shared-gray fallback.

Assignments are saved with history and retained when new models appear, across restarts, ranges, and exports. Imports preserve existing local assignments and reassign incoming collisions. Distinct models never intentionally reuse an exact swatch in either appearance, but large palettes inevitably contain similar-looking colours; legends and numeric breakdowns remain essential.

## Limits

The Codex reader is checked against local rollout transcripts, including GPT-6 Astra sessions. It ignores repeated cumulative totals and saves the cumulative baseline between scans. Unsupported event shapes are skipped.

If a model has no published rate, its output tokens still appear in Tokens view. Cost view marks partial totals with `+`, shows a dash for unpriced models, and says `No rate` when none of the period's models can be priced. Astra has a built-in fallback from [OpenAI's published rates](https://developers.openai.com/api/docs/models/gpt-6-astra). Its cost is marked as estimated because daily aggregates cannot reconstruct per-request pricing tiers.

Cost is computed from published list prices. It's what the usage would cost at those rates, not a bill. Subscription plans, negotiated discounts, and promotional credits aren't modelled.

## License

MIT. See [LICENSE](LICENSE).
