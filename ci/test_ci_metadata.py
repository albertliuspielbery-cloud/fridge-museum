# 離線測試 ci_metadata.py 的流程（假的 App Store Connect，不連網）：python3 ci/test_ci_metadata.py
# 測：--dry-run 不寫入、第一次填好、重跑不再寫入、截圖組滿 10 張時的替換與排序、第一版不送 whatsNew、審查中不動、
#     iPad 13 吋截圖組（新增時 iPhone 那組不動）、check() 的截圖檢查、listing.json 舊的截圖格式
# 截圖用暫存資料夾裡的假 PNG（只有檔頭），不讀 appstore/screenshots/
import sys, os, re, json, struct, shutil, atexit, tempfile, itertools
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.update(ASC_KEY_ID='k', ASC_ISSUER_ID='i', ASC_KEY_P8='p')
import ci_metadata as M

M.time.sleep = lambda s: None

TMP = tempfile.mkdtemp(prefix='ci-metadata-test-')
atexit.register(shutil.rmtree, TMP, True)
IPHONE_OLD = {'displayTypes': ['APP_IPHONE_67']}  # listing.json 舊格式
IPAD_COUNT = 3
GROUPS = [{'dir': '', 'displayTypes': ['APP_IPHONE_67'], 'size': [1320, 2868], 'count': M.SHOT_COUNT},
          {'dir': 'ipad', 'displayTypes': ['APP_IPAD_PRO_3GEN_129'], 'size': [2064, 2752], 'count': IPAD_COUNT}]


def fake_png(path, size, tag, color=2):
    # PNG 檔頭 + IHDR（寬、高、色彩類型）；後面加 tag 讓每張的 MD5 不同
    os.makedirs(os.path.dirname(path), exist_ok=True)
    ihdr = struct.pack('>II5B', size[0], size[1], 8, color, 0, 0, 0)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + struct.pack('>I', 13) + b'IHDR' + ihdr + b'\0\0\0\0' + tag.encode())


for loc in M.LOCALES:
    for i in range(1, M.SHOT_COUNT + 1):
        fake_png(os.path.join(TMP, loc, f'{i:02d}.png'), (1320, 2868), f'{loc}-iphone-{i}')
    for i in range(1, IPAD_COUNT + 1):
        fake_png(os.path.join(TMP, loc, 'ipad', f'{i:02d}.png'), (2064, 2752), f'{loc}-ipad-{i}')
M.SHOTS_DIR = TMP
SHOTS = {'v': IPHONE_OLD}  # 測試用的 listing['screenshots']；其他欄位用真的 listing.json
_real_load = M.load_listing
M.load_listing = lambda: dict(_real_load(), screenshots=SHOTS['v'])
ids = itertools.count(100)
S = {
    'versions': {'v1': {'versionString': '1.0', 'appVersionState': 'PREPARE_FOR_SUBMISSION', 'appStoreState': 'PREPARE_FOR_SUBMISSION'}},
    'vlocs': {'L1': {'locale': 'zh-Hant', 'description': 'old'}},
    'ilocs': {'I1': {'locale': 'zh-Hant', 'name': '冰箱美術館', 'subtitle': None, 'privacyPolicyUrl': None}},
    'age': {k: None for k in M.load_listing()['ageRating']} | {'brandNewQuestion': None},
    'review': None,
    'sets': {}, 'shots': {}, 'order': {}, 'cats': {},
}
log = []


def fake_call(method, path, body=None, ok404=False, soft=False, want_error=False):
    if method != 'GET' and re.search(r'reviewSubmission|appStoreVersionSubmission', path, re.I):
        raise SystemExit('SUBMIT BLOCKED')
    p = path.split('?')[0]
    log.append((method, p))
    d = (body or {}).get('data') if isinstance(body, dict) else None
    if method == 'GET':
        if p == '/v1/apps':
            return {'data': [{'id': 'A', 'attributes': {'bundleId': M.BUNDLE, 'primaryLocale': 'zh-Hant'}}]}
        if p == '/v1/apps/A/appStoreVersions':
            return {'data': [{'id': k, 'attributes': v} for k, v in S['versions'].items()]}
        if re.fullmatch(r'/v1/appStoreVersions/\w+/appStoreVersionLocalizations', p):
            return {'data': [{'id': k, 'attributes': v} for k, v in S['vlocs'].items()]}
        if p == '/v1/apps/A/appInfos':
            return {'data': [{'id': 'INFO', 'attributes': {'state': 'PREPARE_FOR_SUBMISSION'}}]}
        if p == '/v1/appInfos/INFO/appInfoLocalizations':
            return {'data': [{'id': k, 'attributes': v} for k, v in S['ilocs'].items()]}
        if p.startswith('/v1/appInfos/INFO/') and p.endswith('Category'):
            c = S['cats'].get(p.rsplit('/', 1)[1])
            return {'data': {'id': c, 'type': 'appCategories'} if c else None}
        if p == '/v1/appInfos/INFO/ageRatingDeclaration':
            return {'data': {'id': 'AGE', 'attributes': dict(S['age'])}}
        if p.endswith('/appStoreReviewDetail'):
            return {'data': S['review']}
        m = re.fullmatch(r'/v1/appStoreVersionLocalizations/(\w+)/appScreenshotSets', p)
        if m:
            return {'data': [{'id': k, 'attributes': {'screenshotDisplayType': v['t']}} for k, v in S['sets'].items() if v['loc'] == m.group(1)]}
        m = re.fullmatch(r'/v1/appScreenshotSets/(\w+)/appScreenshots', p)
        if m:
            return {'data': [{'id': i, 'attributes': S['shots'][i]} for i in S['order'][m.group(1)]]}
        m = re.fullmatch(r'/v1/appScreenshots/(\w+)', p)
        if m:
            a = S['shots'][m.group(1)]
            a['assetDeliveryState'] = {'state': 'COMPLETE'}
            return {'data': {'id': m.group(1), 'attributes': a}}
        raise AssertionError('unhandled GET ' + p)
    if method == 'PATCH':
        m = re.fullmatch(r'/v1/appStoreVersions/(\w+)', p)
        if m:
            S['versions'][m.group(1)].update(d['attributes']); return {}
        m = re.fullmatch(r'/v1/appStoreVersionLocalizations/(\w+)', p)
        if m:
            S['vlocs'][m.group(1)].update(d['attributes']); return {}
        m = re.fullmatch(r'/v1/appInfoLocalizations/(\w+)', p)
        if m:
            S['ilocs'][m.group(1)].update(d['attributes']); return {}
        if p == '/v1/appInfos/INFO':
            for k, v in d['relationships'].items():
                S['cats'][k] = v['data']['id']
            return {}
        if p == '/v1/ageRatingDeclarations/AGE':
            if 'socialMedia' in d['attributes'] and not S.get('rejected'):
                S['rejected'] = True
                return {'__error__': 409, 'errors': [{'detail': 'nope', 'source': {'pointer': '/data/attributes/socialMedia'}}]}
            S['age'].update(d['attributes']); return {}
        if p.startswith('/v1/appStoreReviewDetails/'):
            S['review']['attributes'].update(d['attributes']); return {}
        m = re.fullmatch(r'/v1/appScreenshots/(\w+)', p)
        if m:
            S['shots'][m.group(1)].update(d['attributes'], assetDeliveryState={'state': 'UPLOAD_COMPLETE'}); return {}
        m = re.fullmatch(r'/v1/appScreenshotSets/(\w+)/relationships/appScreenshots', p)
        if m:
            S['order'][m.group(1)] = [x['id'] for x in body['data']]; return {}
        raise AssertionError('unhandled PATCH ' + p)
    if method == 'POST':
        n = f'N{next(ids)}'
        if p == '/v1/appStoreVersionLocalizations':
            S['vlocs'][n] = dict(d['attributes']); return {'data': {'id': n}}
        if p == '/v1/appStoreVersions':
            S['versions'][n] = dict(d['attributes'], appVersionState='PREPARE_FOR_SUBMISSION')
            return {'data': {'id': n, 'attributes': S['versions'][n]}}
        if p == '/v1/appInfoLocalizations':
            S['ilocs'][n] = dict(d['attributes']); return {'data': {'id': n}}
        if p == '/v1/appStoreReviewDetails':
            S['review'] = {'id': n, 'attributes': dict(d['attributes'])}; return {'data': S['review']}
        if p == '/v1/appScreenshotSets':
            S['sets'][n] = {'t': d['attributes']['screenshotDisplayType'], 'loc': d['relationships']['appStoreVersionLocalization']['data']['id']}
            S['order'][n] = []
            return {'data': {'id': n, 'attributes': {}}}
        if p == '/v1/appScreenshots':
            sid = d['relationships']['appScreenshotSet']['data']['id']
            S['shots'][n] = dict(d['attributes'], assetDeliveryState={'state': 'AWAITING_UPLOAD'})
            S['order'][sid].append(n)
            return {'data': {'id': n, 'attributes': {'uploadOperations': [
                {'method': 'PUT', 'url': 'https://up/x', 'offset': 0, 'length': d['attributes']['fileSize'], 'requestHeaders': [{'name': 'Content-Type', 'value': 'image/png'}]}]}}}
        raise AssertionError('unhandled POST ' + p)
    if method == 'DELETE':
        m = re.fullmatch(r'/v1/appScreenshots/(\w+)', p)
        del S['shots'][m.group(1)]
        for o in S['order'].values():
            if m.group(1) in o:
                o.remove(m.group(1))
        return {}
    raise AssertionError(method + p)


class R:
    def read(self): return b''
    def __enter__(self): return self
    def __exit__(self, *a): pass


M.call = fake_call
M.urllib.request.urlopen = lambda req, timeout=0: R()


def run(*argv):
    sys.argv = ['x', *argv]
    log.clear(); M.report.clear(); M.DRY = False
    try:
        M.main()
    except SystemExit as e:
        print('EXIT', e.code)
        assert e.code in (0, None), f'ci_metadata exited with {e.code}'
    return [x for x in log if x[0] != 'GET']


print('--- dry run'); w = run('--dry-run'); print('writes:', w); assert not w
print('--- first run'); w = run(); print(len(w), 'writes')
assert S['versions']['v1']['versionString'] == '1.1.0'
assert 'whatsNew' not in [k for v in S['vlocs'].values() for k in v]
assert S['cats'] == {'primaryCategory': 'PHOTO_AND_VIDEO', 'secondaryCategory': 'LIFESTYLE'}
assert S['age']['gambling'] is False and S['age']['socialMedia'] is None
print('--- age retry run'); run()
# simulate old screenshots in zh set: add 7 old ones to test 10-cap
print('--- second run (should be no writes)'); w = run(); print('writes:', w); assert not w, w
zh_set = next(k for k, v in S['sets'].items() if S['vlocs'][v['loc']]['locale'] == 'zh-Hant')
for i in range(5):
    n = f'OLD{i}'; S['shots'][n] = {'fileName': f'old{i}.png', 'assetDeliveryState': {'state': 'COMPLETE'}}; S['order'][zh_set].insert(0, n)
# change one file name to force 1 re-upload
first = S['order'][zh_set][5]; S['shots'][first]['fileName'] = 'stale.png'
print('--- third run with 11 shots in zh set'); w = run(); print(w)
assert len(S['order'][zh_set]) == M.SHOT_COUNT and all(S['shots'][i]['fileName'].startswith('zh-Hant-0') for i in S['order'][zh_set])
assert [S['shots'][i]['fileName'][8:10] for i in S['order'][zh_set]] == [f'{i:02d}' for i in range(1, M.SHOT_COUNT + 1)], [S['shots'][i]['fileName'] for i in S['order'][zh_set]]
print('--- fourth run no writes'); w = run(); assert not w, w
print('--- kept UPLOAD_COMPLETE screenshot: waited for, nothing re-uploaded or deleted')
k = S['order'][zh_set][2]; S['shots'][k]['assetDeliveryState'] = {'state': 'UPLOAD_COMPLETE'}
w = run(); assert ('GET', f'/v1/appScreenshots/{k}') in log, log
assert not [x for x in w if x[0] in ('POST', 'DELETE')], w
assert S['shots'][k]['assetDeliveryState']['state'] == 'COMPLETE'
print('--- iPad group added: iPad sets created and filled, iPhone sets untouched')
SHOTS['v'] = GROUPS
iphone_sets = {k: list(S['order'][k]) for k, v in S['sets'].items() if v['t'] == 'APP_IPHONE_67'}
iphone_shots = {i: dict(S['shots'][i]) for o in iphone_sets.values() for i in o}
assert len(iphone_sets) == 2, S['sets']
w = run(); print(w)
ipad_sets = {k: v for k, v in S['sets'].items() if v['t'] == 'APP_IPAD_PRO_3GEN_129'}
assert len(ipad_sets) == 2, S['sets']
for k, v in ipad_sets.items():
    loc = S['vlocs'][v['loc']]['locale']
    names = [S['shots'][i]['fileName'] for i in S['order'][k]]
    assert [n[:-15] for n in names] == [f'{loc}-ipad-{i:02d}' for i in range(1, IPAD_COUNT + 1)], names
for k, o in iphone_sets.items():
    assert S['order'][k] == o, (k, S['order'][k], o)
assert all(S['shots'][i]['fileName'] == a['fileName'] for i, a in iphone_shots.items())
assert not [x for x in w if x[0] == 'DELETE'], w
assert not [x for x in w if any(k in x[1] for k in iphone_sets)], w
assert len([x for x in w if x == ('POST', '/v1/appScreenshots')]) == 2 * IPAD_COUNT, w
assert any('iPad 13 吋' in r for r in M.report), M.report
print('--- rerun with both groups: no writes'); w = run(); assert not w, w
print('--- changed iPad file: only that one re-uploaded in the iPad set')
fake_png(os.path.join(TMP, 'en-US', 'ipad', '02.png'), (2064, 2752), 'en-US-ipad-2-new')
w = run(); print(w)
assert len([x for x in w if x == ('POST', '/v1/appScreenshots')]) == 1, w
assert len([x for x in w if x[0] == 'DELETE']) == 1, w
assert not [x for x in w if any(k in x[1] for k in iphone_sets)], w
print('--- check(): screenshot errors per group name the device')

shot_errs = lambda: [e for e in M.check(M.load_listing()) if '截圖' in e or 'PNG' in e or '透明' in e]
assert not shot_errs(), shot_errs()
p_ipad = os.path.join(TMP, 'zh-Hant', 'ipad', '03.png')
os.remove(p_ipad)
e = shot_errs(); assert len(e) == 1 and 'iPad 13 吋' in e[0], e
fake_png(p_ipad, (1320, 2868), 'wrong size')
e = shot_errs(); assert len(e) == 1 and 'iPad 13 吋' in e[0] and '2064×2752' in e[0], e
fake_png(p_ipad, (2064, 2752), 'alpha', color=6)
e = shot_errs(); assert len(e) == 1 and '透明' in e[0], e
fake_png(p_ipad, (2064, 2752), 'zh-Hant-ipad-3')
os.remove(os.path.join(TMP, 'en-US', '07.png'))
e = shot_errs(); assert len(e) == 1 and 'iPhone 6.9 吋' in e[0], e
print('--- old listing format: one iPhone group, SHOT_COUNT shots, iPad files ignored')
SHOTS['v'] = IPHONE_OLD
g = M.shot_groups(M.load_listing())
assert len(g) == 1 and g[0]['dir'] == '' and g[0]['count'] == M.SHOT_COUNT and g[0]['size'] == M.SHOT_SIZE, g
os.remove(p_ipad)
e = shot_errs(); assert len(e) == 1 and 'en-US' in e[0] and '07.png' in e[0], e
fake_png(os.path.join(TMP, 'en-US', '07.png'), (1320, 2868), 'en-US-iphone-7')
assert not shot_errs(), shot_errs()
assert M.shot_name('zh-Hant', g[0], 1, 'abcdef0123456789') == 'zh-Hant-01-abcdef0123.png'
assert M.shot_name('zh-Hant', M.shot_groups({'screenshots': GROUPS})[1], 1, 'abcdef0123456789') == 'zh-Hant-ipad-01-abcdef0123.png'
print('--- old format rerun: no writes, iPad sets left alone'); w = run(); assert not w, w
print('--- released app: whatsNew sent')
S['versions']['v0'] = {'versionString': '1.0.5', 'appStoreState': 'READY_FOR_SALE', 'appVersionState': 'READY_FOR_DISTRIBUTION'}
w = run('--no-screenshots', '--version', M.parse_metadata_md()['whatsNewVersion']); print(w); assert any('whatsNew' in v for v in S['vlocs'].values())
print('--- whatsNew not sent when --version differs from metadata.md section 6')
for v in S['vlocs'].values():
    v['whatsNew'] = 'keep me'
w = run('--no-screenshots', '--version', '1.2.0')
assert S['versions']['v1']['versionString'] == '1.2.0'
assert all(v['whatsNew'] == 'keep me' for v in S['vlocs'].values())
assert any('沒有送（版本號不符）' in r for r in M.report)
S['versions']['v1']['versionString'] = '1.1.0'
print('--- releaseType notice for existing AFTER_APPROVAL version (not changed)')
S['versions']['v1']['releaseType'] = 'AFTER_APPROVAL'
w = run('--no-screenshots'); assert S['versions']['v1']['releaseType'] == 'AFTER_APPROVAL'
assert not [x for x in w if x == ('PATCH', '/v1/appStoreVersions/v1')], w
print('--- in review: exits 0 without writes')
S['versions']['v1']['appVersionState'] = 'WAITING_FOR_REVIEW'; S['versions']['v1']['appStoreState'] = 'WAITING_FOR_REVIEW'
w = run(); assert not w
print('--- no editable version: new one created with releaseType MANUAL')
S['versions']['v1']['appVersionState'] = S['versions']['v1']['appStoreState'] = 'READY_FOR_DISTRIBUTION'
S['versions']['v1']['versionString'] = '1.1.0'
w = run('--no-screenshots', '--version', '1.2.0')
nv = [v for k, v in S['versions'].items() if k.startswith('N')]
assert len(nv) == 1 and nv[0]['releaseType'] == 'MANUAL' and nv[0]['versionString'] == '1.2.0', nv
print('ALL OK')
