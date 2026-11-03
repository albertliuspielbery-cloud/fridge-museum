# 1.3.0 設計：家庭美術館 ＋ 主畫面小工具

2026-11-03。Albert 同意開工（「開工」）。實作完、測試全過、獨立審查 GO 之後才給 Albert 看；他回「可以」才合併、上傳。

## A. 家庭美術館（不同 Apple 帳號共用一個美術館）

### 產品規則（Claude 先定的預設，Albert 可改）
- 完整版使用者（館長）在設定頁按「建立家庭美術館」→「邀請家人」，用系統分享面板傳 iCloud 邀請連結（LINE、訊息都可以）。
- 家人點連結 → 打開冰箱美術館 → 「加入 ○○ 的家庭美術館」。家人不用買完整版：在家庭美術館裡大家都是完整版功能（館長的購買涵蓋全家）。
- 加入後所有人都能新增、編輯、刪除作品和小朋友（刪除照舊要確認）。
- 只同步「收進美術館」的作品（`isKept && !isSample`）和小朋友。拍到一半的待收作品留在拍的那支手機，收進之後才上傳。
- **個人美術館一筆都不刪**：建立或加入家庭美術館時，手機原本的資料庫原封不動留著（不開啟、不同步）。
  - 館長建立時：把個人美術館的作品「複製」進家庭美術館。
  - 家人加入時：問「要把你手機上的 N 件作品也放進家庭美術館嗎？」（複製，預設不要）。
- 離開（家人）或停止分享（館長）：回到個人美術館。離開前可以選「把家庭美術館的作品複製一份到我的手機」。被館長移除或停止分享時，自動把本機快取的家庭作品複製進個人美術館，冰冰提示一次。
- 1.2 的 iCloud 個人同步：在家庭模式時不開個人資料庫，所以也不同步。回到個人模式時照 1.2 規則。

### 技術架構
- SwiftData 不支援 CloudKit 共享資料庫，所以家庭美術館**不用** NSPersistentCloudKitContainer，改用 **CKSyncEngine**（iOS 17+）。
- 本機：另一個 SwiftData 檔案 `family.store`（`cloudKitDatabase: .none`，同一個 Schema、不同 configuration 名稱 → 不同檔案）。每次開 App 只開一個資料庫：個人（`default.store`，照 1.2 規則）或家庭（`family.store`）。切換＝下次開 App 生效（同 1.2 的理由），或切換後提示「重新打開 App」——實作時若能在 RootView 安全地重建 container（沒有任何 view／task 握著舊的）就直接切，否則請使用者重開。
- 雲端：館長私人資料庫裡的自訂 zone `FamilyMuseum`，用 **zone-wide CKShare**（`CKShare(recordZoneID:)`，`publicPermission = .none`，參與者 readWrite）。館長的 CKSyncEngine 跑 `privateCloudDatabase`；家人的跑 `sharedCloudDatabase`。
- 紀錄：`Child` / `Artwork` 各一種 record type（`FMChild`、`FMArtwork`，recordName = UUID 字串）。欄位對應模型的屬性；圖片、錄音用 `CKAsset`（暫存檔）。小朋友關聯用欄位 `childID`（字串），不用 CKReference，避免刪除連鎖。
- 本機變更追蹤：不用 SwiftData history。`FamilySyncState`（JSON 檔，和 CKSyncEngine 的 state serialization 一起存）記每筆已上傳的 `(id, modifiedAt, renderVersion)`；存檔後（AppModel 已有的儲存點）掃一次 `isKept && !isSample` 的作品與小朋友，`modifiedAt`/`renderVersion` 變了的排上傳，記錄裡有、本機沒有的排刪除。掃描只讀小欄位，不碰 externalStorage。
- 衝突：伺服器回 `serverRecordChanged` 時，比 `modifiedAt`，新的贏（和 1.2 SyncDedupe 一致）；平手用伺服器的。
- 下載：`fetchedRecordZoneChanges` → upsert 到 `family.store`（下載的變更不算本機變更：寫入後同步更新 FamilySyncState，避免回傳）。刪除同理。
- 邀請：`UICloudSharingController`（館長管理成員、停止分享）。接受：`UIApplicationDelegateAdaptor` + scene delegate 的 `windowScene(_:userDidAcceptCloudKitShareWith:)` → `CKAcceptSharesOperation`。Info.plist 加 `CKSharingSupported = YES`。
- 純邏輯（record ↔ 欄位對應、變更比對、衝突決策、模式決策）放 `ArchiveKit/FamilySyncPolicy.swift`，單元測試 `FridgeMuseumTests/FamilySyncTests.swift`。CloudKit 呼叫只在 `App/FamilySync.swift`。模擬器／DemoMode／單元測試不碰 CloudKit（同 `CloudSync.isSupportedEnvironment`）。
- CloudKit schema：Production 不能自動建 record type。`ci/cloudkit/schema.ckdb` 加 `FMChild`、`FMArtwork`（含 `___recordID` queryable 索引）、`cloudkit.share` 不用另加。跑 cloudkit-schema.yml 匯入開發環境 → Console 部署到 Production（Albert 按或請他同意 Claude 按）。

### 實作時定下或調整的（`fix/1.3-family`）
- **切換一律「重新打開 App」生效**（建立、加入、離開、停止分享）。沒有在 RootView 重建 container：AppModel 的背景工作、CloudSync 的維護 closure 都握著舊的 context，重建不保證安全。
- **掃描本機變更的時機**：不在 AppModel 各個存檔點加程式，而是 FamilySync 監聽 `ModelContext.didSave`（AppModel、編輯器、設定頁的存檔都會觸發），2 秒節流；App 進背景時再掃一次。AppModel 只多一行 `let family = FamilySync()`（方便和小工具分支合併）。
- **正在算圖的作品先不上傳**（`processingState` pending/processing），算完 `renderVersion` 變了才上傳一次；但不會被當成刪除。
- **防誤刪**（審查後改成按比例）：這次開 App 以來「看過」又不見的紀錄＝真的刪了（使用者刪除、或不再收在美術館），照常送刪除；「這次開 App 從沒看過」就不見的（資料庫打開就是空的或壞的）若 ≥ 3 筆**且**超過已上傳的一半，先不送刪除（不會把每支手機清空）。family.store 打不開（退回暫存記憶體）時整個 session 不同步。刪除小朋友時，他的作品會 `touch()`，「未分類」才會同步出去。
- **衝突細節**：下載的紀錄若本機自上次上傳後沒改過，一律用伺服器的（不比兩支手機的時鐘）；本機有沒上傳的修改才比 `modifiedAt`，新的贏、平手用伺服器的。別人刪除、但這支手機有沒上傳的修改 → 保留並重新上傳（資料安全優先）。時間比較容許 10 ms（CloudKit 只存到毫秒）。
- **讀不到的圖檔不當成「沒有圖」**（審查後加）：欄位沒有值＝真的沒有；有 CKAsset 但檔案讀不到（例如衝突時 `serverRecord` 沒帶下載的圖）＝不套用這筆、不更新 change tag、不記成已上傳，改用 `records(for:)` 直接重抓整筆（每次開 App 最多 5 輪，剩下的下次再抓；等待期間這筆不上傳）。所以「圖不見 → 下次編輯把空的圖傳上去」不會發生。
- **不同步的欄位**：`lastSavedToPhotosAt`（「這支手機」存到照片過）、`isKept`／`isSample`（只同步收進的作品，必為 true／false）。
- **複製（個人 ⇄ 家庭）**：保留原本的 id，所以重複複製不會變兩份；目標已有同 id 的紀錄時，只有來源的 `modifiedAt` 比較新才更新，**目標一筆都不刪**。複製用短暫的第二個 container 開「另一個」檔案（從不在同一個檔案開兩個 container）。唯一會清空資料庫的 `resetFamilyStore`（加入／建立新的家庭美術館前清 family.store）遇到個人資料庫的路徑會直接拒絕。
- **停止分享（館長）**：先抓最新的變更 → 複製到個人美術館 → **刪掉整個 `FamilyMuseum` zone**（share 跟著消失，不佔館長 iCloud 空間）。家人手機發現 zone 不見了就自動把本機的家庭作品複製進個人美術館。沒網路就不停止、提示再試。停止前先掃描並送出這支手機還沒上傳的變更。開始停止時先記 `stopRequested`，沒做完（沒網路、複製失敗、或在系統分享畫面按了「停止分享」但後續失敗）下次開 App 會自動接著做，結果用提示告訴館長，不會停在一半。
- **離開（家人）**：先抓最新變更、掃描、送出還沒上傳的（各有時間上限）→（選了的話）全部複製 → 從自己的共享資料庫刪掉 share（＝離開，館長的資料不受影響）。沒網路就不離開。**選「直接離開」時，家庭還沒有的作品（沒上傳成功、還在算圖）也一定複製進個人美術館**，並提示一聲，不會因為離開而不見。
- **自動結束**：被移除／停止分享（共享 zone 不見、或上傳回 zoneNotFound）、iCloud 登出或換帳號（CKSyncEngine 的 accountChange）→ 自動複製進個人美術館、冰冰提示一次。複製失敗時保留 membership 並標 `pendingEnd`，下次開 App 會開 family.store（不同步）重試，成功才回個人美術館。
- **邀請**：`UICloudSharingController`，只開放「受邀的人」＋可編輯（`publicPermission = .none`）。用「訊息」「郵件」寄會自動把對方加成參與者；用 LINE 這類 App 傳連結時，要先在分享畫面加對方的 Apple 帳號電話或 email，否則對方打不開（不開「知道連結的任何人」，避免連結外流；隱私權頁也不提這個選項。要不要開連結分享，Albert 之後再決定）。
- **館長自己的另一台裝置**（同 Apple 帳號）點自己的邀請連結 → 以館長身分加入（同一個私人資料庫 zone）。
- **1.2 個人同步**：家庭模式時設定頁不顯示 iCloud 同步區、也不跳 1.2 的同步說明；建立家庭美術館、個人同步的判斷都用「這個 Apple 帳號買過」（`StoreBridge.isPurchased`），家庭給的完整版不算。
- 狀態：沒有網路監看，離線時只會顯示「準備中／已同步」與上次同步時間；上傳失敗（空間不足等）才顯示問題。

## B. 主畫面小工具（WidgetKit）

- 小／中／大三種尺寸：輪播（每 3 小時換一張）美術館裡的作品（`isInMuseum`、有成品圖），顯示作品圖、小朋友名字、日期；點了打開 App 到那件作品（`fridgemuseum://artwork/<uuid>`）。空的時候顯示冰冰和「拍第一張作品吧」。
- 資料：App 每次存檔後（節流 30 秒）把最多 24 件作品的小圖（長邊 600px JPEG）和 `widget.json`（id、名字、日期）寫到 App Group 容器 `group.tw.starlight.fridgemuseum`，然後 `WidgetCenter.reloadAllTimelines()`。小工具不開資料庫。
- 新 target `FridgeMuseumWidget`（app-extension，bundle id `$(APP_BUNDLE_ID).widget`），project.yml 加，App embed。兩個 target 都要 App Group entitlement。
- 簽名：`ci/ci_sign.py` 要多登記 widget 的 bundle id、兩個 id 都開 `APP_GROUPS` 功能、做兩個描述檔；ios.yml 的 export.plist 帶兩個描述檔。**App Group 本身 ASC API 建不了**，要 Albert 到 developer.apple.com → Identifiers → App Groups 建 `group.tw.starlight.fridgemuseum`，並在兩個 App ID 勾上（或 Claude 在他同意下用瀏覽器操作）。
- 注意：`ci_sign.py` 剛被另一個對話改過（不主動刪憑證，608cebd），改的時候保留那個行為。

### B 實作記錄（2026-11-03，`fix/1.3-widget`）與設計差異
- **存檔掛勾**：不是在 AppModel 每個 `context.save()` 後面加呼叫（儲存點散在 UI 各處），改成監聽 SwiftData 的 `ModelContext.didSave`（任何 context），30 秒節流；另外開 App 寫一次、進背景立刻寫。AppModel 只多一個 `widgetArtworkID` 屬性（點小工具用），方便和家庭同步分支合併。
- **選作品**：最多 24 件，最愛優先、其次最新；輪播新到舊。時段固定在當地 00/03/06…點（夏令時間照牆上時鐘），同一時段同一件。
- **widget.json**：多了 `version`、`generatedAt`、`kind`、`imageFile`（圖檔名含 renderVersion，改圖就換新檔、舊的刪掉）。
- **點小工具**：直接開作品頁（RootView 回首頁再推 `Route.detail`），不用退而求其次開美術館。相機／付費頁蓋著時作品頁在底下。
- **外觀**：薄荷冰箱門＋白相紙＋水果磁鐵（同分享卡片），素材是 App 既有 SVG 的複本；字型用系統圓體（不把字型檔包進 extension）。
- **簽名**：除了上面寫的，`ci_sign.py` 會先讀描述檔確認有 App Group，沒有就停下並印出手動步驟；描述檔改成每個 target 各自指定（project.yml Release 設定讀 `FM_APP_PROFILE`／`FM_WIDGET_PROFILE`）。

## 驗收
- 模擬器編譯＋全部單元測試通過（push `fix/**` 自動跑）。
- 獨立代理審查 GO（重點：資料不會被刪、切換模式安全、CloudKit 錯誤處理、簽名不影響星光）。
- 實機（Albert）：兩支手機、兩個 Apple 帳號：建立、邀請、加入、雙向新增／編輯／刪除、離開、停止分享；小工具三種尺寸。
