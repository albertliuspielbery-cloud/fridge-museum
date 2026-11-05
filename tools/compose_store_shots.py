"""Compose App Store screenshots (1320x2868): wall background, title + subtitle, framed phone, Bibi peeking.

Usage: python compose_store.py <raw shots dir> <out dir> <chrome.exe>
Raw shots are named <lang>-light-<scenario>.png (from the ci-shots-store branch).
"""
import os, subprocess, sys, tempfile, pathlib

RAW, OUT, CHROME = sys.argv[1], sys.argv[2], sys.argv[3]
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
]

DOTS = ("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='58' height='58'>"
        "<rect x='22' y='22' width='10' height='10' fill='%23F3D6AB' transform='rotate(45 27 27)'/></svg>")

TEMPLATE = """<!doctype html><html><head><meta charset="utf-8"><style>
@font-face{{font-family:Hun;src:url("{fonts}/Huninn-Regular.ttf")}}
@font-face{{font-family:Chi;src:url("{fonts}/ChironGoRoundTC-Regular.ttf")}}
html,body{{margin:0;width:1320px;height:2868px;overflow:hidden}}
body{{background:#FCEBD2 url("{dots}");position:relative;color:#4A2F24}}
.t{{position:absolute;left:60px;right:60px;top:{ttop}px;text-align:center;font-family:Hun;font-size:{tsize}px;line-height:1.15}}
.s{{position:absolute;left:80px;right:80px;top:{stop}px;text-align:center;font-family:Chi;font-size:{ssize}px;color:#5E4536;line-height:1.3}}
.peek{{position:absolute;left:830px;top:470px;width:160px}}
.phone{{position:absolute;left:143px;top:555px;width:1035px;height:2240px;box-sizing:border-box;border:15px solid #4A2F24;
  border-radius:130px;overflow:hidden;background:#FCEBD2;box-shadow:0 30px 60px rgba(120,80,40,.18)}}
.phone img{{display:block;width:100%}}
</style></head><body>
<img class="peek" src="{art}/bibi-head.imageset/bibi-head.svg">
<div class="phone"><img src="{shot}"></div>
<div class="t">{title}</div><div class="s">{sub}</div>
</body></html>"""


def main():
    os.makedirs(OUT, exist_ok=True)
    tmp = tempfile.mkdtemp()
    for lang, loc in (("zh", "zh-Hant"), ("en", "en-US")):
        d = os.path.join(OUT, loc)
        os.makedirs(d, exist_ok=True)
        for i, (scen, zt, zs, et, es) in enumerate(SHOTS, 1):
            raw = os.path.join(RAW, f"{lang}-light-{scen}.png")
            if not os.path.isfile(raw):
                raise SystemExit(f"missing {raw}")
            zh = lang == "zh"
            title, sub = (zt, zs) if zh else (et, es)
            html = TEMPLATE.format(fonts=FONTS, dots=DOTS, art=ART, shot=pathlib.Path(raw).as_uri(), title=title, sub=sub,
                                   ttop=120 if zh else 130, tsize=112 if zh else 92, stop=300 if zh else 290,
                                   ssize=58 if zh else 50)
            hp = os.path.join(tmp, f"{lang}{i}.html")
            open(hp, "w", encoding="utf-8").write(html)
            png = os.path.join(d, f"{i:02d}.png")
            subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--allow-file-access-from-files",
                            "--hide-scrollbars", "--force-device-scale-factor=1", "--window-size=1320,2868",
                            f"--screenshot={png}", pathlib.Path(hp).as_uri()],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=120)
            print("wrote", png)


main()
