# 冰箱美術館 交接文件

2026-10-28　星光工作室 Starlight Studio　著作權與 IP 屬於星光工作室 Starlight Studio

這份是給「新對話的 Claude」看的完整交接。新對話開始時先讀完這份，再動手。

---

## 1. 目前狀態（2026-10-28）

| 項目 | 狀態 |
|---|---|
| iOS App | **1.0** 已上傳 TestFlight（run 40660153242，main @ fbd56ee）。擁有者還沒在實機測過 |
| App 內購買 | `tw.starlight.fridgemuseum.full`「完整版 / Full Version」已建立：NT$190、家人共享開、地區 TW/HK/US/CA/GB/AU/SG。狀態 MISSING_METADATA → 已把審查截圖放到 `ci/iap_review.png`，要再跑一次「App 內購買項目」流程 |
| 網頁測試版 | **0.9.0** 上線中：https://claude.ai/artifact/MQTbRzJLuHZUzNpgRvADPf （只有擁有者看得到）。原始碼在 `web/` |
| repo | `albertliuspielbery-cloud/fridge-museum`（**公開**）。main = App 1.0 |
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
- 結構：`FridgeMuseum/App`（AppModel、RootView、DemoMode 只在 Debug）、`UI/`、`ArchiveKit/`（SwiftData：Child、Artwork；CloudKit 目前關）、`CaptureKit/`、`ProcessingKit/`（API 見 `ProcessingKit/API.md`）、`StoreKit/`（API 見 `StoreKit/API.md`）、`Resources/`（素材、字型 Huninn + Chiron GoRound TC 子集，OFL）。
- 字串：`Localizable.xcstrings`、`InfoPlist.xcstrings`、`StoreKit/Paywall.xcstrings`（zh-Hant + en）。工具：`tools/make_strings.py`、`tools/l10n_scan.py`、`tools/sprite_to_assets.py`、`tools/subset_fonts.py`。
- 勞作去背用 Apple `VNGenerateForegroundInstanceMaskRequest`（每個 instance = 一個可點選部件），失敗退回顏色法，再退回原照片。

### GitHub Actions（都在 main，手動 Run workflow）

| 流程 | 連結 | 誰按 |
|---|---|---|
| iOS App（勾「上傳」才上傳 TestFlight） | https://github.com/albertliuspielbery-cloud/fridge-museum/actions/workflows/ios.yml | 上傳由 Albert |
| App 內購買項目 | https://github.com/albertliuspielbery-cloud/fridge-museum/actions/workflows/ios-iap.yml | Albert |
| 準備 App 識別碼 | https://github.com/albertliuspielbery-cloud/fridge-museum/actions/workflows/bundle-id.yml | 已完成 |
| iOS Screenshots（模擬器拍 14 畫面 × 中英 × 淺深，推到 `ci-shots` 分支） | https://github.com/albertliuspielbery-cloud/fridge-museum/actions/workflows/ios-shots.yml | Claude 可跑 |

- Secrets：`ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_KEY_P8`、`APPLE_TEAM_ID`（Albert 設的，Admin 權限金鑰）。
- 沒有 Mac：CI 是唯一的編譯器。雲端環境的 proxy 擋掉 Actions log 和 artifact 下載，看錯誤用 annotations（`ci/annotate_log.py`），看畫面用 `git fetch origin ci-shots`。
- push 到 main 會自動跑模擬器編譯＋單元測試（95 個測試）。

### TestFlight 還要做的
1. 再跑一次「App 內購買項目」，讓商品從 MISSING_METADATA 變成 Ready to Submit（沙盒才拿得到價格）。之後最好換成實機付費頁截圖（存成 `ci/iap_review.png` 重跑）。
2. App Store Connect →「價格與供應狀況」：App 本身的地區只勾 TW/HK/US/CA/GB/AU/SG。
3. TestFlight 內部測試群組加 Albert。
4. 第一次送審時，在版本頁把「完整版」加進去；英文名稱 My Fridge Museum、截圖、說明、關鍵字還沒做（可比照星光的 ios-metadata.yml）。

### 實機要測的（審查員列的）
重拍／刪除不閃退；12MP/48MP/ProRAW 匯出 4096 的記憶體（舊機 4GB RAM）；照片權限四種狀態（每次只跳一個系統視窗、每個孩子的相簿）；沙盒購買／恢復／Ask to Buy／退款；相機權限與中斷；語音轉文字；跨午夜額度；Dynamic Type、VoiceOver；Vision instance 去背實際效果。

### 已知小問題（nit）
- 語音轉文字完成後寫入前沒檢查作品是否已刪除（`UI/EditPanels.swift` 約 529 行）。
- 中文首頁副標最後一字掉到第二行；英文空冰箱範例卡不捲動時被流理台切到。

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

## 6. 待辦與未決

- [ ] Albert：iPhone 安裝 TestFlight 1.0，回報問題（截圖或原始照片）。
- [ ] 重跑 App 內購買項目（補審查截圖）；設定 App 銷售地區。
- [ ] App Store 上架資料：中英文名稱、副標「寶貝的畫，一張都不用丟」、說明、關鍵字、截圖、隱私問卷（不收集資料）。
- [ ] 上架後：早鳥價 NT$150 一個月、兌換碼（比照星光）。
- [ ] 之後的方向：語音小故事強化、年度作品書印刷（主要營收）、去年今日提醒、LINE 分享給祖父母、iCloud 同步（CloudKit 目前關）。
- 未決：無。
