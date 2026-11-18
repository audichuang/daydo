# Task attachments

A user's device attaches files to tasks by syncing an `attachment` row and transferring raw bytes through `PUT /attachments/{id}/content` and `GET /attachments/{id}/content` on the API host. An AI client connected to DayDo MCP can inspect a task's attachments with `get_task`, read text or image attachments with `get_attachment` (including magic-byte sniffing for untyped `application/octet-stream` PNGs and 0-byte files), and attach new files with `upload_attachment` that the device can immediately download byte-for-byte.

## Sub-features

- `put-get-attachment-content`: push an `attachment` row over `/sync/push`, `PUT /attachments/{id}/content` (204), and `GET /attachments/{id}/content` (200) matching exact bytes and `Content-Type`.
- `unauthenticated-get-401`: `GET /attachments/{id}/content` on the API host without a Bearer token returns 401.
- `mcp-host-gate-404`: anonymous `GET /attachments/{id}/content` on the MCP host (`cfg.mcp` origin, without `Authorization`) returns 404.
- `empty-attachment`: `--empty` uploads a 0-byte `text/plain` attachment; `GET` returns 0 bytes and `get_attachment` succeeds without error.
- `png-magic-byte-sniff`: `--png-no-type` uploads a small valid PNG labeled `application/octet-stream`; `get_attachment` sniffs its header and returns MCP image content with `mimeType: image/png`.
- `mcp-get-task-attachments`: `get_task` returns full `attachments` entries (`id`, `file_name`, `size`, `mime_type`).
- `mcp-get-attachment`: `get_attachment` decodes UTF-8 `text/plain` content and returns image content for PNGs.
- `mcp-upload-attachment`: `upload_attachment` stores bytes in R2 and creates the `attachment` row, verified by a device `GET /attachments/{id}/content`.

## How to get to it (user POV)

- On the iOS App, adding an attachment syncs the `attachment` row and uploads/downloads file bytes via `PUT`/`GET /attachments/{id}/content` on `api.daydoapp.com`.
- In Claude Code (or any connected MCP client), ask to inspect or attach files on a task; the model calls `mcp__daydo-verify__get_task`, `mcp__daydo-verify__get_attachment`, and `mcp__daydo-verify__upload_attachment`.

## Driving it with daydo-verify scripts

Preconditions:

- [Email sign-in](./email-sign-in.md) and the bootstrap step of [device sync](./device-sync.md) succeeded, so the device session has `meMemberId` and `inboxProjectId`.
- For the MCP assertion step, [Connect Claude Code](./mcp-connect.md) succeeded.

- **Device attach.** Run `node $S/device.mjs attach --empty --png-no-type`.
  - Records the probe task ID into `<state>/probe-ledger.<host>.<hash>.<userId>.json` before pushing (so interrupted pushes stay cleanable), creates `${probePrefix} attachment <UTC>` in the inbox, pushes the `attachment` rows (UTF-8 Chinese `text/plain`, optional 0-byte file, optional `application/octet-stream` PNG), `PUT`s and `GET`s each file, verifies unauthenticated `GET` returns 401 and anonymous MCP-host `GET` returns 404, and writes `<state>/attachment-probe.json` and `<run>/attach.json`.
- **MCP attachment assertions.** Run `node $S/claude-assert.mjs attachment`.
  - Checks (in `<run>/claude-attachment.json`):
    - `connected`
    - `getTaskOk`, `getTaskListsAllAttachments` (verifies `id`, `file_name`, `size`, and `mime_type`)
    - `getAttachmentTextOk` (`content` matches uploaded text), `getAttachmentEmptyOk` (when `--empty`: `size: 0`, `content: ""`), `getAttachmentPngOk` (when `--png-no-type`: image content block with `mimeType: "image/png"`)
    - `uploadAttachmentOk`
    - `getTaskAfterUploadHasUploaded` (second `get_task` after `upload_attachment` lists the uploaded attachment with matching `id`, `file_name`, `size`, and `mime_type`)
    - `deviceGetUploadedMatches` (`device.mjs get-attachment` reads back identical bytes and `text/plain`)
- **Proof.** `<run>/attach.json`, `<run>/claude-attachment.json`, `<run>/claude-attachment.jsonl`, and `device.log`.
- **Cleanup.** `bash $S/cleanup.sh` runs `device.mjs purge-probes`, which sends `op: 'delete'` only for probe task IDs recorded in this account+target's probe ledger so the server removes each task and best-effort deletes its `att/<taskId>/` R2 prefix.

## Gotchas

- `PUT /attachments/{id}/content` enforces that `Content-Length` and the actual body length equal the `attachment` row's `size`; mismatches fail with 400.
- Server-side R2 cleanup on task purge is **best-effort**: `GET /attachments/{id}/content` on a purged task returns 404 before checking R2, so a 404 after `purge-probes` does not prove R2 object removal, and cleanup does not claim R2 deletion is verified.
- `get_attachment` only sniffs image magic bytes (PNG/JPEG/GIF/WebP) when the row's `mimeType` is `application/octet-stream` and `size > 0`.
- `device.mjs attach` puts its probe task in the inbox (`inboxProjectId`), not `verify-seed`, so `find`, `delete-probes`, and `purge-probes` scan across all scopes (while `delete-probes` / `purge-probes` still restrict to IDs in this account's probe ledger).
