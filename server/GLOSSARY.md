# server 詞彙表

新 module、函式與審查意見用這些名字；要新增概念先在這裡加一條。協議本身的定義在 `spec/sync.md`。

## 資料放哪

- **Scope**：一個使用者自己的同步空間，名稱 `u:<userId>`（只由 `src/sync/scopeName.ts` 組）。每個 Scope 是一個 Durable Object，用自己的 SQLite 存清單、任務等列。
- **Scope ledger**：Scope DO 裡的帳本規則，在 `src/scope/`（schema、store、push、members、purge、pull、row 檢視）。全部同步執行；DO 類別本身只是 RPC 轉接器。
- **D1 帳本**：跨使用者的資料。`entityHome`（每一列住在哪個 Scope，由 sync/push 綁定）；`projectMembership`、`listScopes`、`purgedProject` 只由 `src/membership/` 讀寫。
- **membership**：清單成員與角色（owner／editor／viewer），以及把成員關係投影到各 Scope、在 pull 時修復。
- **listScopes**：一份共享清單的列散在哪些成員的 Scope；永久刪除清單時要逐一通知它們。

## 寫入路徑

- **op**：App 送來的一筆變更（`/sync/push` 的單位），帶 opId 與逐欄 HLC。
- **OpEnvelope**：Worker 驗證過的 op（原始 op、解析出的 entity、驗證結果）。`validateSyncOp` 只在 `src/sync/envelope.ts` 呼叫一次。Worker 傳給 DO 的仍是原始 op 加上 `validated`，因為部署時新舊版本會混跑。
- **intent**：伺服器端（MCP、ICS）想寫的結果（`WriteIntent`）。`serverops/writer.ts` 的 `pushIntents`／`writeOrThrow` 把它組成 op，走和 App 一樣的 push 路徑，並自己補 `updatedAt`。
- **snapshot**：伺服器端讀到的使用者全部列，包含垃圾桶與 tombstone（`loadSnapshot`）。
- **listWriteDenial**：清單寫入權限的唯一判斷，回傳 `Project is purged`、`Forbidden` 或可寫（`src/sync/access.ts`）。

## 刪除的三種狀態

- **軟刪除**：`deletedAt` 有值，在垃圾桶裡，可以還原。
- **tombstone／purged**：永久刪除；列只留下 `purgedAt`，之後的寫入都會被拒。永久刪除清單的流程是 `membership/purge.ts` 的 `purgeProject`（D1 加上通知各 Scope），和 `scope/purge.ts` 的 `purgeProject`（單一 Scope 內）不是同一個函式。
- **gone／departure**：列離開某份清單（移動、清單被永久刪除）時，DO 記一筆 `departure`；pull 時只對「已經看不到這一列」的人回 `gone: true`，App 本機硬刪除但不記 `purgedId`，因為這個 id 之後還可能回來。
