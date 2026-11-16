# deps-clock：db、DO stub、時鐘、env 接線收斂（架構審查候選 5）

- worktree：`/Users/audichuang/Project/ticktick-wt/deps-clock`，分支 `deps-clock`，base `b24c709`（`npm run check` 已綠）。
- 三張票依序做，同一 worktree 同一分支，票內每步一個 commit。不能平行：三張都會碰 `tests/architecture.test.ts`，票 2、3 都會碰 `tests/helpers/`。
- 指令都在 `server/` 跑。每個 commit 前 `npm run check:fast`；每張票結尾 `npm run check`（已含 `e2e:fault`）。
- 這份計畫做完就刪，該留的決策寫進 commit message、`server/GLOSSARY.md`、`server/AGENTS.md`。

## 0. 讀碼後對任務描述的更正

寫票前先知道這四件事，它們改變了範圍：

1. **「12 個測試檔各自 mock `cloudflare:workers`／`void/durable`／`void/db`」已不成立。** `tests/helpers/scopeMocks.ts` 已經是 `vite.config.ts` 的 `setupFiles`，全域生效。自帶 `vi.mock` 的只剩 `access.test.ts`（`void/env`）、`avatar.test.ts`（`void`、`void/db`、`void/env`）、`mcp-route.test.ts`（`void`、`void/env`、`durable-objects/scope`）、`validate-once.test.ts`（`src/sync/entities`）。真正被抄來抄去的是各檔開頭 59–181 行的 `createHarness`／`projectRow`／`taskRow`／`deviceOp`／`seedUser`／`seedBasic`／`call`／`pulled`（見票 3 的雜湊表）。票 3 的目標改成收這段。
2. **`Date.now` 還有兩處任務描述沒算到**：`src/ics/store.ts:225`、`:524` 是 `this.now = options.now ?? Date.now`（捕捉參照，沒有括號，所以 `Date.now()` 的 grep 找不到）。這也表示專案裡已經有「函式型時鐘」的前例（`options.now?: () => number`）。
3. **`createDb` 每呼叫一次就是一個新的 D1 session**（`node_modules/void/dist/dispatch-*.mjs`：`drizzle(d1.withSession(options?.session ?? …))`）。`crons/ics-sync.ts` 現在開兩個（清理一個、ICS 一個），`routes/index.ts` 一個 request 共用一個。factory 不能把它們合併或拆開。
4. **`uuidv7()` 的預設參數在 `src/` 沒有人用**（8 個呼叫端都傳了時間），只有 `tests/domain-basic.test.ts:37` 用到。

## 1. 全域約束（每張票都適用）

| # | 約束 | 落在哪張票的哪一步 |
|---|------|------|
| C1 | 行為不變；D1／DO schema 不變；Worker↔DO RPC 不變，不把 nowMs 加進 RPC；`src/scope/**` 不得 async | 三張票都**不碰** `durable-objects/**`、`src/scope/**`、`db/**`、`src/sync/push.ts`、`src/sync/push/**`。RPC 影響：三張票皆「無」 |
| C2 | `import.meta.env.DEV` 是 build-time 常數，不變成 runtime config | 四處（`src/auth/access.ts`、`src/ics/fetch.ts`、`src/mail/mailer.ts`、`durable-objects/scope.ts`）列入每張票的「不准碰」。factory 只呼叫 `selectMailer`／`parseInsecureHosts`，dev 判斷留在它們裡面 |
| C3 | clock 是 `() => Date.now()`，不捕捉參照；不合併一個 request 內原本的多次取時 | 票 1：逐處一對一替換，原本讀幾次就還是幾次；`ics/store.ts` 的捕捉參照改掉 |
| C4 | HLC／serverTime 的牆鐘不接注入值；ICS 的舊 nowMs 不流進 planOps | 票 1 的護欄例外表（§票 1.4），每個例外寫理由 |
| C5 | import 方向、行數上限不放寬；`durable-objects/` 的唯一例外只能搬移 | 票 1.2（`src/clock.ts` 放頂層、`uuid.ts` 改必填）、票 2.2（例外從 `src/mcp/services.ts` 搬到 `src/deps.ts`） |
| C6 | 每張新護欄要有「故意違規會紅」的驗收 | 各票「護欄與違規證明」小節 |
| C7 | 每 commit `check:fast`、票尾 `check`、碰 push 路徑或 DO 確認 `e2e:fault` | 票 2 改了 `routes/sync/push.ts` 的接線，票尾 `npm run check` 內含 `e2e:fault`，要在回報裡單獨寫出它的結果 |

違規證明的共同做法：暫時改檔 → 跑指定指令確認**紅** → `git -C <worktree> checkout -- <檔>` 還原 → 再跑確認綠。違規內容不得進 commit；回報附上紅的那段輸出。

## 2. 判斷「不做」的部分

| 項目 | 結論 | 理由 |
|------|------|------|
| 把 `now?: number` 家族（auth／oauth／sharing 共 20 處）改成由 factory 傳一個值進去 | **不做** | `handleEmailVerify`（`src/auth/email.ts:209`、`:220`）把 `params.now` 同時傳給 `verifyEmailCode` 與 `createSessionForIdentity`，正式環境是 `undefined`，兩邊各讀一次鐘。由 route 傳一個值會把兩次併成一次，違反 C3。這 20 處只做逐處的 `?? Date.now()` → `?? systemNow()`（票 1.3），簽名與語意不動 |
| `AppDeps.config`／讓 routes 不再 import `void/env`（任務目標裡的 config，原本的第三張票） | **不做** | `void/env` 的 `env` 已經是單一、有 schema（`server/env.ts`）、逐 key 延遲驗證的設定模組，再包一層沒有新能力：13 個 route 把 `env.X` 改寫成 `deps.config.X` 只是搬字。（若日後真的要做，config 必須是 proxy 的直通或逐 key 的 getter：測試以「只給部分 key」的物件 mock `void/env`，急切組出的物件會讓它們壞掉。）改成一道凍結護欄（票 2.5 的 A4）：`src/**`、`crons/**`、`durable-objects/**` 裡 import `void/env` 的只准現有兩檔，不得增加 |
| 把 `src/auth/access.ts` 的 `env.MCP_HOST` 預設值搬到 `middleware/01.access.ts` | **不做** | 這是正式環境 Access 閘門；開發建置整段跳過 Access，本機 e2e 驗不到「MCP 主機繞過 Access」這條路。為了讓一個測試檔少一個 mock 去動它不划算 |
| `requireUser(c)` 改成收 `jwtSecret` | **不做** | 9 個 route 呼叫點都要改，`avatar.test` 仍然要 mock `void`，沒有收益 |
| ICS engine 的 lease 取時（`src/ics/engine.ts:231–239`）接注入時鐘 | **不做** | 註解已寫明 lease 用牆鐘、不用 nowMs；lease 是跨 isolate 的互斥，接可注入的鐘只會讓它可能被凍住。列為護欄例外 |
| `parseIcs` 的預設 window 改必填 | **不做** | `src/` 唯一的呼叫端（`engine.ts:340`）一律傳 window；預設值只有 `tests/ics-parser.test.ts` 的 39 個呼叫在用。列為護欄例外 |
| `routes/test/mail.dev.ts` 改用 factory | **不做** | 它只要 mailer、不要 db；走 factory 會多開一個 D1 session。維持直接 `selectMailer` |
| `mcp-route.test.ts` 改成 mock `src/deps` | **不做** | 它現在 mock `Scope.get` 並斷言被查的 scope，等於正式接線（`src/deps.ts`）的端到端測試，留著才有東西守 factory |

## 3. 命名與 GLOSSARY（票 1 第一個 commit 就加進 `server/GLOSSARY.md`）

`clock` 在這個 codebase 已經是 `ServerHlcClock`（`deps.clock`、`services.ics.clock`、`world.clock`）；`now`／`nowMs` 已經是「讀好的數字」。所以函式型的鐘另取名：

- **`now`／`nowMs`（值）**：已讀好的 epoch ms。沿用現況：auth／oauth 叫 `now`，sharing／writer／scope 叫 `nowMs`。不改名。
- **`getNow`（函式）**：`() => number`，每呼叫一次讀一次鐘。跟既有的 `getScopeStub`、`getConfig`、`getMcpHost` 同一種命名。型別 `GetNow`。
- **`systemNow`**：`getNow` 的正式實作，`() => Date.now()`，定義在 `src/clock.ts`。只能當「可注入時間的預設值」（`x ?? systemNow()` 或 `getNow ?? systemNow`）。
- **牆鐘讀取（HLC）**：HLC、serverTime、lease 直接寫 `Date.now()`，不經 `getNow`，檔案明列在護欄的 allow。
- **AppDeps**（票 2）：正式接線的一包 `{ db, getScopeStub, getNow, mailer }`，由 `src/deps.ts` 的 `productionAppDeps` 產生；測試由 `createScopeWorld().deps` 產生。

`src/ics/store.ts` 兩個 store 的建構選項 `options.now?: () => number` 是既有名稱，不改名（5 個測試呼叫點在用），只改預設值。

---

## 票 1：clock 模組＋`Date.now` 護欄

**目標**：`src/` 內所有「業務時間」的讀取都經 `systemNow`／`getNow`；MCP 工具與 ICS cron 的時間可注入；`Date.now` 護欄從「三個目錄凍結三個檔」換成「全 server 只准 `src/clock.ts` 加明列的牆鐘例外」。

**RPC 影響**：無。**push 路徑／DO**：不碰（`src/sync/push.ts`、`src/scope/push.ts`、`durable-objects/scope.ts`、`src/serverops/writer.ts` 都只是留在例外表，一個字不改）。

**建議 writer**：Sonnet。全部是列好位置的一對一替換，現有測試不改就是行為不變的證據。護欄的 regex 與違規證明請主線（Opus）審。

**預估 diff**：`src/` 約 +55／−45（16 檔），`tests/architecture.test.ts` 約 +45／−8，`tests/domain-basic.test.ts` 1 行，GLOSSARY ＋6 行。

### 1.1 邏輯的去處

新檔 `src/clock.ts`（頂層，與 `src/log.ts`、`src/http.ts` 同級；`src/scope`、`src/sync`、`src/membership` 的 lint 只擋 `../(auth|oauth|…)`，import `../clock` 合法；`src/domain` 不能 import 它，見 1.2）：

```ts
/** Reads the wall clock (epoch ms). A function, so every call reads again. */
export type GetNow = () => number;

/** Production GetNow. Only ever the default of an injectable time: `x ?? systemNow()` or `getNow ?? systemNow`. */
export const systemNow: GetNow = () => Date.now();
```

不可寫成 `export const systemNow = Date.now`（捕捉參照，`vi.spyOn(Date, 'now')` 與 fake timers 會失效）。

型別新增（都是 optional，所以沒有呼叫端要跟著改）：

- `src/mcp/toolkit.ts` 的 `ToolServices`：`getNow?: GetNow`（註解：Production leaves it unset → `systemNow`）。同檔新增
  `export function nowOf(ctx: ToolContext): number { return (ctx.services?.getNow ?? systemNow)(); }`
- `src/ics/engine.ts` 的 `IcsEngineDeps`：`getNow?: GetNow`（註解：只有 cron 入口拿它算「這一輪的 now」；engine 內的 lease 與耗時量測一律讀牆鐘）。

### 1.2 `src/domain/uuid.ts`：改必填，不留例外

`uuidv7(now: number = Date.now())` → `uuidv7(now: number)`。理由：`src/domain/**` 只能 import 自己，無法用 `systemNow`；而 `src/` 的 8 個呼叫端本來就都傳值，預設值是死的。改完 `src/domain` 完全沒有 `Date.now`。
唯一要改的呼叫端：`tests/domain-basic.test.ts:37` `expect(uuidv7()).not.toBe(uuidv7())` → 兩邊傳同一個常數（例如 `uuidv7(1)`；同一毫秒仍不相等才是這個測試要證明的事）。

### 1.3 要改的位置（全部一對一，讀鐘次數與位置不變）

**(a) `?? Date.now()` → `?? systemNow()`，20 處，各檔加一行 `import { systemNow } from '../clock'`：**

| 檔 | 行 |
|----|----|
| `src/auth/email.ts` | 73、143 |
| `src/auth/session.ts` | 166、268 |
| `src/oauth/authorize.ts` | 266、276、324、375、403、499、531 |
| `src/oauth/codes.ts` | 29 |
| `src/oauth/register.ts` | 42 |
| `src/oauth/token.ts` | 131 |
| `src/sharing/index.ts` | 83、122、169、230、297、354 |

**(b) 捕捉參照 → 函式，2 處：** `src/ics/store.ts:225`、`:524` `options.now ?? Date.now` → `options.now ?? systemNow`。
（行為差異只在「store 建好之後才裝 `Date.now` spy」的測試；現有測試沒有這種情況——用 spy／fake timers 的 `mcp-complete`、`mcp-projects`、`mcp-tasks-write`、`task-writes`、`scope.test` 都不建 ICS store。）

**(c) MCP 工具 → `nowOf(ctx)`，10 處：**

| 檔 | 行 | 備註 |
|----|----|------|
| `src/mcp/tools/tasks.ts` | 329、408、438、443、464 | 438 與 443 在不同分支，各自保留一次讀取 |
| `src/mcp/tools/projects.ts` | 121、187 | |
| `src/mcp/tools/tags.ts` | 60 | |
| `src/mcp/tools/ics.ts` | 192、195 | 192 在 `run` 裡，每個 source 讀一次；195 另讀一次。**兩個都保留，不合併** |

**(d) ICS cron：** `src/ics/cron.ts:30` `Date.now()` → `(deps.getNow ?? systemNow)()`。

**(e) 測試**：只改 `tests/domain-basic.test.ts:37` 與 `tests/architecture.test.ts`。其他測試檔一行都不改——`systemNow` 在呼叫時才讀 `Date.now`，`advancingNow`、fake timers、`scope.test.ts:1634` 的 spy 照舊生效，全綠就是行為不變的證據。

### 1.4 留在護欄 allow 的牆鐘例外（最終 9 檔，一個字都不改）

| 檔 | 處數 | 為什麼不經 `getNow` |
|----|------|------|
| `src/clock.ts` | 1 | `systemNow` 的定義 |
| `durable-objects/scope.ts` | 3 | DO 自己的 HLC：`projectMember`（`input.nowMs ?? Date.now()`，nowMs 是既有的 RPC 欄位）、`purgeProject`、`reconcileProjectMembers` 都拿這個值餵 `advanceServerHlc`。DO 在另一個 isolate，Worker 的注入值進不來，也不准加進 RPC（C1、C4） |
| `src/scope/push.ts` | 2 | `:41` 是 HLC clamp 的基準，`:395` 是 `serverTime`（`Math.max(Date.now(), nowMs)`，刻意第二次讀）。`src/scope` 同步、由 DO 呼叫 |
| `src/sync/push.ts` | 2 | `:47` 的 `nowMs` 一個值同時餵 D1 的 `claimOwner`／`purgedAt` 戳記與空批次的 `serverTime`；`:80` 是批次結束的 `serverTime`。拆開等於改行為，整個留牆鐘 |
| `src/serverops/writer.ts` | 1 | `planOps:276`：HLC 與 opId 一律牆鐘（`WriteOptions.nowMs` 的註解、spec/mcp.md §6.2「hlc 取 max(now, …)」）。呼叫端的 `nowMs` 只進 `stampedSet`（`stampMs ?? nowMs`），**不得**改成用它算 HLC——ICS 傳進來的是這一輪 cron 開始時的舊 nowMs |
| `src/ics/engine.ts` | 7 | `:231–239` 五處是 lease（註解：store checks leases against its own clock, so lease calls use wall time, not nowMs）；`:740`、`:747` 是每個 source 的耗時量測 |
| `src/mcp/protocol.ts` | 2 | 一次 JSON-RPC 呼叫的耗時量測（log 用），不是業務時間 |
| `src/mail/mailer.ts` | 1 | dev mailbox 的 `sentAt`，只在開發建置寫入 |
| `src/ics/parser.ts` | 1 | `parseIcs` 預設 window；`src/` 唯一呼叫端一律傳 window（見 §2） |

### 1.5 護欄與違規證明

改 `tests/architecture.test.ts` 的 `GUARDS`：

**G1（取代現有的「Date.now() in domain, serverops and scope stays in its frozen files」）**
- name：`Date.now only in src/clock.ts and the listed wall-clock readers`
- dirs：`['src', 'routes', 'crons', 'middleware', 'durable-objects']`
- pattern：`/\bDate\.now\b/`（不帶括號，捕捉參照也擋）
- allow：§1.4 的 9 檔。
- bad：`'const nowMs = Date.now();'`、`'this.now = options.now ?? Date.now;'`
- 關於「allow 只准縮小」：舊護欄管的三個目錄，allow 從 `[uuid.ts, scope/push.ts, serverops/writer.ts]` 縮成 `[scope/push.ts, serverops/writer.ts]`，沒有新增。其餘 7 檔位在舊護欄沒管的目錄，是範圍擴大後第一次列冊。
- **分階段**：commit 1 先把 dirs 擴大、pattern 換掉，allow 填當下實際命中的 22 檔加上新的 `src/clock.ts`（共 23 檔，清單在下）；之後每個 commit 改完一批就從 allow 刪掉那批，最後剩 9 檔。任何 commit 都不得往 allow 加檔。
  - commit 1 的 allow（23 檔）：`durable-objects/scope.ts`、`src/auth/email.ts`、`src/auth/session.ts`、`src/clock.ts`、`src/domain/uuid.ts`、`src/ics/cron.ts`、`src/ics/engine.ts`、`src/ics/parser.ts`、`src/ics/store.ts`、`src/mail/mailer.ts`、`src/mcp/protocol.ts`、`src/mcp/tools/ics.ts`、`src/mcp/tools/projects.ts`、`src/mcp/tools/tags.ts`、`src/mcp/tools/tasks.ts`、`src/oauth/authorize.ts`、`src/oauth/codes.ts`、`src/oauth/register.ts`、`src/oauth/token.ts`、`src/scope/push.ts`、`src/serverops/writer.ts`、`src/sharing/index.ts`、`src/sync/push.ts`

**G2（新）**
- name：`systemNow() is only the default of an injectable time`
- dirs：同 G1
- pattern：`/(?<!\?\?\s*)\bsystemNow\(\)/`（直接呼叫 `systemNow()` 而前面不是 `??`）
- allow：`[]`
- bad：`'const now = systemNow();'`、`'expiresAt: systemNow() + TTL_MS,'`
- 不會誤擋：`params.now ?? systemNow()`、`(deps.getNow ?? systemNow)()`、`options.now ?? systemNow`、`import { systemNow } …`、`src/clock.ts` 的定義。
- 沒有這道，G1 只是把 `Date.now()` 改名成 `systemNow()`。

**G3（擴充既有的「updatedAt bump stays in serverops/writer.ts」，否則新呼叫形式會讓它變空殼）**
- pattern：`/Math\.max\((now|nowMs|Date\.now\(\)|systemNow\(\)|nowOf\(ctx\)), *Number\(/`
- bad 加兩筆：`'const updatedAt = Math.max(systemNow(), Number(row.updatedAt) + 1);'`、`'const updatedAt = Math.max(nowOf(ctx), Number(row.updatedAt) + 1);'`（每個 alternative 一個樣本是現行規定）。

**違規證明（指令：`npx vitest run tests/architecture.test.ts`）**

| 護欄 | 暫時的違規 | 預期 |
|------|-----------|------|
| G1 | `src/sharing/index.ts` 任一函式內加 `const t = Date.now();` | G1 紅，訊息列出 `src/sharing/index.ts` |
| G1 | `src/mcp/toolkit.ts` 加 `const read = Date.now;` | G1 紅（證明不帶括號也擋） |
| G1 | `routes/health.ts` 加 `Date.now()` | G1 紅（證明 routes 在範圍內） |
| G2 | `src/mcp/tools/tags.ts:60` 改成 `const now = systemNow();` | G2 紅 |
| G3 | `src/mcp/tools/tags.ts` 加 `Math.max(nowOf(ctx), Number(existing.row.updatedAt) + 1)` | G3 紅 |

### 1.6 commit 切法

1. `src/clock.ts`、GLOSSARY 三條（`getNow`、`systemNow`、牆鐘讀取）、`spec/mcp.md` §2 檔案樹加一行 `src/clock.ts`、G1（23 檔 allow）、G2、G3。
2. (a) 20 處＋(b) 2 處；allow 刪 `auth/email`、`auth/session`、`oauth/authorize`、`oauth/codes`、`oauth/register`、`oauth/token`、`sharing/index`、`ics/store`。
3. `ToolServices.getNow`、`nowOf`、(c) 10 處；`IcsEngineDeps.getNow`、(d)；allow 刪四個 `mcp/tools/*` 與 `ics/cron`。（`src/mcp/tools/ics.ts` 的 `engineDeps()` 不用把 `getNow` 傳下去：engine 不讀它，工具自己用 `nowOf(ctx)`。）
4. `uuidv7` 必填＋`tests/domain-basic.test.ts:37`；allow 刪 `domain/uuid`，剩 9 檔。跑五個違規證明。票尾 `npm run check`。

### 1.7 不准碰

`durable-objects/**`、`src/scope/**`、`src/sync/**`、`src/serverops/**`、`src/membership/**`、`db/**`、`routes/**`、`crons/**`、`middleware/**`、`.oxlintrc.json`、`src/auth/access.ts`、`src/ics/fetch.ts`、`src/mail/mailer.ts`、`src/ics/engine.ts`（只准加 `GetNow` 的 type import 與 `IcsEngineDeps.getNow` 一個欄位）、`tests/` 內 `architecture.test.ts` 與 `domain-basic.test.ts` 以外的檔。

### 1.8 驗收

```bash
cd server
npm run check:fast                      # 每個 commit
npm run check                           # 票尾
rg -n '\bDate\.now\b' src routes crons middleware durable-objects   # 只剩 §1.4 的 9 檔、共 20 處
rg -n 'systemNow\(\)' src | rg -v '\?\? systemNow\(\)'              # 無輸出
git -C .. diff b24c709 --stat -- server/tests                      # 只有 architecture.test.ts 與 domain-basic.test.ts
```

---

## 票 2：deps factory＋對應的 test world＋接線護欄

**目標**：正式環境只有 `src/deps.ts` 一處呼叫 `createDb(…, { session: 'first-primary' })` 與 `Scope.get`；routes、cron 都跟它拿；`createScopeWorld()` 產出同一個 interface。

**RPC 影響**：無（只改 Worker 端誰去呼叫 `Scope.get`，stub 與參數不變）。**push 路徑**：`routes/sync/push.ts`、`routes/sync/pull.ts` 的接線有改 → 票尾 `npm run check` 內的 `e2e:sync`、`e2e:fault` 結果要在回報裡單獨列出。

**建議 writer**：Opus（或 Codex）。要動 `.oxlintrc.json` 的例外搬移、注意 `import/no-cycle`、`Scope.get` 的型別（`services.ts` 現在有一個 `as unknown as ScopeStub`，routes 沒有，要弄清楚差在哪再決定 cast 放哪）、D1 session 數量不變。不是機械替換。

**預估 diff**：`src/` 約 +70／−30，routes 21 檔約 +60／−90，`.oxlintrc.json` 約 +25／−25，`tests/` 約 +60／−10，文件約 20 行。

### 2.1 interface

新檔 `src/deps.ts`：

```ts
import { createDb } from 'void/db';
import { Scope } from '../durable-objects/scope';
import { systemNow, type GetNow } from './clock';
import { selectMailer, type Mailer } from './mail/mailer';
import type { ScopeStub } from './scope/api';
import type { AppDb } from './sync/push';

/** What an entry point (route, cron) needs to reach the outside world. Tests build one with createScopeWorld(). */
export interface AppDeps {
  /** One D1 session (`first-primary`) per AppDeps. */
  db: AppDb;
  getScopeStub: (scope: string) => ScopeStub;
  getNow: GetNow;
  mailer: Mailer;
}

export interface AppBindings {
  DB: Parameters<typeof createDb>[0];
  EMAIL?: SendEmail;
}

/** Call once where the handler used to call createDb: each call opens a new D1 session. */
export function productionAppDeps(bindings: AppBindings): AppDeps { … }
```

要點：

- **不 memoize、不做成 lazy singleton**。「原本一個 `createDb` 呼叫 ＝ 現在一個 `productionAppDeps` 呼叫，位置相同」。每個 route handler 現況都剛好一個 `createDb`（已逐檔確認），`crons/ics-sync.ts` 是兩個。
- `mailer` 急切建立：`selectMailer` 沒有 IO、不寫 log（log 在 `send` 時才寫），dev／正式的選擇仍在 `selectMailer` 裡（C2）。
- **沒有 `config`**（見 §2）。routes 繼續 `import { env } from 'void/env'`。
- `getScopeStub` 的回傳型別是完整的 `ScopeStub`；各消費端要的 `Pick<ScopeStub, …>`、`ScopeLookup`（`src/auth/session.ts:13`）都相容。
- `src/deps.ts` **不 import `void/env`、不 import `src/mcp`、`src/ics`、`src/oauth`**（保持它在依賴圖的底部，避免 `import/no-cycle`）。

`src/mcp/services.ts` 改成純轉接（不再 import `durable-objects/`、不再 import `Scope`）：

```ts
export function toolServices(deps: Pick<AppDeps, 'db' | 'getScopeStub' | 'getNow'>, env: ToolServicesEnv): ToolServices
```

- 內容照現在的 `productionToolServices`，`getScopeStub` 改成 `deps.getScopeStub`，多帶 `getNow: deps.getNow`。
- `parseInsecureHosts(env.ICS_ALLOW_INSECURE_HOSTS)` 留在這裡，build-time 的 dev 閘門在它裡面（C2）。
- 改名是因為它不再做正式接線。`ToolServicesEnv` 不變。

**env 來源各入口維持原樣**：`routes/index.ts` 傳 `void/env` 的 `env`（有 schema 預設值，`DEFAULT_TIMEZONE` 會是 `'Asia/Taipei'`）；cron 傳 handler 的 raw `env`（沒有預設值就是 `undefined`，下游各自 fallback）。不要把 cron 換成 `void/env`。

### 2.2 lint：`durable-objects/` 例外的搬移（不是放寬）

`.oxlintrc.json` 的改動點，全部列出：

1. `"files": ["src/mcp/services.ts"]` 那個 override → 改成 `"files": ["src/deps.ts"]`（內容不變：只留 membership schema 的限制，沒有 `durable-objects` pattern）。
2. 最後 `"files": ["src/**"]` 的 `excludeFiles`：`"src/mcp/services.ts"` → `"src/deps.ts"`。`src/mcp/services.ts` 從此落回一般規則，被擋 import `durable-objects/`。
3. 9 個 override 裡的訊息 `"src/** must not import durable-objects/ (except src/mcp/services.ts)."` → `(except src/deps.ts)`（`src/membership`、`src/sync`、`src/scope`、`src/domain`、`src/auth`、`src/serverops`、`src/mcp/tools`、`src/ics`、一般 `src/**`）。
4. `routes/**` override 收緊（見 2.5 的 L1、L2）。

例外的總數前後都是 1。

### 2.3 所有要改的呼叫端

**`src/`**

| 檔 | 改動 |
|----|------|
| `src/deps.ts` | 新增 |
| `src/mcp/services.ts` | `productionToolServices(db, env)` → `toolServices(deps, env)`；刪 `Scope` import；第 13 行註解裡的 `createDb(env.DB, …)` 字樣改掉（會被 A1 命中） |
| `src/ics/cron.ts` | 刪 `createDb` import；`productionDeps(env)` 改成 `const app = productionAppDeps(env); const services = toolServices(app, env);`，回傳多帶 `getNow: app.getNow`；`IcsCronEnv.DB` 型別改沿用 `AppBindings['DB']` |
| `src/ics/engine.ts:50`、`src/serverops/writer.ts:55` | **只改註解**：`/** \`createDb(env.DB, { session: 'first-primary' })\`. */` → `/** \`AppDeps.db\` (first-primary D1 session). */`。這兩行會被 A1 的 `\bcreateDb\(` 命中。除此之外這兩檔不准動 |

**`crons/`**

| 檔 | 改動 |
|----|------|
| `crons/ics-sync.ts` | `createDb(env.DB, { session: 'first-primary' })` → `productionAppDeps(env).db`；刪 `void/db` import。`runIcsCron(env)` 不變（它內部另開一個 session，跟現在一樣是兩個） |

**`routes/`（21 檔、23 個 `createDb`、10 個 `Scope.get`、2 個 `selectMailer`）**

每個 handler 在原本 `createDb(...)` 的那一行改成 `const deps = productionAppDeps(c.env);`（原本是行內引數的就在呼叫前一行宣告），之後 `db`／`primaryDb`／`database` 換成 `deps.db`，`getScopeStub: (scope) => Scope.get(scope)` 換成 `getScopeStub: deps.getScopeStub`，`selectMailer({ binding: c.env.EMAIL })` 換成 `deps.mailer`。刪掉 `void/db` 與 `durable-objects/scope` 的 import。**`env`（`void/env`）與 `requireUser(c)` 不動；不傳 `now`／`nowMs`。**

| 批次（一個 commit） | 檔 | db | Scope.get | mailer |
|------|----|----|-----------|--------|
| sync／me | `routes/sync/push.ts` | 1 | 1 | |
| | `routes/sync/pull.ts` | 1 | 1 | |
| | `routes/me/avatar.ts` | 1 | | |
| auth | `routes/auth/apple.ts` | 1 | 1 | |
| | `routes/auth/google.ts` | 1 | 1 | |
| | `routes/auth/refresh.ts` | 1 | 1 | |
| | `routes/auth/email/start.ts` | 1 | | 1 |
| | `routes/auth/email/verify.ts` | 1 | 1 | |
| sharing | `routes/invites/index.ts` | 1 | | |
| | `routes/invites/[code]/index.ts` | 2（GET、DELETE 各一） | 1 | |
| | `routes/invites/[code]/accept.ts` | 1 | 1 | |
| | `routes/projects/[id]/members/[userId].ts` | 2（PUT、DELETE 各一） | 2 | |
| oauth／mcp | `routes/authorize/index.ts` | 1（`deps(db)` helper，GET、POST 各呼叫一次；helper 參數改成 `c.env`） | | |
| | `routes/authorize/start.ts` | 1 | | |
| | `routes/authorize/apple/callback.ts` | 1 | | |
| | `routes/authorize/google/callback.ts` | 1 | | |
| | `routes/authorize/email/start.ts` | 1 | | 1 |
| | `routes/authorize/email/verify.ts` | 1 | | |
| | `routes/register.ts` | 1 | | |
| | `routes/token.ts` | 1 | | |
| | `routes/index.ts` | 1（`authenticateMcp` 與 `toolServices` 共用同一個 `deps.db`，跟現在一樣） | （經 `toolServices(deps, env)`） | |

`routes/sync/push.ts` 的 `clock: serverClock` 不動。`routes/authorize/*` 的 oauth handler 參數名是 `database`，傳 `deps.db`。

不改的 routes：`routes/health.ts`、`routes/.well-known/*`、`routes/test/protected.dev.ts`、`routes/test/mail.dev.ts`（見 §2）。

**`tests/`**

| 檔 | 改動 |
|----|------|
| `tests/mcp-route.test.ts` | 只改最後一個 `describe('productionToolServices')`（`:107–125`）與 `:40` 的 import：第一個測試改呼叫 `toolServices({ db, getScopeStub: () => { throw new Error('unused'); }, getNow: systemNow }, {…})`，三個斷言（`s.db`、`defaultTimeZone`、`ics`）原樣保留——它們逐欄位比對，多一個 `getNow` 不影響；第二個測試「resolves scope stubs through Scope.get」改成測 `productionAppDeps({ DB: d1 }).getScopeStub('u:x')`，斷言 `scopeGets` 原樣保留，`describe` 拆成 `toolServices` 與 `productionAppDeps` 兩個。**`:1–105` 不動**，特別是對 `durable-objects/scope` 的 mock 與經過 route 的那幾個測試：route 改走 `src/deps.ts` 之後它們不改而仍然綠，就是正式接線沒變的證據 |
| `tests/avatar.test.ts` | 預期不用改（它 mock 的 `void/db` `createDb` 仍會被 `src/deps.ts` 呼叫到）。若紅了先查原因再動，不要直接改斷言 |
| `tests/helpers/scopeWorld.ts` | `createScopeWorld()` 的回傳多一個 `deps`，見 2.4 |
| `tests/architecture.test.ts` | 2.5 的護欄 |

### 2.4 test world：同一個 interface

`tests/helpers/scopeWorld.ts` 的 `createScopeWorld(options)`：

- `CreateScopeWorldOptions` 加 `getNow?: GetNow`（預設 `systemNow`）。
- 回傳值加：
  - `sentMail: MailMessage[]`
  - `deps: { db, getScopeStub, getNow, mailer } satisfies AppDeps`，其中 `mailer` 是把訊息 push 進 `sentMail` 並回 `{ ok: true }` 的記錄用 mailer。
- `satisfies AppDeps` 是重點：`AppDeps` 加減欄位時 `tsc` 會在這裡紅，兩邊不會各走各的。
- 既有欄位（`d1`、`db`、`sqlite`、`trace`、`clock`、`scopes`、`scopeSqlites`、`calls`、`getScopeStub`、`push`、`pull`）不改名、不搬走；現有 20 多個呼叫端不用改。
- 這張票裡 `world.deps` 只有型別檢查（`satisfies`）在用，第一個真正的使用者是票 3 的 `createServerHarness`（`toolContext` 的 `services` 從 `world.deps` 取）。放在這張票是為了讓 `AppDeps` 定案時就有第二個實作對著它；票 3 若因故不做，這個欄位要一起拿掉。

### 2.5 護欄與違規證明

**architecture.test.ts**

- **A1（新）** `createDb( is called only in src/deps.ts`：dirs `['src','routes','crons','middleware','durable-objects']`，pattern `/\bcreateDb\(/`，allow `['src/deps.ts']`，bad `["const db = createDb(c.env.DB, { session: 'first-primary' });"]`。
- **A2（新）** `Scope.get( is called only in src/deps.ts`：同 dirs，pattern `/\bScope\.get\(/`，allow `['src/deps.ts']`，bad `["getScopeStub: (scope) => Scope.get(scope),"]`。
- **A3（收緊既有的「routes/** do not query the database directly」）**：pattern 後半 `\.DB\b(?!\s*[,)])` → `\.DB\b`（routes 連把 `env.DB` 轉手都不需要了）。bad 四筆照留——第二筆原本靠 `.run(` 命中，現在也被 `.DB` 命中，仍是有效樣本；另補一筆 `'handle(deps(c.env.DB));'` 證明「轉手」這個原本的豁免已經關掉。
- **A4（新，凍結）** `void/env is imported in src only by the two auth edge files`：dirs `['src','crons','durable-objects']`，pattern `/from ['"]void\/env['"]/`，allow `['src/auth/access.ts','src/auth/middleware.ts']`，bad `["import { env } from 'void/env';"]`。只准縮小。這是「config 不做」的替代品：設定讀取留在 routes／middleware 這層邊界，`src/` 不得再長出新的隱性 env 依賴。

**.oxlintrc.json（`routes/**` override，都是收緊）**

- **L1**：`paths` 裡 `void/db` 那筆拿掉 `allowImportNames: ["createDb"]`，訊息改成 `routes/** must not import void/db; take db from productionAppDeps (src/deps.ts).`
- **L2**：`patterns` 加 `{ "regex": "(^|/)durable-objects(/|$)", "message": "routes/** must not import durable-objects/; take getScopeStub from productionAppDeps (src/deps.ts)." }`

**違規證明**

| 護欄 | 暫時的違規 | 指令 | 預期 |
|------|-----------|------|------|
| A1 | `src/ics/cron.ts` 加回 `import { createDb } from 'void/db'` 與一個 `createDb(env.DB, …)` | `npx vitest run tests/architecture.test.ts` | A1 紅 |
| A2 | `routes/sync/pull.ts` 把 `deps.getScopeStub` 換回 `(scope) => Scope.get(scope)`（含 import） | 同上；另跑 `npm run lint` | A2 紅；lint 因 L2 紅 |
| A3 | `routes/health.ts` 加 `const raw = c.env.DB;` | 同上 | A3 紅 |
| A4 | `src/sharing/index.ts` 加 `import { env } from 'void/env';` | 同上 | A4 紅 |
| L1 | `routes/health.ts` 加 `import { createDb } from 'void/db';` | `npm run lint` | 紅，訊息是 L1 那句 |
| 例外搬移 | `src/mcp/services.ts` 加 `import { Scope } from '../../durable-objects/scope';` | `npm run lint` | 紅，訊息含 `(except src/deps.ts)`——證明舊例外真的關掉了 |
| `satisfies` | 在 `AppDeps` 暫時加一個必填欄位 | `npm run typecheck` | `tests/helpers/scopeWorld.ts` 紅 |

### 2.6 commit 切法

1. `src/deps.ts`＋lint 例外搬移（2.2 的 1–3）＋`services.ts` 改 `toolServices`＋`ics/cron.ts`＋`crons/ics-sync.ts`＋`routes/index.ts`＋`mcp-route.test.ts` 三行＋兩個註解。（這幾個互相依賴，必須同一個 commit 才會綠。）
2. routes：sync／me 批。這個 commit 後先單獨跑一次 `npm run e2e:sync && npm run e2e:fault`。
3. routes：auth 批。
4. routes：sharing 批。
5. routes：oauth 批（`routes/index.ts` 已在 commit 1）。
6. 護欄 A1–A4、L1、L2＋七個違規證明。
7. `createScopeWorld().deps`（2.4）。
8. 文件：`server/GLOSSARY.md` 加 AppDeps；`server/AGENTS.md` 第 29 行「cron 內可用 `createDb`、`Scope.get`、`env`」改成「cron 經 `productionAppDeps(env)` 拿 db 與 Scope stub，`env` 用 handler 參數」，lint 那段補一句「`createDb`／`Scope.get` 只在 `src/deps.ts`」；`spec/mcp.md` §6.2（324 行）與 §9.5（536 行）的 `createDb(env.DB, …)` 字樣對齊，§2 檔案樹加一行 `src/deps.ts`（`productionToolServices`、`mcp/services` 在 spec／README／AGENTS 都沒有被提到，已 grep 確認，不用改）。票尾 `npm run check`。

### 2.7 不准碰

`durable-objects/**`、`src/scope/**`、`src/sync/**`、`src/membership/**`、`db/**`、`middleware/**`、`env.ts`、`src/auth/**`、`src/oauth/**`、`src/sharing/**`、`src/mail/**`、`src/ics/fetch.ts`、`src/mcp/tools/**`、`src/serverops/**`（`writer.ts:55` 的註解除外）、`src/ics/engine.ts`（`:50` 的註解除外）、`routes/test/**`、票 1 的 G1–G3。`routes/**` 內不得新增 `Date.now`、`systemNow`、`now:` 參數。

### 2.8 驗收

```bash
cd server
npm run check:fast                                   # 每個 commit
npm run check                                        # 票尾；回報單獨列出 e2e:sync、e2e:ics（含 cron runtime 探測）、e2e:mcp、e2e:fault
rg -n '\bcreateDb\(|\bScope\.get\(' src routes crons middleware durable-objects   # 只剩 src/deps.ts 各一處
rg -n "durable-objects" src --glob '!src/deps.ts'    # 無輸出
rg -c 'productionAppDeps\(' routes crons src         # routes 合計 23、crons/ics-sync.ts 1、src/ics/cron.ts 1（＝改之前 createDb 的 25 處；另有 src/deps.ts 的定義 1 處）
wc -l routes/**/*.ts                                 # 每檔 ≤ 100
```

「未實測」要寫明：正式建置的 cron（`withRuntimeEnv` 包住的 `scheduled()`）本機跑不到，替代驗證是 `e2e:ics` 的 cron runtime 探測；這個限制在這次重構之前就有（spec/mcp.md §9.5 M2 spike），這張票沒有改變 cron 的 env 來源，所以風險沒有增加。

---

## 票 3：測試 harness 收斂＋拿掉 fake timers

**目標**：新測試檔不用再抄 100 多行前置；時間相關的 MCP／task-writes 測試改用注入的 `getNow`，不用 fake timers、不 spy `Date.now`。只動 `tests/`。

**RPC 影響**：無。**`src/`、`routes/`**：一行都不改。

**建議 writer**：Sonnet 寫、Opus 審 diff。風險不在難度，在「搬 helper 時順手改弱斷言」：審查看 `git diff` 裡 `expect(` 開頭的行應該零變動（3.3 列出的少數例外除外）。

**預估 diff**：`tests/` 約 +220／−620。

### 3.1 現況（函式本體的 md5，同雜湊＝逐字相同）

| helper | 相同的一組 | 變體 |
|--------|-----------|------|
| `projectRow` | 11 檔全同（`afaa56f1`）：`ics-engine-guards`、`ics-engine-sync`、`mcp-complete`、`mcp-ics`、`mcp-projects`、`mcp-tasks-read`、`mcp-tasks-write`、`scope-rpc-compat`、`task-writes`、`validate-once`、`writer` | 無 |
| `taskRow` | 8 檔全同（`4c4a5476`） | 無 |
| `deviceOp` | `b3532c3c`×5（四個 mcp-＊＋writer） | `df80f146`×3（兩個 ics-engine＋task-writes）、`e03aa7ca`×2（scope-rpc-compat、validate-once）、`mcp-ics` 自己一版 |
| `seedUser` | `213d7b7d`×5（四個 mcp-＊＋writer） | `f4ee1ef3`×2（ics-engine-guards、task-writes）、`ics-engine-sync`、`mcp-ics` 各一版 |
| `seedBasic` | 5 檔全同（`2fc267f8`） | 無 |
| `call` | `46850103`×4（mcp-complete、mcp-projects、mcp-tasks-read、mcp-tasks-write） | `mcp-ics` 一版 |
| `pulled` | `a810a3ef`×2 | `task-writes` 一版 |
| `createHarness` | `mcp-tasks-read` 與 `writer` 相同 | 其餘各有 `onPush`／fetch／store 的差異 |

### 3.2 邏輯的去處

新檔 `tests/helpers/serverHarness.ts`（建在 `createScopeWorld` 之上，不取代它）：

- `NOW_ISH`、`projectRow`、`taskRow`：直接搬（全同）。
- `deviceOp`：以 `b3532c3c` 版為準。三個變體先 diff；差異若只是 opId 字串格式或參數預設值，就併成一版加選項；若牽涉到測試在斷言的東西（例如 `scope-rpc-compat` 要逐位元比對 RPC 輸入），那個檔保留自己的版本並在檔內註解原因，列進 H1 的 allow。
- `createServerHarness(options?: CreateScopeWorldOptions & { getNow?: GetNow })`：回傳 `mcp-tasks-read`／`writer` 那版 `createHarness` 的欄位（`db`、`calls`、`deviceHlc`、`devicePush`、`deps(userId)`、`snapshot(userId)`），再加 `pull`、`getScopeStub`、`clock`、`world`，以及 `toolContext(userId): ToolContext`（`services: { db, getScopeStub, getNow }`）。各檔自己的 `onPush` 邏輯、假 fetch、`MemoryIcsStore` 留在各檔，包在這個上面。
- `seedUser`、`seedBasic`、`call`、`pulled`：以多數版為準搬進來；變體同 `deviceOp` 的處理原則。
- `tests/helpers/advancingClock.ts`：`advancingNow(start)` 從「spy `Date.now`」改成**回傳一個 `GetNow`**（每呼叫一次加 1），不再碰全域。註解保留原意：凍住的鐘分不出「帶著呼叫端的 now」與「之後又讀一次鐘」。

### 3.3 fake timers 與 `Date.now` spy

| 位置 | 現況 | 改法 |
|------|------|------|
| `tests/mcp-complete.test.ts:172–179` | 全檔 `beforeEach` `vi.useFakeTimers({ toFake: ['Date'] })`＋`setSystemTime(FIX_NOW)` | 刪掉；harness 以 `getNow: () => now` 建立（`let now = FIX_NOW`），工具經 `nowOf(ctx)` 讀到它 |
| `tests/mcp-complete.test.ts:253` | `vi.setSystemTime(Date.parse('2026-11-15T17:00:00Z'))` | 改成設定那個 `now` 變數 |
| `tests/mcp-complete.test.ts:280`、`:291` | `advancingNow(FIX_NOW)`（spy）＋`afterEach(vi.restoreAllMocks)` | harness 以 `getNow: advancingNow(FIX_NOW)` 建立；`restoreAllMocks` 若沒有別的 spy 就刪 |
| `tests/mcp-projects.test.ts:264`、`tests/mcp-tasks-write.test.ts:505` | `advancingNow(Date.now() + 120_000)`＋`try/finally restoreAllMocks` | 同上，拿掉 try/finally |
| `tests/task-writes.test.ts:377–384`、`:529` | fake timers；`complete()` helper（`:345`）傳 `nowMs: Date.now()` | `complete()` 直接收／傳 `nowMs`（預設 `FIX_NOW`），`:529` 那個案例傳自己的時間；刪 fake timers。`completeOccurrence` 本來就收 `nowMs`，不需要任何注入 |
| `tests/scope.test.ts:1634` | `vi.spyOn(Date, 'now').mockReturnValue(fixedNow)` | **不動**。它測的是「牆鐘固定時 DO 的 serverTime 仍然單調」，那是 HLC 牆鐘（票 1 §1.4 的例外），本來就不能注入 |

**要先知道的語意差異**：fake timers 底下，種子資料的 device HLC、writer 的 HLC、DO 的 clamp 基準全部是 `FIX_NOW`；改完之後只有「工具蓋的戳記」（`completedAt`、`deletedAt`、`updatedAt`、`uuidv7` 的時間位元、「今天是哪一天」）是 `FIX_NOW`，HLC 走真實牆鐘。照程式的設計這兩者本來就獨立（戳記是普通欄位，LWW 看 HLC），所以斷言應該不用改。

**規則**：斷言一行不改。某個案例改完會紅，先查它是不是依賴了「HLC 也等於 FIX_NOW」：
- 是 → 那個案例維持原狀（留在 fake timers），把檔名加進 H2 的 allow 並在回報的「偏離」寫明哪個案例、依賴什麼；不要為了拿掉 fake timers 去改斷言或改 `src/`。
- 不是 → 回報主線，可能是票 1 的替換有地方多讀或少讀了一次鐘。

### 3.4 所有要改的檔

`tests/helpers/serverHarness.ts`（新）、`tests/helpers/advancingClock.ts`、`tests/mcp-complete.test.ts`、`tests/mcp-tasks-write.test.ts`、`tests/mcp-projects.test.ts`、`tests/mcp-tasks-read.test.ts`、`tests/writer.test.ts`、`tests/task-writes.test.ts`、`tests/mcp-ics.test.ts`、`tests/ics-engine-sync.test.ts`、`tests/ics-engine-guards.test.ts`、`tests/scope-rpc-compat.test.ts`、`tests/validate-once.test.ts`、`tests/architecture.test.ts`。

`tests/snapshot.test.ts`、`tests/sharing.test.ts`、`tests/scope.test.ts`、`tests/membership.test.ts` 的 `createHarness` 只有 3–12 行且各不相同，不動。

### 3.5 護欄與違規證明

護欄表掃 `tests/` 時，H2、H3 會命中 `architecture.test.ts` 自己的 bad 樣本。做法：這兩道的 bad 樣本用字串拼接寫（例如 `'vi.use' + 'FakeTimers();'`），並在護欄上方註解原因；不為此改 `Guard` 的形狀，也不把 `architecture.test.ts` 自己放進 allow。H1 的 pattern 以行首 `^` 錨定，陣列裡縮排又帶引號的樣本本來就不會命中，照一般寫法即可。

- **H1** `test row builders are defined only in tests/helpers`：dirs `['tests']`，pattern `/^(async )?function (projectRow|taskRow|deviceOp|seedUser|seedBasic)\(/m`，allow `[]`＋3.2 判定必須保留自己版本的檔（預期 0–3 個，逐一寫原因；`tests/helpers/serverHarness.ts` 用 `export function`，不會命中）。bad 每個名字一筆。
- **H2** `no fake timers in tests`：dirs `['tests']`，pattern `/\buseFakeTimers\b|\bsetSystemTime\b/`，allow `[]`（＋3.3 規則留下來的檔），bad 兩筆。
- **H3** `Date.now is spied only where the HLC wall clock is under test`：dirs `['tests']`，pattern `/spyOn\(\s*Date\b/`，allow `['tests/scope.test.ts']`，bad 一筆。

| 護欄 | 暫時的違規 | 預期（`npx vitest run tests/architecture.test.ts`） |
|------|-----------|------|
| H1 | 在 `tests/mcp-tasks-read.test.ts` 貼回 `function projectRow(…) {…}` | H1 紅 |
| H2 | `tests/mcp-complete.test.ts` 加回 `beforeEach(() => vi.useFakeTimers())` | H2 紅 |
| H3 | `tests/writer.test.ts` 加 `vi.spyOn(Date, 'now')` | H3 紅 |
| H2、H3 | 把該護欄某筆 bad 樣本的拼接改回一般字串 | 該護欄紅且列出 `tests/architecture.test.ts`——證明掃描真的涵蓋 `tests/` |

### 3.6 commit 切法

1. `serverHarness.ts`＋四個 mcp-＊與 `writer`（雜湊全同的那組）。
2. `task-writes`、兩個 `ics-engine-*`、`mcp-ics`、`scope-rpc-compat`、`validate-once`（變體）。
3. `advancingClock.ts` 改回傳 `GetNow`＋三個使用它的檔。
4. 拿掉 `mcp-complete`、`task-writes` 的 fake timers。
5. H1–H3＋違規證明；`server/AGENTS.md` 加一句「新的 server 測試用 `tests/helpers/serverHarness.ts`，時間用 `getNow` 注入，不用 fake timers」。票尾 `npm run check`。

每個 commit 除了 `check:fast`，另外比對測試數量沒有減少：改之前記下 `npx vitest run` 的 `Tests N passed`，改之後 N 不得變小。

### 3.7 不准碰

`tests/` 以外的任何檔（`server/AGENTS.md` 那一句除外）；`tests/sqliteD1.ts`、`tests/helpers/scopeMocks.ts`、`tests/helpers/scopeWorld.ts` 的既有欄位；`tests/scope.test.ts`；任何 `expect(…)` 的內容（3.3 規則允許的偏離除外，且要回報）。

### 3.8 驗收

```bash
cd server
npm run check:fast && npm run check
rg -n 'useFakeTimers|setSystemTime' tests --glob '!tests/architecture.test.ts'   # 無輸出（或只剩回報過的偏離）
rg -n 'spyOn\(\s*Date' tests --glob '!tests/architecture.test.ts'                # 只有 tests/scope.test.ts
git -C .. diff <票3起點> --stat -- server/src server/routes server/durable-objects   # 無輸出
git -C .. diff <票3起點> -- server/tests | rg '^[-+]\s*expect\('                    # 逐行說明，預期為空
```

---

## 4. 風險（由大到小）

1. **票 2 的 D1 session 數量**。`createDb` 每呼叫一次開一個 `first-primary` session；合併（例如 cron 的清理與 ICS 共用）或拆開（一個 handler 內呼叫兩次 factory）都會改變「哪個查詢先打 primary」。本機 e2e 沒有讀取副本，測不出來，只能靠 2.8 的計數（25 處對 25 處）與逐檔審查。
2. **票 3 把斷言改弱**。搬 helper、拿 fake timers 時最容易發生；靠「`expect(` 行零變動」與測試數量不減少來守。
3. **票 2 的 lint 例外搬移只做一半**：`excludeFiles` 沒改到，`src/deps.ts` 會被一般規則擋下（當場紅，容易發現）；反過來 `src/mcp/services.ts` 沒落回一般規則則是靜默放寬——所以違規證明表有一列專門驗它。
4. **票 1 的 G2 lookbehind** `(?<!\?\?\s*)` 是可變長度的 lookbehind，Node 支援；如果寫的人把 `??` 後面換行再縮排，`\s*` 也涵蓋。寫法換成 `params.now || systemNow()` 之類則會被擋，這是預期行為。
5. **票 2 的 `Scope.get` 型別**。`services.ts` 現在要 `as unknown as ScopeStub`，routes 卻不用 cast 就能傳給 `(scope) => ScopeStub`。搬到 `src/deps.ts` 時先弄清楚原因（多半是 `.void/` 產生的型別與 route 的型別推論路徑不同），cast 只留在 `src/deps.ts` 一處。

## 5. 看板

| 票 | 內容 | 狀態 | commit 範圍 | 偏離 |
|----|------|------|-------------|------|
| 1 | clock 模組（`src/clock.ts`、`getNow`／`systemNow`、`nowOf`）＋ G1–G3 護欄、`uuidv7` 必填 | 完成 | 1054afb..b68cf3c（4 commit，check 與 e2e 全綠，852 tests） | 無 |
| 2 | `src/deps.ts`（`AppDeps`／`productionAppDeps`）、lint 例外搬移、21 個 route＋cron 遷移、`createScopeWorld().deps`、A1–A4／L1–L2 護欄 | 未開始 | | |
| 3 | `tests/helpers/serverHarness.ts`、拿掉 fake timers 與 `Date.now` spy、H1–H3 護欄 | 未開始 | | |
| — | config／env 收斂（原第三塊） | 不做（§2），以 A4 凍結護欄取代 | — | — |
