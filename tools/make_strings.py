#!/usr/bin/env python3
"""Writes FridgeMuseum/Resources/Localizable.xcstrings and InfoPlist.xcstrings.

Source language is zh-Hant: the Chinese UI text is the key (SwiftUI Text("…") / String(localized: "…")).
English copy reuses the reviewed table in kidart/i18n-zh-en.md wherever the string exists there; new strings follow
the same voice (warm, concise US English; Title Case for buttons/titles per Apple HIG, sentence case for hints).
Plurals: EN maps a key to {"one": …, "other": …}. Entries already in the catalog that this table doesn't know
(e.g. the Store team's `paywall.*` keys) are kept untouched.

Usage: python3 tools/make_strings.py
"""
import json
import os
from collections import OrderedDict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "FridgeMuseum", "Resources")

# zh-Hant key → English (str) or plural dict, or (zh-Hant value, en) tuple when the source text differs from the key.
EN = {
    # Brand / home
    "冰箱美術館": "My Fridge Museum",
    "照片只在這支手機上處理，不會上傳": "Photos are processed on this phone and never uploaded",
    "設定": "Settings",
    "版本資訊": "Version Info",
    "這次收的作品": "On the Fridge",
    "最近掛上的": "Recently Hung",
    "到美術館看全部 %lld 件": {"one": "See the Museum (1)", "other": "See All %lld in the Museum"},
    "冰箱還空空的，拍第一張作品掛上來吧": "The fridge is empty. Snap your first artwork and hang it up!",
    "按下方快門拍一張。整理好按「收進這次」，作品就會掛在這裡。":
        "Tap the shutter below to take a photo. When it looks good, tap “Hang It Up” and it will appear here.",
    "上一張還沒收進": "Your last artwork isn’t hung up yet",
    "還有 %lld 張還沒收進": {"one": "1 artwork isn’t hung up yet", "other": "%lld artworks aren’t hung up yet"},
    "存到手機或收進這次，才不會不見": "Save it to Photos or hang it up so you don’t lose it.",
    "繼續": "Resume",
    "還沒收進的作品": "Artwork not hung up yet",
    "不要了": "Discard",
    "全部不要": "Discard All",
    "不要這 %lld 張作品？": {"one": "Discard this artwork?", "other": "Discard these %lld artworks?"},
    "這 %lld 張會從 App 裡刪掉，不會存到手機。": {
        "one": "It will be deleted from the app and won’t be saved to Photos.",
        "other": "These %lld artworks will be deleted from the app and won’t be saved to Photos."},
    "平面畫作": "Drawing",
    "立體勞作": "Craft",
    "找出紙張四角，拉正、修平光線": "Finds the paper’s corners, straightens it, and evens out the light",
    "AI 去掉桌面，換上乾淨背景和陰影": "AI removes the table and adds a clean background and shadow",
    "看範例畫作": "See Sample",
    "看範例勞作": "See Sample",
    "拍照小技巧": "Photo Tips",
    "拍畫作時盡量讓整張紙入鏡，四周留一點桌面。": "For drawings, get the whole sheet in the frame with a little table showing around it.",
    "拍勞作時放在素色桌面上，四周留空。": "For crafts, use a plain table and leave some space around the piece.",
    "光線均勻最好；不用開閃光燈，App 會幫你修平光線。": "Even light works best. Skip the flash — the app evens out the light for you.",
    "所有處理都在這支手機上完成，不會上傳。": "Everything is processed on this phone. Nothing is uploaded.",
    "相簿": "Photos",
    "美術館": "Museum",
    "拍一張作品": "Take a Photo of Artwork",
    "作品類型": "Artwork type",
    "%lld 張": {"one": "1 artwork", "other": "%lld artworks"},
    "這張照片打不開，請換一張再試一次。": "Couldn’t open this photo. Try another one.",

    # Quota bubble (reviewed: quotaFlat / quotaFlatOut / quotaCraft / quotaCraftOut)
    "今天還能再收 %lld 張畫作喔！": {"one": "1 free drawing left today!", "other": "%lld free drawings left today!"},
    "今天的免費畫作收滿了，明天再來": "No free drawings left today",
    "勞作免費試用剩 %lld 次": {"one": "1 free trial craft left", "other": "%lld free trial crafts left"},
    "勞作免費試用已用完": "Free craft trial used up",
    "完整版：想收幾張都可以喔！": "Full Version: hang up as many as you like!",
    "按下快門，把作品掛上冰箱吧！": "Tap the shutter and hang your art on the fridge!",

    # Toasts
    "已掛上冰箱！": "Hung on the fridge!",
    "這是第 %lld 張，按快門拍下一張。": "That’s %lld so far. Tap the shutter for the next one.",
    "按快門，再拍下一張。": "Tap the shutter for the next one.",
    "已存到手機！": "Saved to Photos!",
    "已存到相簿「%@」，也掛上冰箱了。": "Saved to the “%@” album and hung on the fridge.",
    "已存到照片，也掛上冰箱了。": "Saved to Photos and hung on the fridge.",
    "已存 %lld 張到照片": {"one": "Saved 1 artwork to Photos", "other": "Saved %lld artworks to Photos"},
    "處理失敗，請重試": "Processing failed. Please try again.",
    "沒有照片權限，請到「設定 › 冰箱美術館」開啟": "No access to Photos. Turn it on in Settings › My Fridge Museum.",
    "儲存失敗": "Couldn’t save.",
    "拍照失敗，再試一次": "Couldn’t take the photo. Try again.",
    "我的作品": "My Artwork",
    "冰箱美術館 – %@": "My Fridge Museum – %@",
    "氣球派對": "Balloon Party",
    "國旗勞作": "Flag Craft",

    "作品資料庫打不開，這次收的作品不會被保存。請先存到照片，再重新開啟 App。":
        "Couldn’t open the artwork library, so nothing you hang up this time will be kept. Save to Photos first, then reopen the app.",
    "為每位小朋友建立相簿？": "Create an Album for Each Child?",
    "建立相簿": "Create Albums",
    "只存到照片": "Just Save to Photos",
    "要建立「冰箱美術館 – 小明」這樣的相簿，iPhone 會詢問是否允許取用所有照片。App 只會新增作品，不會讀取或上傳你的照片。":
        "To make albums like “My Fridge Museum – Mia,” iPhone will ask for full Photos access. The app only adds artworks — it never reads or uploads your photos.",
    "沒有照片權限": "No Access to Photos",
    "好": "OK",
    "作品還在 App 裡。到「設定 › 冰箱美術館 › 照片」選「僅限加入照片」或「完整取用」，就能存到照片。":
        "Your artwork is still in the app. In Settings › My Fridge Museum › Photos, choose Add Photos Only or Full Access to save it.",
    "copyright.fallback": ("© 星光工作室", "© Starlight Studio"),
    # Camera
    "關閉": "Close",
    "找到紙張了，按下快門": "Found the paper. Tap the shutter.",
    "把整張畫放進畫面，四個角都要拍到": "Fit the whole drawing in the frame, all four corners",
    "把勞作放在桌上，拍清楚一點": "Put the craft on a table and get a clear shot",
    "需要相機權限才能拍作品": "Camera access is needed to photograph artwork",
    "打開設定": "Open Settings",
    "也可以回到廚房，按「相簿」從照片挑選": "Or go back and tap “Photos” to pick from your library",
    "這台裝置不能使用相機\n可以回到廚房，按「相簿」從照片挑選":
        "The camera isn’t available on this device.\nGo back and tap “Photos” to pick from your library.",

    # Editor (reviewed keys: backHome, flatShort, craftShort, retake, sampleTag, compare, done, sheet*, t*, hints …)
    "畫作": "Drawing",
    "勞作": "Craft",
    "重拍": "Retake",
    "不要這張": "Discard",
    "不要這張作品？": "Discard this artwork?",
    "這張會從 App 裡刪掉，不會存到手機。": "It will be deleted from the app and won’t be saved to Photos.",
    "範例": "Sample",
    "對比": "Compare",
    "完成": "Done",
    "裁切": "Crop",
    "調整": "Adjust",
    "筆刷": "Brush",
    "說明牌": "Label",
    "裁切四角": "Crop & Rotate",
    "作品說明牌": "Museum Label",
    "原圖": "Before",
    "處理後": "After",
    "處理中…": "Processing…",
    "AI 去背中…": "Cutting out with AI…",
    "這張照片處理不了": "Couldn’t process this photo",
    "可以試試「裁切」對準紙張四角，或改成勞作。": "Try “Crop” to line up the paper’s corners, or switch to Craft.",
    "可以試試改成畫作，或重拍一張。": "Try switching to Drawing, or retake the photo.",
    "再試一次": "Try Again",
    "左上角": "Top-left corner",
    "右上角": "Top-right corner",
    "右下角": "Bottom-right corner",
    "左下角": "Bottom-left corner",
    "拖曳四個白點對準紙張四角，放開後會自動重新處理。": "Drag the four white dots to the paper’s corners. It updates when you let go.",
    "在髒點上塗抹，會塗成白色。只建議用在空白紙面。": "Paint over smudges to turn them white. Use only on blank areas of the paper.",
    "塗抹被誤刪的作品部分，把它補回來。": "Paint over parts of the artwork that were removed by mistake to bring them back.",
    "塗抹要去掉的背景部分。": "Paint over any background you want removed.",
    "冰冰正在整理這張作品，請稍等一下。": "Bibi is tidying up this artwork. Just a moment.",
    "左右拖曳白線，比較前後": "Drag the white line to compare before and after.",
    "改好了就存到手機或分享。修改會自動保存。": "When it looks right, save or share it. Changes are saved automatically.",
    "看起來可以了，就存到手機或收進這次。": "Looks good? Save it to Photos or hang it up.",
    "已自動清掉 %lld 個小黑點": {"one": "Removed 1 speck automatically.", "other": "Removed %lld specks automatically."},
    "收進這次": "Hang It Up",
    "存到手機": "Save to Photos",
    "分享": "Share",
    "取消最愛": "Remove from Favorites",
    "加到最愛": "Add to Favorites",
    "重新自動找四角": "Auto-Detect Corners",
    "用整張照片": "Use Whole Photo",
    "紙張變白": "Whiten Paper",
    "保護淡色": "Protect Pale Colors",
    "淡黃蠟筆、水彩、鉛筆不會被洗掉": "Keeps pale yellow crayon, watercolor, and pencil from washing out",
    "色彩鮮豔": "Color Boost",
    "自動清掉紙上的小黑點": "Auto-Remove Specks",
    "這張清掉了 %lld 個": {"one": "Removed 1 speck from this one", "other": "Removed %lld specks from this one"},
    "去背範圍": "Cutout Strength",
    "背景": "Background",
    "純白": "White",
    "暖白": "Warm White",
    "淺灰": "Light Gray",
    "柔光漸層": "Soft Glow",
    "加上自然陰影": "Add Natural Shadow",
    "擦掉背景": "Erase Background",
    "補回作品": "Restore Artwork",
    "筆刷大小": "Brush Size",
    "復原一筆": "Undo Stroke",
    "清除所有筆刷": "Clear All Strokes",

    "向左轉": "Rotate Left",
    "向右轉": "Rotate Right",
    "拉直": "Straighten",
    "已轉向。再按一次「裁切」可回到四角。": "Rotated. Tap “Crop” again to get the corners back.",
    "點選要留的部分": "Tap What to Keep",
    "完成選取": "Done Picking",
    "全部保留": "Keep All",
    "至少要留下一個部分喔": "Keep at least one part.",
    "點一下要留下或拿掉的部分，至少要留一個。": "Tap a part to keep or remove it. At least one has to stay.",
    "顏料幾乎蓋滿紙，只輕調光線": "Paint covers most of the paper, so only the lighting was adjusted.",
    # Processing notes (ProcessingNote.localizationKey; copy from the reviewed web table)
    "processing.note.paperNotFound": ("沒找到紙邊，先用整張照片，可用「裁切四角」調整",
                                      "Couldn’t find the paper’s edges, so the whole photo is used. Fix it in “Crop.”"),
    "processing.note.notWhitePaper": ("不是白紙，保留紙本來的顏色", "This isn’t white paper, so its original color is kept."),
    "processing.note.dotsKeptAsPattern": ("小點很多像是圖案，沒有清掉",
                                          "Lots of little dots look like part of the design, so they were left alone."),
    "processing.note.touchesEdge": ("作品碰到照片邊緣，可能被切到", "The craft touches the edge of the photo and may be cut off."),
    "processing.note.autoDroppedEdgeParts": ("已自動去掉邊緣的其他東西，點一下可以加回來",
                                             "Other things at the edge were removed. Use “Tap What to Keep” to bring them back."),
    "processing.note.cutoutFallback": ("沒能分開作品和桌面，先保留原照片",
                                       "Couldn’t separate the craft from the table, so the original photo is kept."),

    # Museum label sheet (reviewed: infoSub, kidName, kidBirth, artTitle, artMedium, artDate, captionSwitch …)
    "這是掛在冰箱上的作品說明牌。名字和生日只會記在這支手機上，下次不用再填。":
        "This is the museum label that hangs with the artwork. The name and birthday are saved only on this phone, "
        "so you won’t have to enter them again.",
    "小朋友": "Artist",
    "生日": "Birthday",
    "作品名稱": "Title",
    "例：我的家": "e.g., My House",
    "用什麼做的": "Made With",
    "例：蠟筆、紙": "e.g., Crayons",
    "作品日期": "Date Made",
    "標籤": "Tags",
    "備註": "Note",
    "孩子說了什麼？": "What did your child say about it?",
    "錄音": "Voice Note",
    "在圖片下方加上名字、年齡、日期": "Add Name, Age & Date Below Image",
    "小畫家（不指定）": "Little Artist (No One Specific)",
    "新增小朋友…": "Add Child…",
    "選擇": "Choose",
    "先選小朋友": "Choose an artist first",
    "填生日": "Add Birthday",
    "移除標籤 %@": "Remove tag %@",
    "新增標籤": "New tag",
    "加入": "Add",
    "停止錄音": "Stop Recording",
    "錄下孩子的介紹": "Record Your Child",
    "暫停": "Pause",
    "播放錄音": "Play Voice Note",
    "無題": "Untitled",
    "小畫家": "Little Artist",
    "紙上作品": "Work on paper",
    "mediumCraft": ("立體勞作", "Mixed media"),

    # Ages (reviewed: ageY / ageM / ageYM)
    "%lld歲": {"one": "%lld yr", "other": "%lld yrs"},
    "%lld個月": {"one": "%lld mo", "other": "%lld mos"},
    "%@ %@": ("%1$@%2$@", "%1$@ %2$@"),
    "未滿1個月": "Under 1 mo",
    "%lld 歲": {"one": "Age %lld", "other": "Age %lld"},
    "未滿 1 歲": "Under 1",

    # Child editor
    "名字或暱稱（例：小明）": "Name or nickname (e.g., Mia)",
    "填生日（算出作品當時幾歲）": "Add Birthday (Shows Age on Each Artwork)",
    "代表色": "Color",
    "刪除這位小朋友": "Delete This Child",
    "作品不會被刪除，會移到「未分類」。": "Their artworks stay in the museum under “Unsorted.”",
    "新增小朋友": "Add Child",
    "編輯小朋友": "Edit Child",
    "取消": "Cancel",
    "儲存": "Save",
    "確定刪除？": "Delete this child?",

    # Detail
    "編輯": "Edit",
    "編輯說明牌": "Edit Label",
    "孩子說": "In Their Words",
    "刪除": "Delete",
    "更多": "More",
    "刪除這件作品？": "Delete this artwork?",
    "只會刪除 App 裡的資料，已存到照片的不受影響。": "This only deletes it from the app. Copies saved in Photos stay.",
    "找不到這件作品": "Artwork Not Found",

    # Museum
    "全部": "All",
    "編輯 %@": "Edit %@",
    "未分類": "Unsorted",
    "新增": "Add",
    "依學期": "By Semester",
    "依年齡": "By Age",
    "依年份": "By Year",
    "不分組": "No Grouping",
    "%lld 件": {"one": "1 artwork", "other": "%lld artworks"},
    "共 %lld 件": {"one": "1 artwork", "other": "%lld artworks"},
    "最愛": "Favorites",
    "全部學期": "All Semesters",
    "學期": "Semester",
    "全部年齡": "All Ages",
    "年齡": "Age",
    "全部標籤": "All Tags",
    "清除": "Clear",
    "新的在前": "Newest First",
    "舊的在前": "Oldest First",
    "排序": "Sort",
    "分組": "Group",
    "8 月 – 1 月": "Aug – Jan",
    "2 月 – 7 月": "Feb – Jul",
    "%@ 年": "%@",
    "還沒填生日": "No birthday yet",
    "全部作品": "All Artworks",
    "美術館還是空的": "The museum is empty",
    "回到廚房拍下第一張作品，按「收進這次」就會掛到這裡。": "Go back to the kitchen, snap your first artwork, and tap “Hang It Up.” It will hang here.",
    "沒有符合的作品": "No matching artworks",
    "清除篩選": "Clear Filters",

    # Settings / about
    "已解鎖完整版": "Full Version Unlocked",
    "免費版": "Free Version",
    "今天還可收 %lld 張畫作 · 勞作試用剩 %lld 次": "Drawings left today: %1$lld · Trial crafts left: %2$lld",
    "解鎖完整版": "Unlock Full Version",
    "已恢復完整版": "Full Version restored",
    "這個 Apple 帳號沒有購買紀錄": "No purchase found for this Apple Account",
    "無法連線到 App Store，請稍後再試": "Couldn’t reach the App Store. Try again later.",
    "恢復購買": "Restore Purchases",
    "完整版": "Full Version",
    "一次買斷，不是訂閱。支援「家人共享」。": "One-time purchase — not a subscription. Works with Family Sharing.",
    "存到照片時依小朋友分相簿": "Separate Album for Each Child",
    "照片": "Photos",
    "需要「完整照片取用權限」才能建立「冰箱美術館 – 小明」這樣的相簿；只允許加入照片時，會存到「最近項目」。":
        "Albums like “My Fridge Museum – Mia” need Full Photo Access. With add-only access, artworks go to Recents.",
    "語言": "Language",
    "在「設定」中更改語言": "Change Language in Settings",
    "App 支援繁體中文和英文，預設跟隨 iPhone 的語言。": "The app is in Traditional Chinese and English, and follows your iPhone’s language by default.",
    "隱私權政策": "Privacy Policy",
    "支援與意見回饋": "Support & Feedback",
    "授權條款": "Licenses",
    "版本": "Version",
    "關於": "About",
    "所有照片都只在這支手機上處理，不會上傳；App 不蒐集任何個人資料。":
        "All photos are processed on this phone and never uploaded. The app collects no personal data.",
    "把孩子的作品掛上冰箱": "Hang your kid’s art on the fridge",
    "Huninn（粉圓體）": "Huninn",
    "Chiron GoRound TC（昭源甜圓）": "Chiron GoRound TC",
    "字型": "Fonts",
    "App 內附的字型為了縮小檔案只保留常用字，依 OFL 授權修改與散布。":
        "To keep the app small, the bundled fonts are subset to common characters, as the OFL permits.",
    "App 內購（StoreKit）、相機、照片、Vision 與語音辨識都是 Apple 的系統功能，沒有使用第三方程式庫。":
        "In-app purchase (StoreKit), camera, Photos, Vision, and speech recognition are Apple system frameworks. "
        "No third-party code libraries are used.",
    "其他": "Other",

    # Voice notes
    "沒有麥克風權限，請到「設定」開啟": "No microphone access. Turn it on in Settings.",
    "無法開始錄音": "Couldn’t start recording.",
    "無法播放": "Couldn’t play the recording.",
    "這台手機無法離線辨識語音，已保留錄音": "This phone can’t transcribe speech offline. The recording is kept.",
}

# ---- Child avatars (feat/avatars) — kept as a separate block so parallel branches merge cleanly ----
EN_AVATARS = {
    "頭像": "Avatar",
    "從照片選": "Choose from Photos",
    "用他的作品": "Use Their Artwork",
    "用顏色": "Use a Color",
    "頭像只存在這支手機裡。": "The avatar stays on this phone.",
    "選一件作品": "Choose an Artwork",
    "作品": "Artwork",
    "調整頭像": "Adjust Avatar",
    "使用": "Use",
    "縮放": "Zoom",
    "拖曳移動，兩指縮放": "Drag to move, pinch to zoom",
}
EN.update(EN_AVATARS)

INFOPLIST = {
    "CFBundleDisplayName": ("冰箱美術館", "My Fridge Museum"),
    "CFBundleName": ("冰箱美術館", "My Fridge Museum"),
    "NSHumanReadableCopyright": ("© 星光工作室 Starlight Studio", "© Starlight Studio"),
    "NSCameraUsageDescription": ("用相機拍下孩子的畫作和勞作。照片只會存在這支手機裡。",
                                 "Take photos of your kid’s drawings and crafts. Photos stay on this phone."),
    "NSPhotoLibraryAddUsageDescription": ("把整理好的作品存到「照片」。", "Save finished artworks to Photos."),
    "NSPhotoLibraryUsageDescription": ("為每位小朋友建立「冰箱美術館」相簿，並把整理好的作品放進去。",
                                       "Create a My Fridge Museum album for each child and add finished artworks to it."),
    "NSMicrophoneUsageDescription": ("錄下孩子介紹自己作品的聲音，錄音只會存在這支手機裡。",
                                     "Record your kid talking about their artwork. Recordings stay on this phone."),
    "NSSpeechRecognitionUsageDescription": ("在手機上把孩子的錄音轉成文字備註，不會上傳到網路。",
                                            "Turn your kid’s recording into a text note on this phone. Nothing is uploaded."),
}


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def entry(en, zh_value=None):
    loc = OrderedDict()
    if isinstance(en, dict):
        loc["en"] = {"variations": {"plural": {k: unit(v) for k, v in en.items()}}}
    else:
        loc["en"] = unit(en)
    if zh_value is not None:
        loc["zh-Hant"] = unit(zh_value)
    return {"extractionState": "manual", "localizations": dict(sorted(loc.items()))}


def write(path, strings, keep_unknown=True):
    old = {}
    if keep_unknown and os.path.exists(path):
        old = json.load(open(path, encoding="utf-8")).get("strings", {})
    merged = dict(old)
    merged.update(strings)
    doc = {"sourceLanguage": "zh-Hant", "strings": dict(sorted(merged.items())), "version": "1.0"}
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2, separators=(",", " : "))
        f.write("\n")
    print(f"{os.path.relpath(path, ROOT)}: {len(merged)} strings")


def main():
    strings = {}
    for key, val in EN.items():
        if isinstance(val, tuple):
            strings[key] = entry(val[1], zh_value=val[0])
        else:
            strings[key] = entry(val)
    write(os.path.join(RES, "Localizable.xcstrings"), strings)
    info = {k: entry(en, zh_value=zh) for k, (zh, en) in INFOPLIST.items()}
    write(os.path.join(RES, "InfoPlist.xcstrings"), info, keep_unknown=False)


if __name__ == "__main__":
    main()
