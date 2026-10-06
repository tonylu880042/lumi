# Lumi 簡短接待與自然收尾

> 日期：2026-09-17
> 狀態：實作與自動化驗證完成；真實語音語境待實機驗收

## 已確認的體驗

2026-09-23 owner 修訂：Lumi 以打招呼與提醒為主要用途，不要求會員聊天或回答。
原本「約 30 秒交流」方向由 [ADR-0019](decisions/ADR-0019-greeting-reminder-first.md)
取代：一次一個重點，說完留白；這不新增固定時間中斷或自動斷線。
回應以 1–2 句為主，不為延長對話而新增話題或固定追問
「還有什麼想聊的嗎？」。必要的問題、隱私與同意說明仍完整保留。
客人仍有問題時繼續協助；自然祝福或收尾語本身不等於客人要求斷線。

當客人清楚表示結束這次聊天，例如「再見」「掰掰」「不聊了」，
Lumi 道別一次，結束語音連線，透過既有 Application 流程返回待機。
不能只因一句話包含關鍵字就結束：「先別說再見，我還有問題」、
「再見英文怎麼說？」或引用別人的話都不是結束意圖。

同一次鏡頭前停留在道別後不立即重新迎賓。沿用已批准的 presence
重置條件，等待確認離開後才允許下一次自動迎賓，不新增 checkout 計數。

## 道別聲音

Live 組合重用已批准的 Marin 音檔 `07-goodbye`：
「謝謝妳來跟我聊天，祝妳今天有個好心情！」。
這句可結束對話而不假設客人正離開店內；`08-goodbye` 的
「路上小心」保留給未來具有實際離店語境的功能。
本期不重新生成聲音，不改變語音模型。2026-09-17 後續核准的響度校準
可調整這段既有錄音的音量與峰值，見 `audio-loudness-calibration.md`。

2026-09-23 後續缺口：`07-goodbye` 的「來跟我聊天」仍是舊錄音內容。
修改 prompt 無法改變 WAV，需另完成新版簡短道別音檔與音量／播放驗收；
在此之前，不得聲稱整個 Live 體驗已移除聊天定位。

正常路徑只播放一次道別，播放完成後關閉連線。
播放失敗也必須能結束；停止、取消、舊 session 回呼或重複工具事件
不可造成重播、重新啟動語音或影響下一位客人。

## 實作與驗證界線

Infrastructure 使用模型的上下文判讀接收收尾意圖；Application
只接收不帶逐字稿、姓名或 provider payload 的生命週期訊號。
Application 保持 session 狀態與硬體回 Home 的唯一管理者。
會員資料查詢、登錄同意與既有權限維持原規則。

自動化測試驗證收尾工具契約、單次播放、輸入保護、播放完成後結束、
失敗／取消／重複／過期事件與同次 presence 不重迎賓。
提示文字測試只能確認指示存在，不能證明真實模型一定理解否定語境。

## 待實機驗收的對話

1. 客人說「今天很累」，Lumi 簡短接話，不刻意新增聊天問題。
2. 客人說「再見」或「我不聊了」，一次道別後回到待機。
3. 客人說「先別說再見，我還有問題」，繼續回答。
4. 客人問「再見英文怎麼說？」，正常解答。
5. 超過約 30 秒仍有實際問題，不被計時器切斷。
6. 說完再見仍站在鏡頭前，不立即重新迎賓；確認離開後的新到訪能開始。
7. 道別期間停止 App／斷線／重試，不殘留播放或重複收尾。

實際模型意圖辨識率、延遲、現場語音效果與節費幅度需另行量測。

## 2026-09-17 開發驗證

- `swift test`：844 個測試、66 個 suite 全數通過。
- `LumiApp` Simulator build（不簽章）：成功。
- `LumiApp` Simulator test：118 個測試、11 個 suite 全數通過。
- `LumiApp-Live` / `Debug-Live` iPhone build：成功；已確認產物 bundle identifier 為 `com.curves.lumi.live`。
- 回歸測試先重現並修正：重複道別、道別途中斷線重連、麥克風關閉失敗仍播放、
  重複停止、錯用離店道別與缺少本機播放的 speaking 狀態事件。
- App 整合測試確認：道別後回待機、同次停留不重迎賓、確認離開後下位訪客可開始。
- 不含真實模型語意辨識率或現場音質的驗收；上列實機對話清單仍需試說。

測試記錄位於本機 `/private/tmp/lumi-natural-closing-swift-test.log`、
`/private/tmp/lumi-natural-closing-simulator-build.log` 與
`/private/tmp/lumi-natural-closing-app-tests.log`。

實機部署：2026-09-17 已安裝到 TonyLu 的 iPhone 15 Plus，安裝回報的
bundle ID 為 `com.curves.lumi.live`。第一次無線安裝逾時，延長時間重試成功；
記錄 `/private/tmp/lumi-natural-closing-install-retry.json` 回報 `success`。
`/private/tmp/lumi-natural-closing-launch.log` 確認已啟動 `com.curves.lumi.live`。
安裝成功不代表上述真實語境已驗收。
