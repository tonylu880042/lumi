# Curves Lumi Avatar 視覺資源與眼睛設計規範

> 文件狀態：Draft v1.0  
> 適用範圍：iPad SwiftUI MVP 與後續視覺資源交付  
> 主要讀者：產品、視覺設計、iOS、QA  
> 更新日期：2026-08-08

## 1. 目的與設計決策

本文件定義 Curves Lumi Avatar 的視覺語言、可動畫參數、SwiftUI 實作邊界、素材交付方式與測試原則。目標是讓 Lumi 呈現親切、溫暖、略帶俏皮且有生命感的大眼睛角色，同時避免用大量完整表情圖造成資源與狀態組合失控。

核心方向為：

> **Vector-first + SwiftUI Native Animation + 少量特殊資源**

建議比例可作為規劃參考，而非硬性採購或容量限制：

- 約 80%：SwiftUI 原生組合與動畫。
- 約 15%：SVG、Vector PDF 或其他可縮放向量素材。
- 約 5%：只有在原生繪製不合理時使用的特殊慶祝素材。

核心分工原則：

> **視覺資源描述「長什麼樣」；`AvatarVisualState` 描述「現在呈現什麼」；動畫層決定「如何從目前畫面過渡」。**

`AssistantState` 是產品與 Domain 狀態；它不應包含眼睛座標、透明度或 SwiftUI 型別。Presentation 層以純函式 `AvatarStateMapper` 將它轉換為 `AvatarVisualState`，SwiftUI View 只消費後者。

```text
AssistantState
      ↓
AvatarStateMapper（Presentation）
      ↓
AvatarVisualState
      ↓
Continuous / State / Event 動畫合成
      ↓
LumiAvatarView（SwiftUI）
```

## 2. 視覺基調與驗收語言

Lumi 的視覺應具有以下特徵：

- 大眼睛、紫色或紫藍色虹膜，整體明亮但不刺眼。
- 水汪汪的多點高光，而非單一白點或單純實心圓。
- 親切、有活力、溫暖、有一點俏皮，但不幼兒化。
- 沒有互動時仍有微小生命感；互動時狀態變化清楚但不躁動。
- 左右眼使用同一套設計 token；非刻意表情不得產生不一致的大小、光向或色彩。
- 所有數值參數應可插值、可限制範圍、可測試。

以下詞彙作為共同驗收標準：

- **必須**：若未達成即不符合本規格。
- **應**：原則上遵守；若偏離需記錄原因。
- **可以**：選用項目，不影響基準驗收。

## 3. Avatar 與眼睛圖層拆解

Avatar 不以一張完整臉部圖片交付，而應拆成可獨立控制與重用的圖層。

```text
LumiAvatar
├─ Background / Ambient Glow
├─ LeftEye
│  ├─ EyeWhite（眼白）
│  ├─ IrisOuterRing（虹膜深色外圈）
│  ├─ IrisBody（虹膜主體與深淺漸層）
│  ├─ Pupil（瞳孔）
│  ├─ SoftGloss（柔光／玻璃感漸層）
│  ├─ Highlights（2–4 個白色圓／橢圓高光）
│  ├─ UpperEyelid（上眼皮）
│  └─ LowerEyelid（下眼皮，可選）
├─ RightEye（與 LeftEye 同構）
├─ Eyebrows（左右眉毛）
├─ Blush（左右腮紅）
├─ Mouth（嘴型）
├─ Waveform（Listening / Speaking）
└─ Effects
   ├─ Sparkles
   ├─ Hearts
   ├─ QuestionMark
   ├─ SweatDrop
   └─ Celebration
```

### 3.1 建議繪製順序

單眼由後至前的基準順序：

1. 眼白。
2. 虹膜深色外圈。
3. 虹膜主體與放射／線性漸層。
4. 瞳孔。
5. 虹膜上半部柔光漸層。
6. 多個白色高光圓或橢圓。
7. 眼皮與眼框遮罩。

虹膜、瞳孔、柔光與高光應在眼睛形狀內被裁切。瞳孔位移時不得穿出眼白或被硬切成不自然形狀；先對正規化座標做限制，再轉為實際點數。

### 3.2 各圖層責任

| 圖層 | 視覺責任 | 動態控制建議 |
|---|---|---|
| 眼白 | 提供清楚輪廓與可讀性 | 輕微縮放；主要由眼皮控制開合 |
| 虹膜 | 角色主色、視線與情緒焦點 | 位置、縮放、亮度 |
| 瞳孔 | 注視方向與專注程度 | X/Y 位移、縮放 |
| 白色高光 | 水汪汪與生命感 | 整體透明度、縮放、短暫增亮 |
| 柔光漸層 | 玻璃感與濕潤感 | 低幅度透明度變化 |
| 深色外圈 | 增加虹膜層次與辨識度 | 通常固定；避免獨立跳動 |
| 眼皮 | 眨眼、笑眼、疲倦與休息 | 開合量、曲率、上下位置 |
| 眉毛 | 好奇、專心、困惑與關心 | 樣式、旋轉、垂直位移 |
| 腮紅 | 溫度、迎賓與鼓勵感 | 透明度、極小幅度縮放 |
| 嘴型 | 微笑、驚訝與語音回饋 | 樣式、開口量；MVP 不必做完整唇形同步 |
| Effects | 星星、愛心、問號、汗滴與慶祝 | 事件觸發、有限時長、可中斷 |

## 4. 「水汪汪」眼睛規則

### 4.1 高光數量與位置

- 每眼必須有 **2–4 個不同大小**的白色高光圓或橢圓。
- 主高光位於虹膜左上方，為最大且最亮的高光。
- 次高光靠近主高光，但尺寸明顯較小，避免看成兩個同權重白點。
- 至少可以有一個位於右下或下半部的低透明反光，作為環境光回彈。
- 左右眼的主光源方向必須一致；不得一眼左上亮、另一眼右上亮。
- 高光位置使用虹膜局部正規化座標描述，並隨虹膜群組移動；不得在每一幀隨機換位。

建議基準值如下：

| 元件 | 虹膜直徑占比 | Opacity | 基準位置（局部座標） |
|---|---:|---:|---|
| 主高光 | 18–26% | 0.90–1.00 | x: -0.28，y: -0.30 |
| 次高光 | 7–12% | 0.75–0.95 | x: -0.05，y: -0.18 |
| 低透明反光 | 8–16% | 0.10–0.28 | x: +0.25，y: +0.28 |
| 可選微光點 | 3–7% | 0.35–0.65 | 靠近上半部、不得與主高光重疊 |

局部座標以虹膜中心為 `(0, 0)`；X 向右、Y 向下。數值是設計起點，最終以實機 iPad 觀看距離驗收。

### 4.2 虹膜層次與玻璃感

虹膜不得只使用單一實色。至少應包含：

1. 深色外圈：定義邊界與深度。
2. 中間主色：紫色或紫藍色品牌主體。
3. 靠近左上主高光處的局部提亮。
4. 靠下方或外緣的略深色區域。
5. 虹膜上半部的低透明白色橢圓或漸層，形成玻璃反光。

可使用 `RadialGradient` 搭配一層 `LinearGradient` 或橢圓柔光。玻璃感應來自層次與透明度，不應依賴高強度模糊或昂貴的每幀濾鏡。

### 4.3 動態規則

- 一般狀態只調整整組高光的 `opacity`、`scale` 或微量亮度，不改變光源方向。
- `greeting`、`encouraging` 可將高光強度提高約 15–30%，虹膜放大約 5–12%。
- `confused`、`offline` 可降低高光，但主高光不應完全消失，避免角色看起來失去生命。
- 高光的連續呼吸變化應低於主狀態變化，且週期不可與固定眨眼形成機械式同步。
- 若開啟「減少動態效果」，保留靜態多點高光，只停用脈動、彈跳與大幅粒子移動。

## 5. AssistantState 與視覺參數對應

### 5.1 共同參數範圍

- `eyeOpenAmount`：`0...1`，0 為閉眼，1 為完全張開。
- `pupilOffset.x`：建議限制在 `-0.65...0.65`。
- `pupilOffset.y`：建議限制在 `-0.45...0.45`。
- `irisScale`：一般建議 `0.92...1.12`。
- `pupilScale`：一般建議 `0.88...1.08`。
- `highlightIntensity`、`blushOpacity`、`sparkleIntensity`：`0...1`。

所有表格數值為基準 token。狀態 Mapper 應輸出確定值；微眼動、音量與人臉追蹤等即時輸入由後續動畫合成層疊加。

### 5.2 基準狀態表

| `AssistantState` | 視覺目的 | 眼睛／瞳孔 | 水光與臉部 | 眉毛／嘴型／Effects | 建議過渡 |
|---|---|---|---|---|---|
| `idle` | 平靜、有生命但不打擾 | 開眼 0.88；虹膜 1.00；瞳孔置中；允許 ±0.05 微眼動 | 高光 0.70；腮紅 0.15 | 中性眉；柔和微笑；sparkle 0.15 | 300–500 ms ease-in-out |
| `detected` | 先注意來客方向 | 開眼 1.00；瞳孔 X 朝來源方向約 ±0.55；虹膜 1.05 | 高光 0.85；腮紅 0.20 | 眉毛輕抬；sparkle 0.30 | 180–260 ms ease-out |
| `recognizing` | 專注辨識、避免像錯誤 loading | 開眼 0.95；瞳孔跟隨臉部；虹膜 0.98；瞳孔 0.92 | 高光 0.65；腮紅 0.10 | 專注眉；中性嘴；小型微光 | 200–300 ms ease-in-out |
| `greeting` | 最有溫度的迎賓表情 | 開眼 1.00；置中；虹膜 1.08 | 高光 1.00；腮紅 0.70 | 柔和抬眉；笑嘴；sparkle 0.90 | 350–550 ms spring |
| `listening` | 清楚表示正在聆聽 | 開眼 0.92；穩定注視來客；虹膜 1.00 | 高光 0.75；腮紅 0.25 | 專注眉；中性嘴；輸入 waveform | 180–280 ms ease-in-out |
| `thinking` | 將等待轉成角色行為 | 開眼 0.88；瞳孔右上約 `(0.30, -0.35)`；虹膜 0.97 | 高光 0.65，可低幅脈動；腮紅 0.15 | 一側眉輕抬；小嘴；sparkle 0.35 | 250–400 ms ease-in-out |
| `speaking` | 穩定、自然地回應 | 開眼 0.92；眼神回到來客；虹膜 1.00 | 高光 0.75；腮紅 0.30 | 溫暖眉；嘴型或輸出 waveform 隨音量變化 | 120–220 ms；音訊值平滑化 |
| `encouraging` | 活力鼓勵與小型慶祝 | 開眼 1.00；虹膜 1.12；瞳孔 1.06 | 高光 1.00；腮紅 0.85 | 開心眉；大笑嘴；sparkle 1.00，可有愛心 | 450–700 ms spring/keyframe |
| `reminding` | 溫柔關心，不像警告 | 開眼 0.90；置中；虹膜 0.98 | 高光 0.65；腮紅 0.25 | 關心眉；柔和微笑；sparkle 0.15 | 250–400 ms ease-in-out |
| `confused` | 表達沒聽清楚而非責怪會員 | 開眼 0.86；瞳孔偏側約 0.25；虹膜 0.96；瞳孔 0.92 | 高光 0.45；腮紅 0.10 | 不對稱眉；小 O 嘴；QuestionMark | 250–400 ms ease-in-out |
| `offline` | 休息、離線或打烊 | 開眼 0.45；瞳孔略向下；虹膜 0.92 | 高光 0.25；腮紅 0 | 放鬆眉；中性嘴；無 waveform/effect；整體降亮度 | 500–900 ms ease-in-out |

### 5.3 狀態與事件的界線

`playful`、`memberRecognized`、`firstVisit`、`longTimeNoSee`、`goalAchieved`、`weeklyGoalCompleted` 與 `error` 等較適合定義為短暫 Event，而非長駐 `AssistantState`。事件結束後應回到「當下最新的主狀態」，不可回到事件開始時已過期的狀態。

`encouraging` 與 `confused` 是可持續到下一次轉移的 `AssistantState`，不是短暫 Event。Domain 不得再為同一語意新增 `encouragement`、`retry` 或 `confusion` 等重複 Event case；短暫的 sparkle、question mark 等效果由既有 Event 或 Presentation 合成器處理。

Phase 1 已新增不帶方向參數的 `rotating`；其表情使用置中、專注的等待視覺，不延續 `detected` 的左右注視、不顯示 waveform，也不加入 Event effect。它必須保有明確 mapping、測試與 snapshot，不可由 View 以 `default` 靜默落回 `idle`。`ending` 與 `returnHome` 是 Application action，不是 `AssistantState`。

Domain Event 必須先由 Presentation 完整映射成 `AvatarEventCommand`；`LumiUI` 不得直接 import `LumiDomain`。本節邊界以 `docs/decisions/ADR-0005-development-scope-and-boundaries.md` 為準。

## 6. `AvatarVisualState` 建議欄位

以下為建議的 Presentation Model。型別名稱可以配合專案調整，但欄位語意、範圍與預設值應集中管理。

```swift
struct NormalizedOffset: Equatable, Sendable {
    var x: Double   // Recommended clamp: -0.65 ... 0.65
    var y: Double   // Recommended clamp: -0.45 ... 0.45
}

struct AvatarVisualState: Equatable, Sendable {
    // Eyes
    var eyeOpenAmount: Double
    var eyeSquintAmount: Double
    var irisScale: Double
    var irisBrightness: Double
    var pupilOffset: NormalizedOffset
    var pupilScale: Double

    // Watery-eye treatment
    var highlightIntensity: Double
    var highlightScale: Double
    var softGlossOpacity: Double

    // Expression
    var eyelidStyle: EyelidStyle
    var eyebrowStyle: EyebrowStyle
    var eyebrowTilt: Double
    var blushOpacity: Double
    var mouthStyle: MouthStyle
    var mouthOpenAmount: Double

    // Feedback
    var audioAmplitude: Double
    var sparkleIntensity: Double
    var waveformMode: WaveformMode
    var effect: AvatarEffect?
    var effectIntensity: Double   // Recommended clamp: 0 ... 1; nil effect is always 0

    // Whole-avatar presentation
    var overallBrightness: Double
    var transition: AvatarTransition
}
```

建議 enum：

```swift
enum EyelidStyle: Equatable, Sendable {
    case neutral, happyCurve, focused, sleepy
}

enum EyebrowStyle: Equatable, Sendable {
    case neutral, raisedSoft, attentive, thinking, joyful
    case concernedSoft, asymmetricConfused, relaxed
}

enum MouthStyle: Equatable, Sendable {
    case neutral, softSmile, smile, wideSmile, smallO
}

enum WaveformMode: Equatable, Sendable {
    case none, microphoneInput, audioOutput, processing
}

enum AvatarEffect: Equatable, Sendable {
    case sparkles, hearts, questionMark, sweatDrop
    case celebration(CelebrationKind)
}
```

設計約束：

- `AvatarVisualState` 必須是純資料，不持有 Timer、Task、Audio Engine、View 或 Closure。
- `AvatarStateMapper` 必須是同步且可重現的純函式；隨機眨眼不得放在 Mapper。
- 所有正規化數值應由單一 clamp／validation 邊界保護。
- 音量、人臉位置與感測方向先轉為正規化資料，再進入視覺合成層。
- 顏色與幾何常數應集中為 design tokens，不散落在各個 View。

## 7. SwiftUI 實作建議

### 7.1 技術分工

| SwiftUI 技術 | 適合用途 |
|---|---|
| `ZStack` | 組合眼白、虹膜、瞳孔、高光、眼皮與 Effects |
| `Shape` / `Path` | 眼框、眼皮、眉毛、嘴型等可縮放幾何 |
| `Canvas` | 音訊 waveform、多顆粒 sparkle、需要批次繪製的 2D 效果 |
| `withAnimation` | `AssistantState` 變更造成的單段參數插值 |
| `PhaseAnimator` | 眨眼階段、短促提示、有限步驟的表情序列 |
| `KeyframeAnimator` | Greeting 彈跳、達標慶祝等需要精確時間軸的事件 |
| `TimelineView` | 低幅度連續呼吸、微光與自訂時間驅動繪製 |
| `mask` / `clipShape` | 確保虹膜與瞳孔不超出眼睛輪廓 |

### 7.2 View 組合示意

```swift
struct LumiEyeView: View {
    let state: AvatarVisualState
    let highlights: [EyeHighlight]

    var body: some View {
        ZStack {
            EyeWhiteShape()
                .fill(.white)

            ZStack {
                Circle()
                    .fill(Color.lumiIrisOuter)

                Circle()
                    .inset(by: 3)
                    .fill(
                        RadialGradient(
                            colors: [.lumiIrisLight, .lumiIris, .lumiIrisDark],
                            center: .topLeading,
                            startRadius: 2,
                            endRadius: 44
                        )
                    )

                Circle()
                    .fill(Color.lumiPupil)
                    .scaleEffect(state.pupilScale)

                Ellipse()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(state.softGlossOpacity), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 34)
                    .offset(y: -12)

                ForEach(highlights) { highlight in
                    Ellipse()
                        .fill(.white.opacity(
                            highlight.baseOpacity * state.highlightIntensity
                        ))
                        .frame(
                            width: highlight.width,
                            height: highlight.height
                        )
                        .offset(highlight.offset)
                }
            }
            .scaleEffect(state.irisScale)
            .offset(pupilAndIrisOffset)
            .clipShape(EyeWhiteShape())

            EyelidView(
                openAmount: state.eyeOpenAmount,
                squintAmount: state.eyeSquintAmount,
                style: state.eyelidStyle
            )
        }
        .accessibilityHidden(true)
    }
}
```

此段為結構示意；實作時應由 GeometryReader 或 layout token 將正規化位移換算為實際點數，且同一個視線 offset 應一致套用到虹膜相關群組。

### 7.3 動畫使用原則

- 狀態切換：在單一協調點使用 `withAnimation`，避免每個子 View 各自猜測 animation。
- 眨眼：以 `Open → Closing → Closed → Opening → Open` 表示；隨機等待由可注入 Clock 與 RandomSource 控制。
- `PhaseAnimator` 適合短階段動畫；若需要隨機 2–6 秒眨眼，應由 controller 觸發一次 blink sequence，而非讓固定 phase 永久循環。
- `KeyframeAnimator` 適合 1–2 秒 Event；昂貴計算不得放入每幀執行的 content closure。
- Waveform 的 raw amplitude 應先做平滑、降採樣與最大值限制，避免抖動及不必要重繪。
- Effects 結束時移除事件 overlay，不直接改寫 Domain 狀態。
- 畫面離開、App 進入背景或 `offline` 時，停止不必要的時間軸與音訊驅動畫面更新。
- 支援系統「減少動態效果」：將大幅彈跳、旋轉與粒子移動替換為短淡入淡出或靜態圖示；不得直接移除事件的語意回饋。

## 8. 動畫分層：Continuous / State / Event

三層應由同一個 Presentation 合成器管理，避免多個 View 同時寫同一個參數。

| 層級 | 內容 | 生命週期 | 參數權限 | 測試重點 |
|---|---|---|---|---|
| Continuous | 自然眨眼、微眼動、微小呼吸、柔光脈動 | 長駐；背景／離線時可暫停 | 只能做低幅度 additive modifier | 範圍、取消、Clock、RandomSource |
| State | `AssistantState` 對應的核心表情 | 持續到下一個狀態 | 提供 base visual state | 每個狀態的確定 mapping |
| Event | 辨識成功、達標、初次到店、錯誤提示等 | 通常 0.4–2 秒，可中斷 | 可暫時覆蓋指定參數或添加 Effects | 優先權、重入、取消、結束回復 |

建議合成順序：

```text
State base
   + Continuous low-amplitude modifiers
   + Event overlay（最高視覺優先權）
   + Accessibility / safety constraints（最後限制）
   = RenderedAvatarVisualState
```

優先權規則：

1. Accessibility 與安全限制永遠最後生效。
2. Event 只覆蓋它宣告擁有的欄位；其餘仍取最新 State。
3. State 決定語意與主要表情。
4. Continuous 不得讓 `offline` 看起來興奮，也不得把 `confused` 的視線拉回中央。
5. 同時只保留一個 Event；新 Event 立即取代舊 Event，不排隊、不疊加。取消會立即清除，逾時後回到當下最新的主狀態。
6. `LumiUI` 只接收 Presentation `AvatarEventCommand`；不得直接接收 Domain `AssistantEvent`。
7. Reduced Motion 仍保留事件的靜態圖示或短淡入淡出，只移除位移、彈跳、旋轉與循環粒子。

## 9. 圖像資源交付結構

### 9.1 建議目錄

```text
Avatar/
├─ README.md
├─ Tokens/
│  ├─ avatar-colors.json
│  └─ avatar-metrics.json
├─ Eyes/
│  ├─ eye-white.svg
│  ├─ iris-outer-ring.svg
│  ├─ iris-body.svg
│  ├─ pupil.svg
│  ├─ soft-gloss.svg
│  ├─ highlight-main.svg
│  ├─ highlight-secondary.svg
│  ├─ highlight-reflection.svg
│  ├─ eyelid-upper.svg
│  └─ eyelid-lower.svg
├─ Brows/
│  ├─ brow-left.svg
│  └─ brow-right.svg
├─ Mouth/
│  ├─ mouth-neutral.svg
│  ├─ mouth-soft-smile.svg
│  ├─ mouth-wide-smile.svg
│  └─ mouth-small-o.svg
├─ Face/
│  ├─ blush-left.svg
│  └─ blush-right.svg
├─ Effects/
│  ├─ sparkle-01.svg
│  ├─ sparkle-02.svg
│  ├─ heart.svg
│  ├─ question-mark.svg
│  ├─ sweat-drop.svg
│  └─ Celebration/
└─ Icons/
   ├─ microphone.svg
   ├─ exercise.svg
   └─ hydration.svg
```

### 9.2 SVG / Vector PDF 建議

- 設計原始檔優先保留 SVG；iOS Asset Catalog 可依專案工具鏈選擇 SVG 或 Vector PDF。
- 需要在 SwiftUI 中連續變形、裁切或依參數生成的幾何，優先實作為 `Shape`／`Path`，不要輸出多份近似素材。
- 所有眼睛元件使用一致 artboard、中心點與座標基準，確保左右眼定位可預測。
- 向量素材不得內嵌點陣圖；文字應轉外框或改由 App 字型呈現。
- 素材必須提供透明背景、sRGB 色彩空間、命名一致且無空白字元。
- 左右對稱元件若只是鏡像，原則上交付一份並由程式鏡像；若光向、眉型或品牌細節不同，才交付左右兩份。
- 高光可以是 SwiftUI Ellipse token，而不必每顆都做檔案；若有特殊不規則光斑，再以向量素材交付。
- 每個特殊完整動畫必須另附：尺寸、幀率、循環規則、時長、透明背景需求、靜態 fallback 與 Reduced Motion fallback。

### 9.3 設計交付清單

- 正常狀態與所有基準 `AssistantState` 的組合預覽。
- 左、中、右與右上注視方向預覽。
- 完全張眼、半閉眼、閉眼與笑眼預覽。
- 高光圖層單獨開關的對照圖，以驗證水汪汪效果。
- 淺色／深色背景上的對比檢查。
- iPad 目標尺寸 1x 實機預覽，不只在設計工具中放大觀看。
- Design tokens 與素材版本號。
- 所有非向量特殊資源的授權、來源與壓縮規格。

## 10. 不建議大量 PNG / GIF 換圖

禁止將主要狀態設計成以下形式：

```text
idle.png
blink.png
happy.png
listening.gif
thinking.gif
speaking.gif
happy-02.png
happy-03.png
...
```

原因：

- 狀態、視線方向、眨眼與高光強度會形成組合爆炸。
- PNG 在不同 iPad 尺寸與未來解析度下需要多倍率資源。
- GIF 難以和即時音量、人臉位置、感測方向及狀態切換同步。
- 換圖容易產生尺寸、中心點、顏色與光向跳動。
- 大量點陣幀增加 App 體積、記憶體與設計維護成本。
- 無法自然插值，未來新增 `.shy`、`.proud`、`.sleepy` 等表情時必須再製作整套圖片。

可以接受點陣或預先渲染資源的例外：

- 只有少數、短暫且高複雜度的 Celebration。
- 非角色 UI 的會員照片或背景攝影。
- 經 profiling 證明原生向量實作成本或效能不合理的效果。

即使使用例外資源，也必須保留靜態 fallback、可取消播放、事件結束回復與 Reduced Motion 版本。

## 11. TDD 測試原則與例子

### 11.1 原則

採用 Red → Green → Refactor：先用失敗測試描述狀態映射、動畫合成或邊界行為，再寫最少程式通過，最後在測試保護下整理實作。

優先測試可觀察行為與資料契約：

1. **Mapper 單元測試**：每個 `AssistantState` 產生正確的 `AvatarVisualState`。
2. **邊界測試**：瞳孔位移、透明度與縮放會被限制在安全範圍。
3. **合成器測試**：Continuous、State、Event 與 Reduced Motion 優先權正確。
4. **事件生命週期測試**：可取消、不重複疊加，結束後回到最新主狀態。
5. **Clock／Random 測試**：眨眼以注入的 Clock 與 RandomSource 測試，不在測試中真實等待。
6. **音訊轉換測試**：RMS/amplitude 的平滑、降採樣與 clamp 可預測。
7. **Snapshot／圖像回歸測試**：驗證每個狀態、眼皮開合與主要注視方向；固定裝置尺寸、色彩模式與 scale。
8. **Accessibility 測試**：Reduced Motion 時不執行大幅位移或循環粒子，但保留狀態與事件語意的可辨識性。

不要只測 View 內部 modifier 數量，也不要使用固定 `sleep` 等待動畫。動畫的決策、時間軸與合成應抽離成可直接測試的資料。

### 11.2 Mapper 測試示例

```swift
import XCTest
@testable import LumiPresentation

final class AvatarStateMapperTests: XCTestCase {
    func testGreetingUsesBrightWateryEyesAndWarmExpression() {
        let result = AvatarStateMapper().map(.greeting)

        XCTAssertEqual(result.eyeOpenAmount, 1.0, accuracy: 0.001)
        XCTAssertEqual(result.irisScale, 1.08, accuracy: 0.001)
        XCTAssertEqual(result.highlightIntensity, 1.0, accuracy: 0.001)
        XCTAssertEqual(result.blushOpacity, 0.70, accuracy: 0.001)
        XCTAssertEqual(result.eyebrowStyle, .raisedSoft)
        XCTAssertEqual(result.mouthStyle, .smile)
        XCTAssertEqual(result.waveformMode, .none)
    }

    func testDetectedLooksTowardLeftPresence() {
        let result = AvatarStateMapper().map(
            .detected(direction: .left)
        )

        XCTAssertLessThan(result.pupilOffset.x, 0)
        XCTAssertEqual(result.pupilOffset.y, 0, accuracy: 0.001)
        XCTAssertEqual(result.eyeOpenAmount, 1.0, accuracy: 0.001)
    }
}
```

如果目前的 Domain enum 將方向作為獨立事件而非 associated value，測試應配合真實介面調整；不可為了符合示例而污染 Domain。

### 11.3 邊界與事件測試示例

```swift
func testPupilOffsetIsClampedToEyeSafeArea() {
    let input = NormalizedOffset(x: 2.0, y: -2.0)

    let result = EyeMotionLimiter().limit(input)

    XCTAssertEqual(result.x, 0.65, accuracy: 0.001)
    XCTAssertEqual(result.y, -0.45, accuracy: 0.001)
}

func testCelebrationEndsOnLatestStateRatherThanCapturedOldState() async {
    let clock = TestClock()
    let sut = AvatarAnimationCoordinator(clock: clock)

    await sut.setState(.greeting)
    await sut.play(.goalAchieved)
    await sut.setState(.listening)
    await clock.advance(by: .seconds(2))

    XCTAssertEqual(await sut.currentBaseState, .listening)
    XCTAssertNil(await sut.activeEvent)
}
```

### 11.4 Snapshot 最小矩陣

最小回歸矩陣應包含：

- 12 個 Phase 1 基準 `AssistantState` 各一張。
- `detected` 左／右方向。
- `listening` 與 `speaking` 的 waveform 靜態代表幀。
- Open、Half、Closed、Happy Curve 四種眼皮。
- Watery-eye highlights 開啟與基準強度。
- Reduced Motion 的 `greeting` 與 `encouraging`。
- 至少覆蓋亮白與淡紫兩種正式產品背景。深色背景只可作為非產品的對比診斷，
  不得視為 Lumi 支援的主題或正式畫面。

Snapshot 只用來攔截非預期視覺變更，不能取代 Mapper、邊界與事件生命週期的單元測試。

## 12. MVP 驗收條件

MVP 視覺完成需同時符合：

- 眼睛不是單純圓形：包含深色外圈、虹膜深淺、瞳孔、柔光與 2–4 個白色高光。
- 主高光固定在左上光向，左右眼一致。
- 12 個 Phase 1 基準 `AssistantState` 都有明確、可測試的 visual mapping 與 snapshot。
- `detected` 可依來客方向連續移動視線，且瞳孔不穿出眼睛。
- 眨眼不是 GIF，等待時間可變且測試不需真實 sleep。
- `listening` 與 `speaking` waveform 可由實際 amplitude 驅動。
- Continuous、State 與 Event 不互相永久覆寫。
- 事件結束後回到最新主狀態。
- Reduced Motion 有可辨識但低動態的替代呈現，且不會抹除 Event 語意。
- 核心視覺不依賴大量 PNG／GIF 換圖。
- Mapper、clamp、合成優先權與事件生命週期測試通過。
- 指定的 snapshot matrix 已建立並由設計／產品確認基準。

## 13. 後續可擴充方向

在不改變核心架構的前提下，可以新增：

- `.shy`、`.sleepy`、`.proud`、`.excited`、`.concerned` 等 mapping。
- 更細緻的嘴型或音素驅動，但應先驗證是否真的提升體驗。
- 依實際人臉位置進行連續注視，而非只有左／中／右。
- 店舖時段或活動主題的 Effects token。
- 少量高品質 Celebration 資源。

當角色演進為完整人物、身體動作、骨架動畫、頭髮物理或 3D Avatar 時，才重新評估 SpriteKit、RealityKit、Rive、Lottie 或其他專用動畫技術。此決策不應提前增加 Lumi MVP 的複雜度。

## 14. 官方技術參考

- [Apple Developer Documentation — Canvas](https://developer.apple.com/documentation/swiftui/canvas)
- [Apple Developer Documentation — TimelineView](https://developer.apple.com/documentation/swiftui/timelineview)
- [Apple Developer Documentation — PhaseAnimator](https://developer.apple.com/documentation/swiftui/phaseanimator)
- [Apple Developer Documentation — KeyframeAnimator](https://developer.apple.com/documentation/swiftui/keyframeanimator)
- [Apple Developer Documentation — Controlling the timing and movements of your animations](https://developer.apple.com/documentation/swiftui/controlling-the-timing-and-movements-of-your-animations)
