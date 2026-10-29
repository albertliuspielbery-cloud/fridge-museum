# 雲端用：把 App Store 上架資料（appstore/listing.json + appstore/screenshots/）填進 App Store Connect
# 參考 ci/ci_iap.py 的做法（同一組金鑰、同樣的 call() 與註解訊息）。可以重複執行：內容一樣的部分不會再動。
#   版本：找可以編輯的 App Store 版本（準備提交、被退回…）；沒有就建立；版本號不同就改成指定的版本號
#   版本資料（每個語言）：描述、關鍵字、宣傳文字、支援網址、行銷網址、此版本新增內容（第一個上架版本不送）
#   App 資料（每個語言）：名稱、副標題、隱私權政策網址；主要／次要類別；年齡分級問卷
#   版權、App 審查備註（不填聯絡人姓名電話：缺的話提醒擁有者到 ASC 填）
#   截圖：iPhone 6.9 吋（1320×2868）每個語言 6 張，照順序，新的全部上傳成功才刪舊的
# **永遠不會送審**：不碰 reviewSubmissions／appStoreVersionSubmissions（call() 也會擋）。也不選建置版本、
# 不改價格與銷售地區、不填 App 隱私權問卷（API 不支援）。
# 用法：
#   python3 ci/ci_metadata.py --check                  只檢查 listing.json（字數上限、和 metadata.md 一致、截圖尺寸），不連網
#   python3 ci/ci_metadata.py --from-md                依 appstore/metadata.md 重新產生 listing.json 的文字欄位（開發用）
#   python3 ci/ci_metadata.py [--version 1.1.0] [--no-screenshots] [--dry-run]
# 環境變數：ASC_KEY_ID、ASC_ISSUER_ID、ASC_KEY_P8（必要，--check／--from-md 不用）；APP_BUNDLE_ID（可選）
import os, re, sys, json, time, struct, hashlib, argparse, urllib.request, urllib.error

sys.stdout.reconfigure(encoding='utf-8')  # 中文註解訊息；不靠執行環境的預設編碼

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LISTING = os.path.join(ROOT, 'appstore', 'listing.json')
METADATA_MD = os.path.join(ROOT, 'appstore', 'metadata.md')
SHOTS_DIR = os.path.join(ROOT, 'appstore', 'screenshots')
BUNDLE = os.environ.get('APP_BUNDLE_ID') or 'tw.starlight.fridgemuseum'
API = 'https://api.appstoreconnect.apple.com'
TITLE = 'App Store 上架資料'

# Apple 的字數上限（字元）
LIMITS = {'name': 30, 'subtitle': 30, 'promotionalText': 170, 'description': 4000, 'keywords': 100,
          'whatsNew': 4000, 'reviewNotes': 4000}
LOCALES = ('zh-Hant', 'en-US')
SHOT_SIZE = (1320, 2868)
SHOT_COUNT = 6
MAX_SHOTS_PER_SET = 10

# 版本狀態（appVersionState 新欄位，appStoreState 舊欄位，兩個都看）
EDITABLE = {'PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED', 'INVALID_BINARY',
            'READY_FOR_REVIEW'}
RELEASED = {'READY_FOR_SALE', 'READY_FOR_DISTRIBUTION', 'REPLACED_WITH_NEW_VERSION', 'DEVELOPER_REMOVED_FROM_SALE',
            'REMOVED_FROM_SALE', 'PREORDER_READY_FOR_SALE'}
APPINFO_EDITABLE = {'PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED', 'READY_FOR_REVIEW'}

DRY = False
report = []


def esc(s):
    # GitHub 註解指令裡的換行、百分比要跳脫
    return s.replace('%', '%25').replace('\r', '').replace('\n', '%0A')


def error(msg):
    print(f'::error title={TITLE}::' + esc(msg))
    raise SystemExit(1)


def warning(msg):
    print(f'::warning title={TITLE}::' + esc(msg))


def notice(msg):
    print(f'::notice title={TITLE}::' + esc(msg))


# ---------------------------------------------------------------- metadata.md → 文字欄位

MD_SECTIONS = {1: 'name', 2: 'subtitle', 3: 'promotionalText', 4: 'description', 5: 'keywords', 6: 'whatsNew'}


def parse_metadata_md(path=METADATA_MD):
    """讀 metadata.md：回傳 {'locales': {locale: {field: text}}, 'reviewNotes': str, 'urls': {...}, 'copyright': str}"""
    lines = open(path, encoding='utf-8').read().split('\n')
    out = {'locales': {l: {} for l in LOCALES}, 'reviewNotes': None, 'urls': {}, 'copyright': None,
           'whatsNewVersion': None}
    sec, loc, buf = None, None, None
    for line in lines:
        if buf is not None:
            if line.strip() == '```':
                text = '\n'.join(buf)
                if sec in MD_SECTIONS and loc:
                    out['locales'][loc][MD_SECTIONS[sec]] = text
                elif sec == 11:
                    out['reviewNotes'] = text
                buf, loc = None, None
            else:
                buf.append(line)
            continue
        m = re.match(r'^## (\d+)\.', line)
        if m:
            sec, loc = int(m.group(1)), None
            if sec == 6:  # 「## 6. 此版本新增內容 What's New（1.1.0）」→ 這段寫的是哪一版
                vm = re.search(r'[（(]\s*(\d+(?:\.\d+)+)\s*[）)]', line)
                out['whatsNewVersion'] = vm.group(1) if vm else None
            continue
        if line.strip() == '```':
            buf = []
            continue
        for l in LOCALES:
            if line.startswith(l):
                loc = l
        if sec == 12 and line.startswith('|'):
            cells = [c.strip() for c in line.strip('|').split('|')]
            if len(cells) >= 2:
                if 'Support URL' in cells[0]:
                    out['urls']['supportUrl'] = cells[1]
                elif 'Privacy Policy URL' in cells[0]:
                    out['urls']['privacyPolicyUrl'] = cells[1]
                elif 'Copyright' in cells[0]:
                    out['copyright'] = cells[1]
    return out


def load_listing():
    return json.load(open(LISTING, encoding='utf-8'))


def png_info(path):
    b = open(path, 'rb').read(33)
    if b[:8] != b'\x89PNG\r\n\x1a\n':
        return None
    w, h = struct.unpack('>II', b[16:24])
    return w, h, b[25]  # color type：2 = RGB，6 = RGBA


def shot_files(locale):
    d = os.path.join(SHOTS_DIR, locale)
    return [os.path.join(d, f'{i:02d}.png') for i in range(1, SHOT_COUNT + 1)]


def check(listing):
    """離線檢查；回傳錯誤清單（空的 = 通過）"""
    errs, md = [], parse_metadata_md()
    for loc in LOCALES:
        L = listing['locales'].get(loc)
        if not L:
            errs.append(f'listing.json 缺少語言 {loc}')
            continue
        for f, lim in LIMITS.items():
            if f in L and L[f] is not None and len(L[f]) > lim:
                errs.append(f'{loc} {f} 有 {len(L[f])} 字，超過上限 {lim}')
        for f in ('name', 'subtitle', 'description', 'keywords', 'supportUrl', 'privacyPolicyUrl'):
            if not L.get(f):
                errs.append(f'{loc} {f} 是空的')
        kw = L.get('keywords') or ''
        if ', ' in kw or '，' in kw:
            errs.append(f'{loc} 關鍵字要用半形逗號分隔、逗號後不空格')
        for f in ('supportUrl', 'privacyPolicyUrl', 'marketingUrl'):
            if L.get(f) and not L[f].startswith('https://'):
                errs.append(f'{loc} {f} 要是 https 網址')
        for f in MD_SECTIONS.values():
            if md['locales'][loc].get(f) != L.get(f):
                errs.append(f'{loc} {f} 和 appstore/metadata.md 不一致（跑 python3 ci/ci_metadata.py --from-md 重新產生）')
        for f, v in md['urls'].items():
            if L.get(f) != v:
                errs.append(f'{loc} {f} 和 metadata.md 第 12 節不一致')
    if len(listing.get('reviewNotes') or '') > LIMITS['reviewNotes']:
        errs.append('審查備註超過 4000 字')
    if listing.get('reviewNotes') != md['reviewNotes']:
        errs.append('審查備註和 metadata.md 第 11 節不一致')
    if listing.get('copyright') != md['copyright']:
        errs.append('版權和 metadata.md 第 12 節不一致')
    if listing.get('whatsNewVersion') != md['whatsNewVersion']:
        errs.append('whatsNewVersion 和 metadata.md 第 6 節標題的版本號不一致')
    for loc in LOCALES:
        for p in shot_files(loc):
            if not os.path.isfile(p):
                errs.append(f'缺截圖 {os.path.relpath(p, ROOT)}')
                continue
            info = png_info(p)
            if not info:
                errs.append(f'{os.path.relpath(p, ROOT)} 不是 PNG')
            elif info[:2] != SHOT_SIZE:
                errs.append(f'{os.path.relpath(p, ROOT)} 是 {info[0]}×{info[1]}，要 {SHOT_SIZE[0]}×{SHOT_SIZE[1]}')
            elif info[2] in (4, 6):
                errs.append(f'{os.path.relpath(p, ROOT)} 有透明通道（App Store 不收），請存成不透明的 PNG')
    return errs


def from_md():
    listing = load_listing() if os.path.isfile(LISTING) else {'locales': {}}
    md = parse_metadata_md()
    for loc in LOCALES:
        L = listing['locales'].setdefault(loc, {})
        L.update({k: v for k, v in md['locales'][loc].items()})
        L.update(md['urls'])
        L.setdefault('marketingUrl', '')
    listing['reviewNotes'] = md['reviewNotes']
    listing['copyright'] = md['copyright']
    listing['whatsNewVersion'] = md['whatsNewVersion']
    with open(LISTING, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(listing, f, ensure_ascii=False, indent=2)
        f.write('\n')
    print('wrote', LISTING)


# ---------------------------------------------------------------- App Store Connect API

def token():
    import jwt  # pyjwt + cryptography；workflow 會先安裝
    now = int(time.time())
    return jwt.encode({'iss': os.environ['ASC_ISSUER_ID'], 'iat': now, 'exp': now + 900, 'aud': 'appstoreconnect-v1'},
                      os.environ['ASC_KEY_P8'], algorithm='ES256', headers={'kid': os.environ['ASC_KEY_ID'], 'typ': 'JWT'})


def call(method, path, body=None, ok404=False, soft=False, want_error=False):
    """soft=True：失敗時回傳 None。want_error=True：4xx 時回傳 {'__error__': code, 'errors': [...]}，讓呼叫端決定怎麼辦。"""
    if method != 'GET' and re.search(r'reviewSubmission|appStoreVersionSubmission', path, re.I):
        error('程式錯誤：這個流程不應該送審，已擋下 ' + method + ' ' + path)  # 安全閥：永遠不送審
    url = path if path.startswith('http') else API + path
    for attempt in range(4):
        req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None,
                                     headers={'Authorization': 'Bearer ' + token(), 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                t = r.read()
                return json.loads(t) if t else {}
        except urllib.error.HTTPError as e:
            msg = e.read().decode(errors='replace')
            if ok404 and e.code == 404:
                return None
            if e.code in (429, 500, 502, 503, 504) and attempt < 3:
                time.sleep(2 ** (attempt + 1))
                continue
            if want_error and 400 <= e.code < 500:
                try:
                    errs = json.loads(msg).get('errors', [])
                except ValueError:
                    errs = [{'detail': msg[:500]}]
                return {'__error__': e.code, 'errors': errs}
            if soft:
                return None
            error(f'App Store Connect API {method} {url.split("?")[0].replace(API, "")} 失敗（{e.code}）：{msg[:900]}')
        except urllib.error.URLError as e:
            if attempt < 3:
                time.sleep(2 ** (attempt + 1))
                continue
            if soft:
                return None
            error(f'連不上 App Store Connect：{e.reason}')


def write(method, path, body=None, what='', **kw):
    """會改 ASC 的呼叫都走這裡；--dry-run 時只印出來。"""
    if DRY:
        print(f'[dry-run] 會 {method} {path}：{what}')
        if body is not None:
            print('          ' + json.dumps(body, ensure_ascii=False)[:600])
        return None
    print(f'{method} {path}：{what}')
    return call(method, path, body, **kw)


def all_pages(path):
    out, url = [], path
    while url:
        r = call('GET', url)
        out += r.get('data', [])
        url = (r.get('links') or {}).get('next')
    return out


def states(v):
    a = v.get('attributes') or {}
    return {a.get('appVersionState'), a.get('appStoreState'), a.get('state')} - {None}


def err_text(r):
    return '；'.join((e.get('detail') or e.get('title') or '') for e in r.get('errors', []))[:900]


def diff(cur_attrs, want):
    return {k: v for k, v in want.items() if (cur_attrs or {}).get(k) != v}


# ---------------------------------------------------------------- 步驟

def find_app():
    apps = [a for a in call('GET', f'/v1/apps?filter[bundleId]={BUNDLE}')['data'] if a['attributes']['bundleId'] == BUNDLE]
    if not apps:
        error(f'在 App Store Connect 找不到套件識別碼 {BUNDLE} 的 App。')
    a = apps[0]
    print('App', BUNDLE, a['id'], 'primaryLocale', a['attributes'].get('primaryLocale'))
    return a


def ensure_version(app_id, version, listing):
    vs = all_pages(f'/v1/apps/{app_id}/appStoreVersions?filter[platform]=IOS&limit=50')
    released = any(states(v) & RELEASED for v in vs)
    editable = [v for v in vs if states(v) & EDITABLE]
    in_flight = [v for v in vs if not (states(v) & (EDITABLE | RELEASED))]
    for v in vs:
        print('version', v['attributes'].get('versionString'), sorted(states(v)))
    if not editable:
        if in_flight:
            v = in_flight[0]
            notice(f'版本 {v["attributes"].get("versionString")} 目前是 {"/".join(sorted(states(v)))}（審查中或等待發布），'
                   '版本資料現在不能改，這次不動。')
            raise SystemExit(0)
        if any(v['attributes'].get('versionString') == version for v in vs):
            error(f'版本 {version} 已經上架過了。要更新請用新的版本號（例如下一版），在「版本號」欄位填新的號碼重跑。')
        r = write('POST', '/v1/appStoreVersions', {'data': {'type': 'appStoreVersions', 'attributes': {
            # releaseType MANUAL：審查通過後也要擁有者自己按「發布」，絕不自動上架
            'platform': 'IOS', 'versionString': version, 'copyright': listing['copyright'], 'releaseType': 'MANUAL'},
            'relationships': {'app': {'data': {'type': 'apps', 'id': app_id}}}}}, f'建立版本 {version}')
        report.append(f'已建立版本 {version}（發布方式：手動發布）')
        return (r or {}).get('data'), released
    v = editable[0]
    a = v['attributes']
    vid = v['id']
    old_vs, old_cr = a.get('versionString'), a.get('copyright')
    rt = a.get('releaseType')
    if rt in ('AFTER_APPROVAL', 'SCHEDULED'):
        # 既有版本的發布方式不改（擁有者的決定），只提醒
        notice(f'版本 {old_vs} 的發布方式目前是 {"審查通過後自動發布" if rt == "AFTER_APPROVAL" else "排定日期自動發布"}（{rt}）。'
               '這個流程不會改它；如果想審查通過後自己按發布，請到 ASC 版本頁「版本發布」選「手動發布此版本」。')
    if old_vs != version:
        clash = [x for x in vs if x['id'] != vid and x['attributes'].get('versionString') == version]
        if clash:
            error(f'已經有另一個 {version} 版本（{"/".join(sorted(states(clash[0])))}），不能把 {old_vs} 改成 {version}。')
        write('PATCH', f'/v1/appStoreVersions/{vid}', {'data': {'type': 'appStoreVersions', 'id': vid,
              'attributes': {'versionString': version}}}, f'版本號 {old_vs} → {version}')
        report.append(f'版本號：{old_vs} → {version}')
    if old_cr != listing['copyright']:
        write('PATCH', f'/v1/appStoreVersions/{vid}', {'data': {'type': 'appStoreVersions', 'id': vid,
              'attributes': {'copyright': listing['copyright']}}}, '版權')
    report.append(f'版本 {version}（{"/".join(sorted(states(v)))}），版權：{listing["copyright"]}')
    return v, released


def version_localizations(vid, listing, released, version):
    have = {l['attributes']['locale']: l for l in all_pages(f'/v1/appStoreVersions/{vid}/appStoreVersionLocalizations?limit=50')}
    fields = ['description', 'keywords', 'promotionalText', 'supportUrl', 'marketingUrl']
    wn_note = '；第一個上架版本，不填「此版本新增內容」'
    if released:
        if listing.get('whatsNewVersion') == version:
            fields.append('whatsNew')
            wn_note = '、此版本新增內容'
        else:
            warning(f'metadata.md 的「此版本新增內容」是寫給 {listing.get("whatsNewVersion")} 的，這次版本是 {version}，'
                    '所以沒有送出。請先更新 metadata.md 第 6 節（標題的版本號和內容），跑 --from-md 再重跑。')
            wn_note = '；此版本新增內容：沒有送（版本號不符）'
    out = {}
    for loc in LOCALES:
        L = listing['locales'][loc]
        want = {f: L[f] for f in fields if L.get(f)}  # 空的（例如行銷網址）不送，也不清掉 ASC 上現有的
        cur = have.get(loc)
        if cur:
            d = diff(cur['attributes'], want)
            if d:
                write('PATCH', f'/v1/appStoreVersionLocalizations/{cur["id"]}', {'data': {
                    'type': 'appStoreVersionLocalizations', 'id': cur['id'], 'attributes': d}}, f'{loc} 版本資料：{", ".join(d)}')
            out[loc] = cur['id']
        else:
            r = write('POST', '/v1/appStoreVersionLocalizations', {'data': {'type': 'appStoreVersionLocalizations',
                      'attributes': dict(want, locale=loc),
                      'relationships': {'appStoreVersion': {'data': {'type': 'appStoreVersions', 'id': vid}}}}},
                      f'新增語言 {loc}')
            out[loc] = ((r or {}).get('data') or {}).get('id')
    extra = sorted(set(have) - set(LOCALES))
    if extra:
        warning('ASC 上還有其他語言：' + '、'.join(extra) + '（這個流程不會動它們，也不會刪掉；不需要的話請到 ASC 移除）')
    report.append('版本資料（描述、關鍵字、宣傳文字、網址）：' + '、'.join(LOCALES) + wn_note)
    return out


def pick_appinfo(app_id):
    infos = all_pages(f'/v1/apps/{app_id}/appInfos?limit=10')
    for i in infos:
        print('appInfo', i['id'], sorted(states(i)))
    ed = [i for i in infos if states(i) & APPINFO_EDITABLE]
    if not ed:
        warning('App 資訊（名稱、副標題、類別、年齡分級）目前不能編輯（可能在審查中），這次跳過。')
        return None
    return ed[0]


def appinfo_localizations(info_id, listing):
    have = {l['attributes']['locale']: l for l in all_pages(f'/v1/appInfos/{info_id}/appInfoLocalizations?limit=50')}
    for loc in LOCALES:
        L = listing['locales'][loc]
        want = {'name': L['name'], 'subtitle': L['subtitle'], 'privacyPolicyUrl': L['privacyPolicyUrl']}
        cur = have.get(loc)
        if cur:
            d = diff(cur['attributes'], want)
            if d:
                r = write('PATCH', f'/v1/appInfoLocalizations/{cur["id"]}', {'data': {'type': 'appInfoLocalizations',
                          'id': cur['id'], 'attributes': d}}, f'{loc} 名稱／副標題／隱私權網址：{", ".join(d)}', want_error=True)
                if r and '__error__' in r:
                    error(f'{loc} App 名稱／副標題更新失敗（{r["__error__"]}）：{err_text(r)}'
                          '（名稱已被別的 App 使用時也會這樣，請到 ASC 確認）')
        else:
            r = write('POST', '/v1/appInfoLocalizations', {'data': {'type': 'appInfoLocalizations',
                      'attributes': dict(want, locale=loc),
                      'relationships': {'appInfo': {'data': {'type': 'appInfos', 'id': info_id}}}}},
                      f'新增 App 資訊語言 {loc}', want_error=True)
            if r and '__error__' in r:
                error(f'新增 {loc} App 名稱失敗（{r["__error__"]}）：{err_text(r)}')
    report.append('名稱／副標題：' + '；'.join(f'{listing["locales"][l]["name"]}／{listing["locales"][l]["subtitle"]}' for l in LOCALES))


def categories(info_id, listing):
    want = {'primaryCategory': listing['primaryCategory'], 'secondaryCategory': listing['secondaryCategory']}
    rel = {}
    for k, cat in want.items():
        cur = call('GET', f'/v1/appInfos/{info_id}/{k}', ok404=True, soft=True)
        if ((cur or {}).get('data') or {}).get('id') != cat:
            rel[k] = {'data': {'type': 'appCategories', 'id': cat}}
    if rel:
        write('PATCH', f'/v1/appInfos/{info_id}', {'data': {'type': 'appInfos', 'id': info_id, 'relationships': rel}},
              '類別：' + ', '.join(f'{k}={v["data"]["id"]}' for k, v in rel.items()))
    report.append(f'類別：主要 {want["primaryCategory"]}，次要 {want["secondaryCategory"]}')


def age_rating(info_id, listing):
    want = dict(listing['ageRating'])
    r = call('GET', f'/v1/appInfos/{info_id}/ageRatingDeclaration', ok404=True, soft=True)
    d = (r or {}).get('data')
    if not d:
        warning('讀不到年齡分級問卷，請到 ASC →「App 資訊」→「年齡分級」手動填（全部選「無／否」，結果 4+）。')
        report.append('年齡分級：沒有填（讀不到問卷，請手動填）')
        return
    cur = d.get('attributes') or {}
    # 所有答案都送（GET 沒回傳的欄位也送）；ASC 不收的欄位由下面的重試拿掉並回報
    new_q = [k for k, v in cur.items() if k not in listing['ageRating'] and v is None
             and k not in ('developerAgeRatingInfoUrl', 'gracRatingClassificationNumber', 'koreaAgeRatingOverride',
                           'ageRatingOverride', 'socialMediaAgeRestricted')]
    if new_q:
        warning('年齡分級問卷有這個流程不認得的新題目：' + '、'.join(new_q) + '。請到 ASC →「App 資訊」→「年齡分級」確認（應該都是「無／否」）。')
    patch = diff(cur, want)
    already = len(want) - len(patch)
    dropped, written, failed = [], [], None
    for _ in range(10):
        if not patch:
            break
        res = write('PATCH', f'/v1/ageRatingDeclarations/{d["id"]}', {'data': {'type': 'ageRatingDeclarations',
                    'id': d['id'], 'attributes': patch}}, '年齡分級：' + ', '.join(patch), want_error=True)
        if not res or '__error__' not in res:
            written = sorted(patch)
            break
        bad = set()
        for e in res['errors']:
            m = re.search(r'/data/attributes/(\w+)', ((e.get('source') or {}).get('pointer') or ''))
            if m and m.group(1) in patch:
                bad.add(m.group(1))
        if not bad:
            failed = f'{res["__error__"]}：{err_text(res)}'
            break
        dropped += sorted(bad)
        for k in bad:
            patch.pop(k)
    else:
        failed = '重試太多次'
    if dropped:
        warning('年齡分級這些題目 ASC 不收，已跳過：' + '、'.join(dropped) + '。請到 ASC →「App 資訊」→「年齡分級」確認問卷已完成。')
    if failed:
        warning(f'年齡分級更新失敗（{failed}）。請到 ASC 手動填（全部「無／否」，結果 4+）。')
        report.append(f'年齡分級：寫入失敗，未寫入：{", ".join(sorted(patch))}；原本就一樣 {already} 題')
        return
    verb = '會寫入' if DRY else '已寫入'
    report.append(f'年齡分級：{verb} {len(written)} 題（{", ".join(written) or "無"}）；原本就一樣 {already} 題；'
                  f'ASC 不收而跳過：{", ".join(dropped) or "無"}。答案都是「無／否」，請到 ASC 確認結果是 4+')


def review_detail(app_id, vid, listing):
    r = call('GET', f'/v1/appStoreVersions/{vid}/appStoreReviewDetail', ok404=True, soft=True)
    d = (r or {}).get('data')
    want = {'notes': listing['reviewNotes'], 'demoAccountRequired': False}
    cur = (d or {}).get('attributes') or {}
    if listing.get('reviewContactEmail') and not cur.get('contactEmail'):
        want['contactEmail'] = listing['reviewContactEmail']
    if d:
        p = diff(cur, want)
        if p:
            write('PATCH', f'/v1/appStoreReviewDetails/{d["id"]}', {'data': {'type': 'appStoreReviewDetails',
                  'id': d['id'], 'attributes': p}}, '審查資訊：' + ', '.join(p))
    else:
        write('POST', '/v1/appStoreReviewDetails', {'data': {'type': 'appStoreReviewDetails', 'attributes': want,
              'relationships': {'appStoreVersion': {'data': {'type': 'appStoreVersions', 'id': vid}}}}}, '建立審查資訊')
    missing = [zh for k, zh in (('contactFirstName', '名字'), ('contactLastName', '姓氏'), ('contactPhone', '電話'))
               if not cur.get(k)]
    if missing:
        warning('App 審查的聯絡資訊還缺：' + '、'.join(missing) + '（這個流程不會代填）。請到 App Store Connect → 你的 App →'
                f' 版本頁最下面「App 審查資訊」→「聯絡資訊」填好：https://appstoreconnect.apple.com/apps/{app_id}/distribution/ios/version/inflight')
        report.append('審查備註：已填；聯絡資訊：還缺 ' + '、'.join(missing))
    else:
        report.append('審查備註：已填；聯絡資訊：已有')


def upload_screenshot(set_id, path, file_name):
    b = open(path, 'rb').read()
    r = call('POST', '/v1/appScreenshots', {'data': {'type': 'appScreenshots',
             'attributes': {'fileName': file_name, 'fileSize': len(b)},
             'relationships': {'appScreenshotSet': {'data': {'type': 'appScreenshotSets', 'id': set_id}}}}})['data']
    for op in r['attributes'].get('uploadOperations') or []:
        part = b[op['offset']:op['offset'] + op['length']]
        for attempt in range(4):
            req = urllib.request.Request(op['url'], method=op['method'], data=part,
                                         headers={h['name']: h['value'] for h in (op.get('requestHeaders') or [])})
            try:
                urllib.request.urlopen(req, timeout=120).read()
                break
            except (urllib.error.HTTPError, urllib.error.URLError) as e:
                if attempt == 3:
                    error(f'截圖 {file_name} 上傳失敗：{e}')
                time.sleep(2 ** (attempt + 1))
    call('PATCH', f'/v1/appScreenshots/{r["id"]}', {'data': {'type': 'appScreenshots', 'id': r['id'],
         'attributes': {'uploaded': True, 'sourceFileChecksum': hashlib.md5(b).hexdigest()}}})
    print('uploaded', file_name, r['id'])
    return r['id']


def shot_state(s):
    return (((s.get('attributes') or {}).get('assetDeliveryState') or {}).get('state'))


def screenshots(loc_ids, listing):
    types = listing['screenshots']['displayTypes']
    for loc in LOCALES:
        lid = loc_ids.get(loc)
        files = shot_files(loc)
        # 檔名帶 MD5 前 10 碼：重跑時靠檔名認出「這張已經傳過了」
        want = []
        for i, p in enumerate(files, 1):
            md5 = hashlib.md5(open(p, 'rb').read()).hexdigest()
            want.append((p, f'{loc}-{i:02d}-{md5[:10]}.png'))
        if not lid:
            print(f'[dry-run] {loc}：語言還沒建立，會上傳 {len(want)} 張截圖')
            continue
        sets = all_pages(f'/v1/appStoreVersionLocalizations/{lid}/appScreenshotSets?limit=50')
        sset = next((s for t in types for s in sets if s['attributes'].get('screenshotDisplayType') == t), None)
        if not sset:
            if DRY:
                print(f'[dry-run] {loc}：會建立 {types[0]} 截圖組，上傳 {len(want)} 張')
                continue
            for t in types:
                r = call('POST', '/v1/appScreenshotSets', {'data': {'type': 'appScreenshotSets',
                         'attributes': {'screenshotDisplayType': t},
                         'relationships': {'appStoreVersionLocalization': {'data': {
                             'type': 'appStoreVersionLocalizations', 'id': lid}}}}}, want_error=True)
                if r and '__error__' not in r:
                    sset = r['data']
                    break
                print('screenshot set', t, 'failed:', err_text(r or {}))
            if not sset:
                error(f'{loc} 建立 iPhone 6.9 吋截圖組失敗（試過 {", ".join(types)}）。')
        sid = sset['id']
        old = all_pages(f'/v1/appScreenshotSets/{sid}/appScreenshots?limit=50')
        by_name = {}
        for s in old:
            if shot_state(s) in ('COMPLETE', 'UPLOAD_COMPLETE'):
                by_name.setdefault(s['attributes'].get('fileName'), s)
        keep_ids = {by_name[n]['id'] for _, n in want if n in by_name}
        broken = [s for s in old if s['id'] not in keep_ids and shot_state(s) not in ('COMPLETE', 'UPLOAD_COMPLETE')]
        stale = [s for s in old if s['id'] not in keep_ids and s not in broken]
        todo = [(p, n) for p, n in want if n not in by_name]
        final_order = [by_name[n]['id'] if n in by_name else None for _, n in want]
        current_order = [s['id'] for s in old]
        # 只有 COMPLETE 算完成；之前傳過但還是 UPLOAD_COMPLETE 的保留（不重傳），但一樣要等它變 COMPLETE 才刪舊的
        kept_unfinished = {i for i in keep_ids if shot_state(next(s for s in old if s['id'] == i)) != 'COMPLETE'}
        if not todo and not stale and not broken and not kept_unfinished and current_order == final_order:
            report.append(f'截圖 {loc}：{len(want)} 張已經是最新的')
            continue
        room = MAX_SHOTS_PER_SET - len(keep_ids) - len(stale)
        early = max(0, len(todo) - room)
        if DRY:
            print(f'[dry-run] {loc}：截圖組 {sid}，會上傳 {len(todo)} 張、刪除舊的 {len(stale) + len(broken)} 張'
                  f'（其中 {early} 張要在上傳前先刪，因為一組最多 {MAX_SHOTS_PER_SET} 張）、保留 {len(keep_ids)} 張，然後排好順序')
            continue
        # 壞掉（沒傳完、FAILED）的先刪，它們本來就不會顯示
        for s in broken:
            call('DELETE', f'/v1/appScreenshots/{s["id"]}')
        # 一組最多 10 張。舊的 + 新的放不下時，只好在上傳前先刪舊截圖，而且只刪「剛好放得下」的張數，
        # 從排在最後面的開始刪（最不顯眼；商店頁前幾張維持原樣）。之後上傳失敗的話，這幾張就沒了，
        # 但其餘舊截圖還在，重跑會補齊。
        if early:
            warning(f'{loc} 截圖組已經有 {len(keep_ids) + len(stale)} 張（上限 {MAX_SHOTS_PER_SET}），'
                    f'要先刪掉排在最後的 {min(early, len(stale))} 張舊截圖才能上傳新的。上傳失敗的話請重跑。')
        while room < len(todo) and stale:
            s = stale.pop()  # 排在最後面的先刪
            call('DELETE', f'/v1/appScreenshots/{s["id"]}')
            room += 1
            print('deleted old screenshot before upload (set is full)', s['id'])
        new_ids = {}
        for p, n in todo:
            new_ids[n] = upload_screenshot(sid, p, n)
        # 等 Apple 處理完（全部 COMPLETE，包含保留下來的）才刪舊的
        deadline, pending = time.time() + 600, set(new_ids.values()) | kept_unfinished
        while pending and time.time() < deadline:
            time.sleep(5)
            for i in list(pending):
                st = shot_state(call('GET', f'/v1/appScreenshots/{i}')['data'])
                if st == 'COMPLETE':
                    pending.discard(i)
                elif st == 'FAILED':
                    error(f'{loc} 截圖處理失敗（{i}）。舊截圖沒有刪，請重跑。')
        if pending:
            warning(f'{loc} 有 {len(pending)} 張截圖 Apple 還在處理，這次先不刪舊截圖。過幾分鐘再跑一次就會整理好。')
            report.append(f'截圖 {loc}：已上傳，Apple 還在處理（請再跑一次）')
            continue
        for s in stale:
            call('DELETE', f'/v1/appScreenshots/{s["id"]}')
        order = [by_name[n]['id'] if n in by_name else new_ids[n] for _, n in want]
        call('PATCH', f'/v1/appScreenshotSets/{sid}/relationships/appScreenshots',
             {'data': [{'type': 'appScreenshots', 'id': i} for i in order]})
        report.append(f'截圖 {loc}：{len(want)} 張（新上傳 {len(todo)}，刪除舊的 {len(stale) + len(broken)}）')


def main():
    global DRY
    ap = argparse.ArgumentParser()
    ap.add_argument('--version', default='1.1.0')
    ap.add_argument('--no-screenshots', action='store_true')
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--check', action='store_true', help='只做離線檢查')
    ap.add_argument('--from-md', action='store_true', help='依 metadata.md 重新產生 listing.json 的文字欄位')
    args = ap.parse_args()
    if args.from_md:
        from_md()
        return
    listing = load_listing()
    errs = check(listing)
    if errs:
        error('上架資料檢查沒過：\n' + '\n'.join(errs))
    if args.check:
        for loc in LOCALES:
            L = listing['locales'][loc]
            print(loc, ', '.join(f'{f}={len(L[f])}/{lim}' for f, lim in LIMITS.items() if L.get(f)))
        print('reviewNotes', len(listing['reviewNotes']), '/', LIMITS['reviewNotes'])
        print('check ok')
        return
    if not re.fullmatch(r'\d+(\.\d+){1,2}', args.version):
        error(f'版本號格式不對：{args.version}（例如 1.1.0）')
    for k in ('ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_P8'):
        if not os.environ.get(k):
            error(f'缺少 GitHub Secret：{k}（到 GitHub → Settings → Secrets and variables → Actions 新增）')
    DRY = args.dry_run
    if DRY:
        report.append('只預覽：這次沒有寫入任何東西')

    app = find_app()
    app_id = app['id']
    v, released = ensure_version(app_id, args.version, listing)
    vid = (v or {}).get('id')
    # App 資訊的語言（名稱）先建，再建版本的語言：新增語言時 ASC 比較不會卡在「缺 App 名稱」
    info = pick_appinfo(app_id)
    if info:
        appinfo_localizations(info['id'], listing)
    loc_ids = version_localizations(vid, listing, released, args.version) if vid else {}
    if info:
        categories(info['id'], listing)
        age_rating(info['id'], listing)
    if vid:
        review_detail(app_id, vid, listing)
        if args.no_screenshots:
            report.append('截圖：這次沒勾「上傳截圖」，沒有動')
        else:
            screenshots(loc_ids, listing)
    report.append('沒有送審。還要手動：選建置版本、加入「完整版」內購、價格與供應狀況、App 隱私權問卷，'
                  f'送審前先確認：https://appstoreconnect.apple.com/apps/{app_id}/distribution/ios/version/inflight')
    notice('\n'.join(report))


if __name__ == '__main__':
    main()
