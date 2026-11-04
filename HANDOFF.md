# 冰箱美術館 交接文件

2026-10-28　星光工作室 Starlight Studio　著作權與 IP 屬於星光工作室 Starlight Studio

這份是給「新對話的 Claude」看的完整交接。新對話開始時先讀完這份和 DECISIONS.md（討論歷程與決策理由），再動手。

---

## 1. 目前狀態（2026-10-28）

| 項目 | 狀態 |
|---|---|
| iOS App | **1.1.0** 已送審（2026-10-29，App＋「完整版」內購，等待審查；手動發布；`v1.1.0` 標籤＝送審版本）。**1.2.2** 已上傳 TestFlight（2026-11-03；1.2.1 在 10-30）：iCloud 同步（完整版）、分享卡片、拍照自動轉正（1.2.1 修平放／連拍方向）、筆刷放大、美術館大圖／小圖／一次轉向、新手教學。1.2.2 加強昏暗／白桌紙張偵測（先跑 1.2.1 原判斷，找不到才救援）＋相機手電筒。1.2.x 還要實機測（平放拍照、手電筒；iCloud 後台看得到 10/30 上傳約 220 MB）。**1.3.0** 已上傳 TestFlight（2026-11-04，已合併 main）：家庭美術館＋主畫面小工具；要用兩個 Apple 帳號實機測。上架憑證已滿且都 <14 天時，上傳自動改用 Apple 雲端簽名（先匯出檢查 iCloud／推播／App Group entitlements 才上傳）；小工具 App ID 一定要在 App Groups 裡指派 group.tw.starlight.fridgemuseum，否則雲端簽名回 Authentication failed。**1.2.2**（`fix/1.2.2`，未合併）：暗光／白桌子找紙、相機手電筒 |
| App 內購買 | `tw.starlight.fridgemuseum.full`「完整版 / Full Version」已建立：NT$190、家人共享開、地區 TW/HK/US/CA/GB/AU/SG。審查截圖已上傳（10/28 第 2 次執行成功），但流程結束時讀到的狀態仍是 MISSING_METADATA，要到 ASC 確認是否已變 Ready to Submit |
| 網頁測試版 | **0.9.0** 上線中：https://claude.ai/artifact/MQTbRzJLuHZUzNpgRvADPf （只有擁有者看得到）。原始碼在 `web/` |
| repo | `albertliuspielbery-cloud/fridge-museum`（**公開**）。main = App 1.2.2（1.1.0 在審查中，修正請從 `v1.1.0` 標籤開分支）。開發分支用 `fix/**`（push 也會跑模擬器測試） |
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

### 1.3.0 主畫面小工具（已合併 main）
- 小／中／大三種尺寸。薄荷冰箱門底色、白相紙上的作品、水果磁鐵（依作品 id 固定 lemon/tomato/berry），下面是小朋友名字和日期（系統依語言顯示 zh-Hant／en 日期）。每 3 小時（00、03、06…點，當地時間）換一件；同一個時段一定是同一件（`WidgetSchedule`：第 n 個時段顯示第 n mod 件數件，一整天依序輪過去）。點作品打開 App 到那件作品頁（`fridgemuseum://artwork/<uuid>`）。美術館沒有作品（或 App 還沒寫過資料）：冰冰＋「拍第一張作品吧」。
- 選哪些：收進美術館的（`isKept && !isSample`）、有成品圖或小圖的，最多 24 件：最愛優先，其次最新（作品日期）；輪播順序是新到舊。
- 資料流：App 存檔（任何 ModelContext 的 `didSave`，包括編輯、刪除、同步整理）後最多 30 秒寫一次、開 App 寫一次、進背景立刻寫（`App/WidgetSnapshot.swift`，背景執行緒、自己的 ModelContext）。寫到 App Group `group.tw.starlight.fridgemuseum`：`WidgetImages/<id>-<renderVersion>.jpg`（長邊 ≤ 600、JPEG 0.85；已存在就不重做）＋ `widget.json`（原子寫入），寫完才刪沒用到的圖，內容有變才 `reloadAllTimelines()`。小工具不開資料庫。拿不到 App Group 容器（模擬器未簽名、描述檔沒有 App Group）就安靜跳過；單元測試、DemoMode 不寫。
- 程式：`Shared/WidgetModel.swift`（App 和小工具都編譯：路徑、JSON、選作品、時段；測試 `FridgeMuseumTests/WidgetModelTests.swift`）、`App/WidgetSnapshot.swift`、`FridgeMuseumWidget/`（extension、自己的 String Catalog、素材是 App 冰冰／磁鐵 SVG 的複本，沒有新美術；字型用系統圓體，不帶字型檔）。點小工具：`FridgeMuseumApp.onOpenURL` → `AppModel.widgetArtworkID` → RootView 關掉設定頁、回首頁再推作品頁（冷啟動也會開）。相機全螢幕或付費頁開著時，作品頁推在底下，關掉才看到（沒特別處理）。
- 簽名（只在「上傳」時跑，push 的模擬器測試驗證不到）：`ci/ci_sign.py` 多登記 `tw.starlight.fridgemuseum.widget`、兩個識別碼都開 `APP_GROUPS`、用同一張憑證做兩個描述檔（`FridgeMuseum AppStore CI`、`FridgeMuseum Widget AppStore CI`），並檢查兩個描述檔裡真的有這個 App Group，沒有就停下、印出下面的步驟。憑證規則沒改（不主動刪，608cebd）。`ios.yml` 不再傳全域 `PROVISIONING_PROFILE_SPECIFIER`，改傳 `FM_APP_PROFILE`／`FM_WIDGET_PROFILE`，由 `project.yml` 兩個 target 的 Release 設定各自取用；export.plist 的 `provisioningProfiles` 帶兩個識別碼。

**Albert 要手動做一次（Apple 沒有開放 API），上傳 1.3.0 之前：**
1. 打開 https://developer.apple.com/account/resources/identifiers/list/applicationGroup → 右上「＋」→ 選 **App Groups** → Continue → Description 填 `Fridge Museum`、Identifier 填 `group.tw.starlight.fridgemuseum` → Continue → Register。
2. 跑一次「準備 App 識別碼」https://github.com/albertliuspielbery-cloud/fridge-museum/actions/workflows/bundle-id.yml （會登記 `tw.starlight.fridgemuseum.widget` 並在兩個識別碼開 App Groups 功能）。
3. 打開 https://developer.apple.com/account/resources/identifiers/list → 點 **tw.starlight.fridgemuseum** → 在 App Groups 那一行按 Configure（或 Edit）→ 勾 `group.tw.starlight.fridgemuseum` → Continue → Save（問描述檔會失效選 Confirm）。
4. 回列表點 **tw.starlight.fridgemuseum.widget**，同樣勾 `group.tw.starlight.fridgemuseum` → Save。
5. 之後照常按「上傳」。沒做第 1、3、4 步時，上傳會停在「簽名準備」並顯示這些步驟（會多建立一張上架憑證，Apple 上限內沒關係）。

**只能實機驗證：** 三種尺寸在不同 iPhone（SE／mini／Pro Max）上的版面與深色模式；新增、刪除、改圖、轉向後小工具在 30 秒內更新；App 被關掉時（進背景那次寫入）是否來得及；3 小時輪播（Apple 會依電量排程，不一定準時）；點小工具冷啟動／熱啟動都打開那件作品；被刪掉的作品顯示「找不到這件作品」；小工具記憶體（30 MB 上限，圖 ≤ 600 px 應該很寬鬆）；上傳流程（兩個描述檔、App Group）第一次跑。

### 1.3.0 家庭美術館（已合併 main）
- 不同 Apple 帳號共用一個美術館。設計與實作時的調整見 `PLAN-1.3.md` §A（含「實作時定下或調整的」）。
- 程式：`ArchiveKit/FamilySyncPolicy.swift`（模式決策、變更比對、衝突、record 欄位對應，全部可單元測試）、`App/FamilySync.swift`（CKSyncEngine、建立／邀請／加入／離開／停止分享、接受邀請的 app／scene delegate）、`ArchiveKit/ArchiveStore.swift`（`family.store`、個人 ⇄ 家庭複製）、`UI/FamilyViews.swift`（設定頁區塊、加入確認頁）、`UI/StoreBridge.swift`（`FamilyAccess`：家庭模式大家都是完整版）。測試：`FridgeMuseumTests/FamilySyncTests.swift`。
- 每次開 App 只開一個資料庫（個人 `default.store` 或家庭 `family.store`），切換都是「重新打開 App」生效。**個人資料庫永遠不刪不清**：建立／加入是把作品複製進 family.store，離開／停止分享／被移除是複製回個人。
- 館長：私人資料庫 zone `FamilyMuseum` + zone-wide CKShare。家人：共享資料庫。只同步收進美術館的作品（`isKept && !isSample`）和小朋友。
- Info.plist 加了 `CKSharingSupported`（project.yml）。
- 審查（NO-GO）後修正：讀不到的圖檔不當成沒有圖（重抓，不套用、不上傳）；離開／停止分享前先送出本機變更，「直接離開」也一定把沒上傳的作品複製回個人美術館；停止分享沒做完會在下次開 App 接著做；邀請只開放受邀的人；防誤刪改成按比例；刪除小朋友時他的作品會同步成未分類。細節見 `PLAN-1.3.md`。

**擁有者要手動做的（上傳第一個 1.3.0 TestFlight 之前）**
1. 跑「CloudKit 資料結構（開發環境）」流程：https://github.com/albertliuspielbery-cloud/fridge-museum/actions/workflows/cloudkit-schema.yml （`schema.ckdb` 新增了 `FMArtwork`、`FMChild`，原有的不變）。
2. https://icloud.developer.apple.com/dashboard/ → 選容器 → Development → Schema 確認有 `FMArtwork`、`FMChild` →「Deploy Schema Changes…」→ Deploy。TestFlight／App Store 用正式環境，沒部署的話建立家庭美術館後上傳會失敗（設定頁顯示「暫時無法同步」）。

**只能實機驗證的**（兩支手機、兩個 Apple 帳號）：建立 → 邀請（訊息、LINE＋加電話/email）→ 點連結打開 App（App 開著／沒開兩種）→ 加入確認頁 → 重新打開進入家庭美術館；雙向新增／編輯／刪除作品和小朋友、推播即時更新、大量作品第一次上傳；離線編輯後連線；兩支同時改同一件（衝突後圖片不會不見）；離線時「直接離開」（沒上傳的作品要出現在個人美術館）；停止分享時沒網路、下次開 App 自動接著停；家人離開（有／沒有複製）、館長停止分享（家人手機自動複製並提示）、在系統分享畫面「停止分享／移除我」；同步中登出 iCloud；館長 iCloud 空間不足；家人沒買也能用完整版、館長離開後回到免費版的額度；館長自己的 iPad 點邀請連結。CloudKit 本身沒辦法在 CI 測（模擬器版本沒簽名、沒有 Apple 帳號）。

### 1.2.2 暗光／白桌子找紙（`fix/1.2.2`）
- 擁有者回報：餐廳／家裡暗暗的暖光、白色大理石桌（紋路、反光）上常找不到紙邊。實測（他的照片貼一張白紙）：大理石本身的邊緣對比約 2.5–4.5，沒有影子的白紙邊約 5–9，有一點影子約 20–40；1.2.1 規定 Vision 外框底下對比要 ≥ 5，剛好把對的外框丟掉。
- 找紙：**先跑和 1.2.1 一模一樣的判斷**（`PaperDecision.legacy`），1.2.1 會裁的照片結果完全相同；只有 1.2.1 會用整張照片時，才用新的「多個偵測器提案、一個分數決定」補救（`PaperCandidateScoring.rescue`：Vision 文件偵測 ≥ 0.3、矩形偵測、移植偵測器沒把握的外框；形狀 × 證據）。補救只在外框像紙、≤ 95% 畫面、邊緣對比 ≥ 4，且有 1.2.1 等級的 Vision 文件（或邊緣在 4–8 的淡邊範圍）時才裁切，否則只當「裁切」的起始角。
- 找不到紙：仍用整張照片（紙填滿畫面時才不會被切到），提示改成「找不到紙的邊，可以拖四個角，或在白桌子上墊一張深色的紙」；打開「裁切」時四角先用虛線顯示在建議位置（弱外框，沒有就內縮 12%），拖了才生效（只為了轉向打開裁切不會被裁掉）。
- 相機：即時外框仍是 Vision 文件偵測約 8 次／秒；文件偵測不確定時才跑矩形偵測，最多每 0.3 秒一次（發熱）。暗光判斷用畫面 EXIF 亮度（Bv），沒有就用 ISO＋快門估、畫面太暗也算，進入要持續 1 秒、離開 1.5 秒（`CaptureKit/LowLight.swift`）。左上新增手電筒鈕（有手電筒的裝置才顯示；模擬器、DemoMode 截圖不會有），暗的時候變黃框，冰冰提示「有點暗，開手電筒會更清楚」。手電筒只由使用者打開；離開相機、App 進背景就關；系統自己關掉（過熱、中斷）就接受、不再打開。拍照閃光燈維持關閉。
- 只能實機驗證：暗光判斷的門檻（Bv < 0 進入、> 1 離開）在真實餐廳／家裡是否合適；手電筒在三鏡頭虛擬裝置上的行為與發熱；白大理石上 Vision 文件／矩形偵測的實際效果。

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
- 重複：新手機用舊手機備份還原、兩台都開同步，會各上傳一份（同 id）→ 依「裝置 id 字串最小的那份」留下那筆紀錄（固定順序，避免兩台各刪一份），但欄位內容取「最後編輯」的那份（`modifiedAt`，每次家長編輯都會 `touch()`；標籤取新的那組，不聯集）；兩台各自新增同名的小朋友（生日相同或其中一個沒填）也會合併。
- 帳號檢查：同步過的手機每次開 App 都要確認還是同一個 Apple 帳號（帳號狀態和使用者一起查，最多等 3 秒）；帳號不同或沒網路確認不了 → 這次不同步（設定頁顯示原因）。換了帳號只能換回原本的帳號才會繼續——**沒有「改用新帳號」的按鈕**：清掉記住的帳號、用新帳號開同步時，NSPersistentCloudKitContainer 會把舊帳號同步過的資料從手機刪掉，做不到安全；支援頁請使用者關閉同步並來信。之後要做的話，得先把資料搬到另一個沒有同步紀錄的新資料庫再開同步。上傳失敗（空間不足等）時設定頁一直顯示問題，直到上傳成功才顯示「已同步」。
- 已知限制（實機測試時注意）：用「從沒同步過」的舊手機備份還原到新手機、而舊手機也繼續用時，兩台的副本 id 相同；如果新手機的 UserDefaults 沒跟著還原（例如只還原 App 資料），兩份會被標成同一台裝置，重複合併不會處理（同一台裝置的副本永遠不刪），美術館會看到重複的作品。
- 編輯器套用修改時，新的處理參數和 processingState = pending 一起存；成品圖算完才改成 done。別台不會看到「新參數＋舊成品圖＋done」。同步過來、超過 10 分鐘還沒完成的作品（含合併後成品圖對不上參數的）會在這台重算。
- **資料結構（`ci/cloudkit/schema.ckdb`）在 review 後改過**（新增 `CD_modifiedAt`、字串欄位的 `_ckAsset`）：部署到正式環境前要重跑「CloudKit 資料結構（開發環境）」流程再部署；如果已經部署過舊版，也要再跑一次＋再部署一次（只會新增欄位）。

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
- [ ] 之後的方向：語音小故事強化、年度作品書印刷（主要營收）、去年今日提醒、LINE 分享給祖父母。（iCloud 同步已在 1.2.0 做好，見「1.2.0 iCloud 同步」。）
- 未決：無。
