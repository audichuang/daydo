#!/usr/bin/env node
// Drives the DayDo MCP tools through `claude -p` in the temp dir made by mcp-login.mjs and
// asserts on the tool_result JSON in the stream (never on the model's prose), cross-checked
// against a device pull.
//   node claude-assert.mjs read       list_projects + get_project_data(verify-seed): task count == device active count
//   node claude-assert.mjs write      create_task "verify-probe <UTC>" in verify-seed; device sees it (status 0)
//   node claude-assert.mjs complete   complete_task on that probe; device sees status 2 + completedAt
//   node claude-assert.mjs all        read, write, complete in order
// Options: --model <alias> (default haiku). Evidence: claude-<step>.jsonl, claude-<step>.json, probe.json.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { SCRIPTS_DIR, cfg, die, parseArgs, readJson, redact, runDir, saveEvidence, statePath } from './lib.mjs';

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
        let json = null;
        try {
          json = JSON.parse(text);
        } catch {
          // tool errors are plain text ("Error: …")
        }
        calls.push({ tool: use.name.replace(/^mcp__daydo-verify__/, ''), input: use.input, isError: Boolean(c.is_error), json, text: text.slice(0, 300) });
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
  const summary = { step, model, mcpStatus: out.mcpStatus, result: out.result, calls: out.calls.map(({ tool, input, isError, text }) => ({ tool, input, isError, text: isError ? text : undefined })), checks: conds, failed };
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
  const probe = { title, id: ct?.json?.id ?? null, projectId: seed.projectId };
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

const step = args._[0];
if (step === 'read') read();
else if (step === 'write') write();
else if (step === 'complete') complete();
else if (step === 'all') {
  read();
  write();
  complete();
} else die('usage: claude-assert.mjs read|write|complete|all [--model haiku]', 2);
