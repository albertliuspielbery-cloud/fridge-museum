# 冰箱美術館（iPhone App）

把孩子的畫作和勞作拍下來，App 會自動：

- **平面畫作**：找出紙張四角、拉正、修平光線、把紙變白，但保留淡淡的蠟筆和水彩顏色，還會清掉紙上的小黑點。
- **立體勞作**：把作品從桌面「挖」出來，放到乾淨的背景上，加一點自然的陰影。

作品會依 **小朋友、畫作／勞作、年齡、學期（上／下學期）、年份、標籤、最愛 ⭐** 分類整理，並可以存到手機「照片」裡每位小朋友自己的相簿（「冰箱美術館 – 小明」）。

所有處理都在手機上完成，**不連網、不上傳**。原始照片永遠保留，之後隨時可以重新調整。

---

## 上架到 TestFlight（不需要 Mac）

做法跟「星光小冒險」一樣：GitHub 的雲端 Mac 幫你編譯、簽名、上傳。開發者帳號和 API 金鑰都可以沿用。

**第 1 步：放密鑰（只做一次）**
到 <https://github.com/albertliuspielbery-cloud/fridge-museum/settings/secrets/actions>，新增 4 個 Repository secret
（跟星光小冒險用的值一樣即可）：

| 名稱 | 內容 |
| --- | --- |
| `ASC_KEY_ID` | API 金鑰 ID |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_KEY_P8` | 用記事本打開 `AuthKey_XXXX.p8`，整份內容貼上 |
| `APPLE_TEAM_ID` | Team ID（<https://developer.apple.com/account> 的會員資格頁） |

App 識別碼預設是 `tw.starlight.fridgemuseum`。要換的話，在同一頁的「Variables」新增 `APP_BUNDLE_ID`。

**第 2 步：準備 App 識別碼（只做一次）**
1. 打開 <https://github.com/albertliuspielbery-cloud/fridge-museum/actions/workflows/bundle-id.yml> → 「Run workflow」。
   它會自動登記 App 識別碼（已經有就跳過）。
2. 到 <https://appstoreconnect.apple.com/apps> → 「＋」→「新增 App」：平台 iOS、名稱「冰箱美術館」、
   主要語言繁體中文、套件識別碼選 `tw.starlight.fridgemuseum`、SKU 隨意（例如 `fridgemuseum`）。
   這一步 Apple 不開放自動化，要手動按。
3. 在「App 資訊」把類別設成「攝影與錄影」或「生活風格」，**不要選「兒童」**。

**第 3 步：上傳**
1. 打開 <https://github.com/albertliuspielbery-cloud/fridge-museum/actions/workflows/ios.yml> → 「Run workflow」
   → 勾選「上傳」→ 綠色按鈕。
2. 約 20～40 分鐘後兩個步驟都打勾就完成了。版本號會自動用上傳時間（例如 `202610271530`）。
3. Apple 處理 5～30 分鐘後，到 <https://appstoreconnect.apple.com/apps> →「冰箱美術館」→「TestFlight」，
   把版本加進內部測試群組，再用 iPhone 的 TestFlight App 安裝。

**注意：不要同時按「冰箱美術館」和「星光小冒險」的上傳。** 兩個 App 共用同一組 Apple Distribution 憑證，
簽名腳本會在憑證太多時清掉舊的；兩邊同時跑可能互相刪掉對方正在用的憑證而失敗。請等一邊完成（兩個步驟都打勾）再按另一邊。

平常工程師推程式到 `main` 時，只會自動做「模擬器編譯＋單元測試」，不會上傳。上傳一定是你自己按。

**出現紅色 ✗ 時**：點進那次執行，頁面上方會直接列出錯誤訊息（例如「缺少 GitHub Secrets」「權限不夠」）。
不懂的話把那頁網址傳給工程師就好。

## 給工程師：專案說明

### 需求

- 雲端：GitHub Actions `macos-15` runner，**Xcode 26**（App Store 規定 iOS 26 SDK；`ci/select_xcode.sh` 挑最新的 Xcode_26*.app，沒有就報錯，並補裝 Metal Toolchain），XcodeGen。
- 簽名：`ci/ci_sign.py` 用 API 金鑰建立／重用 Apple Distribution 憑證和 `IOS_APP_STORE` 描述檔「FridgeMuseum AppStore CI」，
  App 識別碼不存在會用 `POST /bundleIds` 自動登記；手動簽名設定以 xcodebuild 參數帶入（不改專案檔）。
- 本機（如果有 Mac）：Xcode 26，`brew install xcodegen && xcodegen generate`，打開 `FridgeMuseum.xcodeproj`。
  在 Xcode 的 Signing 選自己的 Team 就能免費裝到自己的 iPhone（免費帳號 7 天後要重裝）。
- 最低支援 iOS 18，Swift 6（strict concurrency: complete；明確固定 `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`，不用 Xcode 26 新專案的 MainActor 預設），iPhone only，直式。
- 版權字串只定義在 `project.yml` 的 `APP_COPYRIGHT`（目前「© 星光工作室 Starlight Studio」，待確認）。

### 架構

MV + `@Observable`。三個模組以資料夾區分（之後可以拆成 Swift Package）：

```
project.yml                     XcodeGen 設定（Info.plist 權限說明、Metal CI kernel 旗標、Bundle ID 變數）
.github/workflows/ios.yml       推到 main：模擬器編譯＋單元測試；手動勾「上傳」：簽名＋上傳 TestFlight
.github/workflows/bundle-id.yml 「準備 App 識別碼」：只登記 Bundle ID
ci/                             CI 小工具（選 Xcode 26、挑模擬器、整理紀錄並列成註記、ci_sign.py 簽名）
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
- CI：模擬器編譯＋單元測試（不需任何 secret）；手動上傳 TestFlight（沿用星光小冒險的簽名流程）；登記 App 識別碼。

### 尚未完成 / 待確認（TODO）

- **還沒在真正的 Xcode 上編譯過**（開發環境是 Linux）。第一次 CI 很可能會有少量編譯錯誤要修，屬正常。
- iOS 26 SDK 可能把經典 `VN*` Vision API 標為 deprecated（只是警告）。
- 新 Swift Vision API（`DetectDocumentSegmentationRequest` 等）目前預設關閉，改用經典 `VN*` API；
  確認 CI 綠燈後，可在 `project.yml` 打開 `FM_SWIFT_VISION` 試用。
- 演算法數值是照網頁原型移植，需用真實照片在手機上微調（另一位工程師正在強化 JS 版演算法，之後同步移植）。
- 拍照時的自動連拍（偵測穩定後自動按快門）、拍照放大鏡、iCloud 同步、匯出 PDF 作品集、多語系。
- App 圖示是暫代設計；App Store 上架前要補隱私權政策網址與截圖。

### 本機開發小提醒

- 改 `project.yml` 後要重新 `xcodegen generate`；`.xcodeproj` 與 `Info.plist` 不進版控。
- 模擬器沒有相機，也可能不支援 Vision 去背：首頁會提示改用「相簿」，勞作去背會自動改用原型演算法。
