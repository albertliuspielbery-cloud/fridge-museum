# 雲端打包用：用 App Store Connect API 金鑰，自動準備「上架用」的簽名憑證和描述檔（不需要登記 iPhone 裝置）。
# 改自「星光小冒險」已在使用的 ci_sign.py，多了兩件事：App 識別碼（Bundle ID）不存在時會自動登記；
# 1.2.0 起會確認 App 識別碼已開啟 iCloud（CloudKit）和推播（Push Notifications）功能，沒開就用 API 開。
# 注意：iCloud 容器 iCloud.tw.starlight.fridgemuseum 的「建立」和「指派給 App 識別碼」Apple 沒有開放 API，
#       要在 developer.apple.com 手動做一次（步驟見 HANDOFF.md「1.2.0 iCloud 同步」）。沒指派的話，打包會因描述檔缺少容器而失敗。
# 1.3.0 起多一個「主畫面小工具」（widget extension，識別碼 <APP_BUNDLE_ID>.widget）：兩個識別碼都要登記、都開 App Groups
# 功能，各做一個描述檔（同一張憑證）。App Group group.tw.starlight.fridgemuseum 本身同樣沒有 API，要手動建立並在兩個
# 識別碼勾選（HANDOFF.md「1.3.0 主畫面小工具」）；描述檔裡沒有這個 App Group 時，這支程式會直接停下並說明怎麼做。
#
# 用法：
#   python3 ci/ci_sign.py <輸出資料夾>        準備憑證 + 描述檔（會先確認／登記 App 識別碼）
#   python3 ci/ci_sign.py --register-only     只確認／登記 App 識別碼（「準備 App 識別碼」工作流程用）
#
# 需要環境變數：ASC_KEY_ID、ASC_ISSUER_ID、ASC_KEY_P8（.p8 檔的文字內容）
# 可選環境變數：APP_BUNDLE_ID（預設 tw.starlight.fridgemuseum）、PROFILE_NAME（預設 FridgeMuseum AppStore CI）、
#             WIDGET_PROFILE_NAME（預設 FridgeMuseum Widget AppStore CI）
# 需要套件：pyjwt、cryptography
import base64
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BUNDLE = os.environ.get('APP_BUNDLE_ID') or 'tw.starlight.fridgemuseum'
PROFILE_NAME = os.environ.get('PROFILE_NAME') or 'FridgeMuseum AppStore CI'
# Apple 的 Identifier 名稱只接受英數字和空白，所以用英文名；App 顯示名稱「冰箱美術館」在 Info.plist。
BUNDLE_NAME = 'Fridge Museum'
ICLOUD_CONTAINER = 'iCloud.tw.starlight.fridgemuseum'
# 主畫面小工具（1.3.0）：widget extension 的識別碼與描述檔（project.yml 的 FridgeMuseumWidget：$(APP_BUNDLE_ID).widget）。
WIDGET_BUNDLE = BUNDLE + '.widget'
WIDGET_BUNDLE_NAME = 'Fridge Museum Widget'
WIDGET_PROFILE_NAME = os.environ.get('WIDGET_PROFILE_NAME') or 'FridgeMuseum Widget AppStore CI'
APP_GROUP = 'group.tw.starlight.fridgemuseum'
APP_GROUP_PORTAL = 'https://developer.apple.com/account/resources/identifiers/list/applicationGroup'
# App 識別碼需要的功能（App Store Connect API bundleIdCapabilities）。
# ICLOUD 的 ICLOUD_VERSION = XCODE_6 就是「Include CloudKit support」（Xcode 6 以後的 iCloud）。
# PUSH_NOTIFICATIONS：CloudKit 用無聲推播通知「別台裝置改了東西」（aps-environment）。
# APP_GROUPS（1.3.0）：App 和小工具共用 App Group 容器（widget.json + 作品小圖）。
CAPABILITIES = [
    ('ICLOUD', [{'key': 'ICLOUD_VERSION', 'options': [{'key': 'XCODE_6'}]}]),
    ('PUSH_NOTIFICATIONS', None),
    ('APP_GROUPS', None),
]
WIDGET_CAPABILITIES = [
    ('APP_GROUPS', None),
]
API = 'https://api.appstoreconnect.apple.com/v1'


def need_env():
    missing = [k for k in ('ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_P8') if not os.environ.get(k)]
    if missing:
        print('::error::缺少 GitHub Secrets：' + '、'.join(missing) + '（Settings → Secrets and variables → Actions）')
        raise SystemExit(1)
    if 'BEGIN PRIVATE KEY' not in os.environ['ASC_KEY_P8']:
        print('::error::ASC_KEY_P8 看起來不是 .p8 金鑰內容（請用記事本打開 AuthKey_XXXX.p8，整份複製貼上）')
        raise SystemExit(1)


def token():
    import jwt
    now = int(time.time())
    return jwt.encode({'iss': os.environ['ASC_ISSUER_ID'], 'iat': now, 'exp': now + 900, 'aud': 'appstoreconnect-v1'},
                      os.environ['ASC_KEY_P8'], algorithm='ES256',
                      headers={'kid': os.environ['ASC_KEY_ID'], 'typ': 'JWT'})


class ApiError(Exception):
    def __init__(self, code, msg):
        super().__init__(msg); self.code = code; self.msg = msg


def call(method, path, body=None, soft=False):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={'Authorization': 'Bearer ' + token(), 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req) as r:
            t = r.read()
            return json.loads(t) if t else {}
    except urllib.error.HTTPError as e:
        msg = e.read().decode(errors='replace')
        if soft:
            raise ApiError(e.code, msg)
        hint = ''
        if e.code == 401:
            hint = '（金鑰 ID、Issuer ID 或 .p8 內容不對，或金鑰已被撤銷）'
        elif e.code == 403:
            hint = '（這把 API 金鑰權限不夠，請用「管理（Admin）」權限的金鑰）'
        print(f'::error::App Store Connect API {method} {path.split("?")[0]} 失敗 {e.code}{hint}: {msg[:700]}')
        raise SystemExit(1)


def _created_days_ago(c):
    # API 沒有建立日期；上架憑證有效期 1 年，用到期日反推
    import datetime as dt
    exp = c['attributes'].get('expirationDate') or ''
    try:
        e = dt.datetime.fromisoformat(exp.replace('Z', '+00:00'))
    except ValueError:
        try:
            e = dt.datetime.strptime(exp, '%Y-%m-%dT%H:%M:%S.%f%z')
        except ValueError:
            return 0
    return 365 - (e - dt.datetime.now(dt.timezone.utc)).days


def create_dist_cert(body):
    """建立上架憑證。不主動刪舊憑證：同一個 Apple 帳號的其他 App（日本自駕道場、星光小冒險、冰箱美術館…）
    可能有 build 還在審查或 TestFlight，刪掉簽它的憑證會讓那個 build 變成「無效簽章」（ITMS-90035，2026-10-22 發生過）。
    只有 Apple 回報憑證數已滿（409）時，才刪「最舊、而且至少 CERT_MIN_AGE_DAYS（預設 14）天前建立」的一張再重試。"""
    min_age = int(os.environ.get('CERT_MIN_AGE_DAYS', '14'))
    try:
        return call('POST', '/certificates', body, soft=True)['data']
    except ApiError as e:
        if e.code != 409 or not any(w in e.msg.lower() for w in ('current distribution certificate', 'pending certificate request', 'maximum', 'limit')):
            print(f'::error::App Store Connect API POST /certificates {e.code}: {e.msg[:700]}')
            raise SystemExit(1)
        certs = call('GET', '/certificates?filter[certificateType]=DISTRIBUTION,IOS_DISTRIBUTION&limit=200')['data']
        certs.sort(key=lambda c: c['attributes'].get('expirationDate') or '')
        old = [c for c in certs if _created_days_ago(c) >= min_age]
        if not old:
            print('::error::上架憑證數量已達 Apple 上限，而且每一張都是 ' + str(min_age) + ' 天內建立的（可能有 App 正在審查或測試中），'
                  '為了不讓那些 build 變成無效簽章，這次先不刪。請過幾天再上傳。 Apple 訊息：' + e.msg[:300])
            raise SystemExit(1)
        print('憑證已滿，刪除最舊的一張（約 ' + str(_created_days_ago(old[0])) + ' 天前建立）：' + old[0]['id'])
        call('DELETE', '/certificates/' + old[0]['id'])
        return call('POST', '/certificates', body)['data']


def ensure_bundle_id(identifier=BUNDLE, name=BUNDLE_NAME, is_app=True):
    """回傳識別碼的 API id；不存在就用 POST /bundleIds 登記。"""
    q = urllib.parse.quote(identifier, safe='')
    found = [x for x in call('GET', f'/bundleIds?filter[identifier]={q}&limit=20')['data']
             if x['attributes']['identifier'] == identifier]
    if found:
        print(f'App 識別碼已存在：{identifier}')
        return found[0]['id']
    created = call('POST', '/bundleIds', {'data': {'type': 'bundleIds', 'attributes': {
        'identifier': identifier, 'name': name, 'platform': 'IOS'}}})['data']
    print(f'已登記新的 App 識別碼：{identifier}')
    if is_app:
        print(f'::notice::已登記 App 識別碼 {identifier}。下一步：到 https://appstoreconnect.apple.com/apps 用這個識別碼新增 App。')
    else:
        print(f'::notice::已登記小工具識別碼 {identifier}。請到 {APP_GROUP_PORTAL} 確認 App Group {APP_GROUP} 已建立，'
              f'並在這個識別碼的 App Groups 功能勾選它（HANDOFF.md「1.3.0 主畫面小工具」）。')
    return created['id']


def ensure_capabilities(bid, capabilities=CAPABILITIES, identifier=BUNDLE):
    """識別碼沒開的功能用 POST /bundleIdCapabilities 打開（已開的跳過）。描述檔是每次重做的，會帶上這些功能。"""
    have = {c['attributes'].get('capabilityType') for c in call('GET', f'/bundleIds/{bid}/bundleIdCapabilities')['data']}
    for ctype, settings in capabilities:
        if ctype in have:
            print(f'App 識別碼功能已開啟（{identifier}）：{ctype}')
            continue
        attrs = {'capabilityType': ctype}
        if settings:
            attrs['settings'] = settings
        call('POST', '/bundleIdCapabilities', {'data': {
            'type': 'bundleIdCapabilities', 'attributes': attrs,
            'relationships': {'bundleId': {'data': {'type': 'bundleIds', 'id': bid}}}}})
        print(f'已開啟 App 識別碼功能（{identifier}）：{ctype}')
    if not any(ctype == 'ICLOUD' for ctype, _ in capabilities):
        return
    print(f'::notice::iCloud 容器 {ICLOUD_CONTAINER} 要在 developer.apple.com 手動建立並指派給 {BUNDLE}'
          '（Apple 沒有開放 API；做過一次就好，步驟見 HANDOFF.md「1.2.0 iCloud 同步」）。沒指派的話，下一步打包會失敗。')


def prepare_signing(out, bid, widget_bid):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.hazmat.primitives.serialization import pkcs12
    from cryptography.x509.oid import NameOID

    os.makedirs(out, exist_ok=True)

    # 1. 清掉以前雲端建立的同名描述檔（App 和小工具的）
    for p in call('GET', '/profiles?limit=200')['data']:
        if p['attributes']['name'] in (PROFILE_NAME, WIDGET_PROFILE_NAME):
            call('DELETE', '/profiles/' + p['id'])

    # 2. 上架用憑證：每次新做一張（私鑰只存在這台雲端電腦）；不主動刪舊憑證，見 create_dist_cert()
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = x509.CertificateSigningRequestBuilder().subject_name(x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, 'FridgeMuseum CI'),
        x509.NameAttribute(NameOID.COUNTRY_NAME, 'TW')])).sign(key, hashes.SHA256())
    csr_b64 = base64.b64encode(csr.public_bytes(serialization.Encoding.DER)).decode()
    cert = create_dist_cert({'data': {'type': 'certificates', 'attributes': {
        'certificateType': 'DISTRIBUTION', 'csrContent': csr_b64}}})
    crt = x509.load_der_x509_certificate(base64.b64decode(cert['attributes']['certificateContent']))
    pw = secrets.token_hex(12)
    enc = (serialization.PrivateFormat.PKCS12.encryption_builder().kdf_rounds(50000)
           .key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC).hmac_hash(hashes.SHA1()).build(pw.encode()))
    with open(f'{out}/dist.p12', 'wb') as f:
        f.write(pkcs12.serialize_key_and_certificates(b'FridgeMuseum CI', key, crt, None, enc))
    with open(f'{out}/p12pass', 'w') as f:
        f.write(pw)

    # 3. 上架用描述檔（App Store）：App 和小工具各一個，同一張憑證
    app_uuid = create_profile(PROFILE_NAME, bid, cert['id'], BUNDLE)
    widget_uuid = create_profile(WIDGET_PROFILE_NAME, widget_bid, cert['id'], WIDGET_BUNDLE)
    print('簽名準備完成：憑證', cert['id'], '描述檔', PROFILE_NAME, app_uuid, '＋', WIDGET_PROFILE_NAME, widget_uuid)


def create_profile(name, bid, cert_id, identifier):
    """做一個 App Store 描述檔、裝到這台電腦，並確認裡面有 App Group（沒有就停下並說明，否則打包時才會看不懂地失敗）。"""
    prof = call('POST', '/profiles', {'data': {
        'type': 'profiles',
        'attributes': {'name': name, 'profileType': 'IOS_APP_STORE'},
        'relationships': {'bundleId': {'data': {'type': 'bundleIds', 'id': bid}},
                          'certificates': {'data': [{'type': 'certificates', 'id': cert_id}]}}}})['data']
    uuid = prof['attributes']['uuid']
    data = base64.b64decode(prof['attributes']['profileContent'])
    for d in ['~/Library/MobileDevice/Provisioning Profiles', '~/Library/Developer/Xcode/UserData/Provisioning Profiles']:
        d = os.path.expanduser(d)
        os.makedirs(d, exist_ok=True)
        with open(f'{d}/{uuid}.mobileprovision', 'wb') as f:
            f.write(data)
    check_app_group(data, identifier)
    return uuid


def check_app_group(profile_data, identifier):
    """描述檔（CMS 包著的 plist）的 Entitlements 要有 APP_GROUP。只在讀得懂描述檔時判斷；讀不懂就交給打包自己檢查。"""
    import plistlib
    a, b = profile_data.find(b'<?xml'), profile_data.find(b'</plist>')
    if a < 0 or b < 0:
        print(f'::warning::讀不到描述檔內容（{identifier}），略過 App Group 檢查')
        return
    try:
        ents = plistlib.loads(profile_data[a:b + len(b'</plist>')]).get('Entitlements', {})
    except Exception as e:  # noqa: BLE001 — 只是事前檢查
        print(f'::warning::描述檔內容解析失敗（{identifier}）：{e}，略過 App Group 檢查')
        return
    groups = ents.get('com.apple.security.application-groups') or []
    if APP_GROUP in groups:
        print(f'描述檔含 App Group（{identifier}）：{APP_GROUP}')
        return
    print(f'::error::{identifier} 的描述檔沒有 App Group {APP_GROUP}（主畫面小工具要用）。Apple 沒有開放 API 建立／指派 App Group，'
          f'請手動做一次：1) 打開 {APP_GROUP_PORTAL} 按「＋」→ App Groups → Description 填 Fridge Museum、'
          f'Identifier 填 {APP_GROUP} → Continue → Register。2) 到 https://developer.apple.com/account/resources/identifiers/list '
          f'分別點 {BUNDLE} 和 {WIDGET_BUNDLE} → 勾 App Groups → Configure（或 Edit）→ 勾 {APP_GROUP} → Continue → Save'
          f'（跳出「描述檔會失效」選 Confirm）。3) 再按一次上傳。詳見 HANDOFF.md「1.3.0 主畫面小工具」。'
          f'（描述檔目前的 App Groups：{groups or "無"}）')
    raise SystemExit(1)


def main():
    if len(sys.argv) != 2:
        print(__doc__ or '用法：python3 ci/ci_sign.py <輸出資料夾> | --register-only')
        raise SystemExit(2)
    need_env()
    bid = ensure_bundle_id()
    ensure_capabilities(bid)
    widget_bid = ensure_bundle_id(WIDGET_BUNDLE, WIDGET_BUNDLE_NAME, is_app=False)
    ensure_capabilities(widget_bid, WIDGET_CAPABILITIES, WIDGET_BUNDLE)
    if sys.argv[1] != '--register-only':
        prepare_signing(sys.argv[1], bid, widget_bid)


if __name__ == '__main__':
    main()
