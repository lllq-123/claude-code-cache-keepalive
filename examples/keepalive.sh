#!/usr/bin/env bash
# Minimal prompt-cache keepalive for one Claude Code session.
#
# Run from cron every minute or two. It fires only when the session has been
# idle longer than a randomized threshold (default 50-58 min against the 1h
# cache TTL), so most invocations exit immediately and cost nothing.
#
# Usage:   keepalive.sh <session-id> <transcript-path>
# Example: keepalive.sh 9f06b231-... ~/.claude/projects/-home-you/9f06b231-....jsonl
#
# Requirements: claude CLI on PATH, jq.
#
# IMPORTANT: run this with the same env and cwd as the main session process.
# The fidelity of the replica decides whether the probe hits the cache —
# a mismatched env var or cwd silently builds a NEW cache line instead
# (billed at write rates, keeping nothing alive). Verify cache_read > 0.

set -euo pipefail

SESSION_ID="${1:?usage: keepalive.sh <session-id> <transcript-path>}"
TRANSCRIPT="${2:?usage: keepalive.sh <session-id> <transcript-path>}"

TTL_FLOOR_MIN=50   # fire no earlier than this many idle minutes
TTL_SPREAD_MIN=9   # randomized spread: threshold lands in [50, 58]

now=$(date +%s)
# Idle basis = transcript mtime. Coarse but dependency-free: merely resuming
# a session also appends metadata and bumps mtime. Good enough for a demo;
# a production probe should track "last real model request" instead.
last=$(stat -c %Y "$TRANSCRIPT" 2>/dev/null || stat -f %m "$TRANSCRIPT")
idle=$(( now - last ))

# Derive the threshold from the activity timestamp itself: the same idle
# period always yields the same target (stable across cron ticks), yet the
# value varies cycle to cycle — randomized without being jittery.
threshold=$(( (TTL_FLOOR_MIN + last % TTL_SPREAD_MIN) * 60 ))

if (( idle < threshold )); then
  exit 0
fi

# Bypass-resume ping: a short-lived process resumes the same session.
# --no-session-persistence keeps this turn OUT of the transcript, so the
# main session's history (and thus its cache prefix) stays untouched.
out=$(timeout 60 claude -p --resume "$SESSION_ID" --no-session-persistence \
        --output-format json "Reply with exactly: ok" 2>/dev/null)

cache_read=$(jq -r '.usage.cache_read_input_tokens // 0' <<<"$out")
cache_create=$(jq -r '.usage.cache_creation_input_tokens // 0' <<<"$out")

if (( cache_read > 0 )); then
  echo "$(date -Is) keepalive OK   cache_read=$cache_read create=$cache_create"
else
  # read=0 with a large create means the replica did not match the main
  # session's prefix: this request built a separate cache line and kept
  # nothing alive. Diff your flags, env, and cwd against the main process.
  echo "$(date -Is) keepalive MISS cache_read=$cache_read create=$cache_create (new cache line?)" >&2
  exit 1
fi
