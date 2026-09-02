# claude-code-cache-keepalive

Keep the Claude Code prompt cache hitting for long sessions and automated
agents: what burns the cache, how to configure a stable prefix, and a
lightweight keepalive before the TTL expires.

[中文说明](README.md)

> [!WARNING]
> Unofficial community notes, not affiliated with Anthropic. Numbers were
> measured on Claude Code 2.1.175 / 2.1.258 against real API usage; behavior may change
> across CC versions — re-verify before trusting. Sister project:
> [claude-code-turn-anchor](https://github.com/lllq-123/claude-code-turn-anchor)
> (sparse append-only injection every 15 prompts since 2026-09-02; no transcript rewrite).

## Read this first: cache collapse heals itself, so you never see it

The most counter-intuitive fact, and the most important one: **a cache-busting
incident recovers on its own, so you will almost never catch it live.**

The turn that busts the cache recomputes the entire prefix at cache-write
rates (1.25× or 2×) — and **the very next turn is back to 99% hits**. You hear
the cache had a problem, you check the current hit rate, everything looks
fine, and you conclude there is no problem. The money (or subscription quota)
was already burned in that one turn.

**Watching the current value never catches a collapse. Look at the series:**

```bash
jq -r 'select(.type=="assistant" and .message.usage) |
  [.timestamp,
   .message.usage.cache_read_input_tokens,
   .message.usage.cache_creation_input_tokens] | @tsv' \
  ~/.claude/projects/<project-dir>/<session-id>.jsonl
```

In a healthy long session `cache_read` climbs steadily and `cache_creation`
stays a thin per-turn slice. A sudden `read=0 / create=huge` row in the middle
is one collapse — it happened, it healed, you missed it.

## The cache on one page

- The request prefix is assembled as **tools → system → messages**; caching is
  **verbatim prefix matching**: from the first differing byte onward,
  everything is recomputed.
- Pricing (Anthropic API): cache writes cost 1.25× (5-minute TTL) or 2×
  (1-hour TTL); cache reads cost 0.1×. On subscriptions (Pro/Max) you burn
  5-hour-window quota instead of dollars — hurts the same.
- The TTL is sliding: every hit resets the clock.
- Three readings that matter when debugging:
  - `read = 0`, huge `create` → **the very front changed** (tools or system
    segment); typical causes: tool-table change, system-prompt change;
  - `read = a modest value`, huge `create` → the front is intact, **the
    divergence sits early in `messages`**; typical causes: rewritten history,
    MCP tools attaching asynchronously;
  - all-zero usage for a turn → almost always an **interrupted turn**; that is
    "no data", not a collapse — don't chase it as a disease.

## Principle: stable things first, changing things last

Verbatim prefix matching means: **the earlier a changing byte sits, the more
it burns.**

- Anti-pattern: current time at the top of the system prompt → full recompute
  every turn; the cache may as well not exist.
- A real case: Claude Code's system reminder carries a `currentDate` field,
  **computed once per process**, sitting at the very front of the prompt.
  A long-lived interactive process is fine (the date is never recomputed while
  it lives; on day rollover CC **appends** a date-change notice at the end,
  leaving the prefix alone — the correct pattern). But a resume-per-turn
  automation recomputes the date in the first turn after midnight → the prefix
  mismatches from its first byte → one full rewrite, every day. Same field,
  two architectures, completely different bill.

  In a resume-per-turn runtime there are two ways out:

  - **Accept it**: the cost is one full rewrite in the first turn after
    midnight, at a predictable time. With a modest context this is the
    low-maintenance choice;
  - **Root fix (unofficial, at your own risk)**: patch the client binary to
    blank that startup-computed date field, and provide the date via an
    end-of-turn hook injection instead — the hands-on version of
    "changing things last". Costs: redo it after every Claude Code upgrade,
    and it modifies client behavior — weigh it yourself. We run this fix
    ourselves, which is why the measured numbers in this document contain
    **no** midnight rewrites.
- The right way: inject dynamic content (time, status, reminders) at the
  **end of the turn** via a `UserPromptSubmit` hook's `additionalContext`,
  never into the prefix. Per-turn injections accumulate in the transcript;
  **do not clean old copies by rewriting the file** — preserved thinking in
  Fable 5.1 requires append-only history. See the sparse
  [turn-anchor](https://github.com/lllq-123/claude-code-turn-anchor) pattern.

## What burns the cache (behavior list)

| Behavior | Divergence point | Cost |
|---|---|---|
| Any tool-table change: installing/removing MCP servers, first load of a deferred tool, MCP connection flapping | tools segment (frontmost) | full |
| System-prompt change: switching output styles, resuming after system-level config edits | system segment | full |
| Switching models | caches are isolated per model | full rebuild |
| Rewriting on-disk history (transcript-surgery schemes), then resuming | first modified message | everything after it |
| `/clear`, `/compact` | the prefix starts over | full (a feature, not an accident — just know it) |
| Idling past the TTL | no mismatch, plain expiry | full rebuild |
| Day rollover in a resume-per-turn runtime (date fields computed at startup) | the very front | full, once a day |
| Editing CLAUDE.md mid-session | **no mismatch that turn** (the live process never re-reads it) | **deferred blast**: every cache line burns from the first message at its own next rebuild |
| Editing any `skills/*/SKILL.md` (body, `name`, or `description`) | a bypass probe may temporarily keep hitting the old line | **deferred blast on the next real user message**: the skill listing is before the first cache breakpoint; locally measured `read=0 / create=76,047` |
| CC 2.1.258 `totalTokensReminder` | appends a dynamic reminder near the tail by default | first-party local sessions did not show a per-turn collapse from it, but 15 million is a padded task budget, not context remaining; top-level `"totalTokensReminder":"off"` disables it and causes one expected cold system-prompt transition |

The most overlooked row is the first: **the tool table sits at the very front
of the prefix, so any change to it is the most expensive kind of change.**
The two "deferred blast" rows are a differently-shaped trap — everything looks
fine the moment you edit, and the bill arrives later. They get their own
section.

## Time your config edits (CLAUDE.md / skills / MCP)

Current conclusion after combining wire captures with a real-user-turn timeline:

- **Editing CLAUDE.md mid-session**: the new content never appears in any
  subsequent request — the live process simply never re-reads the file.
  Zero effect that turn;
- **Treat every SKILL.md edit as cache-busting.** A 2.1.175 wire capture showed
  that body text was absent from the visible listing, but a 2026-09-01 real
  timeline disproved the extrapolation that bodies were safe: a bypass probe
  still read 75,995 after the edit, while the next real user message went
  `read=0 / create=76,047`. The probe is blind to this deferred mismatch.

The first two sound safe? The danger is precisely in the "later". This
content lives at the very front of the prompt (CLAUDE.md is spliced into the first message,
the full skill listing right after it), and **a process rebuild regenerates
it from current disk**. Once the config has changed, every existing cache
line takes one full rewrite at its own next rebuild — reopening a window,
resuming, or a bypass keepalive probe.

Three practical rules:

1. **Edit config when your context is short.** The blast equals each
   window's context length at that moment: finish your config work in a
   fresh 20k-token window and it costs 20k; do it with a 300k-token session
   open and that line costs 300k.
2. **Don't edit with a pile of long sessions open.** Every window is an
   independent cache line; one global config edit detonates once per open
   window, later, each at its own size. Close what you don't need first.
3. **The first resume / fresh window / real user turn after an edit may do one full rewrite —
   that is expected, don't chase it as a failure.** Keepalive users, note:
   any SKILL.md change also
   makes the bypass probe's rebuilt prefix diverge from the main session's,
   so the probe starts missing — after config work, let long sessions wind
   down and reopen sooner rather than later.

One more measured detail that changes *when* the bill lands: **CC's resident
long-lived process initializes lazily** — a stream-json process does nothing
after starting (no SessionStart hooks, no MCP connections; measured: the
event buffer stays empty through 45 minutes of idling) and **only initializes
from whatever is on disk the moment the first input arrives**. So the bill
for a config edit is settled not "when a process starts" but "when the next
process is woken up (receives its first input)" — the process may have been
up for a long while without ever having read the disk.

## Resume-per-turn automation: tools must be fully loaded up front

Headless automation — a fresh `claude -p --resume <session-id>` process per
turn, exiting after each answer — is a common agent shape. Here the prefix is
rebuilt verbatim from disk every turn, and **anything that loads
"mid-flight" is a time bomb**:

1. **`ENABLE_TOOL_SEARCH=false` — disable deferred tools.**
   Claude Code's ToolSearch ships without the deferred tools' definitions and
   splices a schema into the `tools` array the first time it is needed — at
   that moment the tools segment changes and the whole cache is void. The
   longer the context, the worse the trade: in a 300k-token session, one
   dynamic load = 300k tokens recomputed at write rates, in exchange for a few
   tens of kilobytes of upload saved.
   (The **official API's** tool search with `defer_loading` is a different
   thing: definitions are always sent server-side, they just stay out of
   context — the prefix is untouched and caching is preserved. CC currently
   does not take that path, hence turning the whole thing off.)

2. **`"alwaysLoad": true` on every MCP server.**
   This guards more than deferral: MCP servers attach asynchronously, and the
   timing skew alone can make the tool table differ between two turns.

3. **Do both together.** Killing ToolSearch without `alwaysLoad` is worse
   than nothing — the MCP tools all move into the tools segment, and now any
   single server flapping changes the tool table and zeroes `cache_read`.

4. **Environment variables verbatim-identical every turn.** One missing env
   var that affects prompt assembly means a different prefix (measured: a
   resume that dropped one env var went `read=0`, full rewrite, real money
   per shot). Replicate the main process's flags and env mechanically; do not
   retype from memory.

5. **Same cwd.** The working directory is embedded in the system prompt;
   changing directories changes the system segment.

### Slimming the tool table (also a cost item)

The tool table should be stable *and* small — it is a fixed cost shipped
every single turn:

- **Deny built-in tools you never use**: `permissions.deny` in
  `settings.json` can disable tools outright. We cut 29 → 21, the tools
  segment shrank by ~20 KB, saving roughly ten thousand tokens of fixed input
  per turn.
- **Don't hang a row of MCP servers.** Every tool's full JSON schema of every
  server goes into the prefix. For low-frequency services (used once or twice
  a week), don't keep them resident:
  - sink them into a **CLI**: one entry command with a self-describing
    `--help`; the model calls it via Bash, zero tool-table footprint;
  - or wrap them as a **skill**: docs read on demand, gone when done.
  - Both share the property that matters: **zero change to CC's tool table =
    zero prefix risk + zero fixed cost.** We keep two high-frequency servers
    resident; four low-frequency services all route through one CLI gateway.

## TTL keepalive

**When you need it**: the session will idle (waiting for a human, overnight
standby), the TTL (5 min or 1 h) lapses, the cache goes cold, and the next
wake-up is a full rebuild. Keepalive = send one minimal turn before the TTL
expires: read the cache through, reset the TTL.

**Whether it pays**: one keepalive ≈ one full read = 0.1×; a cold rebuild =
1.25×/2×. The longer the context, the better the deal: let a
few-ten-thousand-token session go cold, rebuilding is cheap; for a
several-hundred-thousand-token resident agent, one keepalive vs one cold
rebuild is a 20× difference.

**Mechanism**: rebuild a **verbatim-identical** prefix and send it →
`cache_read` hits in full → the server-side TTL resets → discard the output.

**Bypass-resume flavor** (does not disturb the main session or pollute the
transcript):

```bash
# Minimal working version: a short-lived process resumes the same session
timeout 30 claude -p --resume "$SESSION_ID" --no-session-persistence \
  "Reply with exactly: ok" >/dev/null
```

- `--no-session-persistence`: this turn is never written to disk, so the main
  session's transcript stays clean (otherwise the keepalive turn would be
  appended into history and change the next real turn's prefix);
- replicate the main session's flags, env, and cwd per the previous section —
  **the fidelity of the replica decides whether it hits**;
- verify via `--output-format stream-json` usage:
  - `cache_read > 0` ✅ the cache line was carried forward;
  - `read = 0` with `create > 0` ❌ the replica didn't match — this shot
    **built a separate new cache line**, spending money while keeping nothing
    alive. Go diff your flags and env.

Full example: [`examples/keepalive.sh`](examples/keepalive.sh).

**Randomize the interval**: a fixed request cadence is a textbook automation
fingerprint; out of caution, don't use one. Draw from a range close to the
TTL (1-hour TTL → uniform in 50–58 minutes), sliding from the **last real
activity**, not the wall clock. Two more common-sense rules: never cold-start
the main process just to keep a cache warm; while the user is active, real
requests refresh the TTL anyway — keepalive is only the idle-time backstop.

**Output compression is an optimization, not a requirement** (keepalive
works fine without it): production setups can cap output at 1 token
(`CLAUDE_CODE_MAX_OUTPUT_TOKENS=1` — absent from the official docs but
measured to be a legal value). Know this trap first, though:

- **Truncated output (`stop_reason=max_tokens`) always triggers CC's rescue
  retry, hard-coded to 3 attempts** — one keepalive becomes 4 requests, each
  doing a full cache read;
- **there is no switch**: `CLAUDE_CODE_MAX_RETRIES` governs network-layer
  errors and has no effect here (the trigger is the stop_reason, not a
  network failure);
- **the workaround is a stream-kill**: under `--output-format stream-json`,
  the `message_start` event carries the complete usage and flows out before
  the response finishes — the moment you have it, the server has already
  completed the cache read and refreshed the TTL, so `SIGKILL` the whole
  process group and the retries never leave the machine. Measured: exactly
  1 API request;
- **a reading trap**: in `-p` mode the final `result.usage` is a
  **whole-run accumulation**, not per-request — 4 rescue attempts make
  `cache_read` display at 4× the single-shot value. Read it as one request
  and you will "discover" a phantom hundred-thousand-token injection;
  divide by the actual request count before concluding anything.

## Verification: how to read the numbers

- Pull the whole session's usage series with the `jq` one-liner up top; judge
  the shape, not a single point;
- interpret with the three readings from "The cache on one page";
- reference values (our long-session measurements): with everything above in
  place, regular turns hit above 90%, and short inputs on long sessions sit
  at 99–100%; a resume-recovery turn can inherit the previous turn's cache in
  full (`read` exactly equals the previous turn's `read + create`, zero
  collapse).
  One exception: **when the previous turn ran a long tool chain, the recovery
  turn falls short by a slice** — a request carries at most 4 cache
  breakpoints (`cache_control`), so five-plus tool calls in one turn push the
  earlier breakpoints out, and the recovery turn / keepalive probe can only
  hit up to some middle step of the chain (one measurement: a +3,791 gap,
  with `read` exactly equal to the value as of the chain's second step).
  This is the breakpoint budget's mechanical ceiling, not your replica being
  off — don't chase it as a failure.
  Note: our environment runs the root fix for the midnight date issue from
  the "Principle" section; a stock setup on a resume-per-turn runtime takes
  one additional predictable full rewrite per day, so its long-run average
  hit rate will sit slightly below these numbers.

## Boundaries and known facts

- **OpenAI's rules are nearly identical**: tool definitions live in the
  cached prefix, changing a name/schema/ordering likewise voids it, writes
  1.25× / reads 0.1×, 30-minute TTL. Switching providers does not opt you out
  of this logic.
- **Debugging has a bottom**: if one collapse survives every check on this
  page, stop digging locally. We have seen a class of `read=0` that does not
  reproduce under identical conditions, where the very next turn reads back
  the cache line built *before* the collapse — the old line was alive the
  whole time, it just failed to match once. Rare (3 in 200+ turns in one
  day); accepting it beats mis-blaming your own config.
- Everything here was measured on Claude Code 2.1.175; after upgrades,
  re-verify on low-stakes traffic first.
- Keepalive is a cost optimization, not a necessity. Short-input, regular
  automated requests are themselves a recognizable usage shape — weigh it
  yourself; this document's stance is that randomization and
  "follow real activity" are the polite defaults, not that keepalive should
  be pushed to its limits.

## License

[MIT](LICENSE)
