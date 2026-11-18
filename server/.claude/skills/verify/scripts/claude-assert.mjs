#!/usr/bin/env node
// Drives the DayDo MCP tools through `claude -p` in the temp dir made by mcp-login.mjs and
// asserts on the tool_result JSON in the stream (never on the model's prose), cross-checked
// against a device pull.
//   node claude-assert.mjs read           list_projects + get_project_data(verify-seed): task count == device active count
//   node claude-assert.mjs write          create_task "verify-probe <UTC>" in verify-seed; device sees it (status 0)
//   node claude-assert.mjs complete       complete_task on that probe; device sees status 2 + completedAt
//   node claude-assert.mjs attachment     get_task + get_attachment + upload_attachment against attachment-probe.json + device GET
//   node claude-assert.mjs uncomplete     complete_task then uncomplete_task on probe; device sees status 0
//   node claude-assert.mjs trash-restore  device trash probe -> search_tasks(include_deleted) -> get_task(include_deleted) -> restore_task -> device deletedAt null
//   node claude-assert.mjs all            read, write, complete, uncomplete, trash-restore in order (run attachment separately after device.mjs attach)
// Options: --model <alias> (default haiku). Evidence: claude-<step>.jsonl, claude-<step>.json, probe.json.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { SCRIPTS_DIR, cfg, die, parseArgs, readBoundSession, readJson, recordProbe, redact, runDir, saveEvidence, statePath } from './lib.mjs';

const args = parseArgs(process.argv.slice(2));
const model = args.model ?? 'haiku';
const dir = fs.existsSync(statePath('claude-dir')) ? fs.readFileSync(statePath('claude-dir'), 'utf8').trim() : '';
if (!dir || !fs.existsSync(path.join(dir, '.mcp.json'))) die('no Claude Code temp dir; run mcp-login.mjs first', 2);

function device(...argv) {
  const r = spawnSync(process.execPath, [path.join(SCRIPTS_DIR, 'device.mjs'), ...argv], { encoding: 'utf8', env: process.env });
  const last = (r.stdout ?? '').trim().split('\n').pop();
  let data = null;
  try {
    data = JSON.parse(last);
  } catch {
    // not JSON
  }
  return { status: r.status, data, stderr: r.stderr };
}

/** Runs one `claude -p` turn restricted to the given daydo tools; returns parsed tool calls. */
function claude(step, prompt, tools) {
  const env = { ...process.env, ...(cfg.claudeConfigDir && { CLAUDE_CONFIG_DIR: cfg.claudeConfigDir }) };
  const argv = [
    '-p', prompt,
    '--output-format', 'stream-json', '--verbose',
    '--model', model,
    '--tools', '',
    '--allowedTools', ...tools.map((t) => `mcp__daydo-verify__${t}`),
    '--permission-mode', 'dontAsk',
    '--strict-mcp-config', '--mcp-config', '.mcp.json',
    '--setting-sources', 'project,local',
    '--no-session-persistence',
  ];
  const r = spawnSync('claude', argv, { cwd: dir, env, encoding: 'utf8', timeout: 300_000, maxBuffer: 64 * 1024 * 1024 });
  const lines = (r.stdout ?? '').split('\n').filter(Boolean);
  fs.writeFileSync(path.join(runDir(), `claude-${step}.jsonl`), `${lines.map(redact).join('\n')}\n`);
  const events = lines.map((l) => {
    try {
      return JSON.parse(l);
    } catch {
      return null;
    }
  }).filter(Boolean);
  const uses = new Map();
  const calls = [];
  for (const e of events) {
    const content = e.message?.content;
    if (!Array.isArray(content)) continue;
    for (const c of content) {
      if (e.type === 'assistant' && c.type === 'tool_use') uses.set(c.id, { name: c.name, input: c.input });
      if (e.type === 'user' && c.type === 'tool_result') {
        const use = uses.get(c.tool_use_id) ?? { name: '?', input: null };
        const text = Array.isArray(c.content) ? c.content.filter((x) => x.type === 'text').map((x) => x.text).join('') : String(c.content ?? '');
        const images = Array.isArray(c.content)
          ? c.content
              .filter((x) => x.type === 'image')
              .map((x) => ({
                mimeType: x.source?.media_type ?? x.mimeType ?? null,
                hasData: Boolean(x.source?.data ?? x.data),
              }))
          : [];
        let json = null;
        try {
          json = JSON.parse(text);
        } catch {
          // tool errors are plain text ("Error: …")
        }
        calls.push({ tool: use.name.replace(/^mcp__daydo-verify__/, ''), input: use.input, isError: Boolean(c.is_error), json, images, text: text.slice(0, 300) });
      }
    }
  }
  const result = events.find((e) => e.type === 'result') ?? null;
  const init = events.find((e) => e.type === 'system' && e.subtype === 'init') ?? null;
  const mcpStatus = init?.mcp_servers?.find((s) => s.name === 'daydo-verify')?.status ?? null;
  return { exit: r.status, calls, mcpStatus, result: result && { is_error: result.is_error, subtype: result.subtype, num_turns: result.num_turns, total_cost_usd: result.total_cost_usd, text: String(result.result ?? '').slice(0, 200) }, stderr: (r.stderr ?? '').slice(-500) };
}

function check(step, out, conds) {
  const failed = Object.entries(conds).filter(([, ok]) => !ok).map(([k]) => k);
  const summary = {
    step,
    model,
    mcpStatus: out.mcpStatus,
    result: out.result,
    calls: out.calls.map(({ tool, input, isError, images, text }) => ({
      tool,
      input,
      isError,
      ...(images?.length ? { images } : {}),
      text: isError ? text : undefined,
    })),
    checks: conds,
    failed,
  };
  saveEvidence(`claude-${step}.json`, summary);
  console.log(JSON.stringify({ step, ok: failed.length === 0, failed, cost: out.result?.total_cost_usd ?? null }));
  if (failed.length) die(`${step} failed: ${failed.join(', ')}; see ${runDir()}/claude-${step}.json`);
}

function seedState() {
  const pull = device('pull', '--label', 'claude');
  if (pull.status !== 0 || !pull.data?.projectId) die(`device pull failed or ${cfg.seedProject} missing: ${pull.stderr}`, 2);
  return pull.data;
}

function read() {
  const seed = seedState();
  const out = claude('read', `Call the daydo tool list_projects, then get_project_data for the project named "${cfg.seedProject}". Reply with only the number of tasks.`, ['list_projects', 'get_project_data']);
  const lp = out.calls.find((c) => c.tool === 'list_projects' && !c.isError);
  const listed = Array.isArray(lp?.json) ? lp.json.find((p) => p.name === cfg.seedProject) : null;
  const gpd = out.calls.find((c) => c.tool === 'get_project_data' && !c.isError);
  const tasks = gpd?.json?.tasks;
  check('read', out, {
    connected: out.mcpStatus === 'connected',
    listProjectsHasSeed: listed?.id === seed.projectId,
    getProjectDataForSeed: gpd?.input?.project_id === seed.projectId,
    taskCountMatchesDevice: Array.isArray(tasks) && tasks.length === seed.active,
    allOpen: Array.isArray(tasks) && tasks.every((t) => t.status === 0),
  });
}

function write() {
  const seed = seedState();
  const title = `${cfg.probePrefix} ${new Date().toISOString().replace(/\.\d+Z$/, 'Z')}`;
  const out = claude('write', `Call the daydo tool create_task with project_id "${seed.projectId}" and title "${title}". Do nothing else.`, ['create_task']);
  const ct = out.calls.find((c) => c.tool === 'create_task' && !c.isError);
  const found = device('find', '--title', title, '--status', '0');
  const probeId = ct?.json?.id ?? found.data?.id ?? null;
  const session = readBoundSession();
  if (session?.userId && probeId) {
    recordProbe(session.userId, { id: probeId, title, projectId: seed.projectId });
  }
  const probe = { title, id: probeId, projectId: seed.projectId };
  fs.writeFileSync(path.join(runDir(), 'probe.json'), `${JSON.stringify(probe, null, 2)}\n`);
  check('write', out, {
    createTaskOk: Boolean(ct),
    toolTitle: ct?.json?.title === title,
    toolProject: ct?.json?.project_id === seed.projectId,
    devicePullHasTask: found.status === 0 && found.data?.id === probe.id,
  });
}

function complete() {
  const probe = readJson(path.join(runDir(), 'probe.json'));
  if (!probe?.id) die('no probe.json in this run; run the write step first', 2);
  const out = claude('complete', `Call the daydo tool complete_task with project_id "${probe.projectId}" and task_id "${probe.id}". Do nothing else.`, ['complete_task']);
  const ct = out.calls.find((c) => c.tool === 'complete_task' && !c.isError);
  const found = device('find', '--title', probe.title, '--status', '2');
  check('complete', out, {
    completeTaskOk: Boolean(ct),
    toolStatus2: ct?.json?.status === 2,
    devicePullStatus2: found.status === 0 && Number(found.data?.status) === 2 && Boolean(found.data?.completedAt),
  });
}

function attachment() {
  const probe = readJson(statePath('attachment-probe.json'));
  if (!probe?.taskId || !probe?.projectId || !Array.isArray(probe?.attachments) || !probe.attachments.length) {
    die('no attachment-probe.json; run device.mjs attach first', 2);
  }
  const uploadFileName = 'claude-upload.txt';
  const uploadText = `MCP upload_attachment verify ${new Date().toISOString()}\n中文確認\n`;
  const uploadBase64 = Buffer.from(uploadText, 'utf8').toString('base64');
  const uploadSize = Buffer.byteLength(uploadText, 'utf8');
  const attIds = probe.attachments.map((a) => a.id).join(', ');
  const prompt =
    `On project_id "${probe.projectId}" and task_id "${probe.taskId}":\n` +
    `1. Call get_task for that project_id and task_id.\n` +
    `2. Call get_attachment for each of these attachment_ids: ${attIds}.\n` +
    `3. Call upload_attachment with project_id "${probe.projectId}", task_id "${probe.taskId}", filename "${uploadFileName}", content_type "text/plain", and content_base64 "${uploadBase64}".\n` +
    `4. After upload_attachment succeeds, call get_task again for project_id "${probe.projectId}" and task_id "${probe.taskId}".\n` +
    'Do nothing else.';
  const out = claude('attachment', prompt, ['get_task', 'get_attachment', 'upload_attachment']);

  const gt = out.calls.find((c) => c.tool === 'get_task' && !c.isError && c.input?.task_id === probe.taskId);
  const listedAtts = gt?.json?.attachments;
  const getTaskListsAllAttachments =
    Array.isArray(listedAtts) &&
    probe.attachments.every((att) =>
      listedAtts.some(
        (a) =>
          a.id === att.id &&
          a.file_name === att.fileName &&
          Number(a.size) === att.size &&
          a.mime_type === att.mimeType,
      ),
    );

  const perAttChecks = {};
  for (const att of probe.attachments) {
    const ga = out.calls.find((c) => c.tool === 'get_attachment' && !c.isError && c.input?.attachment_id === att.id);
    if (att.kind === 'text') {
      perAttChecks.getAttachmentTextOk = Boolean(ga) && ga.json?.content === att.expectedText;
    } else if (att.kind === 'empty') {
      perAttChecks.getAttachmentEmptyOk = Boolean(ga) && ga.json?.id === att.id && Number(ga.json?.size) === 0 && ga.json?.content === '';
    } else if (att.kind === 'png-no-type') {
      perAttChecks.getAttachmentPngOk = Boolean(ga) && ga.images.some((img) => img.mimeType === 'image/png' && img.hasData);
    } else {
      perAttChecks[`getAttachment_${att.kind}`] = Boolean(ga);
    }
  }

  const up = out.calls.find((c) => c.tool === 'upload_attachment' && !c.isError);
  const uploadedId = up?.json?.id;
  const upIdx = up ? out.calls.indexOf(up) : -1;
  const gtAfterUpload =
    upIdx >= 0
      ? out.calls.slice(upIdx + 1).find((c) => c.tool === 'get_task' && !c.isError && c.input?.task_id === probe.taskId)
      : null;
  const getTaskAfterUploadHasUploaded =
    Boolean(uploadedId) &&
    Array.isArray(gtAfterUpload?.json?.attachments) &&
    gtAfterUpload.json.attachments.some(
      (a) =>
        a.id === uploadedId &&
        a.file_name === uploadFileName &&
        Number(a.size) === uploadSize &&
        a.mime_type === 'text/plain',
    );
  const dev = uploadedId
    ? device('get-attachment', '--id', uploadedId, '--expect-base64', uploadBase64, '--expect-type', 'text/plain')
    : { status: 1, data: null };

  check('attachment', out, {
    connected: out.mcpStatus === 'connected',
    getTaskOk: Boolean(gt) && gt.json?.id === probe.taskId,
    getTaskListsAllAttachments,
    ...perAttChecks,
    uploadAttachmentOk: Boolean(uploadedId) && up.json?.file_name === uploadFileName && Number(up.json?.size) === uploadSize,
    getTaskAfterUploadHasUploaded,
    deviceGetUploadedMatches: dev.status === 0 && dev.data?.sameBytes === true,
  });
}

function uncomplete() {
  const probe = readJson(path.join(runDir(), 'probe.json'));
  if (!probe?.id) die('no probe.json in this run; run the write step first', 2);
  const out = claude(
    'uncomplete',
    `Call the daydo tool complete_task with project_id "${probe.projectId}" and task_id "${probe.id}", then call uncomplete_task with project_id "${probe.projectId}" and task_id "${probe.id}". Do nothing else.`,
    ['complete_task', 'uncomplete_task'],
  );
  const ct = out.calls.find((c) => c.tool === 'complete_task' && !c.isError);
  const ut = out.calls.find((c) => c.tool === 'uncomplete_task' && !c.isError);
  const st = device('task-status', '--id', probe.id);
  check('uncomplete', out, {
    connected: out.mcpStatus === 'connected',
    completeTaskOk: Boolean(ct) && ct.json?.id === probe.id && ct.json?.status === 2,
    uncompleteTaskOk: Boolean(ut) && ut.json?.id === probe.id && ut.json?.status === 0 && ut.json?.completed_at === null,
    devicePullStatus0: st.status === 0 && Number(st.data?.status) === 0 && st.data?.completedAt === null,
  });
}

function trashRestore() {
  const probe = readJson(path.join(runDir(), 'probe.json'));
  if (!probe?.id || !probe?.title) die('no probe.json in this run; run the write step first', 2);
  const trashed = device('trash', '--id', probe.id);
  if (trashed.status !== 0 || !trashed.data?.deletedAt) {
    die(`device trash failed for ${probe.id}: ${trashed.stderr || JSON.stringify(trashed.data)}`);
  }
  const out = claude(
    'trash-restore',
    `A task titled "${probe.title}" was moved to the trash. Search for it by title using search_tasks with include_deleted: true, then call get_task with include_deleted: true for the matching task, and then call restore_task to restore it. Do nothing else.`,
    ['search_tasks', 'get_task', 'restore_task'],
  );
  const st = out.calls.find((c) => c.tool === 'search_tasks' && !c.isError && c.input?.include_deleted === true);
  const gt = out.calls.find((c) => c.tool === 'get_task' && !c.isError && c.input?.task_id === probe.id && c.input?.include_deleted === true);
  const rt = out.calls.find((c) => c.tool === 'restore_task' && !c.isError && c.input?.task_id === probe.id);
  const dev = device('task-status', '--id', probe.id);
  check('trash-restore', out, {
    connected: out.mcpStatus === 'connected',
    searchFoundDeleted:
      Array.isArray(st?.json) && st.json.some((t) => t.id === probe.id && t.title === probe.title && t.deleted === true),
    getTaskIncludeDeleted: gt?.json?.id === probe.id && gt?.json?.deleted === true,
    restoreTaskOk: rt?.json?.id === probe.id,
    devicePullRestored: dev.status === 0 && dev.data?.found === true && dev.data?.deletedAt === null,
  });
}

const step = args._[0];
if (step === 'read') read();
else if (step === 'write') write();
else if (step === 'complete') complete();
else if (step === 'attachment') attachment();
else if (step === 'uncomplete') uncomplete();
else if (step === 'trash-restore') trashRestore();
else if (step === 'all') {
  read();
  write();
  complete();
  uncomplete();
  trashRestore();
} else die('usage: claude-assert.mjs read|write|complete|attachment|uncomplete|trash-restore|all [--model haiku]', 2);
