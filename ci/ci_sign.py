# 雲端打包用：用 App Store Connect API 金鑰，自動準備「上架用」的簽名憑證和描述檔（不需要登記 iPhone 裝置）。
# 改自「星光小冒險」已在使用的 ci_sign.py，多了一件事：App 識別碼（Bundle ID）不存在時會自動登記。
#
# 用法：
#   python3 ci/ci_sign.py <輸出資料夾>        準備憑證 + 描述檔（會先確認／登記 App 識別碼）
#   python3 ci/ci_sign.py --register-only     只確認／登記 App 識別碼（「準備 App 識別碼」工作流程用）
#
# 需要環境變數：ASC_KEY_ID、ASC_ISSUER_ID、ASC_KEY_P8（.p8 檔的文字內容）
# 可選環境變數：APP_BUNDLE_ID（預設 tw.starlight.fridgemuseum）、PROFILE_NAME（預設 FridgeMuseum AppStore CI）
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


def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={'Authorization': 'Bearer ' + token(), 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req) as r:
            t = r.read()
            return json.loads(t) if t else {}
    except urllib.error.HTTPError as e:
        msg = e.read().decode(errors='replace')
        hint = ''
        if e.code == 401:
            hint = '（金鑰 ID、Issuer ID 或 .p8 內容不對，或金鑰已被撤銷）'
        elif e.code == 403:
            hint = '（這把 API 金鑰權限不夠，請用「管理（Admin）」權限的金鑰）'
        print(f'::error::App Store Connect API {method} {path.split("?")[0]} 失敗 {e.code}{hint}: {msg[:700]}')
        raise SystemExit(1)


def ensure_bundle_id():
    """回傳 App 識別碼的 API id；不存在就用 POST /bundleIds 登記。"""
    q = urllib.parse.quote(BUNDLE, safe='')
    found = [x for x in call('GET', f'/bundleIds?filter[identifier]={q}&limit=20')['data']
             if x['attributes']['identifier'] == BUNDLE]
    if found:
        print(f'App 識別碼已存在：{BUNDLE}')
        return found[0]['id']
    created = call('POST', '/bundleIds', {'data': {'type': 'bundleIds', 'attributes': {
        'identifier': BUNDLE, 'name': BUNDLE_NAME, 'platform': 'IOS'}}})['data']
    print(f'已登記新的 App 識別碼：{BUNDLE}')
    print(f'::notice::已登記 App 識別碼 {BUNDLE}。下一步：到 https://appstoreconnect.apple.com/apps 用這個識別碼新增 App。')
    return created['id']


def prepare_signing(out, bid):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.hazmat.primitives.serialization import pkcs12
    from cryptography.x509.oid import NameOID

    os.makedirs(out, exist_ok=True)

    # 1. 清掉以前雲端建立的同名描述檔
    for p in call('GET', '/profiles?limit=200')['data']:
        if p['attributes']['name'] == PROFILE_NAME:
            call('DELETE', '/profiles/' + p['id'])

    # 2. 上架用憑證：每次新做一張（私鑰只存在這台雲端電腦），舊的只留最新一張，避免超過 Apple 的數量上限。
    #    注意：同一個開發者帳號的其他 App（例如星光小冒險）的雲端打包也是每次重做，所以互相不影響已上傳的版本。
    certs = call('GET', '/certificates?filter[certificateType]=DISTRIBUTION,IOS_DISTRIBUTION&limit=200')['data']
    certs.sort(key=lambda c: c['attributes'].get('expirationDate') or '')
    for c in (certs[:-1] if len(certs) >= 2 else []):
        call('DELETE', '/certificates/' + c['id'])
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = x509.CertificateSigningRequestBuilder().subject_name(x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, 'FridgeMuseum CI'),
        x509.NameAttribute(NameOID.COUNTRY_NAME, 'TW')])).sign(key, hashes.SHA256())
    csr_b64 = base64.b64encode(csr.public_bytes(serialization.Encoding.DER)).decode()
    cert = call('POST', '/certificates', {'data': {'type': 'certificates', 'attributes': {
        'certificateType': 'DISTRIBUTION', 'csrContent': csr_b64}}})['data']
    crt = x509.load_der_x509_certificate(base64.b64decode(cert['attributes']['certificateContent']))
    pw = secrets.token_hex(12)
    enc = (serialization.PrivateFormat.PKCS12.encryption_builder().kdf_rounds(50000)
           .key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC).hmac_hash(hashes.SHA1()).build(pw.encode()))
    with open(f'{out}/dist.p12', 'wb') as f:
        f.write(pkcs12.serialize_key_and_certificates(b'FridgeMuseum CI', key, crt, None, enc))
    with open(f'{out}/p12pass', 'w') as f:
        f.write(pw)

    # 3. 上架用描述檔（App Store）
    prof = call('POST', '/profiles', {'data': {
        'type': 'profiles',
        'attributes': {'name': PROFILE_NAME, 'profileType': 'IOS_APP_STORE'},
        'relationships': {'bundleId': {'data': {'type': 'bundleIds', 'id': bid}},
                          'certificates': {'data': [{'type': 'certificates', 'id': cert['id']}]}}}})['data']
    uuid = prof['attributes']['uuid']
    data = base64.b64decode(prof['attributes']['profileContent'])
    for d in ['~/Library/MobileDevice/Provisioning Profiles', '~/Library/Developer/Xcode/UserData/Provisioning Profiles']:
        d = os.path.expanduser(d)
        os.makedirs(d, exist_ok=True)
        with open(f'{d}/{uuid}.mobileprovision', 'wb') as f:
            f.write(data)
    print('簽名準備完成：憑證', cert['id'], '描述檔', PROFILE_NAME, uuid)


def main():
    if len(sys.argv) != 2:
        print(__doc__ or '用法：python3 ci/ci_sign.py <輸出資料夾> | --register-only')
        raise SystemExit(2)
    need_env()
    bid = ensure_bundle_id()
    if sys.argv[1] != '--register-only':
        prepare_signing(sys.argv[1], bid)


if __name__ == '__main__':
    main()
