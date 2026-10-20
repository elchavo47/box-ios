"""
Box anında dinleme ve YouTube Music arama servisi (VDS).

/stream/music/search|radio|video  ->  YouTube Music araması, şarkı radyosu ve şarkının klibi
(ytmusicapi ile; YouTube Data API kotası harcamaz). İmza: HMAC-SHA256(YT_API_KEY, "music:exp").

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
import threading
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

try:
    from ytmusicapi import YTMusic
except ImportError:  # kurulu değilse arama uçları 503 döner, akış çalışmaya devam eder
    YTMusic = None

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
client = httpx.AsyncClient(timeout=httpx.Timeout(20.0, read=60.0), follow_redirects=True, http2=False)

_cache: dict[str, tuple[str, float]] = {}
FORMATS = {
    "audio": "140/bestaudio[ext=m4a]/bestaudio",
    # Sesli ve görüntülü tek dosya (Range ile oynatılabilir); çoğunlukla 360p.
    # Sessiz H.264 görüntü (ses uygulamadaki ana oynatıcıdan gelir). 360p → 480p → 720p.
    "video": "134/135/136/18/bv*[vcodec^=avc1][height<=720]",
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
    if kind == "video" and YTMusic is not None:
        # Şarkı hali (kapak resmi) yerine gerçek klibi oynat; klip yoksa 404.
        try:
            clip = await clip_for(v)
        except HTTPException:
            clip = v
        if clip is None:
            return JSONResponse({"detail": "Bu şarkının klibi yok."}, status_code=404)
        v = clip

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


# ---------------- YouTube Music ----------------

_local = threading.local()
_music_cache: dict[str, tuple[object, float]] = {}


def ytm():
    """Her iş parçacığına bir YTMusic (requests oturumu iş parçacıkları arasında paylaşılmasın)."""
    inst = getattr(_local, "ytm", None)
    if inst is None:
        inst = YTMusic(language="tr", location="TR")
        _local.ytm = inst
    return inst


def check_music_signature(exp: str, sig: str) -> None:
    if not KEY:
        raise HTTPException(500, "Sunucu anahtarı ayarlı değil.")
    try:
        expires = int(exp)
    except (TypeError, ValueError):
        raise HTTPException(400, "Geçersiz istek.")
    if expires < time.time() or expires > time.time() + 3600:
        raise HTTPException(403, "İsteğin süresi doldu.")
    good = hmac.new(KEY, f"music:{expires}".encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(good, sig or ""):
        raise HTTPException(403, "Geçersiz imza.")
    if YTMusic is None:
        raise HTTPException(503, "ytmusicapi kurulu değil.")


def square(thumbs) -> str | None:
    """En büyük kapağı al; YouTube Music kare kapaklarını 544 px'e büyüt."""
    if not thumbs:
        return None
    best = max(thumbs, key=lambda t: (t.get("width") or 0) * (t.get("height") or 0))
    url = best.get("url") or ""
    if "googleusercontent.com" in url or "ggpht.com" in url:
        url = re.sub(r"=w\d+-h\d+[^/]*$", "=w544-h544-l90-rj", url)
    return url or None


def seconds(text) -> int:
    if isinstance(text, (int, float)):
        return int(text)
    parts = [int(p) for p in str(text or "").split(":") if p.isdigit()]
    total = 0
    for p in parts:
        total = total * 60 + p
    return total


def track(item: dict) -> dict | None:
    vid = item.get("videoId")
    if not vid or not VIDEO_ID.match(vid):
        return None
    artists = ", ".join(a.get("name", "") for a in (item.get("artists") or []) if a.get("name") and a.get("id") is not None) \
        or ", ".join(a.get("name", "") for a in (item.get("artists") or []) if a.get("name"))
    album = item.get("album")
    return {
        "id": vid,
        "title": item.get("title") or "",
        "channel": artists,
        "album": album.get("name") if isinstance(album, dict) else None,
        "thumbnail": square(item.get("thumbnails") or item.get("thumbnail")),
        "duration": item.get("duration_seconds") or seconds(item.get("duration") or item.get("length")),
        "kind": "video" if item.get("resultType") == "video" or item.get("videoType") == "MUSIC_VIDEO_TYPE_OMV" else "song",
    }


async def cached(key: str, ttl: float, fn):
    hit = _music_cache.get(key)
    if hit and hit[1] > time.time():
        return hit[0]
    lock = _locks.setdefault("m:" + key, asyncio.Lock())
    async with lock:
        hit = _music_cache.get(key)
        if hit and hit[1] > time.time():
            return hit[0]
        try:
            value = await asyncio.wait_for(asyncio.to_thread(fn), timeout=20)
        except asyncio.TimeoutError:
            raise HTTPException(504, "YouTube Music yanıt vermedi.")
        except HTTPException:
            raise
        except Exception as e:  # ytmusicapi hataları
            raise HTTPException(502, f"YouTube Music hatası: {type(e).__name__}")
        _music_cache[key] = (value, time.time() + ttl)
        if len(_music_cache) > 3000:
            for k in sorted(_music_cache, key=lambda k: _music_cache[k][1])[:800]:
                _music_cache.pop(k, None)
        return value


@app.get("/stream/music/search")
async def music_search(q: str = "", limit: int = 20, filter: str = "songs", exp: str = "", sig: str = ""):
    check_music_signature(exp, sig)
    q = q.strip()[:200]
    if not q:
        raise HTTPException(400, "Arama metni gerekli.")
    limit = max(1, min(40, limit))
    kind = filter if filter in ("songs", "videos") else "songs"

    def run():
        out, seen = [], set()
        for item in ytm().search(q, filter=kind, limit=limit):
            t = track(item)
            if t and t["id"] not in seen:
                seen.add(t["id"])
                out.append(t)
        return out[:limit]

    return {"ok": True, "results": await cached(f"s:{kind}:{limit}:{q.lower()}", 6 * 3600, run)}


@app.get("/stream/music/radio")
async def music_radio(v: str = "", limit: int = 30, exp: str = "", sig: str = ""):
    check_music_signature(exp, sig)
    if not VIDEO_ID.match(v or ""):
        raise HTTPException(400, "Geçersiz video.")
    limit = max(5, min(50, limit))

    def run():
        data = ytm().get_watch_playlist(videoId=v, limit=limit, radio=True)
        out = []
        for item in data.get("tracks") or []:
            t = track(item)
            if t and t["id"] != v:
                out.append(t)
        return out

    return {"ok": True, "results": await cached(f"r:{v}:{limit}", 12 * 3600, run)}


@app.get("/stream/music/video")
async def music_video(v: str = "", exp: str = "", sig: str = ""):
    """Şarkının klibi: şarkı zaten klipse kendisi, değilse YouTube Music'teki karşılığı (yoksa null)."""
    check_music_signature(exp, sig)
    if not VIDEO_ID.match(v or ""):
        raise HTTPException(400, "Geçersiz video.")

    return {"ok": True, "video": await clip_for(v)}


async def clip_for(v: str):
    def run():
        tracks = ytm().get_watch_playlist(videoId=v, limit=1).get("tracks") or []
        first = tracks[0] if tracks else {}
        if first.get("videoType") == "MUSIC_VIDEO_TYPE_OMV":
            return v
        counterpart = first.get("counterpart") or {}
        cid = counterpart.get("videoId")
        if cid and VIDEO_ID.match(cid):
            return cid
        # Karşılık bilgisi yoksa: aynı ad ve sanatçıyla klip ara.
        title = (first.get("title") or "").lower()
        artist = ((first.get("artists") or [{}])[0].get("name") or "")
        if title:
            for item in ytm().search(f"{first.get('title')} {artist}", filter="videos", limit=5):
                if title[:20] in (item.get("title") or "").lower() and item.get("videoId"):
                    return item["videoId"]
        return None

    return await cached(f"v:{v}", 24 * 3600, run)


@app.get("/stream/music/health")
async def music_health():
    return {"ok": YTMusic is not None, "cached": len(_music_cache)}
