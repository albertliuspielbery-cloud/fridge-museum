# 離線測試 ci_metadata.py 的流程（假的 App Store Connect，不連網）：python3 ci/test_ci_metadata.py
# 測：--dry-run 不寫入、第一次填好、重跑不再寫入、截圖組滿 10 張時的替換與排序、第一版不送 whatsNew、審查中不動
import sys, os, re, json, itertools
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.update(ASC_KEY_ID='k', ASC_ISSUER_ID='i', ASC_KEY_P8='p')
import ci_metadata as M

M.time.sleep = lambda s: None
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
assert len(S['order'][zh_set]) == 6 and all(S['shots'][i]['fileName'].startswith('zh-Hant-0') for i in S['order'][zh_set])
assert [S['shots'][i]['fileName'][8:10] for i in S['order'][zh_set]] == ['01', '02', '03', '04', '05', '06'], [S['shots'][i]['fileName'] for i in S['order'][zh_set]]
print('--- fourth run no writes'); w = run(); assert not w, w
print('--- kept UPLOAD_COMPLETE screenshot: waited for, nothing re-uploaded or deleted')
k = S['order'][zh_set][2]; S['shots'][k]['assetDeliveryState'] = {'state': 'UPLOAD_COMPLETE'}
w = run(); assert ('GET', f'/v1/appScreenshots/{k}') in log, log
assert not [x for x in w if x[0] in ('POST', 'DELETE')], w
assert S['shots'][k]['assetDeliveryState']['state'] == 'COMPLETE'
print('--- released app: whatsNew sent')
S['versions']['v0'] = {'versionString': '1.0.5', 'appStoreState': 'READY_FOR_SALE', 'appVersionState': 'READY_FOR_DISTRIBUTION'}
w = run('--no-screenshots'); print(w); assert any('whatsNew' in v for v in S['vlocs'].values())
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
