---
name: shortcut
description:
  Interact with Shortcut (issue tracker) via the shortcut_api tool — read and
  update stories, post comments, and transition workflow states.
---

# Shortcut

Use the injected `shortcut_api` tool to make authenticated requests to the
Shortcut REST API v3. All paths are relative to `/api/v3`.

## Common Operations

### Get the current story

```json
{ "method": "GET", "path": "/stories/{{ issue.id }}" }
```

### Post a comment

```json
{
  "method": "POST",
  "path": "/stories/{{ issue.id }}/comments",
  "body": { "text": "Your comment here." }
}
```

### Update story state

First fetch the workflow to find the target state ID:

```json
{ "method": "GET", "path": "/workflows/{{ workflow_id }}" }
```

Then update:

```json
{
  "method": "PUT",
  "path": "/stories/{{ issue.id }}",
  "body": { "workflow_state_id": 123456 }
}
```

### Search stories in a workflow

```json
{
  "method": "POST",
  "path": "/stories/search",
  "body": {
    "workflow_id": 123456,
    "workflow_state_types": ["started"],
    "page_size": 25
  }
}
```

### Create a new story

```json
{
  "method": "POST",
  "path": "/stories",
  "body": {
    "name": "Story title",
    "description": "Description",
    "workflow_state_id": 123456,
    "project_id": null
  }
}
```

### Add a label to a story

Fetch current labels first, then PUT the full list back:

```json
{
  "method": "PUT",
  "path": "/stories/{{ issue.id }}",
  "body": { "labels": [{ "name": "label-name" }] }
}
```

## Workflow State Transitions

Symphony's `active_states` and `terminal_states` in `WORKFLOW.md` correspond to
Shortcut workflow state names. To transition a story, you need the numeric
`workflow_state_id`. Fetch the workflow once, cache the state names → IDs, then
use the ID in PUT requests.

## Notes

- Story IDs in Shortcut are integers (e.g. `12345`). The `issue.id` variable
  is a string representation of that integer.
- `issue.identifier` is formatted as `sc-{{ issue.id }}` by Symphony.
- The `shortcut_api` tool always returns a `success` boolean and an `output`
  string. Check `success` before trusting the output.
- Rate limit: 200 requests/minute per token. Batch reads where possible.
- Use `page_size` and the `next` cursor for paginated search results.
