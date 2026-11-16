# server 詞彙表

新 module、函式與審查意見用這些名字；要新增概念先在這裡加一條。規則寫在 `AGENTS.md`，協議本身在 `spec/sync.md`。

## 資料放哪

- **Scope**：一個使用者自己的同步空間，名稱 `u:<userId>`，由一個 Durable Object 存它的清單、任務等列。
- **Scope ledger**：Scope DO 裡的帳本規則（`src/scope/`）：schema、store、push、成員、purge、pull、row 檢視。
- **D1 帳本**：跨使用者的資料。`entityHome` 記每一列住在哪個 Scope（由 sync/push 綁定）；`projectMembership`、`listScopes`、`purgedProject` 屬於 `src/membership/`。
- **home Scope**：一份清單建立者的 Scope。成員關係只投影到這裡的 `projectMember` 列，pull 時由 `planPullMembers` 補齊缺的。
- **listScopes**：一份共享清單的列散在哪些成員的 Scope；永久刪除清單時要逐一通知它們。

## 寫入路徑

- **op**：App 送來的一筆變更（`/sync/push` 的單位），帶 opId、一個 HLC 與改動的欄位名；逐欄 clocks 是伺服器合併後才有的。
- **OpEnvelope**：Worker 驗證過的 op（原始 op、解析出的 entity、驗證結果）。Worker 傳給 DO 的是原始 op 加上 `validated`，因為部署時新舊版本會混跑。
- **intent**：伺服器端（MCP、ICS）想寫的結果（`WriteIntent`），由 `serverops/writer.ts` 組成 op，走和 App 一樣的 push 路徑。
- **snapshot**：伺服器端讀到的使用者全部列，包含垃圾桶與 tombstone（`loadSnapshot`）。
- **listWriteDenial**：清單寫入權限的判斷，回傳 `Project is purged`、`Forbidden` 或可寫（`src/sync/access.ts`）。

## 刪除

- **軟刪除**：`deletedAt` 有值，在垃圾桶裡，可以還原。
- **tombstone**：永久刪除的列。整列保留並標上 `purgedAt`，之後對這列的寫入回 `applied` 但不生效（不回 `rejected`，免得另一台裝置一直重送）；writer 把這種結果歸為 purged。寫進已永久刪除的「清單」才回 `rejected`（`Project is purged`）。
- **永久刪除清單**：`membership/purge.ts` 的 `purgeProject` 在 D1 標記並通知 `listScopes` 裡的每個 Scope，各 Scope 用 `scope/purge.ts` 的 `purgeProject` 把清單與它的列變成 tombstone。兩個函式同名但不是同一層。
- **gone／departure**：任務（連同子列）移到別的清單時，DO 記一筆 `departure`；pull 只對「已經看不到這一列」的人回 `gone: true`，App 本機硬刪除但不記 `purgedId`，因為這個 id 之後還可能回來。清單被永久刪除不走這條，走 tombstone。

## 時間

- **getNow**：`() => number`（型別 `GetNow`，`src/clock.ts`），每呼叫一次讀一次鐘；「可注入的時間」都用它。`now`／`nowMs` 則是已讀好的 epoch ms。
- **systemNow**：`getNow` 的正式實作，`() => Date.now()`（不捕捉 `Date.now` 參照，spy 與 fake timers 才有效）。只能當預設值：`x ?? systemNow()` 或 `getNow ?? systemNow`，由架構測試把關。
- **牆鐘讀取**：HLC、`serverTime`、lease、耗時量測直接寫 `Date.now()`，不經 `getNow`（注入值進不了 DO、舊的 now 不能流進 HLC）。另有三處：`mail/mailer.ts` 的 dev mailbox `sentAt`；`ics/parser.ts` 的 `parseIcs` 預設 window；`sync/push.ts` 的 `nowMs` 同時用在 D1 戳記與 `serverTime`，拆開會改行為。這些檔案明列在 `tests/architecture.test.ts` 的 `Date.now` 護欄 allow。

## 接線

- **AppDeps**：入口（route、cron）對外的一包 `{ db, getScopeStub, getNow, mailer }`。正式環境由 `src/deps.ts` 的 `productionAppDeps(bindings)` 產生，測試由 `createScopeWorld().deps` 產生（`satisfies AppDeps`）。每呼叫一次 `productionAppDeps` 就開一個新的 `first-primary` D1 session，所以它放在原本開 session 的位置，不 memoize、不共用；`crons/ics-sync.ts` 的 OAuth 清理與 ICS 各開一個。設定（`void/env`）不在裡面，routes 照舊直接讀 `env`。
