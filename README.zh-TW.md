# lorenzini

[English](README.md) · [繁體中文](README.zh-TW.md)

這是一組 Claude Code skill，負責輪詢第三方 PR 審查工具（CodeRabbit、GitHub Copilot、Codex）的回應，並裁決該審查結果是否真正代表可以合併。

它們不審查原始碼，而是裁決審查工具到底說了什麼。

鯊魚的勞倫氏壺腹是電感受器，能找出埋在沙裡、肉眼看不見的獵物。這正是這組 skill 的用途。在這些儲存庫所觀察到的每一款自動審查工具，都曾把問題收在摺疊區塊、未列入計數的留言或獨立討論串裡，頂層摘要卻對此隻字不提。本專案過去犯過的每一個缺陷，也全都是同一種錯誤：把沉默當成程式碼乾淨。

## 唯一守則

絕不能從「沒看到問題」推論出「通過」。

判定審查通過必須有明確肯定的完成標記。沒有標記就繼續等。沉默不等於核准，空的問題清單更不代表零缺陷。本專案過去發生的每一次閘門故障，全都是失敗放行（fail-open）：在根本沒掙得通過時回報成功。

每一次漏放的歷史紀錄都寫在 [`docs/fail-open-ledger.md`](docs/fail-open-ledger.md)。它不是附錄，而是這套工具值不值得信任的誠實依據。帳本目前記錄了 11 起早期版本誤放通過的案例。最早的一起是 2026-09-17 的 `coralline#85`：登入過濾條件漏看了 Copilot 兩個登入帳號的其中一個，在帶有 3 條具體問題的 PR 上誤報 `CLEAN`。

## 審查工具與分流

三支 skill 各自對應不同的審查工具：
- [`coderabbit-review-wait`](skills/coderabbit-review-wait/)：對應 CodeRabbit（`coderabbitai[bot]`），用於 10 顆星以上的儲存庫（包括目前 13 顆星的 `lorenzini` 本身）。
- [`copilot-review-wait`](skills/copilot-review-wait/)：對應 GitHub Copilot（`copilot-pull-request-reviewer[bot]`），用於少於 10 顆星的儲存庫。
- [`codex-review-wait`](skills/codex-review-wait/)：對應 Codex（`chatgpt-codex-connector`），因上游訂閱暫停，自 2026-09-17 起休眠。

這項分流是廠商的方案限制，不是架構偏好。CodeRabbit 的開源方案要求少於 10 顆星的公開儲存庫必須手動觸發審查，這類儲存庫才轉向 Copilot。設定前請先用指令查詢星數，不要憑空假設：

```bash
gh api repos/OWNER/NAME -q .stargazers_count
```

分流會路由，但擋不住重疊。任何 PR 都能被手動觸發第二個 reviewer，或在 CodeRabbit 暫停通知的核取方塊中被啟用，而且不會留下被路由到的那支輪詢器讀得出的痕跡。在 `lorenzini` 自己的 PR 上就曾量到：PR #2 有 3 條 Copilot 審查意見穿過兩次判定都未被提及；PR #1 有 4 條意見完全沒出現在審查摘要中，其中 2 條是真缺陷。這就是 `RESULT=OTHERBOT` 存在的理由。

## 裁決結果

每個 skill 會持續輪詢，直到當前 head commit 出現明確裁決為止，並輸出單行機器可讀的 `RESULT=` 結果。三個 skill 對「乾淨」的定義各不相同；請閱讀你所在儲存庫對應的那份 `SKILL.md`。把別處的邏輯搬過來只會靜默失敗，不會大聲報錯。

| 裁決結果 | 代表意義 | 處置方式 |
|---|---|---|
| `RESULT=CLEAN` | 閘門達成，可以合併。 | 合併 PR。 |
| `RESULT=SUGGESTIONS count=N` | head 上有 N 條 inline findings，或 `CHANGES_REQUESTED`。 | 合併前必須先處理或回覆。 |
| `RESULT=NITPICKS count=N` | 其餘乾淨，但有 N 條 findings，或 N 個被略過未讀的檔案，收在摺疊區塊裡。 | 不算通過。沒被讀過的檔案，零計數什麼都不代表。逐條處置後再推一次、重新輪詢。 |
| `RESULT=PREMERGE count=N` | 其餘乾淨，但 N 項 pre-merge 檢查失敗。可靠的數字是 `✅ N | ❌ M` 這行總計和區塊標題；個別列的狀態那格寫的是 `⚠️ Warning`，所以在列裡面找 `❌` 的解析器什麼都找不到，然後回報通過。 | 不算通過。常常是合理的 defer──覆蓋率門檻算的是 diff 碰到的所有函式，不是新增的那些。逐項處置。 |
| `RESULT=MISCOUNT claimed=N counted=M` | 審查工具自己報的數字比閘門數到的多。 | 不算通過。差距本身就是 finding：它貼出來的東西有一部分沒被算到。 |
| `RESULT=UNREPLIED count=N` | N 條已標記解決的討論串沒有人類回覆。 | 不算通過。`@coderabbitai resolve` 會一次關掉全部，留下無人說明的處置紀錄。先寫下處置理由再 resolve。 |
| `RESULT=OTHERBOT` | 這個閘門乾淨，但 PR 上有它讀不到的 reviewer 留下未處置的 findings──可能是未解決討論串，也可能藏在那個 reviewer 自己的 review 內文裡、不產生討論串。 | 不算通過。這裡的乾淨只代表那一個 reviewer 沒找到東西。打開 PR 讀另一個工具說了什麼。 |
| `RESULT=NOT_REVIEWED` | head 上有 review 物件但內文不是 verdict。 | 帶 `reason=quota fallback=coderabbit` 代表 Copilot 什麼都沒審。配額以請求者為單位，那一側的儲存庫會同時全部失去 reviewer：立刻改用 CodeRabbit，不要等。其餘情況在逾時才回報，不是一看到就判定。 |
| `RESULT=UNREAD format=X` | 審查內文的格式沒有已驗證的乾淨樣本，目前是 `ccr-overview-v2`。 | 不算通過也不算失敗，是坦承。該格式從未捕捉到確認乾淨的樣本，零 findings 證明不了什麼。內文會完整印出，由人來讀。 |
| `RESULT=TIMEOUT` | head 在時限內沒有 verdict。 | 閘門扣住，絕不將超時當作通過。 |
| `RESULT=ERROR ...` | 輪詢解決不了的狀態：草稿 PR、審查被暫停或跳過、GitHub API 配額耗盡、無法解析 repo/PR。 | 修正前置條件。配額耗盡會直接指出重置時間，不會一路輪詢到逾時。 |

## 安裝

這三個 skill 是可攜的 [Agent Skill](https://agentskills.io/specification)：每個 reviewer 一份 canonical `SKILL.md` 放在 `skills/` 底下，不為個別平台分叉。以下每一種安裝都是 **user scope**，裝一次、每個專案都能用。

環境需要已登入的 `gh` 與 `jq`。

### 任何 agent（Skills CLI）

```bash
npx skills add Nanako0129/lorenzini -g     # -g 是 user scope
npx skills update lorenzini -g
```

### Claude Code

```bash
claude plugin marketplace add Nanako0129/lorenzini
claude plugin install lorenzini@lorenzini --scope user

# 更新
claude plugin marketplace update lorenzini
claude plugin update lorenzini
```

### Codex

```bash
codex plugin marketplace add Nanako0129/lorenzini
codex plugin add lorenzini@lorenzini

# 更新——先刷新快照再重新加入
codex plugin marketplace upgrade lorenzini
codex plugin add lorenzini@lorenzini
```

### Antigravity

```bash
agy plugin install https://github.com/Nanako0129/lorenzini
```

### Grok Build

```bash
grok plugin install Nanako0129/lorenzini --trust
grok plugin update
```

### QwenPaw

```bash
git clone https://github.com/Nanako0129/lorenzini
qwenpaw plugin install ./lorenzini/.qwenpaw-plugin
```

> **「可以安裝」在這裡的意思。** 打包驗到每份 manifest 都能解析、skill 路徑都解得開為止。各平台載入之後是否照文件運作，沒有逐一驗證；QwenPaw 的進入點完全沒跑過，因為手邊沒有可用的 QwenPaw。你的 agent 卡住的話請開 issue。

### 移除

刻意不放進上面那些區塊：它們是設計成整段複製的，而 install 區塊結尾擺一行
uninstall，複製下去就是裝完立刻移除。

```bash
npx skills remove lorenzini -g          # Skills CLI
qwenpaw plugin uninstall lorenzini      # QwenPaw
```

這裡只記這兩條路線的移除指令。其餘四條沒有實際跑過，而**猜一條會刪東西的指令，
比不寫還糟**——請查你自己那個 host 的文件。

### 從 clone 安裝並固定在 tag

手動路線，也是「閘門只在你說了才變」的那條路：

```bash
git clone https://github.com/Nanako0129/lorenzini.git ~/side-project/lorenzini
cd ~/side-project/lorenzini && git checkout v0.2.3
for s in codex copilot coderabbit; do
  ln -sfn ~/side-project/lorenzini/skills/$s-review-wait ~/.claude/skills/$s-review-wait
done
```

> **從 v0.2.1 或更早版本升上來，這個符號連結會斷。** 三個 skill 目錄從 repo 根目錄搬進了 `skills/`，這樣上面那些工具才裝得起來。pull 過那個點之後，舊的符號連結就懸空了——而**懸空的 skill 符號連結不會告訴你它壞了**，那個 skill 只是消失。請重跑上面那個迴圈，或改用上面任一種套件安裝。

固定在 tag，不要對齊 `main`。這些 skill 決定 PR 能否合併，而 `main` 是修補新發現 fail-open 的地方；指向 `main` 的話，隨手一次 `git pull` 就會改掉你的閘門。符號連結指的是目錄不是 commit，所以切換 tag 不會弄壞它：

```bash
git fetch --tags && git checkout v0.2.3
```

如果你在開發 `lorenzini` 本身，簽出的分支**就是**你當下在跑的閘門。2026-09-20 實測：同一支輪詢器在同一個 PR 上相隔幾分鐘執行，一個分支給 `RESULT=CLEAN`，另一個給 `RESULT=NOT_REVIEWED`，而那份審查內文清清楚楚寫著程式碼從未被讀過。

## 版本支援

| Tag | 支援狀態 | 說明 |
|---|---|---|
| `v0.2.3` | 可以用 | 現行基準版本。讓文件承諾過的「用當前分支的 PR」真的能解析——它從來不會成功，而且會對有 PR 的分支謊稱 `no PR for the current branch`。並收緊參數解析：flag 漏帶值會讓輪詢器安靜卡死，`--repo ""` 會去輪詢錯的 repo，`--timeout ""` 會在沒等任何時間的情況下回報 `RESULT=TIMEOUT`。 |
| `v0.2.2` | 已被取代 | 前一個基準版本。三個 skill 目錄搬進 `skills/`，並加上五份套件 manifest，讓這道閘門可以用外掛安裝，不必手工接符號連結。**破壞性變更：**既有指向這份 clone 的 `~/.claude/skills/` 符號連結，升級後會懸空。 |
| `v0.2.1` | 已被取代 | 前一個基準版本。修掉一個競態：審查正在啟動時，skip 通知會被當成終局狀態；另外把 Copilot 配額耗盡導向 CodeRabbit，而不是停在那裡。 |
| `v0.2.0` | 已被取代 | 有跨審查工具、非審查狀態與格式辨識三道防護，但會在第一次看到 skip 通知時就當成終局。在 CodeRabbit auto review 關閉的 repo 上，這每一輪都會觸發。 |
| `v0.1.1` | 已被取代 | 缺少 cross-reviewer、non-review 與格式辨識三道防護。 |
| `v0.1.0` | 不要用 | 內含 4 道會在未掙得通過時誤報通過的缺陷閘門。 |

如果你在 2026-09-20 之前 clone，本地狀態落在當時 `main` 的 `v0.1.x` 某處。請用 `git log --oneline -1` 對照上表確認。

## 變更如何進來

所有變更皆走 PR。然而這純粹是團隊紀律，沒有任何機制強制：`main` 沒有 branch protection，也沒有 required review。這裡的 PR 能以任何裁決甚至毫無裁決直接合併。閘門是一項決定而非硬性防護，與這套工具所審查的每個儲存庫完全相同。

本專案目前累積 13 顆星，已越過 CodeRabbit 的開源方案門檻，由 CodeRabbit 執行審查並透過 `coderabbit-review-wait` 讀取裁決。未滿 10 顆星時建立的 `copilot-auto-review` ruleset 依然存在，狀態為 disabled；Copilot 過去仍曾審查過這裡的 PR，這也就是前面提到的 `OTHERBOT` 狀況，而且最初正是在本專案被發現。

草稿 PR 會被當場拒絕：腳本立刻退出並回報 `RESULT=ERROR` 指明草稿狀態，避免讓人把草稿的沉默誤讀成審查延遲。只有得到 `RESULT=CLEAN` 才能合併；其餘任何結果，必須先處置印出來的內容。

這個 repo 最早的兩個 commit 是直接推上 `main` 的，完全沒有 PR，也沒有設定任何審查工具。一個全心拒絕在未驗證通過上合併的專案，自己卻在毫無 verdict 的情況下合併了兩次。ruleset 是直到有人詢問為什麼沒有 PR 才補建的。那不是一條被違反的規則，而是一條從沒被寫下來的規則，發生在最不該將它留成隱性的地方──它的本質與帳本中的每一條紀錄相同，只是高了一個層次：那道防護被大家假設存在，而不是被查證存在。

## 選用的 Jev 影子分類器

`coderabbit-review-wait` 可以查詢分類器，判斷 Markdown 摺疊區塊的標題是否在描述還需要人工處理的工作。

Jev 預設關閉，且目前不改變任何裁決。透過 `JEV_SHADOW=1` 啟用後，它完全以影子模式運作：當它不同意通過時，會在閘門自身的裁決旁印出一行 `(jev: would HOLD ...)`，腳本最終依然以閘門原本的裁決退出。啟用 Jev 無法擋下合併，只能告訴你有東西本來會被扣住。

將來若給予它否決權，其架構約束是嚴格的單向機制：只允許 `CLEAN` 轉為 `HOLD`，絕對不允許 `HOLD` 轉為 `CLEAN`。被扣住的結果無論分類器說什麼都維持扣住。這就是為什麼 Jev 的每一種失敗方式──缺少金鑰、逾時、網路錯誤或信心不足──都會讓當前裁決維持原樣。在正式將分類器接上判定前，驗證這項不變原則正是當前觀察期的核心目的。若未設定 `JEV_SHADOW`，則不發出任何請求、不印出任何訊息，也不載入相關相依。

設定方式：
- 設定 `JEV_SHADOW=1` 啟用影子模式。
- 設定環境變數 `TYPESAFE_API_KEY`，或將金鑰寫入 `~/.config/typesafe/api_key`（權限設為 `chmod 600`）。金鑰可至 `https://console.typesafe.ai/settings/keys` 申請（早期存取候補名單）。
- 若使用 Claude Code，請將 `TYPESAFE_API_KEY` 與 `JEV_SHADOW` 加入 `~/.claude/settings.json` 的 `env` 區塊。
- 暫扣紀錄寫入 `$XDG_STATE_HOME/lorenzini/shadow-holds.jsonl`（未設定時退回 `~/.local/state/lorenzini/shadow-holds.jsonl`，可用 `JEV_SHADOW_LOG` 覆寫）；呼叫紀錄則記錄於同目錄下的 `jev-calls.jsonl`（可用 `JEV_LOG` 覆寫）。

Jev 提供四種刻意區隔的輸出訊號：
- `(jev: unavailable -- ...)`：未執行。缺少 API 金鑰、網路逾時、HTTP 錯誤，或問題集檔案遺失。
- `(jev: INCOMPLETE -- M of N heading(s) came back without a usable score)`：已執行，但部分回應遺失或非數值。這不是完整檢查；後續訊息僅涵蓋有成功回傳分數的標題。
- `(jev: checked X of N heading(s), nothing the patterns missed)`：Jev 沒找到 patterns 漏掉的東西。`X` 是拿到可用分數的標題數，所以這行可能跟在 `INCOMPLETE` 後面，那時它只涵蓋那些有回答的。
- `(jev: would HOLD -- ...)`：Jev 發現一個 patterns 不認識的標題。這行同樣可能跟在 `INCOMPLETE` 後面，只針對有回答的標題。

把前三種輸出摺疊成同一種沉默，就是帳本大部分在講的那種錯誤。`INCOMPLETE` 狀態之所以存在，正是因為這支分類器腳本的第一版就犯過這個錯：部分 API 回應產生了空的旗標清單，程式隨後回報什麼都沒漏。

評測準則檔案本身就是分類器。提示詞定義於 `skills/coderabbit-review-wait/jev-questions-v3.json` 而非寫死在腳本中，因為改動任何一個詞都會改變模型的分數判斷。在 gold set 標籤中，`L01` 代表「🧹 Nitpick comments (3)」，正確標註為 findings。在 `v1` 中，分類器給出 0.37 分（低於 0.50 門檻）而漏抓，純粹是因為準則中缺少 "nitpick" 這個字；在 `v2` 明確點名後，同一個標題的分數提升至 0.697。因此每次呼叫都會記錄題目集的雜湊值，題目變體也直接反映在檔名上。

若要評測修改後的題目檔，請執行：

```bash
python3 tests/run-gold-set.py 3 skills/coderabbit-review-wait/jev-questions-v4.json
```

以 `tests/fixtures/` 中的 30 筆標籤為基準，各版本重複執行 3 次的實測資料如下：

| 版本 | 正確率 | 隱藏工作召回率 | 誤判數 | 翻轉率（重複 3 次） | 說明 |
|---|---|---|---|---|---|
| `v1` | 27/30 | 6/8 | 1 | 1/30 | 標籤 `L01`（"🧹 Nitpick comments (3)"）給出 0.37 分（門檻 0.50）而漏抓。 |
| `v2` | 28/30 | 8/8 | 2 | 0/30 | 準則加入 "nitpick" 後，`L01` 分數升至 0.697。 |
| `v3`（現行） | 29/30 | 8/8 | 1 | 0/30 | 無法救回「Action not completed」標題；已在檔案中記為已知限制。 |

## 測試變更

執行測試時直接從出貨腳本載入分類 helper：

```bash
bash tests/test-classifiers.sh
```

`tests/test-classifiers.sh` 直接 source 出貨腳本中的分類邏輯，而非在測試中複製正則表達式。這項區別已經證明了它的價值：過去曾有一條斷言在測試檔中內嵌了一份正則副本，當出貨程式放寬 pattern 時，變異測試竟然毫無反應，因為測試一直對著過期的正則亮綠燈。現在所有新增的斷言都會直接放在受測 helper 旁並直接呼叫它。

各 `SKILL.md` 所列出的公開 PR 是活的人工回歸測試案例，但它們在 GitHub 上的狀態會因為與本專案無關的原因改變。例如 `pysnmp/pysmi#328` 曾在相隔一小時的兩次執行間，從 `SUGGESTIONS` 變成 `PREMERGE`，原因只是上游維護者在期間解決了一個討論串。任何行為驗證都必須以受控比對進行──使用同一份擷取下來的 payload，只改變單一變數──再決定要採信通過還是失敗。

## 防失誤放行帳本

[`docs/fail-open-ledger.md`](docs/fail-open-ledger.md) 記載了每一次閘門誤放通過的實例，總計 11 筆，每一筆均詳列觸發該問題的 PR、造成的代價，以及是由誰發現的。

這份帳本不是附錄，而是這套工具值不值得信任的誠實依據：裡面的每一筆紀錄，都是本專案某個早期版本不該印出 `CLEAN` 卻誤判放行的時刻。最早的一筆發生在 2026-09-17（`Nanako0129/coralline#85`）：登入過濾條件未能比對到 Copilot 兩個登入帳號的其中一個，在帶有 3 條具體問題的 PR 上誤報 `CLEAN`。

輪詢腳本所體現的各種防禦性邏輯，若脫離了當初迫使它們成型的失敗背景，往往顯得武斷。一道理由被遺忘的防護措施，遲早會被下一位修改程式碼的人當成多餘的雜物隨手刪除。
