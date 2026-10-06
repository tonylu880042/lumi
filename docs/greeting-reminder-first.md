# Lumi 打招呼與提醒優先 — Luna 實作包

> 日期：2026-09-23
> Owner 已核准產品定位；P0-4A 已由 Luna 完成，2026-09-30 parent 自動化驗證通過；音檔更新與 Live 語音驗收待辦。
> 決策：[ADR-0019](decisions/ADR-0019-greeting-reminder-first.md)

## 產品目的

Lumi 是主動打招呼與提醒的店內小幫手。會員不需要停下來陪 Lumi 聊天。
一次簡短招呼或一個有依據的提醒，說完留白；不要邀聊、延續話題或把互動撐到約 30 秒。

必要互動仍保留：說明登錄用途並取得同意、詢問稱呼、接收更正、簡短回答會員主動提出的服務問題。
需要回答才能繼續的同意／稱呼步驟，不能因「會員不用回答」而跳過。

## 第一包：P0-4A 提示政策（Luna）

Ownership：`OpenAIConversationPrompts.swift` 與既有 `OpenAIRealtimeConfigurationTests.swift`；
必要時擴及直接驗證該提示的 Voice tests，先與 parent 協調。
Parent 負責規格／roadmap、獨立 review、全套測試與 build。
共享工作區有先前修改；不得 revert、reset 或覆蓋其他工作，不自行 commit/push/deploy。

順序：

1. 讀 AGENTS、SYSTEM_SPEC、architecture、適用 ADR 與此規格。
2. 先新增能在舊提示失敗的契約測試，記錄 RED；不得只改測試去迎合現有文案。
3. 最小修改提示：迎賓／提醒優先、一次一個重點、不要求例行回答、不邀聊、不主動擴展話題、移除三十秒交流目標。
4. 跑 focused GREEN；核對 named／anonymous known、unknown、enrollment、memory、pre/post-workout 的組合沒有互相抵觸。
5. Parent 審查並執行全套檢查；把真人驗收與音檔缺口保留在 roadmap。

不可擅改：工具與資料權限、登錄順序／三份特徵／不存照片、模型／聲音／token cap、
音檔、state machine、麥克風、timer、自動斷線、辨識閾值與事件去重。
這個 slice 不會解決所有「不反應」或自動離店提醒，需要 roadmap 其他任務。

## 可驗收的指示契約

| 情境 | 指示應達成 | 保留邊界 |
| --- | --- | --- |
| 一般迎賓／提醒 | 1–2 句、一個重點、說完留白，不邀聊或用追問延長 | 無資料不捏造，沒有新的硬秒數限制 |
| 已知會員 | 可自然使用已確認稱呼，不重新問候或列舉歷史 | 沒有有效稱呼不自創；memory 不冒充運動次數 |
| 不認識的會員 | 簡短一般問候；可依既有流程介紹認識用途 | 說明臉部特徵與不存照片、明確同意後才取樣、取樣後再問稱呼 |
| 會員主動回話／更正 | 先接住內容、簡短處理，不延伸下一個話題 | 模糊或未同意內容不任意寫入 |
| 運動前／後方向 | 可用的短提醒／肯定；不以回顧問句強迫回答 | direction 不授予資料查詢權限 |
| 明確道別 | 既有一次道別與受控結束 | 否定／引用不是道別；不重播、不把聊天結束當完成運動 |

## 示意文案（非要求逐字輸出）

- 一般：「妳好，我是 Lumi，店裡的小幫手！」
- 已認識：「Angela，歡迎回來，今天也一起加油！」
- 運動後語境已明確但無次數資料：「今天運動辛苦了，妳很努力！」
- 有必要回應時：用簡短一句接住，不在結尾加「還想聊什麼？」。
- 月初量身面談與週月次數提醒：須先完成 roadmap 的來源／日期／觸發等決策，這一包不擅自開啟。

## 後續缺口（不可視為第一包已完成）

- `07-goodbye` 仍含「謝謝妳來跟我聊天」。需另製符合新定位的短道別音檔，保留聲音一致性與響度校準；不能只改文字文件就當 WAV 已更新。
- 檢查其他迎賓 WAV 的實際文案，不能只靠檔名判斷；若需替換，列明新文案、素材來源與驗證。
- Live 真人檢查：會員不答不被追問；同意／稱呼仍等待有效回答；短回應不開新話題；不要把準備中／斷線誤認為留白。
- 觀察／恢復／效能與資料提醒仍依 roadmap P0-1～P2、D1～D9 處理。

## 驗證結果

Luna 回報的 TDD 證據：

- RED：`swift test --filter OpenAIRealtimeConfigurationTests`，9 個測試中 1 個失敗、11 個 assertion；舊提示仍含三十秒目標／固定聊天問題，缺少新單一重點指示。首次 sandbox cache 失敗不算 RED，Luna 表示在核准的執行環境重跑取得上述實際失敗。
- GREEN：`swift test --filter 'CoreMLIdentityCalibrationServiceTests|OpenAIRealtimeConfigurationTests|OpenAIRealtimeAdapterTests'`，94 tests / 3 suites 通過。
- 只修改提示 catalog 與 configuration tests；沒有 timer、音檔、transport、trigger、token cap 或授權變更。

Parent 2026-09-30 獨立驗證：

- Review：已核對 named／anonymous／enrollment／memory／pre-post方向與關閉工具；保留必要同意、最小資料存取、無回覆不等於自動關麥或斷線。
- `swift test`：exit 0，Swift Testing 906 tests / 73 suites passed（opt-in profiling fixture 預設略過），XCTest snapshot 另 4/4；日誌 `/tmp/lumi-greeting-reminder-swift-test.log`。
- 指定 unsigned `LumiApp` Simulator build：exit 0，`BUILD SUCCEEDED`；日誌 `/tmp/lumi-greeting-reminder-simulator-build.log`。
- scoped `git diff --check` 通過。

運動前／後的「主動短提醒」是提示政策，不會額外產生 response.create 或排程；預錄迎賓後的觸發流程仍沿用既有實作。提示契約測試不能證明模型每次遵守，也不能宣稱已完成資料驅動自動提醒。
舊 `07-goodbye` 音檔與真人驗收仍未完成，不將本次當作完整 Live 體驗驗收。未 commit、push 或部署。
