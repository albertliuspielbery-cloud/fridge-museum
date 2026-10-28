# 冰箱美術館 / My Fridge Museum — 中英字串對照表 (v0.8.0)

Generated from `STR.zh` / `STR.en` in `kidart.html` (178 keys). For independent translator review and the owner.
`{n}`, `{price}`, `{v}`, `{name}`, `{age}`, `{y}`, `{m}` are placeholders — keep them. `one: … / other: …` = English plural forms.

## Glossary / 術語

| 中文 | English | 說明 |
|---|---|---|
| 冰箱美術館 | My Fridge Museum | brand |
| 作品 | artwork (1 artwork / 3 artworks) | general term |
| 平面畫作 / 畫作 | Drawing | covers paintings |
| 立體勞作 / 勞作 | Craft | |
| 收進這次 | Hang It Up (button) · “hung on the fridge” | not “Keep” / “Add to this batch” |
| 這次收的作品 | On the Fridge | this visit’s works |
| 存到手機 | Save to Photos | |
| 相簿 | Photos | |
| 說明牌 | Label / Museum Label | title · artist · medium |
| AI 去背 | AI cutout | |
| 完整版 / 解鎖 | Full Version / Unlock | |
| 恢復購買 | Restore Purchases | Apple’s standard button label (plural) |
| 測試模式：不會真的收費 | Test mode — you won’t be charged | |
| 每天免費 / 免費試用 | free drawings (daily) / free trial crafts | quota counts both Hang It Up and Save to Photos, so paywall copy says “save or hang it up” |
| 長按 | touch and hold | Apple Style Guide term (not “press and hold” / “long-press”) |
| 裁切四角 (sheet) | Crop & Rotate | matches the iOS Photos editor; the tool button stays “Crop” |
| 測試版 | Beta | |

Punctuation: serial (Oxford) comma, per Apple Style Guide.
Capitalization: Title Case for buttons, tabs, segmented controls, control labels, sheet titles (Apple HIG); sentence case for descriptions, hints, toasts, notes. Curly quotes/apostrophes. Dates in English: “Oct 28, 2026” (changelog, image caption); zh keeps 2026-10-28 / 2026/10/28.

## All strings

| key | 中文 | English | note |
|---|---|---|---|
| `appName` | 冰箱美術館 | My Fridge Museum | Brand. Kept literal (not “Fridge Art Museum”). <title> stays 冰箱美術館 per page contract. |
| `brandLetters` | 冰 箱 美 術 館 | M Y ␣ F R I D G E ⏎ M U S E U M | One magnet per letter; “\n” = line break, “ ” = word gap. Two lines fit 375px. |
| `privacy` | 照片只在這支手機上處理，不會上傳 | Photos are processed on this phone and never uploaded |  |
| `betaLabel` | 測試版 | Beta |  |
| `langChip` | English | 中文 | Shows the OTHER language in its own script; endonyms are never translated. |
| `langChipAria` | 切換成英文 (Switch to English) | 切換成中文 (Switch to Chinese) |  |
| `pendingAria` | 還沒收進的作品 | Artwork not hung up yet |  |
| `pendingTitle` | 上一張還沒收進 | Your last artwork isn’t hung up yet | 收進這次 → “hang it up” throughout. |
| `pendingSub` | 存到手機或收進這次，才不會不見 | Save it to Photos or hang it up so you don’t lose it. |  |
| `resume` | 繼續 | Resume |  |
| `heroAria` | 打開範例畫作，看看整理前後 | Open the sample drawing to see before and after |  |
| `heroRawAlt` | 拍下來的照片：畫紙放在桌上，看得到桌面、光線不均 | Original photo: a drawing on a table, with the tabletop showing and uneven light |  |
| `heroDoneAlt` | 處理後：紙張拉正、變白，彩色筆顏色保留 | After: the paper is straightened and white, and the marker colors are kept |  |
| `heroRawCap` | 拍下來的 | As snapped | Polaroid-style captions under the two hero prints. |
| `heroDoneCap` | 掛上冰箱 | Fridge-ready |  |
| `processing` | 處理中… | Processing… |  |
| `heroPlTitle` | 氣球派對 | Balloon Party |  |
| `heroPlArtist` | 範例小畫家 · 5歲 | Little Artist · 5 yrs | Placard format: Artist · age. |
| `heroPlMedium` | 彩色筆、紙 · 2026 | Markers · 2026 | Shortened to fit the 46%-wide hero placard at 375px. |
| `heroPlGo` | 點一下，看整理前後 | Tap to compare |  |
| `heroH1` | 拍下孩子的作品， | Snap your kid’s art. | Rewritten as a two-beat headline rather than translated literally. |
| `heroH2` | 拉正、變白，掛上冰箱 | Straightened, brightened, fridge-ready. |  |
| `heroP` | 淡淡的蠟筆和水彩也留得住。全部在手機上完成，拍完就能存進相簿。 | Even faint crayon and watercolor come through. It all happens on your phone, and you can save to Photos right away. |  |
| `seeAgain` | 再看一次範例 | See the sample again |  |
| `flatName` | 平面畫作 | Drawing | 平面畫作 = Drawing (also covers paintings). Same word for long/short zh forms. |
| `flatDesc` | 找出紙張四角，拉正、修平光線 | Finds the paper’s corners, straightens it, and evens out the light |  |
| `flatSample` | 看範例畫作 | See Sample |  |
| `craftName` | 立體勞作 | Craft | 立體勞作 = Craft. |
| `craftDesc` | AI 去掉桌面，換上乾淨背景和陰影 | AI removes the table and adds a clean background and shadow |  |
| `craftSample` | 看範例勞作 | See Sample |  |
| `sessTitle` | 這次收的作品 | On the Fridge | 這次收的作品 = what you hung this visit (not saved across sessions). |
| `sessCount` | {n} 張 | one: 1 artwork / other: {n} artworks | Plural {one, other}. |
| `emptyTitle` | 冰箱還空空的，拍第一張作品掛上來吧 | The fridge is empty. Snap your first artwork and hang it up! |  |
| `emptySub` | 按下方快門拍一張。整理好按「收進這次」，作品就會掛在這裡。 | Tap the shutter below to take a photo. When it looks good, tap “Hang It Up” and it will appear here. |  |
| `sessNote` | 點作品就能存到手機。測試版不會自動保存，關掉頁面前記得存。 | Tap an artwork to save it to Photos. This beta doesn’t keep artworks after you close the page, so save the ones you want first. |  |
| `tipsTitle` | 拍照小技巧與測試版說明 | Photo Tips & Beta Notes |  |
| `tip1` | 建議在 Claude iPhone App 裡打開。按「存到手機」後選「儲存影像」，就會存進「照片」。 | Works best in the Claude iPhone app. Tap “Save to Photos,” then choose “Save Image” to add it to Photos. |  |
| `tip2` | 拍畫作時盡量讓整張紙入鏡，四周留一點桌面。拍勞作時放在素色桌面上，四周留空。 | For drawings, fit the whole sheet in the frame with a little table showing around it. For crafts, set them on a plain surface with space all around. |  |
| `tip3` | 正式 iOS 版會改用 Apple 內建的文件偵測和主體去背，解析度和去背邊緣都會更好。 | The App Store version will use Apple’s built-in document detection and subject cutout for higher resolution and cleaner edges. |  |
| `dockAria` | 拍照 | Camera |  |
| `kindAria` | 作品類型 | Artwork type |  |
| `library` | 相簿 | Photos | iOS name for the photo library. |
| `shutterAria` | 拍一張作品 | Take a photo of an artwork |  |
| `lastAria` | 看這次收的作品 | See what’s on the fridge |  |
| `lastAriaN` | 看這次收的 {n} 張作品 | one: See the 1 artwork on the fridge / other: See the {n} artworks on the fridge | Plural. |
| `lastLabel` | 這次 | Fridge | Dock thumbnail label; scrolls to the fridge gallery. |
| `quotaFlat` | 今天還可以免費收 {n} 張畫作 | one: 1 free drawing left today / other: {n} free drawings left today | Plural; chip must stay one line (~300px max). |
| `quotaFlatOut` | 今天的免費畫作收滿了，明天再來 | No free drawings left today | Kept short so the quota chip stays one line. |
| `quotaCraft` | 勞作免費試用剩 {n} 次 | one: 1 free trial craft left / other: {n} free trial crafts left |  |
| `quotaCraftOut` | 勞作免費試用已用完 | Free craft trial used up |  |
| `editAria` | 整理作品 | Edit artwork |  |
| `backHome` | 美術館 | Museum |  |
| `flatShort` | 畫作 | Drawing |  |
| `craftShort` | 勞作 | Craft |  |
| `retake` | 重拍 | Retake |  |
| `viewAria` | 作品預覽 | Artwork preview |  |
| `sampleTag` | 範例 | Sample |  |
| `compare` | 對比 | Compare |  |
| `done` | 完成 | Done |  |
| `sheetCrop` | 裁切四角 | Crop & Rotate |  |
| `sheetAdjust` | 調整 | Adjust |  |
| `sheetBrush` | 筆刷 | Brush |  |
| `sheetInfo` | 作品說明牌 | Museum Label |  |
| `cropSub` | 拖曳畫面上的四個白點，對準紙張四角。放開手就會重新處理。 | Drag the four white dots to the paper’s corners. It updates when you let go. |  |
| `redetect` | 重新自動找四角 | Auto-Detect Corners |  |
| `rotL` | 向左轉 | Rotate Left |  |
| `rotR` | 向右轉 | Rotate Right |  |
| `tilt` | 拉直 | Straighten |  |
| `strength` | 紙張變白 | Whiten Paper |  |
| `protect` | 保護淡色 | Protect Pale Colors |  |
| `protectSub` | 淡黃蠟筆、水彩、鉛筆不會被洗掉 | Keeps pale yellow crayon, watercolor, and pencil from washing out |  |
| `vivid` | 色彩鮮豔 | Color Boost |  |
| `speck` | 自動清掉紙上的小黑點 | Auto-Remove Specks |  |
| `speckNote` | 這張清掉了 {n} 個 | one: Removed 1 speck from this one / other: Removed {n} specks from this one | Plural. |
| `sens` | 去背範圍 | Cutout Strength | 去背範圍 = how much is treated as background. |
| `bg` | 背景 | Background |  |
| `bgWhite` | 純白 | White |  |
| `bgWarm` | 暖白 | Warm White |  |
| `bgGray` | 淺灰 | Light Gray |  |
| `bgGrad` | 柔光漸層 | Soft Glow |  |
| `shadow` | 加上自然陰影 | Add Natural Shadow |  |
| `brushKindAria` | 筆刷種類 | Brush type |  |
| `brushErase` | 擦掉背景 | Erase Background |  |
| `brushRestore` | 補回作品 | Restore Artwork |  |
| `brushSize` | 筆刷大小 | Brush Size |  |
| `undo` | 復原一筆 | Undo Stroke |  |
| `clearStrokes` | 清除所有筆刷 | Clear All Strokes |  |
| `infoSub` | 這是掛在冰箱上的作品說明牌。名字和生日會記在這支手機上，下次不用再填。 | This is the museum label that hangs with the artwork. The name and birthday are saved only on this phone, so you won’t have to enter them again. |  |
| `kidName` | 小朋友 | Artist | Labelled “Artist” to fit the museum-label metaphor. |
| `kidNamePh` | 例：小明 | e.g., Mia |  |
| `kidBirth` | 生日 | Birthday |  |
| `artTitle` | 作品名稱 | Title |  |
| `artTitlePh` | 例：我的家 | e.g., My House |  |
| `artMedium` | 用什麼做的 | Made With |  |
| `artMediumPh` | 例：蠟筆、紙 | e.g., Crayons |  |
| `artDate` | 作品日期 | Date Made |  |
| `captionSwitch` | 在圖片下方加上名字、年齡、日期 | Add Name, Age & Date Below Image |  |
| `toolsAria` | 整理工具 | Editing tools |  |
| `tCrop` | 裁切 | Crop |  |
| `tAdjust` | 調整 | Adjust |  |
| `tBrush` | 筆刷 | Brush |  |
| `tInfo` | 說明牌 | Label |  |
| `addBtn` | 收進這次 | Hang It Up |  |
| `saveBtn` | 存到手機 | Save to Photos |  |
| `untitled` | 無題 | Untitled |  |
| `artistDefault` | 小畫家 | Little Artist |  |
| `mediumFlat` | 紙上作品 | Work on paper | Museum-placard convention. |
| `mediumCraft` | 立體勞作 | Mixed media | Museum-placard convention for 3D work. |
| `sep` |  ·  |  ·  | Placard separator (both languages). |
| `ageAt` | {name}畫這張時 {age} | Age when made: {age} | Name dropped in English (avoids “Artist’s age”). |
| `ageY` | {n}歲 | one: 1 yr / other: {n} yrs | Compact form for placards/captions: 4 yrs · 4 yrs 3 mos · 1 yr 1 mo · 9 mos. |
| `ageYM` | {y}{m} | {y} {m} | Joins formatted ageY + ageM (zh: no space, en: space). |
| `ageM` | {n}個月 | one: 1 mo / other: {n} mos | Plural. |
| `captionDefault` | 我的作品 | My Artwork | Drawn on the image when no title/name. |
| `fileDefault` | 冰箱美術館 | My Fridge Museum | Default download file name (.jpg added). |
| `thumbAria` | 存到手機：{name} | Save to Photos: {name} |  |
| `hintCrop` | 拖曳四個白點對準紙張四角，放開後會自動重新處理。 | Drag the four white dots to the paper’s corners. It updates when you let go. | English hints are full sentences; hintJoin() adds a space after the period (zh: no space after 。，, “ · ” otherwise). |
| `hintTurned` | 已轉向。再按一次「裁切」可回到四角。 | Rotated. Tap “Crop” again to get the corners back. |  |
| `hintCompare` | 左右拖曳白線，比較前後 | Drag the white line to compare before and after. |  |
| `hintBrushFlat` | 在髒點上塗抹，會塗成白色。只建議用在空白紙面。 | Paint over smudges to turn them white. Use only on blank areas of the paper. |  |
| `hintBrushCraft` | 塗抹要去掉的背景部分。 | Paint over any background you want removed. |  |
| `hintRestore` | 塗抹被誤刪的作品部分，把它補回來。 | Paint over parts of the artwork that were removed by mistake to bring them back. |  |
| `hintView` | 看起來可以了，就存到手機或收進這次。 | Looks good? Save it to Photos or hang it up. |  |
| `hintSpecks` | 已自動清掉 {n} 個小黑點 | one: Removed 1 speck automatically. / other: Removed {n} specks automatically. | Plural. |
| `noteNoPaper` | 沒找到紙邊，先用整張照片，可用「裁切四角」調整 | Couldn’t find the paper’s edges, so the whole photo is used. Fix it in “Crop.” | References the “Crop” tool button the user taps. |
| `noteKeep` | 不是白紙，保留紙本來的顏色 | This isn’t white paper, so its original color is kept. |  |
| `noteSparse` | 顏料幾乎蓋滿紙，只輕調光線 | Paint covers most of the paper, so only the lighting was adjusted. |  |
| `noteDots` | 小點很多像是圖案，沒有清掉 | Lots of little dots look like part of the design, so they were left alone. |  |
| `noteCraftFail` | 沒能分開作品和桌面，先保留原照片 | Couldn’t separate the craft from the table, so the original photo is kept. |  |
| `noteCraftEdge` | 作品碰到照片邊緣，可能被切到 | The craft touches the edge of the photo and may be cut off. |  |
| `toastHung` | 已掛上冰箱！ | Hung on the fridge! |  |
| `toastHungN` | 已掛上冰箱！這是第 {n} 張，按快門拍下一張。 | Hung on the fridge! That’s {n} so far. Tap the shutter for the next one. | Ordinal-free (“That’s 3 so far”, not “your 3rd”). n ≥ 2. |
| `toastSaved` | 已交給手機儲存。在 iPhone 上選「儲存影像」就會進到照片。 | Ready to save. On iPhone, choose “Save Image” to add it to Photos. | “Save Image” = iOS share-sheet label. |
| `nextShot` | 拍下一張 | Take Another |  |
| `toastCancel` | 已取消儲存。 | Save canceled. |  |
| `toastBusySave` | 上一個儲存視窗還開著，請先完成它。 | A save window is still open. Finish that one first. |  |
| `toastBadFile` | 這張照片打不開。請換一張 JPG 或 PNG 照片再試一次。 | Couldn’t open this photo. Try a JPG or PNG instead. |  |
| `toastUnlocked` | 已解鎖完整版（測試模式，沒有收費） | Full Version unlocked (test mode, no charge) |  |
| `toastRestored` | 已恢復完整版（測試模式） | Full Version restored (test mode) |  |
| `toastNoPurchase` | 這支手機上找不到購買紀錄（測試模式） | No purchase found on this phone (test mode) |  |
| `toastReset` | 已重設測試額度，也取消了完整版 | Test limits reset. The Full Version is locked again. |  |
| `productName` | 完整版 | Full Version | 完整版 = Full Version (Title Case as product name). |
| `payTitleFlat` | 今天的 {n} 張免費畫作收滿了 | one: That’s today’s free drawing / other: That’s all {n} free drawings for today | Plural (n = FREE_FLAT_PER_DAY). |
| `payTitleCraft` | 勞作免費試用用完了 | You’ve used your free craft trial |  |
| `paySubFlat` | 這張作品還在。解鎖完整版就能馬上存下或收進來；也可以明天再收，每天都有 {n} 張免費。 | one: This artwork is still here. Unlock the Full Version to save or hang it up now, or come back tomorrow for 1 more free drawing. / other: This artwork is still here. Unlock the Full Version to save or hang it up now, or come back tomorrow for {n} more free drawings. | Plural. |
| `paySubCraft` | 免費試用的 {n} 件勞作已經用完。解鎖完整版就能繼續收勞作，平面畫作每天仍有免費額度。 | one: Your free trial covered 1 craft. Unlock the Full Version for unlimited crafts. You still get free drawings every day. / other: Your free trial covered {n} crafts. Unlock the Full Version for unlimited crafts. You still get free drawings every day. | Plural (once / n times). |
| `perk1` | 畫作、勞作不限張數，想收多少就收多少 | Unlimited drawings and crafts — keep as many as you like |  |
| `perk2` | 勞作 AI 去背無限次使用 | Unlimited AI cutouts for crafts |  |
| `perk3` | 之後的更新都免費 | All future updates included | 改成較保守的承諾（見 Review notes 2） |
| `ticketKicker` | 入場券 | ADMIT ONE | 入場券 → “ADMIT ONE”, the classic ticket stub wording. |
| `oneTime` | 一次買斷，不是訂閱，不會每月扣款 | One-time purchase — not a subscription. No recurring charges. |  |
| `family` | 全家共享：正式 App 會支援 Apple「家人共享」，家人的手機也能一起用。 | The App Store version will support Family Sharing, so family members can use it on their own devices. | Apple’s official feature name: Family Sharing. |
| `unlock` | 解鎖完整版 {price} | Unlock Full Version · {price} | {price} = PRICE_LABEL (NT$190) untouched; the App Store localizes later. |
| `laterFlat` | 明天再收 | Maybe Tomorrow |  |
| `laterCraft` | 先不要 | Not Now |  |
| `restore` | 恢復購買 | Restore Purchases |  |
| `testMode` | 測試模式：不會真的收費 | Test mode — you won’t be charged | Required test-mode disclosure. |
| `close` | 關閉 | Close |  |
| `verTitle` | 版本資訊 | Version Info |  |
| `verNow` | 目前是 | Current version |  |
| `verLabel` | 測試版 {v} | Beta {v} |  |
| `resetQuota` | 重設測試額度 | Reset Test Limits |  |
| `language` | 語言 | Language |  |
| `changelog.0.8.0` | 冰箱美術館新介面；版本資訊；免費額度與完整版（測試模式）；中英文介面 | New My Fridge Museum look; version info; free limits and Full Version (test mode); English interface | Adds 中英文介面 / English interface. |
| `changelog.0.7.0` | 勞作 AI 去背（樂高、花桌布、大理石桌面都更準） | AI cutout for crafts (more accurate on LEGO, patterned tablecloths, and marble tables) |  |
| `changelog.0.6.0` | 修正斜拍時畫作被拉長；A4、八開、四開比例 | Fix for drawings looking stretched when shot at an angle; correct proportions for A4 and other common paper sizes | 八開/四開 (Taiwanese sizes) generalized to “other common paper sizes”. Code also recognizes US Letter (1.294); see Review notes Q5. |
| `changelog.0.5.0` | 大理石桌面找紙、紙角補白、轉向與拉直、真實範例照片 | Paper detection on marble tables; white fill for missing paper corners; rotate and straighten tools; real sample photos |  |
| `changelog.0.4.0` | 改名冰箱美術館；難拍情況加強（白桌、歪拍、彩色紙、點點圖案…） | Renamed to My Fridge Museum; better results with tricky photos (white tables, angled shots, colored paper, polka dots…) |  |
| `changelog.0.3.0` | 新配色與圓體字 | New colors and a rounded font |  |
| `changelog.0.2.0` | 拍照 App 式介面 | Camera-style interface |  |
| `changelog.0.1.0` | 第一版：拍照、拉正、去黃變白、去小黑點、勞作去背 | First version: capture, straighten, whiten paper, remove specks, cut out crafts |  |
| `busyAI` | AI 去背中… | Cutting out with AI… |  |
| `busyAIFirst` | AI 去背中…（第一次需要下載 AI 檔案，請稍等） | Cutting out with AI… (first time only: downloading the AI files) | 原本寫 8MB，實際大小視壓縮而定，改成不寫數字 |
| `cmpBefore` | 原圖 | Before | Drawn on the canvas (compare chips). |
| `cmpAfter` | 處理後 | After |  |
| `overlayAria` | 儲存圖片 | Save image |  |
| `overlayAlt` | 處理好的作品 | Your finished artwork |  |
| `overlayP` | 這個畫面不能直接下載。請長按圖片，選「加入照片」。 | Saving directly isn’t available here. Touch and hold the image, then choose “Save to Photos.” | “Save to Photos” = iOS long-press menu label (zh: 加入照片). |

## Review notes (independent EN review, v0.8.0)

Overall: the English was already good: natural, short, consistent glossary, correct curly quotes and US spelling, and plurals wired correctly. The changes below fix (a) money and privacy wording that was inaccurate or could mislead, (b) Apple-standard terms, (c) serial commas and parallel changelog lines, and (d) a few awkward or wrapping phrases. 36 strings changed. Checked headless at 375 and 390 pt: no page errors, no new clipping (the audit’s 2–4 px flags on `#langChip` and the tilted fridge thumbs are pre-existing and also appear in zh). After screenshots: `scratchpad/en-review/en-375-*.png`, `en-390-*.png`.

### Changes (old → new, why)

**Money / paywall accuracy (App Store–sensitive)**
| key | old | new | why |
|---|---|---|---|
| `paySubFlat` | This artwork is safe, and it won’t disappear. Unlock … to hang it up now, or come back tomorrow: you get {n} free drawings every day. | This artwork is still here. Unlock the Full Version to save or hang it up now, or come back tomorrow for {n} more free drawings. | “Won’t disappear” is untrue: the beta loses it if the page closes. The paywall also opens from **Save to Photos**, not only Hang It Up. Shorter. |
| `paySubCraft` | You’ve tried the AI cutout {n} times. Unlock … to keep hanging up crafts. Drawings are still free every day, up to the daily limit. | Your free trial covered {n} crafts. Unlock the Full Version for unlimited crafts. You still get free drawings every day. | The quota counts crafts *kept* (saved or hung), not cutout attempts. Previewing the cutout is free. |
| `quotaCraft` | Free craft trial: {n} left | one: 1 free trial craft left / other: {n} free trial crafts left | “{n} left” didn’t say left of what. Now matches “{n} free drawings left today”. Pluralized. |
| `quotaFlatOut` | Free drawings used up for today | No free drawings left today | Mirrors the “left today” chip wording. |
| `oneTime` | One-time purchase. Not a subscription, so no monthly charges. | One-time purchase — not a subscription. No recurring charges. | “No monthly charges” leaves room for yearly ones. “Recurring” is the precise word. |
| `family` | Family Sharing: the App Store version will support Apple Family Sharing, so everyone in the family can use it on their own phone. | The App Store version will support Family Sharing, so family members can use it on their own devices. | It said “Family Sharing” twice. “Everyone” overclaims, since Family Sharing has a 6-person cap. Purchases also reach iPads, so “devices”. See open question 1. |
| `restore` | Restore Purchase | Restore Purchases | Standard iOS label. Reviewers look for it. |
| `perk1` | Unlimited drawings and crafts. Hang up as many as you like | Unlimited drawings and crafts — keep as many as you like | Fixes the fragment with a missing period. “Keep” covers both save and hang. |
| `toastReset` | Test limits reset, and the Full Version is turned off | Test limits reset. The Full Version is locked again. | Clearer state. |

**Privacy / data**
| key | old | new | why |
|---|---|---|---|
| `infoSub` | …remembered on this phone, so you won’t have to type them again. | …saved only on this phone, so you won’t have to enter them again. | Says outright that the kid’s name and birthday stay local. |
| `sessNote` | The beta doesn’t save automatically, so save before you close the page. | This beta doesn’t keep artworks after you close the page, so save the ones you want first. | Says exactly what is lost and when. |
| `busyAIFirst` | (first time downloads about 8 MB) | (first time only: about an 8 MB download) | Clearer. It is a download, not an upload. |

**Apple / iOS terminology**
| key | old | new | why |
|---|---|---|---|
| `overlayP` | This screen can’t download directly. Press and hold the image… | Saving directly isn’t available here. Touch and hold the image, then choose “Save to Photos.” | Apple Style Guide says “touch and hold”. See open question 4 for the menu label. |
| `sheetCrop` | Crop Corners | Crop & Rotate | The sheet holds rotate and straighten too. Same name as the iOS Photos editor. |
| `redetect` | Find Corners Again | Auto-Detect Corners | Keeps the “自動” meaning. Reads as a button action. |
| `tip3` | The iOS app will use…, for higher… | The App Store version will use… for higher… | Matches `family` (“App Store version”). Drops a stray comma. |
| `tip1` | …to put it in Photos. | …to add it to Photos. | Same verb as `toastSaved`. |
| `toastSaved` | Sent to your phone to save. On iPhone… | Ready to save. On iPhone… | “Sent to your phone” is odd when you are already on the phone. |

**Clarity / idiom**
| key | old | new | why |
|---|---|---|---|
| `heroPlGo` | Tap for before & after | Tap to compare | Old text wrapped with an orphaned “after” at 375 pt. Now one line. |
| `pendingTitle` / `pendingSub` | Your last photo isn’t hung up yet / …so it isn’t lost. | Your last artwork isn’t hung up yet / …so you don’t lose it. | Glossary term is “artwork”. Active voice. |
| `emptyTitle` | Snap the first artwork… | Snap your first artwork… | More natural. |
| `protect` | Protect Light Colors | Protect Pale Colors | “Light” reads as lighting. “Pale” matches the subtitle. |
| `sens` | Cutout Range | Cutout Strength | It is a 0–100 strength slider, not a range. |
| `cropSub`, `hintCrop` | onto the paper’s corners / Let go and it updates automatically. | to the paper’s corners. It updates when you let go. | The two strings now match. |
| `hintBrushFlat` | Best on blank paper only. | Use only on blank areas of the paper. | “Best … only” was contradictory. |
| `hintRestore` | …that got cut off… | …that were removed by mistake… | Matches 誤刪. “Cut off” already means something else in `noteCraftEdge`. |

**Punctuation (serial comma, Apple Style Guide)**: `flatDesc`, `protectSub`, `changelog.0.7.0`.

**Changelog** (parallel noun phrases, joined by semicolons)
- 0.8.0: “design” → “look”. “New … design” suggested a redesign of the brand.
- 0.6.0: Fixed drawings looking stretched…; A4 and other common paper proportions → Fix for drawings looking stretched when shot at an angle; correct proportions for A4 and other common paper sizes
- 0.5.0: Finds paper on marble tables, fills in paper corners, rotate and straighten, real sample photos → Paper detection on marble tables; white fill for missing paper corners; rotate and straighten tools; real sample photos
- 0.4.0: Renamed My Fridge Museum; handles tricky shots better (…tilted shots…) → Renamed to My Fridge Museum; better results with tricky photos (…angled shots…)
- 0.2.0: Camera-app style interface → Camera-style interface

### Reviewed and kept (deliberately)
- **Age format: keep “5 yrs 3 mos” / “5 yrs” / “9 mos”.** It fits the placard and caption band at 375 pt. “5 years, 3 months” is too long, and “5y 3m” is cryptic. “Age 5” only works for whole years and can’t join with months. `ageAt` (“Age when made: …”) is fine.
- **Magnet title “MY FRIDGE / MUSEUM”**: reads well and breaks cleanly into 2 lines. Keep. Alternative if space gets tight: “FRIDGE / MUSEUM”.
- “Hang It Up”, “On the Fridge”, “Fridge-ready”, “As snapped”, “ADMIT ONE”, “Maybe Tomorrow” / “Not Now”, “Work on paper” / “Mixed media”, “Little Artist”: warm without being cutesy. Keep.
- `privacy` is accurate (processing is on-device, and the 8 MB model is a download). It wraps with an orphaned “uploaded” at 375 pt. Cosmetic only, so the wording is unchanged.
- `testMode` “Test mode — you won’t be charged”, plus the test-mode toasts: clear. Keep.
- “Save Image” (share sheet): this is the correct iOS action name for a single image.

### Open questions for the owner
1. **Family Sharing (`family`)**: only keep this line if the non-consumable IAP will have Family Sharing turned on in App Store Connect. That choice can’t be reversed once it’s on. At submission it must switch to present tense (“Works with Family Sharing…”) or be removed. A future-tense promise on a live paywall invites App Review questions.
2. **`perk3` “Every future feature included”** (zh 之後推出的新功能都包含在內): this is an open-ended promise for a one-time purchase. If you might ever add a paid tier (cloud backup, print orders), change it in both languages to something like “Free updates with new features” / 「之後的更新免費」. I left it as is because this is a business decision.
3. **Price**: `NT$190` appears on US/UK/AU builds. That’s fine in test mode, but the App Store build must show the StoreKit localized price (already planned).
4. **Long-press menu label (`overlayP`)**: iOS 13–16 Safari said “Add to Photos”, and I believe iOS 17+ says “Save to Photos”. I’m not 100 % sure about iOS 18/26 or inside the Claude app’s web view, so please verify on a device. The zh string 「加入照片」 matches the older “Add to Photos” wording and may be outdated (newer zh-TW may read 「儲存到照片」). Check both on iOS 26. Also, the app’s own button is also called “Save to Photos”, so the overlay text could make people think they should tap the button again. On-device wording decides.
5. **US Letter**: the corner/size code recognizes Letter (8.5×11). If that shipped in 0.6.0, say “A4, Letter, and other common paper sizes”. US parents will look for it.
6. **HEIC**: `toastBadFile` suggests JPG or PNG. iPhone photos are HEIC by default, so make sure HEIC decodes in the App Store version, or US users will hit this error.
7. Crop sheet: `cropSub` and the stage hint (`hintCrop`) now say the same sentence, and both are visible at once. Consider hiding the stage hint while the Crop sheet is open (code change, not done).
8. **Test-mode notice is below the fold** on the paywall at 375×667: “Test mode — you won’t be charged” sits under “Not Now”, so a tester sees “Unlock Full Version · NT$190” without the reassurance. Consider moving it above the Unlock button or putting it in the button (e.g. “Unlock (Test) · NT$190”). Layout change, not done.
9. Optional: on placards, consider “age 5” instead of “5 yrs” for whole years only (needs a separate key, e.g. `ageYOnly`). Not done, to keep one format.

### Chinese suggestions (not edited)
- `paySubFlat` 「這張作品還在，不會不見」: “不會不見” overclaims, because the beta loses it if the page closes. Suggest 「這張作品還在。」. Also 「就能馬上收進來」 → 「就能馬上存下或收進來」, because the paywall also appears on 存到手機.
- `paySubCraft` 「你已經用了 {n} 次勞作 AI 去背」: the count is crafts kept, not cutouts. Suggest 「免費試用的 {n} 件勞作已經用完」.
- `restore` 恢復購買: Apple’s zh-TW apps usually say 「回復購買」 / 「回復購買項目」. Optional.
- `overlayP` 「加入照片」: see open question 4.
- `sheetCrop` 裁切四角: fine. If you want it parallel with English, use 「裁切與旋轉」 (optional).
