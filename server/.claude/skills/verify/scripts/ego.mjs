// Runs ego-browser scripts in one persisted TaskSpace (id and page labels in
// <stateDir>/ego-space.json). Each call is a fresh Node process inside ego-browser, so inputs
// go in as a JSON literal and results come back on `__RESULT__ {...}` lines.
import { spawnSync } from 'node:child_process';
import { readJson, redact, statePath, writeJson } from './lib.mjs';

const SPACE_FILE = statePath('ego-space.json');

const PRELUDE = String.raw`
const P = JSON.parse(__PARAMS__);
// Only a space this skill created (name starts with "daydo-verify ") may be reused; a recorded id that now
// belongs to anything else (user space, id reuse) is discarded and a new space is created.
const entry = P.space.spaceId == null ? undefined : (await listTaskSpaces()).find((s) => s.id === P.space.spaceId && String(s.name ?? '').startsWith('daydo-verify '));
const task = !entry
  ? await taskSpace(P.spaceName)
  : entry.ownership === 'user'
    ? await claimTaskSpace(P.space.spaceId)
    : entry.ownership === 'agentDelegatedToUser'
      ? await takeOverTaskSpace(P.space.spaceId)
      : await taskSpace(P.space.spaceId);
const labels = { ...(entry ? P.space.pages : {}) };
async function pageFor(role) {
  // Never adopt existing tabs: always open our own page.
  let page = (await task.pages()).find((p) => p.label === labels[role]);
  if (!page) {
    page = await task.newPage();
    labels[role] = page.label;
  }
  return page;
}
function emit(result) {
  console.log('__EGO__ ' + JSON.stringify({ spaceId: task.spaceId, pages: labels }));
  console.log('__RESULT__ ' + JSON.stringify(result));
}
`;

/**
 * Runs `body` (JS using `P.args`, `task`, `pageFor(role)`, `emit(result)`) and returns the
 * parsed result. Throws with redacted output when the script prints no result.
 */
export function egoRun(body, args = {}, { timeoutMs = 240_000 } = {}) {
  const space = readJson(SPACE_FILE, { spaceId: null, pages: {} });
  const params = { args, space, spaceName: `daydo-verify ${new Date().toISOString()}` };
  const script = PRELUDE.replace('__PARAMS__', JSON.stringify(JSON.stringify(params))) + body;
  const res = spawnSync('ego-browser', ['nodejs'], { input: script, encoding: 'utf8', timeout: timeoutMs });
  // ego-browser prints the script's console output on stderr.
  const out = `${res.stdout ?? ''}\n${res.stderr ?? ''}`;
  const egoLine = out.split('\n').find((l) => l.startsWith('__EGO__ '));
  if (egoLine) writeJson(SPACE_FILE, JSON.parse(egoLine.slice(8)));
  const resultLine = out
    .split('\n')
    .reverse()
    .find((l) => l.startsWith('__RESULT__ '));
  if (!resultLine) {
    throw new Error(`ego-browser script produced no result (exit ${res.status}):\n${redact(out)}`);
  }
  return JSON.parse(resultLine.slice(11));
}

/** Finishes the persisted space (closes only pages it owns) and forgets it. */
export function egoFinish() {
  const space = readJson(SPACE_FILE, null);
  if (space?.spaceId == null) return { finished: false, reason: 'no space recorded' };
  const script = `
const entry = (await listTaskSpaces()).find((s) => s.id === ${Number(space.spaceId)});
if (!entry) { console.log('__RESULT__ ' + JSON.stringify({ finished: false, reason: 'space already gone' })); }
else if (!String(entry.name ?? '').startsWith('daydo-verify ')) {
  console.log('__RESULT__ ' + JSON.stringify({ finished: false, reason: 'recorded space is not ours; record discarded', spaceId: entry.id }));
} else {
  const task = entry.ownership === 'user' ? await claimTaskSpace(entry.id)
    : entry.ownership === 'agentDelegatedToUser' ? await takeOverTaskSpace(entry.id) : await taskSpace(entry.id);
  const out = await task.finish({ keep: [] });
  console.log('__RESULT__ ' + JSON.stringify({ finished: true, spaceId: entry.id, out: out ?? null }));
}`;
  const res = spawnSync('ego-browser', ['nodejs'], { input: script, encoding: 'utf8', timeout: 60_000 });
  const line = `${res.stdout ?? ''}\n${res.stderr ?? ''}`.split('\n').find((l) => l.startsWith('__RESULT__ '));
  const result = line ? JSON.parse(line.slice(11)) : { finished: false, reason: redact(`${res.stdout}${res.stderr}`) };
  if (result.finished || result.reason === 'space already gone' || String(result.reason).startsWith('recorded space is not ours')) writeJson(SPACE_FILE, { spaceId: null, pages: {} });
  return result;
}
