# Codex Task: Fix OpenClaw Compaction Retry (Issue #20873)

## The Problem

OpenClaw's auto-compaction (conversation summarization to free context window space) fails silently when the provider returns a transient error (401, 429, 503, etc.) because `maxAttempts` is hardcoded to `1` for pre-emptive compaction.

**Issue:** https://github.com/openclaw/openclaw/issues/20873

### Why This Matters Now

Anthropic has been actively blocking OAuth subscription tokens (Claude Max/Pro) from working outside their official Claude Code CLI since January 2026:
- Jan 9, 2026: Server-side safeguards deployed
- Jan 27: Accounts suspended for ToS Section 3.7 violations
- Feb 18: Docs updated — OAuth tokens explicitly banned for all third-party tools
- Feb 19: YouTube/Reddit coverage ("Anthropic Just BANNED OpenClaw")

**The practical impact:** Users running OpenClaw with Anthropic OAuth tokens see their main chat session work (OpenClaw may have workarounds in the chat stream path), but secondary API calls like compaction and image analysis get 401 "Invalid bearer token" rejections. With `maxAttempts=1`, one failed compaction attempt means the session context keeps growing until it overflows, forcing a hard session reset and losing the conversation.

Even for users with legitimate API keys (not OAuth), transient 401s during token refresh, rate limits (429), or provider outages (503) cause the same cascade: single failure → no retry → context overflow → session death.

### The Failure Chain (from issue author + our own logs)

```
1. Session reaches maxHistoryShare threshold → pre-emptive compaction triggers
2. Provider returns 401 (OAuth block, token refresh race, transient error)
3. maxAttempts=1 → compaction gives up after single failure
4. Context continues growing → overflow → forced session reset
5. Conversation continuity broken
```

### Current Code

The hardcoded `maxAttempts = 1` is in the compaction runner:

```js
const maxAttempts = params.maxAttempts ?? 1;
```

The overflow path already has `MAX_OVERFLOW_COMPACTION_ATTEMPTS = 3` — so retry infrastructure exists, it's just not exposed for pre-emptive compaction.

Compaction diagnostics already log `attempt/maxAttempts`:
```
[agent/embedded] [compaction-diag] end ... attempt=1 maxAttempts=1 outcome=failed reason=provider_error_4xx
```

## The Fix

### 1. Expose `compaction.maxAttempts` as a config option

**Config schema change:**
```json5
{
  agents: {
    defaults: {
      compaction: {
        maxAttempts: 3,           // NEW — default: 3 (was hardcoded to 1)
        retryDelayMs: 2000,       // NEW — delay between retry attempts
        mode: "safeguard",
        reserveTokensFloor: 24000,
        // ... existing options
      }
    }
  }
}
```

### 2. Implement retry logic with backoff

When compaction fails with a retryable error (401, 429, 503, 502, connection timeout):
- Wait `retryDelayMs` (default 2000ms)
- Retry up to `maxAttempts` (default 3)
- Use exponential backoff: `retryDelayMs * attempt` (2s, 4s, 6s)
- Log each attempt via existing `[compaction-diag]` infrastructure

**Non-retryable errors** (400 bad request, 413 payload too large) should NOT retry — fail immediately.

### 3. Consistency with overflow path

The overflow compaction path already does this:
```js
const MAX_OVERFLOW_COMPACTION_ATTEMPTS = 3;
```

The fix should make pre-emptive compaction consistent with overflow compaction. Ideally, both paths read from the same `compaction.maxAttempts` config, with overflow having its own floor (minimum 3 even if config says 1).

## Where To Look

You'll need to find:
1. The compaction runner that has `const maxAttempts = params.maxAttempts ?? 1;`
2. The config schema/validation that defines the `compaction` config object
3. The overflow compaction path that has `MAX_OVERFLOW_COMPACTION_ATTEMPTS = 3`
4. The `[compaction-diag]` logging to ensure attempts are properly tracked

Start with:
```bash
# Find the compaction runner
grep -r "maxAttempts" src/ --include="*.ts" --include="*.js"
grep -r "compaction-diag" src/ --include="*.ts" --include="*.js"
grep -r "MAX_OVERFLOW_COMPACTION_ATTEMPTS" src/ --include="*.ts" --include="*.js"

# Find the config schema
grep -r "compaction" src/ --include="*.ts" | grep -i "schema\|config\|zod\|type"
```

## Test Plan

1. **Unit test:** Mock provider returning 401, verify retry logic fires up to `maxAttempts` times with correct delays
2. **Unit test:** Mock provider returning 400, verify NO retry (non-retryable)
3. **Unit test:** Mock provider returning 401 twice then 200, verify compaction succeeds on third attempt
4. **Integration test:** Set `compaction.maxAttempts: 1` in config, verify old behavior preserved
5. **Integration test:** Set `compaction.maxAttempts: 5` in config, verify all 5 attempts are made
6. **Log test:** Verify `[compaction-diag]` shows correct `attempt=N maxAttempts=M` for each try

## PR Guidelines

This PR should follow the repo's AI-assisted PR guidelines:

- **Title:** `fix: add configurable compaction.maxAttempts with retry logic (fixes #20873) [AI-assisted]`
- **Mark as AI-assisted** in PR description
- **Testing level:** Include what testing was done (unit tests, integration, manual)
- **Include this prompt** as context for reviewers
- **Confirm understanding:** The fix adds retry logic to pre-emptive compaction to match the resilience already present in overflow compaction, preventing silent session death from transient provider errors

## Context for Reviewers

**Why this matters beyond the immediate fix:**

Anthropic's ongoing enforcement against OAuth tokens in third-party tools (started Jan 2026) means a growing number of OpenClaw users will experience transient 401s during the OAuth→API key migration period. Without retry logic, every transient auth failure during compaction kills the session. This fix provides resilience during that transition and also protects against normal transient provider errors (rate limits, outages).

The fix is minimal and backward-compatible:
- Default `maxAttempts: 3` improves resilience out of the box
- Users can set `maxAttempts: 1` to preserve current behavior
- No changes to the compaction algorithm itself — only the retry wrapper
- Consistent with existing overflow retry logic
