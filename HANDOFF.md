# 冰箱美術館 交接文件

2026-10-28　星光工作室 Starlight Studio　著作權與 IP 屬於星光工作室 Starlight Studio

這份是給「新對話的 Claude」看的完整交接。新對話開始時先讀完這份和 DECISIONS.md（討論歷程與決策理由），再動手。

---

## 1. 目前狀態（2026-10-28）

| 項目 | 狀態 |
|---|---|
| iOS App | **1.1.0** 已送審（2026-10-29 14:50，App＋「完整版」內購共 2 項，狀態「等待審查」；發布方式：手動）。Albert 已實機測過 1.1.0 |
| App 內購買 | `tw.starlight.fridgemuseum.full`「完整版 / Full Version」已建立：NT$190、家人共享開、地區 TW/HK/US/CA/GB/AU/SG。審查截圖已上傳（10/28 第 2 次執行成功），但流程結束時讀到的狀態仍是 MISSING_METADATA，要到 ASC 確認是否已變 Ready to Submit |
| 網頁測試版 | **0.9.0** 上線中：https://claude.ai/artifact/MQTbRzJLuHZUzNpgRvADPf （只有擁有者看得到）。原始碼在 `web/` |
| repo | `albertliuspielbery-cloud/fridge-museum`（**公開**）。main = App 1.1.0。開發分支用 `fix/**`（push 也會跑模擬器測試） |
| 隱私／支援頁 | GitHub Pages：`docs/privacy.html`、`docs/support.html` → https://albertliuspielbery-cloud.github.io/fridge-museum/privacy.html 、…/support.html |

---

## 2. 一定要遵守的規則（擁有者 Albert 定的，沿用星光小冒險）

**溝通**
- 一律繁體中文，簡潔、白話，不要 AI 腔。
- Albert 多用手機。要他做事時給簡短步驟，每一步附可以直接點的連結。
- 背景工作不要一直回報，完成或需要他決定時才說。
- 大工作拆給多個代理平行做，再找沒參與的代理獨立審查。

**發布**
- 每次交付升版本號（網頁：`APP_VERSION` + `CHANGELOG`；App：`project.yml` 的 `MARKETING_VERSION`）。
- 上線前跑全部測試 → 沒參與製作的代理獨立審查 → 拿到 GO → 給 Albert 看，他回「可以」才部署。有問題修好再審一輪。
- iOS「上傳」由 Albert 自己按。**冰箱美術館和星光小冒險不要同時按上傳**（`ci/ci_sign.py` 會清掉同帳號舊的發佈憑證）。
- 送審（提交以供審查）前一定先問 Albert。
- 新美術（角色、插圖、圖示）先給 Albert 看，同意了才用。
- 自動模式下，Claude 不能替 Albert 執行會改 Apple 帳號設定的 workflow（例如 ios-iap.yml），也不能建 GitHub repo；這些給連結請他按。

**內容**
- 不可以有任何有版權的角色或品牌。吉祥物冰冰（英文 Bibi）、小橘貓橘子、所有插圖都是原創。
- 著作權寫「星光工作室 Starlight Studio」。支援信箱 starlight.kids.app@gmail.com。
- 處理全部在裝置上，照片不上傳。不用生成式 AI 改動孩子的作品。
- 不放在「兒童」類別。不在歐盟、中國上架。
- 範例照片（Albert 孩子的畫作、國旗勞作）Albert 同意公開使用（2026-10-28 選 C）。

---

## 3. 產品定案

- 名稱：冰箱美術館 / **My Fridge Museum**。
- 風格：B「暖暖廚房 × 冰冰」，借 A 的蠟筆手寫字、C 的紙膠帶與門票。角色設定：`web/styles/bingbing.html`、`bingbing-sprite.svg`；App 圖示用方案 ①（冰冰大臉）`web/styles/appicon-1024.png`。
- 免費額度：平面畫作每天 3 張（當地午夜重置），立體勞作終身試用 3 件；作品真的收進或存到手機才算，每件只算一次，範例不算。
- 完整版：一次買斷 NT$190，全家共享。上架第一個月早鳥 NT$150（到時在 ASC 排價格，`ios-iap.yml` 預設不會覆蓋，要強制改回才勾 force_price）。
- 付費頁文案「之後的更新都免費」（Albert 接受）；「勞作不限件數」。
- 分類：多個孩子、每個孩子的美術館、畫作／勞作、學期（上學期 8–1 月、下學期 2–7 月）、年齡、標籤、最愛；存照片時依孩子分相簿（要完整照片權限，拒絕就只加入照片）。
- 匯出：畫作最長 4096px、勞作 3072px；處理用 2400px。

---

## 4. iOS App（`/`）

- Bundle ID `tw.starlight.fridgemuseum`，iOS 18+，Swift 6，Xcode 26（App Store 規定 iOS 26 SDK）。XcodeGen：`project.yml`。
- 結構：`FridgeMuseum/App`（AppModel、RootView、DemoMode 只在 Debug）、`UI/`、`ArchiveKit/`（SwiftData：Child、Artwork；1.2.0 起完整版可開 iCloud 同步，見「1.2.0 iCloud 同步」）、`CaptureKit/`、`ProcessingKit/`（API 見 `ProcessingKit/API.md`）、`StoreKit/`（API 見 `StoreKit/API.md`）、`Resources/`（素材、字型 Huninn + Chiron GoRound TC 子集，OFL）。
- 字串：`Localizable.xcstrings`、`InfoPlist.xcstrings`、`StoreKit/Paywall.xcstrings`（zh-Hant + en）。工具：`tools/make_strings.py`、`tools/l10n_scan.py`、`tools/sprite_to_assets.py`、`tools/subset_fonts.py`。
- 勞作去背用 Apple `VNGenerateForegroundInstanceMaskRequest`（每個 instance = 一個可點選部件），失敗退回顏色法，再退回原照片。

### GitHub Actions（都在 main，手動 Run workflow）

| 流程 | 連結 | 誰按 |
|---|---|---|
| iOS App（勾「上傳」才上傳 TestFlight） | https://github.com/albertliuspielbery-cloud/fridge-museum/actions/workflows/ios.yml | 上傳由 Albert |
| App 內購買項目 | https://github.com/albertliuspielbery-cloud/fridge-museum/actions/workflows/ios-iap.yml | Albert |
| App Store 上架資料（文字、類別、年齡分級、審查備註、截圖；不送審；可勾「只預覽」） | https://github.com/albertliuspielbery-cloud/fridge-museum/actions/workflows/ios-metadata.yml | Albert |
| 準備 App 識別碼 | https://github.com/albertliuspielbery-cloud/fridge-museum/actions/workflows/bundle-id.yml | 已完成 |
| iOS Screenshots（模擬器拍 18 畫面 × 中英 × 淺深，推到 `ci-shots` 分支） | https://github.com/albertliuspielbery-cloud/fridge-museum/actions/workflows/ios-shots.yml | Claude 可跑 |

- Secrets：`ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_KEY_P8`、`APPLE_TEAM_ID`（Albert 設的，Admin 權限金鑰）。
- 沒有 Mac：CI 是唯一的編譯器。雲端環境的 proxy 擋掉 Actions log 和 artifact 下載，看錯誤用 annotations（`ci/annotate_log.py`），看畫面用 `git fetch origin ci-shots`。
- push 到 main 會自動跑模擬器編譯＋單元測試（153 個測試）。

### TestFlight 還要做的
1. ~~再跑一次「App 內購買項目」~~（10/28 已跑）。到 ASC 確認商品是否已是 Ready to Submit（沙盒才拿得到價格）。之後最好換成實機付費頁截圖（存成 `ci/iap_review.png` 重跑）。
2. App Store Connect →「價格與供應狀況」：App 本身的地區只勾 TW/HK/US/CA/GB/AU/SG。
3. ~~TestFlight 內部測試群組加 Albert~~（已完成，1.0 已安裝）。
4. 第一次送審時，在版本頁把「完整版」加進去；英文名稱 My Fridge Museum、截圖、說明、關鍵字還沒做（可比照星光的 ios-metadata.yml）。

### 實機要測的（審查員列的）
重拍／刪除不閃退；12MP/48MP/ProRAW 匯出 4096 的記憶體（舊機 4GB RAM）；照片權限四種狀態（每次只跳一個系統視窗、每個孩子的相簿）；沙盒購買／恢復／Ask to Buy／退款；相機權限與中斷；語音轉文字；跨午夜額度；Dynamic Type、VoiceOver；Vision instance 去背實際效果。

### 已知小問題（nit）
- （1.0.1 已修：語音轉文字寫入前檢查作品是否還在；中文首頁副標掉字。1.1.0 已修：空冰箱範例卡被流理台切到。）

### 1.1.0 新功能重點
- 重複提醒：`ArchiveKit/ArtFingerprint.swift`（v2：soft pHash + 格子 + 色相，門檻 0.40），只提醒不擋。
- 重的處理一次只做一張：編輯中、連拍中、匯入中都會暫停背景輸出（AppModel claim/defer/drain）；存到照片的 4096 輸出走 `App/ExportGate.swift` 排隊。
- 資料模型新增（都是 optional）：`Artwork.fingerprintData`、`Child.avatarImageData`。

### 1.1.0 連拍與備份提醒（`feat/burst`）
- 連拍：相機快門上方「連拍」開關。每張直接成為待收作品（給目前「拍給」的孩子），不開編輯器；照樣找紙角，匯出等連拍結束才一張一張跑（AppModel `beginBurst/endBurst`，沿用 deferral；`runDeferred` 現在一次只跑一張、編輯器一開就暫停）。「完成」回廚房，便利貼「繼續」從最舊的一張開始，收進／存到手機／不要這張後自動開下一張（逐張時上一張的完整算圖排到佇列，等沒有編輯器開著才跑；改過的作品標成 processingState = pending，App 被關掉時下次開啟會重算）。開 App 時沒處理完的作品也走同一個佇列。「全部存到照片」在編輯器開著時暫停，單張存到手機排在批次目前那張後面（`ExportGate`，先來先做，一次只做一張 4096 匯出）。
- 備份提醒：首頁沒有便利貼時，若有 ≥10 件沒存到照片、或最舊的一件超過 14 天，顯示「還有 N 張只在 App 裡」；「之後再說」隱藏 14 天（UserDefaults `backupSnoozedUntil`）；這次開 App 才收的作品不算（第一次使用不會跳）。設定頁「備份到照片」顯示已存 X／Y 件。用既有的 `Artwork.lastSavedToPhotosAt`，沒改資料模型。

### 1.2.0 分享卡片（`feat/share-card`）
- 作品頁「分享」鈕改成選單：分享照片（原本的匯出）／分享卡片 直式 4:5／方形；「更多」選單也有分享卡片。免費、不算額度，只輸出一張 JPEG（不附文字，LINE 收到乾淨的圖）。
- 版面全在 `UI/ShareCardLayout.swift`（純計算，`ShareCardTests` 測）：薄荷冰箱門＋白相紙＋水果磁鐵（依作品 id 固定選 lemon/tomato/berry）＋奶油色說明牌＋冰冰標誌；說明牌優先，畫縮小、字不縮。繪製與 ImageRenderer（1080 寬、不透明、sRGB、JPEG 0.9）在 `UI/ShareCardView.swift`。
- 字型：Huninn／Chiron 是子集，**沒有全形空白 U+3000**——卡片文字一律把空白、換行、U+3000 換成半形空白；子集缺的字（罕見名字）靠 cascade list 退到系統圓體／PingFang，不會變豆腐。新增文字前先查字型 cmap。
- DemoMode 場景 `share-card`（全螢幕顯示卡片，給截圖用）。實機待測：分享選單在 SE／mini 與大字體下的樣子、LINE 收圖。

### 1.2.0 iCloud 同步（`feat/icloud`，已併入 `fix/1.2.0`）
- 完整版功能。只用使用者自己 Apple 帳號的 **CloudKit 私人資料庫**（容器 `iCloud.tw.starlight.fridgemuseum`），同一個 Apple 帳號的裝置之間同步；不同 Apple 帳號之間不分享（之後的版本再說）。免費版完全照舊只在手機上，設定頁有「iCloud 同步（完整版）」一行，點了開付費頁。
- 程式：`App/CloudSync.swift`（開店、帳號檢查、狀態、事件監看）、`ArchiveKit/SyncPolicy.swift`（決策、待收作品歸屬、重複合併，全部可單元測試）、`UI/SyncIntroSheet.swift`（第一次說明）、`ArchiveKit/ArchiveStore.swift`（`.private(容器)` 或 `.none`，同一個檔案）。測試：`FridgeMuseumTests/CloudSyncTests.swift`。
- **每次開 App 只決定一次**要不要同步（完整版 + 開關 + 看過說明 + iCloud 帳號可用）；開關、購買、退款、登入登出都是「下次打開 App 生效」。同一個檔案不會同時有兩個 container。關掉同步＝同一個檔案用 `.none` 開，手機上的資料一筆都不刪。
- 已知、改不了的 Apple 行為：同步開著而 App 正在執行時登出 iCloud（或在 iOS 設定關掉這個 App 的 iCloud），NSPersistentCloudKitContainer 會把已同步的資料從手機移除（Apple 說是隱私設計），重新登入同一個帳號會回來；還沒上傳的修改可能遺失。啟動前先查帳號狀態，能避開「App 關著時登出」這種情況。隱私權頁、支援頁有寫。
- 待收作品（還沒收進的）也會同步，但只屬於拍它的那台裝置（`originDeviceID`）：別台的便利貼、全部不要、全部收進、繼續都不會碰它；超過 7 天沒人處理才當成無主。帶著成品圖同步過來的作品不會重算；沒帶成品圖的，10 分鐘後在這台算一次。
- 重複：新手機用舊手機備份還原、兩台都開同步，會各上傳一份（同 id）→ 依「裝置 id 字串最小的那份」合併，每台結果一樣；兩台各自新增同名的小朋友（生日相同或其中一個沒填）也會合併。

**擁有者要手動做的（送 1.2.0 之前，照順序；做過一次就好）**
1. 建 iCloud 容器：https://developer.apple.com/account/resources/identifiers/list/cloudContainer → 右上「＋」→ 選「iCloud Containers」→ Continue → Description 填 `Fridge Museum`、Identifier 填 `iCloud.tw.starlight.fridgemuseum` → Continue → Register。
2. App 識別碼開 iCloud 和推播：（已完成）跑「準備 App 識別碼」流程https://github.com/albertliuspielbery-cloud/fridge-museum/actions/workflows/bundle-id.yml ，`ci_sign.py` 會用 API 打開 iCloud（含 CloudKit）和 Push Notifications。（或手動：下一步的頁面勾 iCloud、Push Notifications）
3. 把容器指派給 App（Apple 沒有開放 API）：https://developer.apple.com/account/resources/identifiers/list → 點 `tw.starlight.fridgemuseum` → iCloud 那一列按「Edit」（或 Configure）→ 勾 `iCloud.tw.starlight.fridgemuseum` → Continue → Save（會提示描述檔失效，沒關係，雲端打包每次重做）。
4. 建 CloudKit 資料結構到「開發」環境（沒有 Mac 的做法）：
   - https://icloud.developer.apple.com/dashboard/ → 右上帳號 → Settings → Tokens → 新增 Management Token → 複製（只顯示一次）
   - 貼到 GitHub Secret `CLOUDKIT_MANAGEMENT_TOKEN`：https://github.com/albertliuspielbery-cloud/fridge-museum/settings/secrets/actions
   - 跑「CloudKit 資料結構（開發環境）」流程：https://github.com/albertliuspielbery-cloud/fridge-museum/actions/workflows/cloudkit-schema.yml
   - （有 Mac 的話更準：Debug 版加啟動參數 `-FMInitCloudKitSchema`，用 SwiftData 模型自動建立。）
5. 部署到「正式」環境：https://icloud.developer.apple.com/dashboard/ → 選容器 → Development → Schema 確認有 `CD_Artwork`、`CD_Child` → 「Deploy Schema Changes…」→ Deploy。**TestFlight 和 App Store 版本都用正式環境**，所以要在上傳第一個 1.2.0 TestFlight 之前做完，不然同步會失敗（設定頁顯示「暫時無法同步」）。之後只要改了資料模型（新增欄位）就要重做 4、5；已部署的欄位不能改名或刪除。
6. 照常跑「iOS App」上傳 TestFlight。1–3 沒做完的話打包會因描述檔缺 iCloud 容器而失敗——**合併到 main 之後，連 1.1.x 的修正版也會受影響**，所以 1–3 要在合併前做。

**只能實機驗證的**：兩台裝置同一個 Apple 帳號互相出現作品、刪除同步、推播即時更新；從 1.1.0 升級後舊作品是否全部上傳；關同步後資料還在、再開能補上傳關閉期間的作品；iCloud 未登入／空間不足的狀態顯示；購買後說明頁、退款後下次開 App 停止同步；備份還原的新手機重複合併；同步中登出 iCloud 的行為。CloudKit 本身沒辦法在 CI 測（模擬器版本沒簽名、沒有 Apple 帳號）。

---

## 5. 網頁測試版（`web/`）

- `web/index.html` = 測試網頁原始碼（artifact 的 kidart.html，0.9.0）。發布到 artifact 時要一起附檔：`samples/flat.jpg`、`samples/craft.jpg`、`ml/ort-wasm-simd-threaded.wasm`、`ml/ort-wasm-simd-threaded.mjs`、`ml/ort.wasm.min.js`，以及 **`ml/u2netp-onnx.wasm`（內容就是 `ml/u2netp.onnx`，因為 artifact 不收 .onnx 副檔名）**。
- 用 Artifact 工具更新同一個網址：`url = https://claude.ai/artifact/MQTbRzJLuHZUzNpgRvADPf`，先 read 再 publish。capabilities 有 `downloads`。
- 除錯：網址加 `#mldebug` 會在提示列顯示 AI 去背走哪條路（例如 `ML on · worker+cdn · 480ms`）。Albert 實機測過 0.48 秒。
- AI 去背：U²-Netp（Apache-2.0）+ onnxruntime-web 1.31.1（MIT），授權全文在 `web/ml/`。說明：`web/ml/INTEGRATION.md`。網頁版專用，App 不用。
- 演算法重點：找紙（多候選＋邊緣吸附）、紙張比例（Zhang & He + 吸附 A4/Letter/八開/四開/4:3/1:1）、三種紙張模式、去小黑點（>14 個當圖案保留）、紙角補白、旋轉／拉直、勞作 ML+顏色融合、點一下選主體。
- 中英對照表與審稿紀錄：`web/i18n-zh-en.md`。
- 測試：`web/tests/`（Playwright 腳本，路徑是當時雲端環境寫死的 `/tmp/claude-0/…` 和 `/home/user/kidart`，要先改路徑）。`run.js`＋`gen.js` 是 22 個合成難拍情況的回歸；`realrun.js` 跑真實照片（請 Albert 提供）；`aspect.js` 是斜拍比例回歸。
- 真實測試照片：沒有放進公開 repo（木桌、大理石畫作，國旗、杯子勞作）。在 Albert 手上，新對話需要時請他附加。

### 網頁版版本紀錄
0.1.0 第一版 → 0.2.0 拍照 App 式介面 → 0.3.0 配色與圓體 → 0.4.0 改名冰箱美術館、難拍情況 → 0.5.0 大理石、紙角、轉向、真實範例 → 0.6.0 斜拍比例 → 0.7.0 勞作 AI 去背 → 0.8.0 冰箱門介面、中英文、免費額度測試 → **0.9.0** 暖暖廚房＋冰冰、點一下選主體、小螢幕裁切放大鏡、杯子雜物修正。

---

### 1.0.1 陰影去除（`ProcessingKit/ShadowEstimator.swift`）
- 只在找到紙或手動設角（quad != .full）時啟用；沒偵測到陰影時輸出和 1.0 完全相同。
- 只處理從紙邊伸進來（3 格內）或接在已確認陰影旁（4 格內）的陰影：避免把畫裡平塗的灰色（大象、烏雲）當成陰影變白。取捨：完全在紙中間的陰影不處理；塗到紙邊的大片灰色仍有小機率被調亮。
- 彩色紙增益上限 2.5×。測試照片（Albert 的實拍）只在本機，沒進 repo；其中一張是有版權角色的著色本，**永遠不要放進 repo 或範例**。

## 6. 待辦與未決

- [x] Albert：iPhone 安裝 TestFlight 1.0，回報問題 → 1.0.1 修正：放棄儲存（不要這張／全部不要）、陰影去除、降低發熱、設定齒輪移到右上角。
- [x] 1.1.0（Albert 10/28 要求）：重複作品提醒、小朋友頭像、美術館多選批次設定、拍給（新照片的小朋友）、連拍、備份提醒、付費頁新文案（Albert 已同意）。三輪獨立審查 GO。
- [ ] Albert：實機測 1.1.0（從 1.0.x 升級、陰影、連拍、重複提醒真實照片、發熱）。
- [x] 上架資料：`appstore/listing.json`＋`appstore/screenshots/`（加標題截圖），用「App Store 上架資料」流程寫入 ASC；隱私「不收集資料」、免費＋7 地區、內容版權、審查聯絡人都已填。2026-10-29 送審。
- [ ] 等審查結果（Apple 寄信）。通過後由 Albert 按「發佈」。被退件就修好再送。
- [ ] 上架後：早鳥價 NT$150（首月）要在 ASC 排價格。
- [ ] 確認內購商品狀態；設定 App 銷售地區（價格與供應狀況）。
- [ ] App Store 上架資料：中英文名稱、副標「寶貝的畫，一張都不用丟」、說明、關鍵字、截圖、隱私問卷（不收集資料）。
- [ ] 上架後：早鳥價 NT$150 一個月、兌換碼（比照星光）。
- [ ] 之後的方向：語音小故事強化、年度作品書印刷（主要營收）、去年今日提醒、LINE 分享給祖父母、iCloud 同步（CloudKit 目前關）。
- 未決：無。
