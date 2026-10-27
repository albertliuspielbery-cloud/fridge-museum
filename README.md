# 冰箱美術館（iPhone App）

把孩子的畫作和勞作拍下來，App 會自動：

- **平面畫作**：找出紙張四角、拉正、修平光線、把紙變白，但保留淡淡的蠟筆和水彩顏色，還會清掉紙上的小黑點。
- **立體勞作**：把作品從桌面「挖」出來，放到乾淨的背景上，加一點自然的陰影。

作品會依 **小朋友、畫作／勞作、年齡、學期（上／下學期）、年份、標籤、最愛 ⭐** 分類整理，並可以存到手機「照片」裡每位小朋友自己的相簿（「冰箱美術館 – 小明」）。

所有處理都在手機上完成，**不連網、不上傳**。原始照片永遠保留，之後隨時可以重新調整。

---

## 你不需要 Mac

這個專案用 **GitHub Actions**（GitHub 提供的雲端 Mac）來編譯 App，再自動上傳到 Apple 的 **TestFlight**。你只要在 iPhone 上安裝 TestFlight App，就能安裝冰箱美術館。

整個流程只有第 1 步一定要你本人做（Apple 要驗證身分），其餘步驟工程師可以陪你一起完成。

### 你需要準備

| 項目 | 說明 |
| --- | --- |
| Apple ID | 你平常用的就可以，建議開啟雙重認證。 |
| Apple Developer Program 會員 | 每年 US$99。上 TestFlight 和 App Store 一定要有。 |
| GitHub 帳號 | 免費。程式碼放在這裡，雲端編譯也在這裡跑。 |
| iPhone（iOS 18 以上） | 安裝「TestFlight」App（App Store 免費下載）。 |

---

## 一步一步上 TestFlight

### 第 1 步：加入 Apple Developer Program（只有你能做）

1. 用 iPhone 下載 **Apple Developer** App，登入你的 Apple ID。
2. 點「帳號」→「立即註冊」，以 **個人** 身分加入（公司身分需要鄧白氏編碼，比較麻煩）。
3. 依指示拍身分證件、付款 US$99。
4. 審核通常 1～2 天。收到「Welcome to the Apple Developer Program」email 就完成了。

### 第 2 步：查你的 Team ID

1. 電腦瀏覽器打開 <https://developer.apple.com/account> 並登入。
2. 在「會員資格詳細資訊（Membership details）」找到 **Team ID**（10 個英數字，例如 `A1B2C3D4E5`），先記下來。

### 第 3 步：登記 App 的「身分證號碼」（Bundle ID）

1. 打開 <https://developer.apple.com/account/resources/identifiers/list>。
2. 按「＋」→ 選 **App IDs** → **App** → 繼續。
3. Description 填 `Fridge Museum`；Bundle ID 選 **Explicit**，填一個別人不會用的名稱，例如 `com.你的英文名.fridgemuseum`（全小寫、不能有空格）。
4. 下面的功能（Capabilities）都不用勾，按 Continue → Register。

> 記下這個 Bundle ID，第 6 步會用到。

### 第 4 步：在 App Store Connect 建立 App

1. 打開 <https://appstoreconnect.apple.com> →「App」→ 左上「＋」→「新增 App」。
2. 平台：iOS；名稱：`冰箱美術館`（如果被用掉了，可以改成「冰箱美術館 – 你的姓」之類）；主要語言：繁體中文；Bundle ID：選第 3 步建立的那個；SKU：隨便填，例如 `fridgemuseum`；使用者存取權：完整存取權。
3. 建立後，在「App 資訊」把 **類別** 設成「攝影與錄影」或「生活風格」。
   **請不要選「兒童」類別**（兒童類別有很多額外規定，我們的 App 是給家長用的）。

### 第 5 步：建立 App Store Connect API 金鑰（讓 GitHub 能幫你上傳）

1. App Store Connect →「使用者與存取權限」→ 上方「整合」分頁 →「App Store Connect API」→「團隊金鑰」。
2. 第一次使用要先按「要求存取權」並同意條款。
3. 按「＋」產生金鑰：名稱 `GitHub CI`，存取權選 **管理（Admin）**。
   （需要 Admin，雲端才能自動幫你建立發佈用的簽署憑證。）
4. 產生後記下兩個值：**Issuer ID**（頁面上方那串）和這把金鑰的 **金鑰 ID（Key ID）**。
5. 按「下載 API 金鑰」，會得到一個 `AuthKey_XXXXXXXXXX.p8` 檔。**這個檔只能下載一次**，請妥善保存，不要寄給別人、不要放到任何公開的地方。

### 第 6 步：把金鑰放進 GitHub（加密保存）

工程師會把專案放到你的 GitHub 帳號（私人儲存庫）。打開那個儲存庫：

1. 「Settings」→ 左側「Secrets and variables」→「Actions」。
2. 在「Secrets」分頁按「New repository secret」，依序新增 4 個：

| 名稱（Name） | 內容（Secret） |
| --- | --- |
| `APPLE_TEAM_ID` | 第 2 步的 Team ID |
| `ASC_ISSUER_ID` | 第 5 步的 Issuer ID |
| `ASC_KEY_ID` | 第 5 步的金鑰 ID |
| `ASC_KEY_P8` | 用「記事本」或「文字編輯」打開 `.p8` 檔，**整份內容複製貼上**（包含 `-----BEGIN PRIVATE KEY-----` 那兩行） |

3. 切到「Variables」分頁，按「New repository variable」：
   名稱 `APP_BUNDLE_ID`，內容填第 3 步的 Bundle ID。

> Secrets 存進去之後連你自己也看不到內容，只有雲端編譯時會用到，很安全。

### 第 7 步：按一個按鈕，送到 TestFlight

1. 儲存庫上方點「Actions」→ 左側「iOS」→ 右邊「Run workflow」→ 勾著「Build and upload to TestFlight」→ 綠色「Run workflow」。
2. 等大約 20～40 分鐘。兩個步驟都出現綠色 ✓ 就是成功了。
   - 第一個「Build & unit tests」是檢查程式有沒有錯；
   - 第二個「Archive & upload to TestFlight」是打包並上傳。
3. 上傳後 Apple 還要「處理」5～30 分鐘，完成後你會收到 email。

> 以後每次工程師更新程式，只要再按一次「Run workflow」就會出新版本（版本號會自動加一）。
> 推送 `v` 開頭的標籤（例如 `v0.2.0`）也會自動上傳。

### 第 8 步：在 iPhone 上安裝

1. App Store Connect → 你的 App →「TestFlight」分頁。
2. 第一次：左側「內部測試」按「＋」建立群組（例如「家人」），把自己（以及另一半，需先在「使用者與存取權限」加為使用者）加進去，再把剛上傳的版本加進群組。
3. iPhone 打開 **TestFlight** App（用同一個 Apple ID 登入）→ 看到「冰箱美術館」→ 按「安裝」。

TestFlight 的每個版本可以用 90 天，到期前再按一次 Run workflow 上傳新版本即可。

### 如果出現紅色 ✗

點進失敗的那一次 →「Summary」最下面有 `test-logs` 或 `testflight-logs` 可以下載，把它傳給工程師。常見原因：

- **Missing secret …**：第 6 步有某個名稱打錯或漏掉了。
- **No profiles / signing 錯誤**：API 金鑰權限不是 Admin，或 Bundle ID 跟第 3 步不一樣。
- **編譯錯誤（error: …）**：交給工程師修。

---

## 給工程師：專案說明

### 需求

- 雲端：GitHub Actions `macos-15` runner，Xcode 16.x（`ci/select_xcode.sh` 自動挑最新的 16.x），XcodeGen。
- 本機（如果有 Mac）：Xcode 16+，`brew install xcodegen && xcodegen generate`，打開 `FridgeMuseum.xcodeproj`。
  在 Xcode 的 Signing 選自己的 Team 就能免費裝到自己的 iPhone（免費帳號 7 天後要重裝）。
- iOS 18+，Swift 6（strict concurrency: complete），iPhone only，直式。

### 架構

MV + `@Observable`。三個模組以資料夾區分（之後可以拆成 Swift Package）：

```
project.yml                     XcodeGen 設定（Info.plist 權限說明、Metal CI kernel 旗標、Bundle ID 變數）
.github/workflows/ios.yml       CI：模擬器編譯＋單元測試；手動 / v* 標籤 → TestFlight
ci/                             CI 小工具（選 Xcode、挑模擬器、整理 log、ExportOptions.plist）
FridgeMuseum/
  App/          FridgeMuseumApp、AppModel（拍照→處理→存檔流程、Toast）、RootView（導覽）
  CaptureKit/   CameraController（AVCaptureSession、即時 Vision 紙張偵測、拍照）
                CameraModel（@MainActor 狀態、RotationCoordinator）、CameraPreview（預覽＋四角框）
                VoiceNoteRecorder（AVAudioRecorder ＋ Speech 離線轉文字）
  ProcessingKit/
    ImageProcessor.swift        actor，唯一共用的 CIContext（非線性 sRGB 工作色彩空間，數值與網頁原型一致）
                                平面：CIPerspectiveCorrection → 低解析度估算紙張光線（CPU）→ Metal kernel 相除
                                      → Metal kernel 色彩保護變白 → 去小黑點 → 白色筆刷
                                勞作：VNGenerateForegroundInstanceMaskRequest → 筆刷 → 留邊裁切
                                      → 背景（純色/漸層）＋兩層合成陰影
    Kernels.metal               fmFlattenDivide、fmWhiten（Core Image color kernels）
    VisionPaths.swift           Vision 包裝（經典 VN* API；新 Swift Vision API 放在 FM_SWIFT_VISION 旗標後）
    PaperDetector / IlluminationEstimator / SpeckRemover / CraftMaskEstimator / AlphaBrush / ImageOps
                                網頁原型演算法的純 Swift 移植（可單元測試；也是 Vision 失敗時的備援）
    Geometry.swift              NormPoint / Quad / 角點排序 / Homography
    ProcessingRecipe.swift      非破壞式編輯配方（Codable，缺欄位用預設值）
  ArchiveKit/   SwiftData 模型 Child / Artwork（CloudKit 相容：全部有預設值、無 unique、關聯皆 optional，
                圖片用 .externalStorage）、AgeCalculator、SchoolTerm（上/下學期、學年、年級）、
                PhotoLibrarySaver（每位小朋友一本相簿）、ThumbnailCache、CaptionComposer
  UI/           CaptureView（首頁＝相機）、SessionSheet（這次）、EditView＋EditPanels（裁切/調整/筆刷/資料）、
                GalleryView（篩選 chips、分組、排序）、ChildEditorView、ShareableArtwork（分享時才算圖）
  Resources/    Assets（App 圖示為暫代設計）、PrivacyInfo.xcprivacy
FridgeMuseumTests/              Swift Testing：年齡、學期/年級、配方 Codable、幾何/Homography、
                                紙張偵測、去小黑點、光線估算、勞作遮罩、筆刷
```

### 資料與隱私

- 原始照片、處理後 JPEG、縮圖、錄音都存在 SwiftData（`.externalStorage`，實際是 App 沙盒裡的檔案）。
- CloudKit 目前關閉（`cloudKitDatabase: .none`）；模型已照 CloudKit 規則設計，之後要同步只需加 entitlement。
- 不連網、不追蹤；PrivacyInfo 只宣告 UserDefaults（CA92.1）。
- **照片權限**：PhotoKit 規定「建立／尋找相簿」需要完整照片權限。所以存檔時若開啟「依小朋友分相簿」（預設開），
  會請求完整權限；家長若不同意，自動改用「只新增」權限存到「最近項目」。可在美術館右上選單關閉。

### 已完成

- 相機首頁：平面／立體切換、連拍成一批、即時紙張四角框、從相簿匯入（讀 EXIF 拍攝日期）。
- 自動處理：平面（偵測四角＋拉正＋去光線不均＋變白＋去黑點）、勞作（去背＋背景＋陰影）。
- 編輯：四角拖曳、重新偵測、整張照片；滑桿（紙張變白／保護淡色／色彩鮮豔／去背範圍）、背景與陰影；
  筆刷（畫作塗白、勞作擦掉／補回）、復原、清除；前後對比；所有編輯皆非破壞式、可重來。
- 分類：小朋友檔案（生日、顏色）、畫作／勞作、年齡、學期（含年級，如「大班」「小一」）、年份、
  自由標籤＋常用建議、最愛；美術館篩選 chips、分組、排序；每位小朋友一本「照片」相簿。
- 存到照片（可加名字／年齡／日期說明列）、分享、批次全部存。
- 語音備註：錄音、播放、裝置端轉文字（手機不支援離線辨識時保留錄音、不上傳）。
- CI：模擬器編譯＋單元測試（不需任何 secret）；TestFlight 上傳工作流程。

### 尚未完成 / 待確認（TODO）

- **還沒在真正的 Xcode 上編譯過**（開發環境是 Linux）。第一次 CI 很可能會有少量編譯錯誤要修，屬正常。
- 新 Swift Vision API（`DetectDocumentSegmentationRequest` 等）目前預設關閉，改用經典 `VN*` API；
  確認 CI 綠燈後，可在 `project.yml` 打開 `FM_SWIFT_VISION` 試用。
- 演算法數值是照網頁原型移植，需用真實照片在手機上微調（另一位工程師正在強化 JS 版演算法，之後同步移植）。
- 拍照時的自動連拍（偵測穩定後自動按快門）、拍照放大鏡、iCloud 同步、匯出 PDF 作品集、多語系。
- App 圖示是暫代設計；App Store 上架前要補隱私權政策網址與截圖。

### 本機開發小提醒

- 改 `project.yml` 後要重新 `xcodegen generate`；`.xcodeproj` 與 `Info.plist` 不進版控。
- 模擬器沒有相機，也可能不支援 Vision 去背：首頁會提示改用「相簿」，勞作去背會自動改用原型演算法。
