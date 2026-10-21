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
import logging
import traceback
from urllib.parse import parse_qs, urlparse

log = logging.getLogger("yt-stream")

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
        started = time.time()
        try:
            out, err = await asyncio.wait_for(proc.communicate(), timeout=45)
        except asyncio.TimeoutError:
            proc.kill()
            stat("resolve", False, (time.time() - started) * 1000)
            raise HTTPException(504, "Şarkı hazırlanamadı (zaman aşımı).")
        url = out.decode().strip().splitlines()[0] if out.strip() else ""
        if proc.returncode != 0 or not url.startswith("http"):
            stat("resolve", False, (time.time() - started) * 1000)
            raise HTTPException(502, "Bu şarkı şu an çalınamıyor.")
        stat("resolve", True, (time.time() - started) * 1000)
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
    return {"ok": True, "cached": len(_cache), "ytmusicapi": YTMUSIC_VERSION or None}


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
STARTED = time.time()
# Panelin VDS takibi için sayaçlar (uç adı -> istek, hata, toplam ms)
STATS: dict[str, dict[str, float]] = {}


try:
    from importlib.metadata import version as _pkg_version
    YTMUSIC_VERSION = _pkg_version("ytmusicapi") if YTMusic is not None else ""
except Exception:
    YTMUSIC_VERSION = ""

LAST_ERROR: dict = {}


def note_error(where: str, error: BaseException, query: str = "") -> None:
    """Son YouTube Music hatası (panelde görünür)."""
    frame = ""
    tb = traceback.extract_tb(error.__traceback__) if error.__traceback__ else []
    if tb:
        last = tb[-1]
        frame = f" @ {os.path.basename(last.filename)}:{last.lineno} {last.name}"
    LAST_ERROR.clear()
    LAST_ERROR.update({"at": int(time.time()), "where": where, "type": type(error).__name__, "detail": (str(error)[:120] + frame)[:220], "query": query[:80]})


def safe_parse(fn, item):
    """Tek bir sonucun ayrıştırılması patlarsa yalnızca o sonucu atla."""
    try:
        return fn(item)
    except Exception as e:
        note_error("parse/" + fn.__name__, e)
        log.warning("music parse %s failed\n%s", fn.__name__, traceback.format_exc(limit=3))
        return None


def ytm_call(method: str, *args, languages=("en", "tr"), **kwargs):
    """ytmusicapi çağrısı: bir dilde ayrıştırma patlarsa diğeriyle dene."""
    last = None
    for language in languages:
        try:
            return getattr(ytm(language), method)(*args, **kwargs)
        except Exception as e:
            last = e
            note_error(method, e, str(args[0]) if args else "")
            log.warning("ytmusic %s (%s) failed\n%s", method, language, traceback.format_exc(limit=4))
    raise last


def part(where: str, fn, default=None):
    """Sayfanın bir bölümü bozuksa (YouTube yapıyı değiştirdi) sayfanın tamamı gitmesin."""
    try:
        return fn()
    except Exception as e:
        note_error(where, e)
        log.warning("music part %s failed\n%s", where, traceback.format_exc(limit=3))
        return [] if default is None else default


def stat(name: str, ok: bool, ms: float) -> None:
    s = STATS.setdefault(name, {"n": 0, "err": 0, "ms": 0.0})
    s["n"] += 1
    s["ms"] += ms
    if not ok:
        s["err"] += 1


SUPPORTED_HL = {"ar", "cs", "de", "en", "es", "fr", "hi", "it", "ja", "ko", "nl", "pt", "ru", "tr", "ur", "zh_CN", "zh_TW"}


def ytm(language: str = "en"):
    """Her iş parçacığına bir YTMusic (requests oturumu iş parçacıkları arasında paylaşılmasın).

    Arama/sanatçı/albüm ayrıştırması ytmusicapi'nin İngilizce bölüm başlıklarıyla en sağlam çalışır
    (Türkçe arayüzde "songs" filtresi boş/KeyError dönüyor). Bölge her zaman TR kalır; böylece
    sonuçlar Türkiye'ye göre gelir. Kullanıcıya başlık gösterilen uçlar (ruh hali, listeler) "tr" kullanır.
    """
    cache = getattr(_local, "ytm", None)
    if not isinstance(cache, dict):
        cache = {}
        _local.ytm = cache
    inst = cache.get(language)
    if inst is None:
        inst = YTMusic(language=language, location="TR")
        cache[language] = inst
    return inst


SEARCH_TYPES = {"songs": "song", "videos": "video", "artists": "artist", "albums": "album"}


def safe_search(q: str, kind: str, limit: int) -> list:
    """Filtreli arama; boş dönerse ya da ayrıştırma patlarsa filtresiz aramadan süz."""
    want = SEARCH_TYPES.get(kind)
    for language in ("en", "tr"):
        try:
            items = ytm(language).search(q, filter=kind, limit=limit)
            if items:
                return items
        except Exception as e:
            note_error("search/" + kind, e, q)
            log.warning("music search %s/%s failed for %r\n%s", kind, language, q, traceback.format_exc(limit=4))
    try:
        items = ytm("en").search(q, limit=max(limit, 20))
        return [i for i in items if not want or i.get("resultType") == want]
    except Exception:
        log.warning("music search (unfiltered) failed for %r\n%s", q, traceback.format_exc(limit=4))
        raise


def check_music_signature(exp: str, sig: str, require_music: bool = True) -> None:
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
    if require_music and YTMusic is None:
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
    artist_id = next((a.get("id") for a in (item.get("artists") or []) if a.get("id")), None)
    return {
        "id": vid,
        "title": item.get("title") or "",
        "channel": artists,
        "album": album.get("name") if isinstance(album, dict) else (album if isinstance(album, str) else None),
        "album_id": album.get("id") if isinstance(album, dict) else None,
        "artist_id": artist_id,
        "thumbnail": square(item.get("thumbnails") or item.get("thumbnail")),
        "duration": item.get("duration_seconds") or seconds(item.get("duration") or item.get("length")),
        "kind": "video" if item.get("resultType") == "video" or item.get("videoType") == "MUSIC_VIDEO_TYPE_OMV" else "song",
    }


async def cached(key: str, ttl: float, fn):
    hit = _music_cache.get(key)
    if hit and hit[1] > time.time():
        stat("music_cache_hit", True, 0)
        return hit[0]
    lock = _locks.setdefault("m:" + key, asyncio.Lock())
    async with lock:
        hit = _music_cache.get(key)
        if hit and hit[1] > time.time():
            return hit[0]
        started = time.time()
        try:
            value = await asyncio.wait_for(asyncio.to_thread(fn), timeout=20)
        except asyncio.TimeoutError:
            stat("music", False, (time.time() - started) * 1000)
            raise HTTPException(504, "YouTube Music yanıt vermedi.")
        except HTTPException:
            raise
        except Exception as e:  # ytmusicapi hataları
            stat("music", False, (time.time() - started) * 1000)
            raise HTTPException(502, f"YouTube Music hatası: {type(e).__name__}")
        stat("music", True, (time.time() - started) * 1000)
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
    kind = filter if filter in ("songs", "videos", "albums", "artists", "playlists") else "songs"

    def run():
        out, seen = [], set()
        for item in safe_search(q, kind, limit):
            t = safe_parse(track, item) if kind in ("songs", "videos") else safe_parse(search_item, item)
            if t and t["id"] not in seen:
                seen.add(t["id"])
                out.append(t)
        return out[:limit]

    return {"ok": True, "results": await cached(f"s:{kind}:{limit}:{q.lower()}", 6 * 3600, run)}


@app.get("/stream/music/searchall")
async def music_search_all(q: str = "", exp: str = "", sig: str = ""):
    """YouTube Music'teki gibi karışık arama: en iyi sonuç ve şarkı, video, albüm, sanatçı, liste."""
    check_music_signature(exp, sig)
    q = q.strip()[:200]
    if not q:
        raise HTTPException(400, "Arama metni gerekli.")

    def run():
        items = []
        try:
            items = ytm("en").search(q, limit=20)
        except Exception:
            log.warning("music searchall failed for %r\n%s", q, traceback.format_exc(limit=4))
            try:
                items = ytm("tr").search(q, limit=20)
            except Exception as e:
                # Karışık arama ayrıştırılamıyor (YouTube yapıyı değiştirdi): türlere göre ayrı ayrı topla.
                note_error("searchall", e, q)
                log.warning("music searchall (tr) failed for %r\n%s", q, traceback.format_exc(limit=4))
                items = []
                for kind in ("artists", "songs", "videos", "albums", "playlists"):
                    items += part("searchall/" + kind, lambda kind=kind: safe_search(q, kind, 6 if kind != "songs" else 15))
        top, out, seen = None, [], set()
        in_card = False
        for item in items:
            category = item.get("category")
            parsed = safe_parse(search_item, item)
            if not parsed:
                continue
            key = parsed["type"] + ":" + parsed["id"]
            if key in seen:
                continue
            seen.add(key)
            if top is None and (category or "").lower() in ("top result", "en iyi sonuç"):
                top = parsed
                top["children"] = []
                in_card = True
                continue
            # En iyi sonuç kartının içindeki şarkılar kategorisiz gelir (YouTube Music'te kartın altındaki 3 şarkı).
            if in_card and not category and parsed["type"] in ("song", "video") and len(top["children"]) < 4:
                top["children"].append(parsed)
                continue
            in_card = False
            out.append(parsed)
        # Sonuçta şarkı yoksa (nadir) şarkı filtresiyle tamamla.
        if not any(i["type"] == "song" for i in out):
            for item in part("searchall/songs", lambda: safe_search(q, "songs", 10)):
                t = safe_parse(track, item)
                if t and "song:" + t["id"] not in seen:
                    t["type"] = "song"
                    seen.add("song:" + t["id"])
                    out.append(t)
        return {"top": top, "items": out}

    return {"ok": True, **(await cached(f"sa:{q.lower()}", 6 * 3600, run))}


@app.get("/stream/music/radio")
async def music_radio(v: str = "", limit: int = 30, exp: str = "", sig: str = ""):
    check_music_signature(exp, sig)
    if not VIDEO_ID.match(v or ""):
        raise HTTPException(400, "Geçersiz video.")
    limit = max(5, min(50, limit))

    def run():
        data = ytm_call("get_watch_playlist", videoId=v, limit=limit, radio=True)
        out = []
        for item in data.get("tracks") or []:
            t = safe_parse(track, item)
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
        tracks = ytm_call("get_watch_playlist", videoId=v, limit=1).get("tracks") or []
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
            for item in safe_search(f"{first.get('title')} {artist}", "videos", 5):
                if title[:20] in (item.get("title") or "").lower() and item.get("videoId"):
                    return item["videoId"]
        return None

    return await cached(f"v:{v}", 24 * 3600, run)


@app.get("/stream/music/health")
async def music_health():
    return {"ok": YTMusic is not None, "cached": len(_music_cache)}


# ---------------- Sanatçı, albüm, liste, Türkiye listesi, ruh hali ----------------

BROWSE_ID = re.compile(r"^[A-Za-z0-9_-]{6,80}$")


def artist_card(item: dict) -> dict | None:
    bid = item.get("browseId")
    if not bid or not BROWSE_ID.match(bid):
        return None
    return {"id": bid, "name": item.get("artist") or item.get("title") or "", "thumbnail": square(item.get("thumbnails"))}


def album_card(item: dict, artist: str = "") -> dict | None:
    bid = item.get("browseId")
    if not bid or not BROWSE_ID.match(bid):
        return None
    return {
        "id": bid,
        "title": item.get("title") or "",
        "artist": artist or ", ".join(a.get("name", "") for a in (item.get("artists") or []) if a.get("name")),
        "year": str(item.get("year") or ""),
        "type": item.get("type") or "",
        "thumbnail": square(item.get("thumbnails")),
    }


def _artists_text(item: dict) -> str:
    return ", ".join(a.get("name", "") for a in (item.get("artists") or []) if isinstance(a, dict) and a.get("name"))


def _people(value) -> str:
    if isinstance(value, list):
        return ", ".join(a.get("name", "") for a in value if isinstance(a, dict) and a.get("name"))
    return str(value or "")


def search_item(item: dict) -> dict | None:
    """Karışık arama sonucu (şarkı, video, albüm, sanatçı, liste) tek biçimde."""
    kind = item.get("resultType")
    if kind in ("song", "video"):
        t = safe_parse(track, item)
        if not t:
            return None
        t["type"] = kind
        if item.get("views"):
            t["views"] = str(item.get("views"))
        if item.get("year"):
            t["year"] = str(item.get("year"))
        return t
    if kind == "album":
        bid = item.get("browseId")
        if not bid or not BROWSE_ID.match(bid):
            return None
        return {
            "type": "album", "id": bid, "title": item.get("title") or "",
            "channel": _artists_text(item), "artist_id": next((a.get("id") for a in (item.get("artists") or []) if isinstance(a, dict) and a.get("id")), None),
            "thumbnail": square(item.get("thumbnails")), "year": str(item.get("year") or ""),
            "album_type": item.get("type") or "Album",
        }
    if kind == "artist":
        bid = item.get("browseId")
        name = item.get("artist") or item.get("title") or ""
        if not bid:
            first = next((a for a in (item.get("artists") or []) if isinstance(a, dict) and a.get("id")), None)
            if first:
                bid, name = first.get("id"), name or first.get("name") or ""
        if not bid or not BROWSE_ID.match(bid):
            return None
        return {"type": "artist", "id": bid, "title": name, "thumbnail": square(item.get("thumbnails")),
                "subscribers": str(item.get("subscribers") or "")}
    if kind == "playlist":
        bid = item.get("browseId") or ""
        pid = bid[2:] if bid.startswith("VL") else bid
        if not pid or not re.match(r"^[A-Za-z0-9_-]{10,80}$", pid):
            return None
        return {"type": "playlist", "id": pid, "title": item.get("title") or "", "thumbnail": square(item.get("thumbnails")),
                "author": _people(item.get("author")), "item_count": str(item.get("itemCount") or "")}
    return None


def find_artist_id(q: str) -> str | None:
    for item in safe_search(q, "artists", 3):
        if item.get("browseId"):
            return item["browseId"]
    return None


@app.get("/stream/music/artists")
async def music_artists(q: str = "", limit: int = 3, exp: str = "", sig: str = ""):
    """Aramada en üstte gösterilecek sanatçılar."""
    check_music_signature(exp, sig)
    q = q.strip()[:120]
    if not q:
        raise HTTPException(400, "Arama metni gerekli.")

    def run():
        return [c for c in (artist_card(i) for i in safe_search(q, "artists", max(1, min(limit, 10)))) if c]

    return {"ok": True, "results": await cached(f"as:{q.lower()}:{limit}", 12 * 3600, run)}


@app.get("/stream/music/artist")
async def music_artist(id: str = "", q: str = "", exp: str = "", sig: str = ""):
    """Sanatçı sayfası: popüler şarkılar, albümler, single'lar, benzer sanatçılar. id yoksa adla bulunur."""
    check_music_signature(exp, sig)
    if id and not BROWSE_ID.match(id):
        raise HTTPException(400, "Geçersiz sanatçı.")
    q = q.strip()[:120]
    if not id and not q:
        raise HTTPException(400, "Sanatçı gerekli.")

    def run():
        bid = id or find_artist_id(q)
        if not bid:
            return None
        data = ytm_call("get_artist", bid)
        name = data.get("name") or q
        songs = part("artist.songs", lambda: [t for t in (safe_parse(track, i) for i in ((data.get("songs") or {}).get("results") or [])) if t])
        # Popüler şarkılar listesinin tamamı (5'ten fazlası) ayrı bir listede.
        songs_list = (data.get("songs") or {}).get("browseId")
        if songs_list and songs_list.startswith("VL"):
            try:
                more = ytm_call("get_playlist", songs_list[2:], limit=40).get("tracks") or []
                seen = {t["id"] for t in songs}
                for i in more:
                    t = safe_parse(track, i)
                    if t and t["id"] not in seen:
                        seen.add(t["id"])
                        songs.append(t)
            except Exception:
                pass
        return {
            "artist": {
                "id": data.get("channelId") or bid,
                "name": name,
                "thumbnail": square(data.get("thumbnails")),
                "description": (data.get("description") or "")[:600],
                "listeners": data.get("monthlyListeners") or data.get("subscribers") or "",
            },
            "songs": songs[:40],
            "albums": part("artist.albums", lambda: [c for c in (album_card(i, name) for i in ((data.get("albums") or {}).get("results") or [])) if c]),
            "singles": part("artist.singles", lambda: [c for c in (album_card(i, name) for i in ((data.get("singles") or {}).get("results") or [])) if c]),
            "related": part("artist.related", lambda: [c for c in ({"id": i.get("browseId"), "name": i.get("title") or "", "thumbnail": square(i.get("thumbnails"))} for i in ((data.get("related") or {}).get("results") or [])) if c["id"]]),
        }

    value = await cached(f"ar:{id or q.lower()}", 12 * 3600, run)
    if value is None:
        raise HTTPException(404, "Sanatçı bulunamadı.")
    return {"ok": True, **value}


@app.get("/stream/music/album")
async def music_album(id: str = "", q: str = "", exp: str = "", sig: str = ""):
    """Albüm sayfası: bütün şarkılar sırasıyla. id yoksa "albüm sanatçı" metniyle bulunur."""
    check_music_signature(exp, sig)
    if id and not BROWSE_ID.match(id):
        raise HTTPException(400, "Geçersiz albüm.")
    q = q.strip()[:160]
    if not id and not q:
        raise HTTPException(400, "Albüm gerekli.")

    def run():
        bid = id
        if not bid:
            found = safe_search(q, "albums", 3)
            bid = next((i.get("browseId") for i in found if i.get("browseId")), None)
        if not bid:
            return None
        data = ytm_call("get_album", bid)
        cover = square(data.get("thumbnails"))
        artist = ", ".join(a.get("name", "") for a in (data.get("artists") or []) if a.get("name"))
        artist_id = next((a.get("id") for a in (data.get("artists") or []) if a.get("id")), None)
        tracks = []
        for i in data.get("tracks") or []:
            if i.get("isAvailable") is False:
                continue
            t = safe_parse(track, i)
            if t:
                t["thumbnail"] = t["thumbnail"] or cover
                t["album"] = data.get("title")
                t["album_id"] = bid
                t["artist_id"] = t["artist_id"] or artist_id
                tracks.append(t)
        return {
            "album": {"id": bid, "title": data.get("title") or "", "artist": artist, "artist_id": artist_id,
                      "year": str(data.get("year") or ""), "type": data.get("type") or "", "thumbnail": cover},
            "tracks": tracks,
        }

    value = await cached(f"al:{id or q.lower()}", 24 * 3600, run)
    if value is None:
        raise HTTPException(404, "Albüm bulunamadı.")
    return {"ok": True, **value}


@app.get("/stream/music/playlist")
async def music_playlist(id: str = "", limit: int = 60, exp: str = "", sig: str = ""):
    check_music_signature(exp, sig)
    if not BROWSE_ID.match(id or ""):
        raise HTTPException(400, "Geçersiz liste.")
    limit = max(5, min(100, limit))

    def run():
        data = ytm_call("get_playlist", id, limit=limit)
        return {"title": data.get("title") or "", "thumbnail": square(data.get("thumbnails")),
                "tracks": [t for t in (safe_parse(track, i) for i in (data.get("tracks") or [])) if t]}

    return {"ok": True, **await cached(f"pl:{id}:{limit}", 6 * 3600, run)}


@app.get("/stream/music/charts")
async def music_charts(country: str = "TR", exp: str = "", sig: str = ""):
    """Ülke listesi: en çok dinlenen müzik videoları listesinin şarkıları + popüler sanatçılar."""
    check_music_signature(exp, sig)
    country = country.upper() if re.match(r"^[A-Za-z]{2}$", country or "") else "TR"

    def run():
        data = ytm_call("get_charts", country)
        lists = data.get("videos") or []
        title, tracks = "", []
        if lists and lists[0].get("playlistId"):
            title = lists[0].get("title") or ""
            pl = ytm_call("get_playlist", lists[0]["playlistId"], limit=50)
            tracks = [t for t in (safe_parse(track, i) for i in (pl.get("tracks") or [])) if t]
        artists = [c for c in ({"id": i.get("browseId"), "name": i.get("title") or "", "thumbnail": square(i.get("thumbnails"))} for i in (data.get("artists") or [])) if c["id"]][:20]
        return {"title": title, "tracks": tracks, "artists": artists}

    return {"ok": True, **await cached(f"ch:{country}", 6 * 3600, run)}


@app.get("/stream/music/moods")
async def music_moods(hl: str = "tr", exp: str = "", sig: str = ""):
    """YouTube Music'in "Ruh hali ve türler" kategorileri (uygulamanın dilinde; varsayılan Türkçe)."""
    check_music_signature(exp, sig)
    if hl not in SUPPORTED_HL:
        hl = "en"

    def run():
        sections = ytm_call("get_mood_categories", languages=(hl, "en") if hl != "en" else ("en",))
        out, seen = [], set()
        names = list(sections.keys())
        # İlk bölüm ("Senin için") hesaba özel; ruh hali ve türler sonra gelir.
        ordered = names[1:] + names[:1] if len(names) > 1 else names
        for name in ordered:
            for c in sections.get(name) or []:
                title = (c.get("title") or "").strip()
                if title and c.get("params") and title.lower() not in seen:
                    seen.add(title.lower())
                    out.append({"key": c["params"], "title": title})
        return out[:24]

    return {"ok": True, "results": await cached("moods:" + hl, 24 * 3600, run)}


@app.get("/stream/music/mood")
async def music_mood(params: str = "", exp: str = "", sig: str = ""):
    """Bir ruh hali/tür kategorisinin şarkıları: kategorinin ilk listelerinden karışık."""
    check_music_signature(exp, sig)
    if not re.match(r"^[A-Za-z0-9_%=-]{6,200}$", params or ""):
        raise HTTPException(400, "Geçersiz kategori.")

    def run():
        playlists = ytm_call("get_mood_playlists", params, languages=("tr", "en"))[:3]
        tracks, seen = [], set()
        for pl in playlists:
            if not pl.get("playlistId"):
                continue
            try:
                items = ytm_call("get_playlist", pl["playlistId"], limit=30).get("tracks") or []
            except Exception:
                continue
            for i in items:
                t = safe_parse(track, i)
                if t and t["id"] not in seen:
                    seen.add(t["id"])
                    tracks.append(t)
        return tracks[:60]

    return {"ok": True, "results": await cached(f"mood:{params}", 12 * 3600, run)}


@app.get("/stream/stats")
async def stats(exp: str = "", sig: str = ""):
    """Panelin VDS takibi: çalışma süresi, istek/hata sayıları ve ortalama süreler."""
    check_music_signature(exp, sig, require_music=False)
    out = {}
    for name, s in STATS.items():
        out[name] = {"n": int(s["n"]), "err": int(s["err"]), "avg_ms": int(s["ms"] / s["n"]) if s["n"] else 0}
    return {"ok": True, "uptime": int(time.time() - STARTED), "music": YTMusic is not None,
            "ytmusicapi": YTMUSIC_VERSION or None, "last_error": LAST_ERROR or None,
            "cache": {"links": len(_cache), "music": len(_music_cache)}, "stats": out}


# ---------------- Bakım uçları (panel ve Telegram) ----------------
# Serbest komut YOK: yalnızca aşağıdaki sabit işlemler. İstek imzası: HMAC(KEY, "admin:<işlem>:<exp>:<nonce>"),
# en fazla 2 dakika geçerli ve her nonce bir kez kullanılır.

SERVICE = os.environ.get("YT_SERVICE_NAME", "yt-stream")
_admin_nonces: dict[str, float] = {}


def check_admin_signature(action: str, exp: str, nonce: str, sig: str) -> None:
    if not KEY:
        raise HTTPException(500, "Sunucu anahtarı ayarlı değil.")
    try:
        expires = int(exp)
    except (TypeError, ValueError):
        raise HTTPException(400, "Geçersiz istek.")
    now = time.time()
    if expires < now or expires > now + 120 or not re.fullmatch(r"[a-f0-9]{16,64}", nonce or ""):
        raise HTTPException(403, "İsteğin süresi doldu.")
    good = hmac.new(KEY, f"admin:{action}:{expires}:{nonce}".encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(good, sig or ""):
        raise HTTPException(403, "Geçersiz imza.")
    for n, until in list(_admin_nonces.items()):
        if until < now:
            _admin_nonces.pop(n, None)
    if nonce in _admin_nonces:
        raise HTTPException(403, "Bu istek zaten kullanıldı.")
    _admin_nonces[nonce] = expires


def _run(cmd: list[str], timeout: int = 60) -> dict:
    import subprocess
    started = time.time()
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        out = (p.stdout or "") + (("\n" + p.stderr) if p.stderr else "")
        return {"code": p.returncode, "output": out[-12000:], "ms": int((time.time() - started) * 1000)}
    except FileNotFoundError:
        return {"code": 127, "output": f"{cmd[0]} bulunamadı.", "ms": 0}
    except subprocess.TimeoutExpired:
        return {"code": 124, "output": f"{timeout} saniyede bitmedi.", "ms": timeout * 1000}


def _schedule_restart() -> str:
    """Servis kendini yeniden başlatır; yanıt gittikten sonra çalışsın diye 2 sn gecikmeli."""
    import subprocess
    if shutil.which("systemd-run"):
        r = _run(["systemd-run", "--on-active=2", f"--unit=yt-restart-{int(time.time())}", "systemctl", "restart", SERVICE], 15)
        if r["code"] == 0:
            return "2 saniye içinde yeniden başlatılacak."
    subprocess.Popen(["sh", "-c", f"sleep 2; systemctl restart {SERVICE}"], start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return "2 saniye içinde yeniden başlatılacak."


def _installed_ytmusicapi() -> str:
    r = _run([sys.executable, "-c", "import importlib.metadata as m; print(m.version('ytmusicapi'))"], 20)
    return r["output"].strip().splitlines()[-1] if r["code"] == 0 and r["output"].strip() else ""


@app.get("/stream/admin/logs")
async def admin_logs(lines: int = 200, exp: str = "", nonce: str = "", sig: str = ""):
    check_admin_signature("logs", exp, nonce, sig)
    lines = max(20, min(1000, lines))
    r = await asyncio.to_thread(_run, ["journalctl", "-u", SERVICE, "-n", str(lines), "--no-pager", "-o", "short-iso"], 20)
    return {"ok": r["code"] == 0, "service": SERVICE, "output": r["output"], "last_error": LAST_ERROR or None,
            "ytmusicapi": YTMUSIC_VERSION or None, "uptime": int(time.time() - STARTED)}


@app.post("/stream/admin/update")
async def admin_update(exp: str = "", nonce: str = "", sig: str = ""):
    """ytmusicapi'yi günceller ve servisi yeniden başlatır."""
    check_admin_signature("update", exp, nonce, sig)
    before = YTMUSIC_VERSION or ""
    r = await asyncio.to_thread(_run, [sys.executable, "-m", "pip", "install", "-U", "--disable-pip-version-check", "ytmusicapi"], 240)
    after = await asyncio.to_thread(_installed_ytmusicapi)
    restart = _schedule_restart() if r["code"] == 0 else "Kurulum başarısız olduğu için yeniden başlatılmadı."
    return {"ok": r["code"] == 0, "before": before or None, "after": after or None,
            "changed": bool(after and after != before), "output": r["output"][-4000:], "restart": restart}


@app.post("/stream/admin/restart")
async def admin_restart(exp: str = "", nonce: str = "", sig: str = ""):
    check_admin_signature("restart", exp, nonce, sig)
    return {"ok": True, "restart": _schedule_restart()}


@app.get("/stream/admin/selftest")
async def admin_selftest(q: str = "tarkan", exp: str = "", nonce: str = "", sig: str = ""):
    """Önbelleği atlayarak gerçek bir YouTube Music araması yapar."""
    check_admin_signature("selftest", exp, nonce, sig)
    q = (q or "tarkan").strip()[:60]
    out = {"ok": True, "query": q, "ytmusicapi": YTMUSIC_VERSION or None, "checks": []}
    if YTMusic is None:
        return {**out, "ok": False, "error": "ytmusicapi kurulu değil."}

    def check(name, fn):
        started = time.time()
        try:
            n = len(fn() or [])
            out["checks"].append({"name": name, "ok": n > 0, "count": n, "ms": int((time.time() - started) * 1000)})
        except Exception as e:
            out["checks"].append({"name": name, "ok": False, "error": f"{type(e).__name__}: {str(e)[:120]}", "ms": int((time.time() - started) * 1000)})

    await asyncio.to_thread(check, "Karışık arama (en)", lambda: ytm("en").search(q, limit=10))
    await asyncio.to_thread(check, "Karışık arama (tr)", lambda: ytm("tr").search(q, limit=10))
    await asyncio.to_thread(check, "Şarkı araması", lambda: ytm("en").search(q, filter="songs", limit=10))
    await asyncio.to_thread(check, "Sanatçı araması", lambda: ytm("en").search(q, filter="artists", limit=5))
    out["ok"] = all(c["ok"] for c in out["checks"])
    return out
