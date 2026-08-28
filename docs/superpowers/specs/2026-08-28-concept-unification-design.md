# 概念與題型合一 — 設計（2026-08-28）

## 目標

工具要幫使用者把「題目」練成「概念」：寫題是入口，留下來的是概念——是什麼、跟哪些概念相連、哪裡用得上。
現在 app 裡有兩套分類並存、互不認識：

- **概念**（`Card.concepts`，模型每題自由判的）：變數代換法 24 題、對數微分法 15、複合函數微分 12……
- **題型**（`ExamScope.topics`，整理考試附檔讀出的）：部分分式積分、根式函數代換積分、萊布尼茲法則……

「部分分式拆解」（概念）跟「部分分式積分」（題型）是同一件事、名字不同、各自計數；概念那邊自己也分裂（「交換積分順序」／「積分順序交換」）。

拍板：**概念是唯一節點，題型收進概念頁**。理由：使用者要的三樣東西（是什麼／怎麼連／哪裡用）都是概念的屬性，題型只是其中一個屬性（「會怎麼考」）。

## 範圍

這一輪只做地基（資料＋概念頁）。地圖（SwiftUI 畫膠囊＋連線＋動畫）與「出一題練」下一輪，因為地圖畫的是概念連結，連結資料要這輪整理出來才有。

視覺已在設計畫布定案（第三頁「8/28 概念版對照」）：https://claude.ai/code/artifact/01ccc2b3-b0a4-400e-9aae-ce8282420c5b

## 1. 資料

### 1.1 概念頁五塊（`WikiPage` 改）

| 欄位 | 內容 | 來源 |
|---|---|---|
| `what` | 是什麼。少字＋一張小圖（見 §2.1） | compileWiki |
| `links` | 相連的概念：`[{concept, why}]`，每條一句為什麼連（「鏈式法則——反過來用」） | compileWiki（只能連既有概念名） |
| `uses` | 哪裡用得上：微積分內＋其他科。沒材料就空字串，不讓模型硬掰 | compileWiki |
| `examTopics` | 會怎麼考：`[{name, examples, howTo, examID}]`——就是現在 `ScopeTopic` 的內容搬進來 | compileScope |
| `stuck` | 你卡過的：由程式從 `Card.stuckSkill` 統計，不再是模型寫的散文 | 程式算，不存 |
| `compiledAt` / `materialCount` / `fallbackNote` | 現有 | 現有 |

砍掉：`keyPoints`（口訣併進 `examTopics.howTo`）、`gaps`（「還沒補的」跟 `uses` 的空欄位重疊，且使用者沒點名要）。舊存檔多出的欄位 decode 時忽略。

### 1.2 技巧標籤（`Card.stuckSkill: String?`）

判題（`ingest`）已經回 `stuck_step`；多回一個 `stuck_skill`：栽的那一步用的是哪個**做題技巧**，二到八個字（「換算上下限」「分母因式分解」「代值正負」）。命名穩定同一招：prompt 餵既有技巧清單（`allStuckSkills()`，去重、新到舊），先選再新增。

只在栽的那一步貼標籤，不是每題每步歸類——量少、只記真的出事的地方。

統計是純程式：`stuckSkills(for concept) -> [(skill, count, cards)]`，概念頁第 5 塊與（下一輪）地圖右欄用。

### 1.3 題型對到概念（`compileScope` 改）

「整理範圍」除了 topics，每型多回 `concepts: [String]`（1–2 個），規則同 ingest：餵既有概念清單、先選再新增。store 端：

- 每個 topic 寫進對應概念的 `wiki[concept].examTopics`（帶 `examID`，重跑同一場考試先清掉該 examID 的舊項再寫）
- 新概念名同時進 `chapters`（用 topic 的 chapter）
- `Exam.scope` 改存 `concepts: [String]`（這場考試涵蓋哪些概念，給下一輪地圖篩選用），`topics` 不再存在 exam 底下

考試頁「範圍」區改列概念（點進概念頁），不再列題型。

### 1.4 概念名穩定

現況：`ingest` 已經餵 `knownConcepts` 並要求「語意相同務必重用原名」，仍然漂移（log 可證）。所以這輪不靠加強 prompt，而是：

1. **講義當骨架**：`compileScope` 吐的概念名先進清單（§1.3），之後貼題有東西可對
2. **整理概念清單（lint）**：新按鈕，在概念總覽。模型一次看整份概念清單＋每個概念底下的題目標題（不帶內容），回 `merges: [{keep, drop: [String]}]`——同義合併、太細的收進上位概念。App 顯示清單讓使用者勾選確認後才套用；套用＝`Card.concepts` 全部改名、`wiki` 與 `chapters` 鍵合併（wiki 內容以 keep 為主，drop 的 `examTopics` 併入）。**按了才跑**，不自動。
3. **手動合併**：概念總覽長按一個概念 → 「併入…」選另一個概念。套用邏輯同上。這是 lint 漏網時唯一要動手的地方。

不做拍目錄：多一步驟會降低使用意願（使用者原話）。

## 2. Prompt

### 2.1 `what` 的講法（吸收 eli5 與 show-me）

- eli5：少字、大圖
- show-me：挑**一種**最小的圖、圖緊貼它支撐的那句話、只標「什麼變了」

規則寫進 compileWiki prompt：`what` 兩句以內；同時回 `figure`：從四種擇一——`diff`（變換前後對照，標出變的部分；換元、換序、換座標都是這型）、`plot`（座標圖，matplotlib code，走現有附圖管線）、`tree`（步驟樹，純文字縮排）、`table`（對照表，兩三欄）。`figure` 存成 `{kind, content}`，`content` 是 LaTeX／code／文字，由 app 依 kind 渲染；`diff` 用兩行 `$$`＋標記變化的部分。

### 2.2 `links`

只能從既有概念清單挑（prompt 附清單），每條 `why` 15 字以內。沒有相連的就空陣列。

### 2.3 `uses`

分兩段：微積分內（從材料抽）、其他科目（只有材料裡真的出現才寫，否則寫空）。

## 3. 畫面

- **概念頁**（`ConceptPageView`）：五塊直排，每塊白底卡片，標題「1 · 是什麼」到「5 · 你卡過的」。第 5 塊每個技巧一列（紅底、×次數），展開才是題目清單；點題進題目樹。最底兩顆按鈕：「出一題練這個概念」（這輪先 disabled，下一輪接）、「原始材料（N 題 · M 問）」進現有的題目／問答清單。
- **概念總覽**（`ConceptListView`）：加「整理概念清單」按鈕（跑 lint → 確認 sheet）；長按概念 →「併入…」。
- **考試頁**（`ExamDetailView`）：「範圍」區改列概念；「整理範圍」按鈕文案不變。

## 4. 錯誤處理

- lint 或 compileScope 回了清單裡沒有的概念名 → 當新概念收，不丟棄
- 合併時 keep 不存在 → 略過該筆並在確認 sheet 標灰
- `figure.kind == plot` 的 code 跑失敗 → 只顯示文字（現有附圖管線的 fallback）

## 5. 測試

- `latexcheck` 跑過 `what`／`examTopics.examples` 的式子（現有工具）
- 合併邏輯寫單元測試：兩個概念合併後 `Card.concepts` 無 drop 名、`wiki[drop]` 為 nil、`examTopics` 併入無重複
- `stuckSkills(for:)` 統計寫單元測試
- E2E：iPad 上對「微積分 8/26」重跑整理範圍 → 概念頁看到第 4 塊；貼一題栽在換算上下限 → 第 5 塊出現 ×1

## 6. 不做

- 「解題動作」層（每題每步歸類）——是運算熟練度那層的東西，使用者說那層多寫就好
- 地圖、出題（下一輪）
- 論文用途（概念清單跨科目長大後再看）
