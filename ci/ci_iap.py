# 雲端用：在 App Store Connect 建好／補齊 App 內購買項目「完整版」（非消耗型、一次買斷）
# 參考星光小冒險 app/ci_iap.py 的做法。可以重複執行：已經建好、設定一樣的部分不會再動。
#   商品代號 tw.starlight.fridgemuseum.full，參考名稱 Full Version
#   名稱與說明：繁體中文（完整版）、英文（Full Version）
#   價格：台灣為基準地區 NT$190，其他地區用 Apple 自動換算的等值價格
#   家人共享：開啟（開了就不能再關，擁有者已同意）
#   銷售地區：台灣、香港、美國、加拿大、英國、澳洲、新加坡（不含歐盟、中國大陸）
#   審查用截圖：有給檔案才上傳（跟星光一樣，不會自動產生假的截圖）
# 不會送審，也不會改 App 本身的銷售地區。第一次送審時，要在 App 版本頁面的「App 內購買項目」把它加進去。
# 用法：python3 ci/ci_iap.py [審查截圖.png]
# 環境變數：ASC_KEY_ID、ASC_ISSUER_ID、ASC_KEY_P8（必要）；APP_BUNDLE_ID（可選）；
#           FORCE_PRICE=1（可選：已經有別的價格時，強制改回 NT$190，會取代整個價格排程，包含早鳥價）
import os, sys, json, time, hashlib, urllib.request, urllib.error

sys.stdout.reconfigure(encoding='utf-8')  # 中文註解訊息；不靠執行環境的預設編碼

BUNDLE = os.environ.get('APP_BUNDLE_ID') or 'tw.starlight.fridgemuseum'
PRODUCT_ID = 'tw.starlight.fridgemuseum.full'
REF_NAME = 'Full Version'
PRICE_TWD = 190
BASE_TERRITORY = 'TWN'
TERRITORIES = ['TWN', 'HKG', 'USA', 'CAN', 'GBR', 'AUS', 'SGP']
TERRITORY_ZH = {'TWN': '台灣', 'HKG': '香港', 'USA': '美國', 'CAN': '加拿大', 'GBR': '英國', 'AUS': '澳洲', 'SGP': '新加坡'}
# App Store Connect 限制：名稱 35 字、說明 55 字以內
LOCALIZATIONS = {
    'zh-Hant': ('完整版', '畫作不限張數、勞作不限件數，全家共享，一次買斷'),
    'en-US': ('Full Version', 'Unlimited drawings and crafts for the family, one-time.'),
}
# 用詞照 DECISIONS.md §三：「勞作不限件數」，不要寫「AI 去背無限次」
for _loc, (_n, _d) in LOCALIZATIONS.items():
    assert len(_n) <= 35 and len(_d) <= 55, (_loc, len(_n), len(_d))
REVIEW_NOTE = (
    'Non-consumable "Full Version" (one-time purchase, Family Sharing on). Free tier: 3 drawings per day and 3 crafts '
    'in total can be kept (Hang It Up or Save to Photos). After that, the paywall sheet appears when keeping another '
    'artwork; it shows the StoreKit price, a "not a subscription" note, and Restore Purchases. To see it: take and keep '
    '4 drawings on the same day. Editing is never blocked.')
SHOT = sys.argv[1] if len(sys.argv) > 1 else ''
FORCE_PRICE = os.environ.get('FORCE_PRICE') == '1'
API = 'https://api.appstoreconnect.apple.com'
LOCKED_STATES = ('WAITING_FOR_REVIEW', 'IN_REVIEW', 'APPROVED', 'PENDING_BINARY_APPROVAL', 'READY_FOR_SALE')


def esc(s):
    # GitHub 註解指令裡的換行、百分比要跳脫
    return s.replace('%', '%25').replace('\r', '').replace('\n', '%0A')


def error(msg):
    print('::error title=App 內購買項目::' + esc(msg))
    raise SystemExit(1)


def warning(msg):
    print('::warning title=App 內購買項目::' + esc(msg))


for k in ('ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_P8'):
    if not os.environ.get(k):
        error(f'缺少 GitHub Secret：{k}（到 GitHub → Settings → Secrets and variables → Actions 新增）')

import jwt  # noqa: E402  (pyjwt + cryptography；workflow 會先安裝)


def token():
    now = int(time.time())
    return jwt.encode({'iss': os.environ['ASC_ISSUER_ID'], 'iat': now, 'exp': now + 900, 'aud': 'appstoreconnect-v1'},
                      os.environ['ASC_KEY_P8'], algorithm='ES256', headers={'kid': os.environ['ASC_KEY_ID'], 'typ': 'JWT'})


def call(method, path, body=None, ok404=False, soft=False):
    """soft=True：失敗時只回傳 None（給「先查再決定」的讀取用），不中止。"""
    url = path if path.startswith('http') else API + path
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={'Authorization': 'Bearer ' + token(), 'Content-Type': 'application/json'})
    for attempt in range(4):
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


def all_pages(path):
    out, url = [], path
    while url:
        r = call('GET', url)
        out += r.get('data', [])
        url = (r.get('links') or {}).get('next')
    return out


report = []

# 0. 找 App
apps = [a for a in call('GET', f'/v1/apps?filter[bundleId]={BUNDLE}')['data'] if a['attributes']['bundleId'] == BUNDLE]
if not apps:
    error(f'在 App Store Connect 找不到套件識別碼 {BUNDLE} 的 App。請先到 App Store Connect →「App」→「＋」→「新增 App」建立 App 紀錄，再重新執行。')
app_id = apps[0]['id']
print('App', BUNDLE, app_id)

# 1. 商品本身（沒有就建立）
have = {x['attributes']['productId']: x for x in all_pages(f'/v1/apps/{app_id}/inAppPurchasesV2?limit=200')}
if PRODUCT_ID in have:
    iap = have[PRODUCT_ID]
    print('IAP exists', iap['id'])
else:
    iap = call('POST', '/v2/inAppPurchases', {'data': {'type': 'inAppPurchases', 'attributes': {
        'name': REF_NAME, 'productId': PRODUCT_ID, 'inAppPurchaseType': 'NON_CONSUMABLE',
        'reviewNote': REVIEW_NOTE, 'familySharable': True},
        'relationships': {'app': {'data': {'type': 'apps', 'id': app_id}}}}})['data']
    report.append('已建立商品 ' + PRODUCT_ID)
    print('IAP created', iap['id'])
iid = iap['id']
a = iap.get('attributes') or {}
if a.get('inAppPurchaseType') not in (None, 'NON_CONSUMABLE'):
    error(f'{PRODUCT_ID} 已經存在，但類型是 {a.get("inAppPurchaseType")}，不是「非消耗型」。商品代號不能重複使用，請聯絡開發者。')

state0 = a.get('state')
if state0 in LOCKED_STATES:
    # 已送審／上架的商品：設定改不了，只回報狀態（重跑不會失敗）
    print(f'::notice title=App 內購買項目::完整版目前狀態 {state0}，已送審或上架，不再修改設定。')
    raise SystemExit(0)

# 2. 參考名稱、家人共享、審查備註
patch = {}
if a.get('name') != REF_NAME:
    patch['name'] = REF_NAME
if not a.get('familySharable'):
    patch['familySharable'] = True  # 開了就不能關（擁有者已同意）
if a.get('reviewNote') != REVIEW_NOTE:
    patch['reviewNote'] = REVIEW_NOTE
if patch:
    call('PATCH', f'/v2/inAppPurchases/{iid}', {'data': {'type': 'inAppPurchases', 'id': iid, 'attributes': patch}})
    if 'familySharable' in patch:
        report.append('已開啟家人共享（之後不能關閉）')
report.append('家人共享：開啟')

# 3. 名稱、說明（繁體中文、英文）
locs = {l['attributes']['locale']: l for l in call('GET', f'/v2/inAppPurchases/{iid}/inAppPurchaseLocalizations?limit=50')['data']}
for locale, (name, desc) in LOCALIZATIONS.items():
    cur = locs.get(locale)
    if cur and (cur['attributes'].get('name'), cur['attributes'].get('description')) == (name, desc):
        continue
    if cur:
        call('PATCH', f'/v1/inAppPurchaseLocalizations/{cur["id"]}', {'data': {'type': 'inAppPurchaseLocalizations',
             'id': cur['id'], 'attributes': {'name': name, 'description': desc}}})
    else:
        call('POST', '/v1/inAppPurchaseLocalizations', {'data': {'type': 'inAppPurchaseLocalizations',
             'attributes': {'locale': locale, 'name': name, 'description': desc},
             'relationships': {'inAppPurchaseV2': {'data': {'type': 'inAppPurchases', 'id': iid}}}}})
    print('localization', locale, 'set')
report.append('名稱：完整版／Full Version')

# 4. 價格：台灣為基準 NT$190，其他地區 Apple 自動換算（只設定基準地區的價格點）
pts = all_pages(f'/v2/inAppPurchases/{iid}/pricePoints?filter[territory]={BASE_TERRITORY}&limit=200')
if not pts:
    error('拿不到台灣的價格點清單，請稍後再試。')
pts.sort(key=lambda x: abs(float(x['attributes']['customerPrice']) - PRICE_TWD))
pp = pts[0]
got = float(pp['attributes']['customerPrice'])
if got != PRICE_TWD:
    error(f'找不到 NT${PRICE_TWD} 的價格點（最接近的是 NT${got:g}）。')

current_pp_ids, base = set(), None
sched = call('GET', f'/v2/inAppPurchases/{iid}/iapPriceSchedule', ok404=True, soft=True)
if sched and sched.get('data'):
    sid = sched['data']['id']
    bt = call('GET', f'/v1/inAppPurchasePriceSchedules/{sid}/baseTerritory', ok404=True, soft=True)
    base = ((bt or {}).get('data') or {}).get('id')
    mp = call('GET', f'/v1/inAppPurchasePriceSchedules/{sid}/manualPrices?include=inAppPurchasePricePoint&limit=50', ok404=True, soft=True)
    for price in (mp or {}).get('data', []):
        rel = ((price.get('relationships') or {}).get('inAppPurchasePricePoint') or {}).get('data') or {}
        if rel.get('id'):
            current_pp_ids.add(rel['id'])

price_ok = base == BASE_TERRITORY and pp['id'] in current_pp_ids
if price_ok:
    report.append(f'價格：NT${PRICE_TWD}（台灣為基準，其他地區自動換算）')
elif current_pp_ids and not FORCE_PRICE:
    warning(f'完整版已經有別的價格設定（可能是早鳥價或手動改過），這次沒有動它。要改回 NT${PRICE_TWD}，請手動執行時勾選「強制改回 NT${PRICE_TWD}」。')
    report.append('價格：保留 App Store Connect 上現有的設定')
else:
    call('POST', '/v1/inAppPurchasePriceSchedules', {'data': {'type': 'inAppPurchasePriceSchedules', 'relationships': {
        'inAppPurchase': {'data': {'type': 'inAppPurchases', 'id': iid}},
        'baseTerritory': {'data': {'type': 'territories', 'id': BASE_TERRITORY}},
        'manualPrices': {'data': [{'type': 'inAppPurchasePrices', 'id': '${p1}'}]}}},
        'included': [{'type': 'inAppPurchasePrices', 'id': '${p1}', 'attributes': {'startDate': None},
                      'relationships': {'inAppPurchaseV2': {'data': {'type': 'inAppPurchases', 'id': iid}},
                                        'inAppPurchasePricePoint': {'data': {'type': 'inAppPurchasePricePoints', 'id': pp['id']}}}}]})
    report.append(f'價格：已設定 NT${PRICE_TWD}（台灣為基準，其他地區自動換算）')

# 5. 銷售地區：只有這 7 個（不含歐盟、中國大陸），之後 Apple 新增的地區也不自動上架
want = set(TERRITORIES)
have_terr, new_terr = None, None
av = call('GET', f'/v2/inAppPurchases/{iid}/inAppPurchaseAvailability', ok404=True, soft=True)
if av and av.get('data'):
    new_terr = (av['data'].get('attributes') or {}).get('availableInNewTerritories')
    ts = call('GET', f'/v1/inAppPurchaseAvailabilities/{av["data"]["id"]}/availableTerritories?limit=200', ok404=True, soft=True)
    if ts is not None:
        have_terr = {t['id'] for t in ts.get('data', [])}
if have_terr != want or new_terr is not False:
    call('POST', '/v1/inAppPurchaseAvailabilities', {'data': {'type': 'inAppPurchaseAvailabilities',
         'attributes': {'availableInNewTerritories': False}, 'relationships': {
             'inAppPurchase': {'data': {'type': 'inAppPurchases', 'id': iid}},
             'availableTerritories': {'data': [{'type': 'territories', 'id': t} for t in TERRITORIES]}}}})
report.append('銷售地區：' + '、'.join(TERRITORY_ZH[t] for t in TERRITORIES))

# 6. 審查用截圖（購買畫面）：有給檔案才上傳；沒有就提醒擁有者
shot = call('GET', f'/v2/inAppPurchases/{iid}/appStoreReviewScreenshot', ok404=True, soft=True)
sd = shot and shot.get('data')
if sd and ((sd.get('attributes') or {}).get('assetDeliveryState') or {}).get('state') not in ('COMPLETE', 'UPLOAD_COMPLETE'):
    call('DELETE', f'/v1/inAppPurchaseAppStoreReviewScreenshots/{sd["id"]}')
    sd = None
if not sd and SHOT and os.path.isfile(SHOT):
    b = open(SHOT, 'rb').read()
    r = call('POST', '/v1/inAppPurchaseAppStoreReviewScreenshots', {'data': {'type': 'inAppPurchaseAppStoreReviewScreenshots',
             'attributes': {'fileName': os.path.basename(SHOT), 'fileSize': len(b)},
             'relationships': {'inAppPurchaseV2': {'data': {'type': 'inAppPurchases', 'id': iid}}}}})['data']
    for op in r['attributes']['uploadOperations']:
        part = b[op['offset']:op['offset'] + op['length']]
        req = urllib.request.Request(op['url'], method=op['method'], data=part,
                                     headers={h['name']: h['value'] for h in op['requestHeaders']})
        urllib.request.urlopen(req, timeout=120).read()
    call('PATCH', f'/v1/inAppPurchaseAppStoreReviewScreenshots/{r["id"]}', {'data': {
        'type': 'inAppPurchaseAppStoreReviewScreenshots', 'id': r['id'],
        'attributes': {'uploaded': True, 'sourceFileChecksum': hashlib.md5(b).hexdigest()}}})
    report.append('審查截圖：已上傳 ' + os.path.basename(SHOT))
elif sd:
    report.append('審查截圖：已經有了')
else:
    warning('還缺「審查用截圖」：請在 iPhone 上打開購買畫面（PaywallView）截圖，'
            '存成 ci/iap_review.png 推上來後重跑這個流程；或直接到 App Store Connect →「App 內購買項目」→「完整版」→「審查資訊」上傳。'
            '沒有截圖，商品會停在「缺少元資料」，不能送審。')
    report.append('審查截圖：還沒有（見上面的提醒）')

st = call('GET', f'/v2/inAppPurchases/{iid}')['data']['attributes'].get('state')
report.append(f'目前狀態：{st}')
print(PRODUCT_ID, 'ok', st)
print('::notice title=App 內購買項目::' + esc('\n'.join(report)))
