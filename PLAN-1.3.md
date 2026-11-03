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

## B. 主畫面小工具（WidgetKit）

- 小／中／大三種尺寸：輪播（每 3 小時換一張）美術館裡的作品（`isInMuseum`、有成品圖），顯示作品圖、小朋友名字、日期；點了打開 App 到那件作品（`fridgemuseum://artwork/<uuid>`）。空的時候顯示冰冰和「拍第一張作品吧」。
- 資料：App 每次存檔後（節流 30 秒）把最多 24 件作品的小圖（長邊 600px JPEG）和 `widget.json`（id、名字、日期）寫到 App Group 容器 `group.tw.starlight.fridgemuseum`，然後 `WidgetCenter.reloadAllTimelines()`。小工具不開資料庫。
- 新 target `FridgeMuseumWidget`（app-extension，bundle id `$(APP_BUNDLE_ID).widget`），project.yml 加，App embed。兩個 target 都要 App Group entitlement。
- 簽名：`ci/ci_sign.py` 要多登記 widget 的 bundle id、兩個 id 都開 `APP_GROUPS` 功能、做兩個描述檔；ios.yml 的 export.plist 帶兩個描述檔。**App Group 本身 ASC API 建不了**，要 Albert 到 developer.apple.com → Identifiers → App Groups 建 `group.tw.starlight.fridgemuseum`，並在兩個 App ID 勾上（或 Claude 在他同意下用瀏覽器操作）。
- 注意：`ci_sign.py` 剛被另一個對話改過（不主動刪憑證，608cebd），改的時候保留那個行為。

## 驗收
- 模擬器編譯＋全部單元測試通過（push `fix/**` 自動跑）。
- 獨立代理審查 GO（重點：資料不會被刪、切換模式安全、CloudKit 錯誤處理、簽名不影響星光）。
- 實機（Albert）：兩支手機、兩個 Apple 帳號：建立、邀請、加入、雙向新增／編輯／刪除、離開、停止分享；小工具三種尺寸。
