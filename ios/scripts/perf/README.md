# 動畫掉幀量測（模擬器）

找哪個動畫卡、或比較改前改後時用。結果是模擬器上的相對排序，不是實機數字。

## 跑法

```bash
cd ios && DD_SIM_OWNER=dd:perf ./scripts/uitest.sh up iphone          # 記下印出的 UDID
UDID=<UDID> OUT=<repo 外的目錄>/traces ./scripts/perf/run.sh 1         # 全部情境；指定情境就接 testPerfXxx
UDID=<UDID> OUT=<同上> ./scripts/perf/run.sh 2                         # 再跑一次，兩次的差距是雜訊範圍
./scripts/perf/perf.py table <OUT> "1 2"                               # 每個情境的掉幀表
./scripts/perf/perf.py hot <OUT>/testPerfMonthSwipe-1.trace            # 主執行緒上 DayDo 的熱點函式
DD_SIM_OWNER=dd:perf ./scripts/uitest.sh down iphone
```

每個情境一次約 1.5 分鐘，全部 11 個兩輪約 35 分鐘。改前改後要在同一台機器、同樣安靜時（沒有別的 xcodebuild）各跑兩輪。trace 每個約 20–40 MB，放 repo 外。

## 組成

- `-DayDoSeedPerf`（Debug 限定，`DayDoApp.swift` 的 `DebugLaunch`）：建 600 筆任務分布在前後 90 天（約 300 筆過期擠在「今天」），結束時把 image 載入位址寫進 App tmp 的 `perf-images.txt`，並打 `seedDone` signpost 當分析起點。
- `DayDoUITests/DayDoPerfTests`：每個情境把一組手勢重複 6 次；`TEST_RUNNER_DAYDO_PERF=1` 才會跑，平常的全套會跳過。`testPerfControlQueriesOnly` 是只查元素、不做手勢的對照組。
- `run.sh`：用 `-O` 加 dSYM 編譯，測試啟動後 attach Time Profiler 錄到 App 結束。
- `perf.py`：主執行緒每個 runloop iteration 的忙碌時間取 Time Profiler 樣本權重和，≥16.7ms 算掉一幀；用對照組校正 trace 與測試 log 的時鐘差，只算 XCUITest `Synthesize event` 後 1 秒內、不貼著元素查詢的幀（每次查詢都會讓 App 主執行緒做一次無障礙快照，列表大時約 0.5 秒）。

模擬器上 Instruments 的 Hitches 與 `XCTHitchMetric` 都不能用，所以才這樣量；`XCTHitchMetric` 留在測試裡，實機上跑才有數字。
