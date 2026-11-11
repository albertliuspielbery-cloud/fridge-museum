"""Compose App Store screenshots: wall background, title + subtitle, framed device, Bibi peeking.

Usage: python compose_store_shots.py <raw shots dir> <out dir> <chrome.exe> [--ipad] [--force]
  iPhone: 1320x2868 -> <out>/<locale>/NN.png      iPad (--ipad): 2064x2752 -> <out>/<locale>/ipad/NN.png
Existing files are kept (so already-uploaded shots keep their checksum) unless --force.
Raw shots are named <lang>-light-<scenario>.png (from the ci-shots-store branch).
"""
import os, subprocess, sys, tempfile, pathlib

RAW, OUT, CHROME = sys.argv[1], sys.argv[2], sys.argv[3]
IPAD, FORCE = "--ipad" in sys.argv, "--force" in sys.argv
REPO = "C:/Users/Albert/fridge-museum"
ART = f"file:///{REPO}/FridgeMuseum/Resources/Assets.xcassets/Art"
FONTS = f"file:///{REPO}/FridgeMuseum/Resources/Fonts"

SHOTS = [  # (scenario, zh title, zh sub, en title, en sub)
    ("home-full", "把孩子的作品掛上冰箱", "選好拍給誰，拍完就收好", "Hang their art on the fridge", "Pick the artist, snap, and it's kept"),
    ("edit-flat", "紙拉正，底色變白", "淡黃蠟筆、水彩、鉛筆不會被洗掉", "Straight, white, and clean", "Pale crayon and watercolor stay bright"),
    ("edit-craft", "勞作自動去背", "去掉桌面，換上乾淨背景和陰影", "Crafts lifted off the table", "A clean background and soft shadow"),
    ("museum", "每個孩子的美術館", "每個孩子都有頭像，依學期、年齡、標籤找作品", "A museum for each child", "Each with an avatar; filter by semester, age, or tag"),
    ("detail", "每件作品的說明牌", "當時幾歲、哪個學期，錄下孩子說的話", "A label for every piece", "Age, semester, and their own words"),
    ("success", "收進這次，馬上拍下一張", "一整疊要拍，就開連拍", "Hang it up, snap the next", "A whole stack? Turn on Burst"),
    ("home-color", "冰箱換上喜歡的顏色", "5 種顏色，在設定裡點一下就換", "Pick your fridge color", "Five colors, one tap in Settings"),
    ("duplicates", "重複的作品幫你找出來", "選一件留下，另一件 30 天內還能復原", "Spot the look-alikes", "Keep one; the other can come back for 30 days"),
    ("trash", "刪錯了也救得回來", "「最近刪除」幫你留 30 天", "Restore what you deleted", "Recently Deleted keeps art for 30 days"),
]

IPAD_SHOTS = [("home-full", "iPad 上的大冰箱", "這次拍的作品，一整面冰箱門都看得到", "A big fridge on iPad", "This session's art, all on one big door")] +     [x for x in SHOTS if x[0] in ("edit-flat", "edit-craft", "museum", "detail", "duplicates", "trash")]

DOTS = ("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='58' height='58'>"
        "<rect x='22' y='22' width='10' height='10' fill='%23F3D6AB' transform='rotate(45 27 27)'/></svg>")

TEMPLATE = """<!doctype html><html><head><meta charset="utf-8"><style>
@font-face{{font-family:Hun;src:url("{fonts}/Huninn-Regular.ttf")}}
@font-face{{font-family:Chi;src:url("{fonts}/ChironGoRoundTC-Regular.ttf")}}
html,body{{margin:0;width:{W}px;height:{H}px;overflow:hidden}}
body{{background:#FCEBD2 url("{dots}");position:relative;color:#4A2F24}}
.t{{position:absolute;left:60px;right:60px;top:{ttop}px;text-align:center;font-family:Hun;font-size:{tsize}px;line-height:1.15}}
.s{{position:absolute;left:80px;right:80px;top:{stop}px;text-align:center;font-family:Chi;font-size:{ssize}px;color:#5E4536;line-height:1.3}}
.peek{{position:absolute;left:{pl}px;top:{pt}px;width:160px}}
.phone{{position:absolute;left:{fl}px;top:{ft}px;width:{fw}px;height:{fh}px;box-sizing:border-box;border:{fb}px solid #4A2F24;
  border-radius:{fr}px;overflow:hidden;background:#FCEBD2;box-shadow:0 30px 60px rgba(120,80,40,.18)}}
.phone img{{display:block;width:100%}}
</style></head><body>
<img class="peek" src="{art}/bibi-head.imageset/bibi-head.svg">
<div class="phone"><img src="{shot}"></div>
<div class="t">{title}</div><div class="s">{sub}</div>
</body></html>"""


# iPhone frame 1035x2240 (screen 1005 wide); iPad frame 1530 wide for a 3:4 screen (1490x1987 + border 20).
GEOM = (dict(W=2064, H=2752, fl=267, ft=560, fw=1530, fh=2027, fb=20, fr=80, pl=1600, pt=476) if IPAD else
        dict(W=1320, H=2868, fl=143, ft=555, fw=1035, fh=2240, fb=15, fr=130, pl=830, pt=470))


def main():
    os.makedirs(OUT, exist_ok=True)
    tmp = tempfile.mkdtemp()
    for lang, loc in (("zh", "zh-Hant"), ("en", "en-US")):
        d = os.path.join(OUT, loc, "ipad") if IPAD else os.path.join(OUT, loc)
        os.makedirs(d, exist_ok=True)
        for i, (scen, zt, zs, et, es) in enumerate(IPAD_SHOTS if IPAD else SHOTS, 1):
            png = os.path.join(d, f"{i:02d}.png")
            if os.path.isfile(png) and not FORCE:
                continue
            raw = os.path.join(RAW, f"{lang}-light-{scen}.png")
            if not os.path.isfile(raw):
                raise SystemExit(f"missing {raw}")
            zh = lang == "zh"
            title, sub = (zt, zs) if zh else (et, es)
            html = TEMPLATE.format(fonts=FONTS, dots=DOTS, art=ART, shot=pathlib.Path(raw).as_uri(), title=title, sub=sub,
                                   ttop=120 if zh else 130, tsize=(128 if IPAD else 112) if zh else (110 if IPAD else 92),
                                   stop=(320 if IPAD else 300) if zh else (310 if IPAD else 290),
                                   ssize=(66 if IPAD else 58) if zh else (60 if IPAD else 50), **GEOM)
            hp = os.path.join(tmp, f"{lang}{i}.html")
            open(hp, "w", encoding="utf-8").write(html)
            subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--allow-file-access-from-files",
                            "--hide-scrollbars", "--force-device-scale-factor=1", f"--window-size={GEOM['W']},{GEOM['H']}",
                            f"--screenshot={png}", pathlib.Path(hp).as_uri()],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=120)
            print("wrote", png)


main()
