# Identity latency profile — 2026-09-23

## 結論與量測界線

已完成 host 元件量測，尚未完成實機 known/unknown 端到端 profile。
這次不更改 production 行為、辨識門檻、影格數、模型或音訊設定。

- 環境：Apple M4 Pro、macOS 26.5.1 (25F80)、Xcode 26.2 (17C52)。
- 原始工作樹 HEAD：`4759791`，含本次開始前已存在的未提交修改；不是乾淨 release benchmark，也不能代表客戶展示裝置的版本。
- 測試使用 App 內 SFace/YuNet Core ML 模型，預設 `MLModelConfiguration`，以及 production 的 preprocessing／inference wrapper／alignment／SQLite decoder／cosine matcher／confidence policy。
- 合成資料：640×480 等灰 BGRA、固定假 landmark、seeded 128D 向量；每會員 5 份樣本。沒有讀取會員資料或攝影機。
- 首次呼叫 n=1 單列；warm n=30，p50/p95 使用 nearest-rank。資料庫建立與填入不計入讀取耗時；read-decode 每次真正呼叫 SQLite store，並非直接使用快取陣列。
- known query 等於合成會員樣本，unknown query 來自另一 seed；每個量測都用既有 policy 檢查結果。但這只驗證合成比對路徑，不是人臉準確率，也沒有三個真實影格。
- native Vision production provider 限 iOS，macOS 明確排除，不能用 mock 速度補上。攝影機、frame wait、presence、真人影像、語音／網路與第一句播出均未量測。
- `inference-wrapper` 包含輸入／輸出驗證、tensor 配置與拷貝、Core ML inference；不能直接等同純模型計算時間。
- host `.mlpackage` compile 時間是工具準備工作；App 已打包 `.mlmodelc`，不可加到 App 冷啟動時間。
- 不將各階段的中位數相加宣稱端到端 p50/p95，不把無臉的早退路徑當陌生人辨識。

## 初步數據

| 階段（warm，n=30） | Debug p50 ms | Debug p95 ms |
| --- | ---: | ---: |
| YuNet 前處理 | 81.036 | 82.787 |
| YuNet inference wrapper | 306.527 | 311.730 |
| YuNet 空白輸入後處理 | 15.781 | 16.237 |
| SFace 對齊（假 landmark） | 14.069 | 14.478 |
| SFace inference wrapper | 10.729 | 11.263 |

| 合成名單（每人 5 份；n=30） | known 讀取／解碼 p50 ms | unknown 讀取／解碼 p50 ms | known 比對 p50 ms | unknown 比對 p50 ms |
| --- | ---: | ---: | ---: | ---: |
| 10 人 | 2.553 | 2.545 | 0.034 | 0.034 |
| 100 人 | 25.683 | 25.743 | 0.496 | 0.479 |
| 800 人 | 204.817 | 205.047 | 4.039 | 4.047 |

首次 model load（各 n=1，非冷機保證）：YuNet 143.365 ms、SFace 171.770 ms。

原始樣本（毫秒）：[Debug](performance/2026-09-23-identity-debug.json)。

## 最佳化對照

同一台 Mac、同樣的資料及 production 元件，`-c release -DDEBUG` 保留 pilot contracts；每項 warm n=30。兩次執行非交錯隨機 A/B，OS/ML cache、排程與環境仍可影響結果，需再做同一手機的對照，不能宣稱實機加速倍數。

| 元件 | Debug p50 ms | 最佳化 p50 ms | 最佳化 p95 ms |
| --- | ---: | ---: | ---: |
| YuNet 前處理 | 81.036 | 0.616 | 0.626 |
| YuNet inference wrapper | 306.527 | 3.662 | 6.263 |
| YuNet 空白輸入後處理 | 15.781 | 0.076 | 0.080 |
| SFace 假 landmark 對齊 | 14.069 | 0.513 | 0.539 |
| SFace inference wrapper | 10.729 | 1.480 | 3.573 |
| 800 人 known read/decode | 204.817 | 4.638 | 5.091 |
| 800 人 unknown read/decode | 205.047 | 4.681 | 4.782 |
| 800 人 known match | 4.039 | 0.479 | 0.597 |
| 800 人 unknown match | 4.047 | 0.474 | 0.675 |

[最佳化原始樣本](performance/2026-09-23-identity-optimized.json)。

優先建議：先比較仍保留 Live 身分辨識／登錄組合的最佳化編譯，不直接切換 Release-Live。上述差異支持「Swift Debug overhead 值得優先排查」，尚不足以證明手機慢的唯一根因。未更動任何 App build setting。

## 已知程式路徑與加速假說

1. `PilotIdentityRecognitionAdapter.recognizeCurrentVisitor()` 對 known 和 unknown 都固定取得三次新影格，再執行 policy；沒有已知會員提早成功返回。
2. `CoreMLIdentityCalibrationService.captureReturnVisit()` 每次成功取到 embedding 後，都重新呼叫 `store.sFaceSamples()`，再排名。三次觀測因此可能有三次完整讀取／解碼；gallery 越大越值得量測。
3. `captureUsableFace()` 的 presence 也會走到 embedding gate，但不查詢 gallery。人接近到開始辨識的等待，不能只用 matcher 時間解釋。
4. `SFaceFrameEmbeddingPipeline` 依序經 Vision、YuNet、對齊及 SFace；無臉或不符合配對條件會提前返回，所以 unknown 需拆未登錄單人、無臉、多人／品質等不同情境。
5. factory 依序載入 SFace/YuNet，App loader 已會共用與快取 service；不要在沒有 trace 證據時聲稱每一位訪客都重載模型。
6. `Debug-Live` project 設定含 `SWIFT_OPTIMIZATION_LEVEL = -Onone`。Host Swift Debug 大量 Swift 迴圈可能成本高；最佳化對照只能用來辨識方向，不等於已能切換 Release-Live。Release 能力／授權仍有獨立 gate。

優先候選是 tensor packing/copy、同一次辨識的 gallery snapshot、必要時現有生命週期內預載。先取得同裝置 baseline，再一次改一項、量測前後並跑正確性回歸。
較輕量 presence 偵測、提前結束三影格或換模型會涉及產品／辨識契約，不在本次改動；見 roadmap P0-2。

## 可重跑的離線工具

位於 `Tests/LumiInfrastructureTests/Identity/IdentityPerformanceProfileTests.swift`。
一般 `swift test` 不執行效能量測；只有設定輸出路徑才啟用。這是 opt-in profiling fixture，不是效能門檻或正式準確率測試。

```sh
LUMI_PROFILE_OUTPUT=/tmp/lumi-identity-profile-debug.json \
  swift test --filter IdentityPerformanceProfileTests

LUMI_PROFILE_CONFIGURATION='optimized debug pilot (-c release -DDEBUG)' \
LUMI_PROFILE_OUTPUT=/tmp/lumi-identity-profile-optimized.json \
  swift test -c release -Xswiftc -DDEBUG --filter IdentityPerformanceProfileTests
```

第二條保留現有 DEBUG-only pilot contracts 並使用最佳化；不是 Release composition 的發布驗證。
普通 `swift test -c release --filter IdentityPerformanceProfileTests` 仍會編譯其他 test target，目前因既有 `IdentityCalibrationPortTests` 依賴 DEBUG-only 型別而失敗；沒有為取得數字刪改那些測試。

## 實機結果：Blocked，手機鎖定

`xcrun devicectl list devices` 可看到配對 iPhone 15 Plus，但讀取 process 時 developer disk image 掛載失敗：
`kAMDMobileImageMounterDeviceLocked`。未安裝、重啟或啟動任何 App，未取得真人辨識數據。
Owner 尚需解鎖裝置並安排已登錄與未登錄受測者，才能完成下列流程。

## 實機 profiling 操作與驗收

1. 確認裝置解鎖、Developer Mode／連線可用，記錄 device model、OS、App revision、模型版本、gallery 數、溫度／電量及網路條件。不能讀出／匯出會員 gallery 來當 report。
2. 唯一合法 product-testing composition：`LumiApp-Live` / `Debug-Live`。若需新建置，遵循 AGENTS.md 實機命令；安裝前讀取 Info.plist，要求 `com.curves.lumi.live`，只啟動這個 ID。
3. 先利用現有 payload-free `continuous operation started/succeeded/failed/cancelled` 記錄定位粗階段。它不是完整 per-stage profile；若缺精確時間，先依 roadmap P0-1 用測試新增匿名 session-local timing/signpost，不能由 UI 推測或用測試 suite 時間代替。
4. 計時點：啟動／模型 load；presence 可用臉；正式 recognition 開始；每一新影格等待／Vision／YuNet／alignment／SFace／gallery read／match；判定完成；稱呼與 memory read；voice ready；實際第一個音訊開始播放。provider ready 不能當作使用者已聽見。
5. 對已登錄單人與未登錄單人，分冷啟動及連續 warm（建議每類 30 次），另測無臉／多人／低品質。冷啟動要記錄重啟方法及樣本數，OS/Core ML cache 未清除時不得宣稱完全冷機。
6. 每次事件按既有 confirmed-absence rearm 才開始下一次；不要為湊次數改成一直重迎賓。未登錄受測者不需要接受登錄、也不應被自動存檔。
7. 報告 known 與 unknown 各自 n、p50、p95、max、失敗／取消數、T_presence→decision 與 T_presence→first-audible；unknown 原因只在 Infrastructure 內分組，不把 `UnknownReason` 暴露給 UI 或 Application public recognition result。
8. 不保留 raw audio、照片、embedding、姓名、會員 ID 或逐字稿。若需 Instruments，限制 template／capture 到時間與必要運算資訊，查驗 artifact 不含敏感 payload。
9. 只有這些結果才能回答手機「認識／不認識各需幾秒」；達成後更新此檔並移除 roadmap P0-1 的已完成部分。

## 驗證紀錄

- 修改前基準：`swift test` 結束但失敗，905 tests / 72 suites 中 `reconnectPreservesSessionOnlyExerciseDisclosureWithoutReplayingOpener` 有 2 個 expectation issues（既有語音測試）；unsigned Simulator build 成功。
- Debug host profile：1/1 成功，30 次 warm samples/stage；原始日誌 `/tmp/lumi-identity-profile-debug.log`。
- 最佳化 pilot host profile：1/1 成功；原始日誌 `/tmp/lumi-identity-profile-optimized.log`。
- 最終 `swift test`：exit 0；Swift Testing 報 906 tests / 73 suites passed（其中本 opt-in profile 預設 skip），XCTest snapshots 4/4；原始日誌 `/tmp/lumi-roadmap-final-swift-test.log`。
- 最終指定 unsigned `LumiApp` Simulator build：exit 0，`BUILD SUCCEEDED`；日誌 `/tmp/lumi-roadmap-final-simulator-build.log`。
- 前後測試結果不一致，既有語音案例應保留為穩定性調查項，不能宣稱本次已修復。未修改該測試或 production 語音程式。
- 本次新檔只有 profiling test harness、效能報告／原始合成耗時、ADR 與 roadmap；production 行為未改。檔案連結與 scoped whitespace check 通過。

## 2026-09-30 遠距離辨識補充

目前相機 backend 選前鏡頭，但沒有在本程式明確指定 sessionPreset 或固定解析度；應量測實際 frame width/height，不能假設必為 720p 或 1080p。
YuNet 將整張畫面 aspect-fit 到 640×640。SFace 對齊裁切仍取自原始 frame，再產生 112×112 輸入，並非從 YuNet 縮圖裁切。
遠距離造成原始臉部細節不足時，插值放大無法補回；YuNet 的小臉關鍵點品質也可能先成為限制。這是待實測的原因假說，不是已證明的手機失敗根因。

量測需分「臉被偵測到」和「會員身分正確」，並覆蓋實際門店近／中／遠站位、光線、偏頭、移動及已登錄／未登錄者。距離是測試條件，不是新產品 threshold。
保存匿名數值（原始 frame 尺寸、臉框像素、耗時及彙總正確／誤認／unknown），不保存照片或會員識別碼。
加速編譯不等於增加遠距離資訊；不得為提高遠距離成功率任意降低信心門檻。

已接受的互動方向：較遠處先說一次不帶名字的「你好」；臉部尺寸顯示已靠近、且身分可靠時才叫名／個人提醒；若始終未靠近，不再發話。面向鏡頭可眨眼。數值門檻、偵測穩定度、朝向訊號與近階段文案仍依 [兩階段規格](two-stage-presence-greeting.md) 實測及確認；production 觸發規則尚未變更。
官方 [YuNet 4.10.0 說明](https://github.com/opencv/opencv_zoo/blob/4.10.0/models/face_detection_yunet/README.md)
談的是 face detection 的像素範圍，不是整個 Lumi pipeline 的身分辨識距離保證。
