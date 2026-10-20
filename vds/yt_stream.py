"""
Box anında dinleme servisi (VDS).

/stream?v=VIDEO&exp=UNIX&sig=HMAC  ->  YouTube ses akışını parça parça (Range destekli) iletir.
İmza mevcut /get ile aynıdır: HMAC-SHA256(YT_API_KEY, "VIDEO:exp").
Telefon şarkının tamamı inmeden ilk saniyeleri çalmaya başlar; ileri sarma da çalışır.
"""
import asyncio
import hashlib
import hmac
import os
import re
import shutil
import sys
import time
from urllib.parse import parse_qs, urlparse

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse
from starlette.background import BackgroundTask

KEY = os.environ.get("YT_API_KEY", "").encode()
VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")
YTDLP = [shutil.which("yt-dlp")] if shutil.which("yt-dlp") else [sys.executable, "-m", "yt_dlp"]
EXTRA = os.environ.get("YTDLP_EXTRA_ARGS", "").split()

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
client = httpx.AsyncClient(timeout=httpx.Timeout(20.0, read=60.0), follow_redirects=True, http2=False)

_cache: dict[str, tuple[str, float]] = {}
FORMATS = {
    "audio": "140/bestaudio[ext=m4a]/bestaudio",
    # Sesli ve görüntülü tek dosya (Range ile oynatılabilir); çoğunlukla 360p.
    "video": "18/b[ext=mp4][vcodec!=none][acodec!=none]",
}
_locks: dict[str, asyncio.Lock] = {}


def check_signature(v: str, exp: str, sig: str) -> None:
    if not KEY:
        raise HTTPException(500, "Sunucu anahtarı ayarlı değil.")
    if not VIDEO_ID.match(v or ""):
        raise HTTPException(400, "Geçersiz video.")
    try:
        expires = int(exp)
    except (TypeError, ValueError):
        raise HTTPException(400, "Geçersiz bağlantı.")
    if expires < time.time():
        raise HTTPException(403, "Bağlantının süresi doldu.")
    good = hmac.new(KEY, f"{v}:{expires}".encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(good, sig or ""):
        raise HTTPException(403, "Geçersiz imza.")


async def audio_url(v: str, fresh: bool = False, kind: str = "audio") -> str:
    """yt-dlp ile akışın doğrudan adresini bulur (birkaç saat önbellekte tutulur)."""
    now = time.time()
    key = f"{kind}:{v}"
    cached = _cache.get(key)
    if cached and not fresh and cached[1] > now:
        return cached[0]
    lock = _locks.setdefault(key, asyncio.Lock())
    async with lock:
        cached = _cache.get(key)
        if cached and not fresh and cached[1] > time.time():
            return cached[0]
        proc = await asyncio.create_subprocess_exec(
            *YTDLP, *EXTRA, "-f", FORMATS.get(kind, FORMATS["audio"]), "-g", "--no-playlist", "--no-warnings",
            f"https://www.youtube.com/watch?v={v}",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        try:
            out, err = await asyncio.wait_for(proc.communicate(), timeout=45)
        except asyncio.TimeoutError:
            proc.kill()
            raise HTTPException(504, "Şarkı hazırlanamadı (zaman aşımı).")
        url = out.decode().strip().splitlines()[0] if out.strip() else ""
        if proc.returncode != 0 or not url.startswith("http"):
            raise HTTPException(502, "Bu şarkı şu an çalınamıyor.")
        expire = parse_qs(urlparse(url).query).get("expire", [str(int(time.time()) + 3600)])[0]
        _cache[key] = (url, min(float(expire) - 300, time.time() + 5 * 3600))
        if len(_cache) > 2000:
            for key in sorted(_cache, key=lambda k: _cache[k][1])[:500]:
                _cache.pop(key, None)
        return url


@app.get("/stream/health")
async def health(v: str = ""):
    """?v=VIDEO ile yt-dlp'nin bu şarkıyı kaç ms'de hazırladığını gösterir (teşhis için)."""
    if v and VIDEO_ID.match(v):
        started = time.time()
        try:
            await audio_url(v)
            return {"ok": True, "cached": len(_cache), "resolve_ms": int((time.time() - started) * 1000)}
        except HTTPException as e:
            return {"ok": False, "error": e.detail}
    return {"ok": True, "cached": len(_cache)}


@app.api_route("/stream", methods=["GET", "HEAD"])
async def stream(request: Request, v: str = "", exp: str = "", sig: str = "", kind: str = "audio", warm: str = ""):
    check_signature(v, exp, sig)
    kind = "video" if kind == "video" else "audio"
    if warm:
        # Uygulama sıradaki şarkıları önceden ısıtır: adres hazır olsun, veri gönderme.
        await audio_url(v, kind=kind)
        return JSONResponse({"ok": True})

    headers = {}
    if "range" in request.headers:
        headers["Range"] = request.headers["range"]

    for attempt in range(2):
        url = await audio_url(v, fresh=attempt > 0, kind=kind)
        upstream = await client.send(client.build_request(request.method, url, headers=headers), stream=True)
        if upstream.status_code in (403, 404, 410) and attempt == 0:
            await upstream.aclose()  # adresin süresi dolmuş: yenisini al
            continue
        break

    if upstream.status_code >= 400:
        await upstream.aclose()
        return JSONResponse({"detail": "Şarkı akışı alınamadı."}, status_code=502)

    out_headers = {"Accept-Ranges": "bytes", "Cache-Control": "private, max-age=3600"}
    for name in ("content-length", "content-range", "last-modified", "etag"):
        if name in upstream.headers:
            out_headers[name.title()] = upstream.headers[name]

    return StreamingResponse(
        upstream.aiter_raw(65536),
        status_code=upstream.status_code,
        headers=out_headers,
        media_type="video/mp4" if kind == "video" else "audio/mp4",
        background=BackgroundTask(upstream.aclose),
    )
