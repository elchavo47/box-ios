"""App Store Connect API ile güncel bir App Store profili oluşturur.

Uygulamaya yeni yetenek (Apple ile giriş, bildirim) eklenince eski profil
geçersiz olur. Bu betik her derlemede imza sertifikasıyla eşleşen yeni bir
profil üretir; böylece profili elle indirip GitHub'a koymak gerekmez.

Kullanım: refresh_profile.py <bundle_id> <sertifika_seri_no> <çıktı.mobileprovision>
Ortam: APPSTORE_KEY_ID, APPSTORE_ISSUER_ID, APPSTORE_KEY_PATH
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt  # PyJWT

API = "https://api.appstoreconnect.apple.com/v1"
PREFIX = "Box CI"


def token() -> str:
    with open(os.environ["APPSTORE_KEY_PATH"], "rb") as f:
        key = f.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["APPSTORE_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": os.environ["APPSTORE_KEY_ID"], "typ": "JWT"},
    )


AUTH = None


def call(method: str, path: str, body=None):
    url = path if path.startswith("http") else API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + AUTH)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:600]
        raise SystemExit(f"{method} {path} -> {e.code}: {detail}")


def norm_serial(s: str) -> str:
    return s.strip().upper().lstrip("0")


def main():
    global AUTH
    bundle, serial, out = sys.argv[1], norm_serial(sys.argv[2]), sys.argv[3]
    AUTH = token()

    ids = call("GET", f"/bundleIds?filter[identifier]={bundle}&limit=200")["data"]
    ids = [b for b in ids if b["attributes"]["identifier"] == bundle]
    if not ids:
        raise SystemExit(f"Bundle ID bulunamadı: {bundle}")
    bundle_id = ids[0]["id"]

    certs = call("GET", "/certificates?filter[certificateType]=DISTRIBUTION,IOS_DISTRIBUTION&limit=200")["data"]
    match = [c for c in certs if norm_serial(c["attributes"].get("serialNumber", "")) == serial]
    if not match:
        raise SystemExit("p12'deki sertifika App Store Connect'te bulunamadı (seri no eşleşmedi).")
    cert_id = match[0]["id"]

    # Önceki derlemelerin oluşturduğu profilleri temizle (aynı ad tekrar kullanılamıyor).
    old = call("GET", f"/profiles?filter[profileType]=IOS_APP_STORE&limit=200")["data"]
    for p in old:
        if p["attributes"]["name"].startswith(PREFIX):
            call("DELETE", f"/profiles/{p['id']}")

    name = f"{PREFIX} {time.strftime('%Y%m%d%H%M%S')}"
    created = call("POST", "/profiles", {
        "data": {
            "type": "profiles",
            "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
                "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
            },
        }
    })
    content = created["data"]["attributes"]["profileContent"]
    with open(out, "wb") as f:
        f.write(base64.b64decode(content))
    print(f"Yeni profil oluşturuldu: {name}")


if __name__ == "__main__":
    main()
