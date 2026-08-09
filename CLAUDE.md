# Lumi

Curves Lumi Avatar — iPad ＋ iPhone SwiftUI，大眼睛虛擬助理角色。
規格是以 iPad 迎賓機寫的；iPhone 為後加需求，讀規格時遇到「iPad」請一併考慮小螢幕。

視覺與動畫的唯一權威是 `Curves_Lumi_Avatar_Visual_Spec.md`。
它有 27k 字，**不要整份讀進 context** — 動到 Avatar 相關程式前，只讀對應章節。

## 不可推導的決策

- **Vector-first**：眼睛／表情用 SVG、Vector PDF ＋ SwiftUI 原生動畫組合，
  不做 PNG／GIF 逐格換圖。想「多畫幾張表情圖」時，先回頭讀規格 §10。
- **狀態邊界**：`AssistantState`（Domain）不得含座標、透明度或任何 SwiftUI 型別。
  只有純函式 `AvatarStateMapper` 能轉成 `AvatarVisualState`，View 只消費後者。
- **動畫三層**：Continuous（眨眼、微眼動）／State（狀態表情）／Event（0.4–2s 覆蓋）
  由同一個合成器管理。合成順序 State → Continuous → Event → Accessibility 限制，
  最後一層永遠贏。多個 View 不得同時寫同一個參數。
- **左右眼共用 token**：非刻意表情不得出現不對稱的大小、光向或色彩。
- **不做對嘴**：`speaking` 的嘴巴只由平滑後的 amplitude 驅動開口量，不做音素／唇形同步。
  中文要對嘴需要 漢字→韻母 對照表，成本遠高於 iPad 觀看距離下的可見差異。已否決，別再提。
  amplitude 由合成器算一次（平滑→降採樣→clamp），嘴巴與 waveform 都只讀，不得各自訂閱音訊。
- **TDD 邊界**：`AvatarStateMapper` 是純函式，先寫測試。Clock 與 RandomSource
  必須可注入，否則 Continuous 層測不了。
- **不做 device 分支**：Avatar 畫在固定長寬比的座標系內，用 scale-to-fit 縮放。
  不得出現 iPad／iPhone 兩套 layout、兩套線寬或 `isPad` 判斷。
  版面差異（直向留白、對話泡泡位置）由外層容器處理，Avatar 本身不知道裝置。

## 規格用語

**必須** = 不做即不符規格；**應** = 偏離需記錄原因；**可以** = 選用。

## 溝通

以繁體中文回覆。
