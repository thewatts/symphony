---
name: debug
description:
  Investigate unexpected agent behavior, failed turns, or stalled runs by
  reading logs, inspecting workspace state, and identifying root cause.
---

# Debug

## When To Use

- A turn completed but left the issue in an unexpected state.
- A turn failed with an error and it's not clear why.
- Claude appeared to loop or stall without making progress.
- A tool call (`shortcut_api`) returned an error that needs investigation.

## Inputs

- Symphony logs (check `logs/` under the workspace root, or stdout if running
  locally).
- The issue state in Shortcut.
- The workspace state (git status, working tree, any temp files left behind).

## Steps

1. **Check Symphony logs** for the issue identifier:
   ```sh
   grep "issue_identifier=<ID>" /path/to/logs/*.log | tail -50
   ```

2. **Check the last Claude turn events** — look for `turn_ended_with_error` or
   `tool_call_failed` events in the log output.

3. **Inspect workspace state**:
   ```sh
   cd /path/to/workspaces/<issue-identifier>
   git status
   git log --oneline -10
   ```

4. **Check Shortcut story state** using the `shortcut_api` tool:
   ```json
   { "method": "GET", "path": "/stories/<story-id>" }
   ```
   Verify `workflow_state`, `owner_ids`, and recent `comments`.

5. **Identify root cause** — common causes:
   - `{:api_error, 401, _}` — `ANTHROPIC_API_KEY` is missing or invalid.
   - `{:api_error, 429, _}` — rate limited; check token usage and model.
   - `{:api_error, 529, _}` — Anthropic overloaded; retries will help.
   - `{:missing_shortcut_api_token}` — `SHORTCUT_API_TOKEN` not set.
   - `{:shortcut_state_not_found, name}` — state name in `WORKFLOW.md`
     doesn't match any state in the workflow; check spelling.
   - Turn stalled without `turn_completed` — check `stall_timeout_ms` and
     whether the model was producing output.

6. **Fix and re-queue** — if the issue is recoverable, move the Shortcut story
   back to an active state so Symphony picks it up again on the next poll cycle.

## Useful Log Patterns

```
# All events for a specific issue
grep "issue_identifier=sc-12345" symphony.log

# Turn completions and errors
grep "turn_completed\|turn_ended_with_error\|tool_call_failed" symphony.log

# API errors
grep "api_error\|api_request_failed" symphony.log

# Token usage
grep "input_tokens\|output_tokens" symphony.log
```

## Notes

- Symphony does not delete workspaces on failure — the workspace is preserved
  for inspection after a failed turn.
- If the workspace is in a broken git state (detached HEAD, failed merge),
  reset it before re-queuing: `git checkout main && git reset --hard origin/main`.
