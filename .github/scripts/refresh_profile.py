"""App Store Connect API ile güncel bir App Store profili oluşturur.

Uygulamaya yeni yetenek (Apple ile giriş, bildirim) eklenince eski profil
geçersiz olur. Bu betik her derlemede imza sertifikasıyla eşleşen yeni bir
profil üretir; böylece profili elle indirip GitHub'a koymak gerekmez.

Kullanım: refresh_profile.py <sertifika_seri_no> <çıktı_klasörü> <bundle_id>...
Her bundle için <klasör>/<bundle_id>.mobileprovision yazar.
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


def ensure_bundle(identifier: str) -> str:
    """Bundle ID'yi bulur; yoksa oluşturur (eklenti için ilk derlemede gerekir)."""
    found = call("GET", f"/bundleIds?filter[identifier]={identifier}&limit=200")["data"]
    found = [b for b in found if b["attributes"]["identifier"] == identifier]
    if found:
        return found[0]["id"]
    created = call("POST", "/bundleIds", {
        "data": {
            "type": "bundleIds",
            "attributes": {"identifier": identifier, "name": "Box " + identifier.split(".")[-1].title(), "platform": "IOS"},
        }
    })
    print(f"Bundle ID oluşturuldu: {identifier}")
    return created["data"]["id"]


def main():
    global AUTH
    serial, out_dir, bundles = norm_serial(sys.argv[1]), sys.argv[2], sys.argv[3:]
    AUTH = token()

    certs = call("GET", "/certificates?filter[certificateType]=DISTRIBUTION,IOS_DISTRIBUTION&limit=200")["data"]
    match = [c for c in certs if norm_serial(c["attributes"].get("serialNumber", "")) == serial]
    if not match:
        raise SystemExit("p12'deki sertifika App Store Connect'te bulunamadı (seri no eşleşmedi).")
    cert_id = match[0]["id"]

    # Önceki derlemelerin oluşturduğu profilleri temizle (aynı ad tekrar kullanılamıyor).
    old = call("GET", "/profiles?filter[profileType]=IOS_APP_STORE&limit=200")["data"]
    for p in old:
        if p["attributes"]["name"].startswith(PREFIX):
            call("DELETE", f"/profiles/{p['id']}")

    stamp = time.strftime('%Y%m%d%H%M%S')
    for bundle in bundles:
        bundle_id = ensure_bundle(bundle)
        name = f"{PREFIX} {stamp} {bundle.split('.')[-1]}"
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
        with open(os.path.join(out_dir, bundle + ".mobileprovision"), "wb") as f:
            f.write(base64.b64decode(content))
        print(f"Yeni profil oluşturuldu: {name}")


if __name__ == "__main__":
    main()
