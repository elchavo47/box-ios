<?php
if (!defined('ROOT')) { http_response_code(404); exit; }

/*
 * Box iş mantığı: kullanıcılar, premium, kotalar, YouTube araması, VDS indirme bağlantısı ve servis izleme.
 * API (app/api.php) ve panel bu fonksiyonları ortak kullanır.
 */

const BOX_VIDEO_ID = '/^[A-Za-z0-9_-]{11}$/D';

/* ---------------- Kullanıcılar ---------------- */

function boxFindUser(int $id): ?array {
    $u = q('SELECT * FROM users WHERE id=? LIMIT 1', [$id])->fetch();
    return is_array($u) ? $u : null;
}

function boxFindUserByEmail(string $email): ?array {
    $u = q('SELECT * FROM users WHERE email=? LIMIT 1', [mb_strtolower(trim($email))])->fetch();
    return is_array($u) ? $u : null;
}

function boxIsPremium(array $u): bool {
    if ((int)($u['is_premium'] ?? 0) !== 1) return false;
    if (empty($u['premium_until'])) return true;
    return strtotime((string)$u['premium_until']) > time();
}

/** Uygulamaya giden kullanıcı nesnesi (sürüm 1 uygulamasıyla uyumlu alan adları). */
function boxUserPublic(array $u): array {
    return [
        'id' => (int)$u['id'],
        'email' => (string)$u['email'],
        'name' => (string)$u['display_name'],
        'premium' => boxIsPremium($u),
        'premium_until' => !empty($u['premium_until']) ? date(DATE_ATOM, (int)strtotime((string)$u['premium_until'])) : null,
        'created_at' => date(DATE_ATOM, (int)strtotime((string)$u['created_at'])),
        'avatar_url' => boxAvatarUrl($u),
        'apple_linked' => !empty($u['apple_sub']),
        'has_password' => (int)($u['has_password'] ?? 1) === 1,
    ];
}

/* ---------------- Profil fotoğrafı ---------------- */

function boxAvatarDir(): string {
    $dir = nbPrivateDir('avatars');
    if (!is_dir($dir)) @mkdir($dir, 0700, true);
    return $dir;
}

function boxAvatarUrl(array $u): ?string {
    $file = (string)($u['avatar_file'] ?? '');
    if ($file === '' || !preg_match('/^[a-f0-9]{32}\.(jpg|png)$/', $file)) return null;
    return rtrim((string)cfg('app.url', ''), '/') . '/api/v1/avatar/' . $file;
}

/** Yeni fotoğrafı kaydeder, eskisini sunucudan siler. */
function boxSetAvatar(array $u, string $binary): void {
    if (strlen($binary) < 100 || strlen($binary) > 1024 * 1024) throw new RuntimeException('Fotoğraf en fazla 1 MB olmalı.');
    $info = @getimagesizefromstring($binary);
    $ext = match ($info['mime'] ?? '') { 'image/jpeg' => 'jpg', 'image/png' => 'png', default => '' };
    if ($ext === '' || ($info[0] ?? 0) < 32 || ($info[1] ?? 0) < 32 || ($info[0] ?? 0) > 4000 || ($info[1] ?? 0) > 4000) throw new RuntimeException('Geçerli bir JPEG ya da PNG fotoğraf gönder.');
    $name = bin2hex(random_bytes(16)) . '.' . $ext;
    if (@file_put_contents(boxAvatarDir() . '/' . $name, $binary, LOCK_EX) === false) throw new RuntimeException('Fotoğraf kaydedilemedi.');
    $old = (string)($u['avatar_file'] ?? '');
    q('UPDATE users SET avatar_file=? WHERE id=?', [$name, $u['id']]);
    boxDeleteAvatarFile($old);
}

function boxDeleteAvatarFile(?string $file): void {
    if ($file && preg_match('/^[a-f0-9]{32}\.(jpg|png)$/', $file)) @unlink(boxAvatarDir() . '/' . $file);
}


function boxBearer(): ?string {
    $candidates = [$_SERVER['HTTP_AUTHORIZATION'] ?? null, $_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ?? null];
    if (function_exists('getallheaders')) foreach ((array)getallheaders() as $k => $v) if (strtolower((string)$k) === 'authorization') $candidates[] = $v;
    foreach ($candidates as $h) if (is_string($h) && preg_match('/^Bearer\s+([a-f0-9]{64})$/i', trim($h), $m)) return strtolower($m[1]);
    $fallback = trim((string)($_SERVER['HTTP_X_BOX_TOKEN'] ?? ''));
    return preg_match('/^[a-f0-9]{64}$/i', $fallback) ? strtolower($fallback) : null;
}

/** Oturumu açık kullanıcı; yoksa 401 döner. */
function boxApiUser(): array {
    $token = boxBearer();
    if ($token === null) jsonOut(['ok' => false, 'error' => 'Oturum açman gerekiyor.'], 401);
    $u = q('SELECT u.*, t.id AS token_id, t.last_used_at AS token_last_used FROM tokens t JOIN users u ON u.id=t.user_id WHERE t.token_hash=? AND t.expires_at>NOW() LIMIT 1', [hash('sha256', $token)])->fetch();
    if (!is_array($u)) jsonOut(['ok' => false, 'error' => 'Oturumun sona erdi, tekrar giriş yap.'], 401);
    if ((int)$u['is_banned'] === 1) jsonOut(['ok' => false, 'error' => 'Hesabın askıya alındı.', 'reason' => (string)($u['ban_reason'] ?? '')], 403);
    $last = $u['token_last_used'] ? strtotime((string)$u['token_last_used']) : 0;
    if (time() - (int)$last > 600) {
        q('UPDATE tokens SET last_used_at=NOW() WHERE id=?', [(int)$u['token_id']]);
        boxTouchDevice((int)$u['token_id']);
        $ver = mb_substr(preg_replace('/[^0-9A-Za-z.() -]/', '', (string)($_SERVER['HTTP_X_BOX_VERSION'] ?? '')), 0, 20);
        q('UPDATE users SET last_seen_at=NOW(), app_version=COALESCE(NULLIF(?,\'\'),app_version) WHERE id=?', [$ver, (int)$u['id']]);
    }
    return $u;
}

/* ---------------- Premium ---------------- */

/** Premium ver ya da uzat. $days = 0 süresiz. Mevcut süre varsa üstüne eklenir. */
function boxGrantPremium(int $userId, int $days, ?int $adminId, string $action = 'grant'): ?string {
    $u = boxFindUser($userId);
    if (!$u) throw new RuntimeException('Kullanıcı bulunamadı.');
    if ($days <= 0) {
        q('UPDATE users SET is_premium=1, premium_until=NULL, premium_since=COALESCE(premium_since,NOW()) WHERE id=?', [$userId]);
        $until = null;
    } else {
        $base = boxIsPremium($u) && !empty($u['premium_until']) ? 'premium_until' : 'NOW()';
        // MySQL atamaları soldan sağa uygular: önce eski değerlere bakan premium_since hesaplanır.
        q("UPDATE users SET premium_since=IF(is_premium=1 AND (premium_until IS NULL OR premium_until>NOW()),COALESCE(premium_since,NOW()),NOW()), premium_until=DATE_ADD($base, INTERVAL ? DAY), is_premium=1 WHERE id=?", [$days, $userId]);
        $until = (string)q('SELECT premium_until FROM users WHERE id=?', [$userId])->fetchColumn();
    }
    q('INSERT INTO premium_log(user_id,admin_id,action,days,until_at) VALUES(?,?,?,?,?)', [$userId, $adminId, $action, max(0, $days), $until]);
    watchRefresh();
    return $until;
}

function boxRevokePremium(int $userId, ?int $adminId, string $action = 'revoke'): void {
    q('UPDATE users SET is_premium=0, premium_until=NULL, premium_since=NULL WHERE id=?', [$userId]);
    q('INSERT INTO premium_log(user_id,admin_id,action) VALUES(?,?,?)', [$userId, $adminId, $action]);
    watchRefresh();
}

/** Süresi dolan üyelikleri kapatır (cron ve trafik zamanlayıcısı çağırır). */
function boxExpirePremiums(): int {
    $ids = q('SELECT id FROM users WHERE is_premium=1 AND premium_until IS NOT NULL AND premium_until<=NOW() LIMIT 500')->fetchAll(PDO::FETCH_COLUMN);
    foreach ($ids as $id) {
        q('UPDATE users SET is_premium=0, premium_since=NULL WHERE id=?', [$id]);
        q("INSERT INTO premium_log(user_id,action) VALUES(?, 'expired')", [$id]);
        if (function_exists('boxNotifyUser') && site('push_auto_expired', '1') === '1') {
            boxNotifyUser((int)$id, 'Premium üyeliğin sona erdi', 'İndirdiğin şarkılar kitaplığında kalır. Premium\'u yeniden açtırmak için bize yazabilirsin.', ['box' => ['open' => 'account']]);
        }
    }
    if ($ids) watchRefresh();
    return count($ids);
}

/* ---------------- Kotalar ---------------- */

function boxTodayDownloads(int $userId): int {
    return (int)q('SELECT COUNT(*) FROM downloads WHERE user_id=? AND created_at>=CURDATE()', [$userId])->fetchColumn();
}

function boxTodaySearches(int $userId): int {
    return (int)q('SELECT n FROM search_log WHERE day=CURDATE() AND user_id=?', [$userId])->fetchColumn();
}

function boxQuota(array $u): array {
    $dl = isset($u['daily_downloads']) && $u['daily_downloads'] !== null ? (int)$u['daily_downloads'] : (int)configValue('premium_daily_downloads', 150);
    $se = (int)configValue('premium_daily_searches', 400);
    $usedDl = boxTodayDownloads((int)$u['id']);
    $usedSe = boxTodaySearches((int)$u['id']);
    return [
        'downloads_limit' => $dl, 'downloads_used' => $usedDl, 'downloads_left' => $dl > 0 ? max(0, $dl - $usedDl) : null,
        'searches_limit' => $se, 'searches_used' => $usedSe, 'searches_left' => $se > 0 ? max(0, $se - $usedSe) : null,
    ];
}

/* ---------------- YouTube araması ---------------- */

function boxYoutubeKey(): string { return secretSetting('yt_api_key'); }

function boxCacheGet(string $key, int $ttl): ?array {
    $file = nbPrivateDir('cache') . '/' . hash('sha256', $key) . '.json';
    if (!is_file($file) || time() - (int)@filemtime($file) >= $ttl) return null;
    $data = json_decode((string)@file_get_contents($file), true);
    return is_array($data) ? $data : null;
}

function boxCachePut(string $key, array $data): void {
    $json = json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    if ($json !== false) @file_put_contents(nbPrivateDir('cache') . '/' . hash('sha256', $key) . '.json', $json, LOCK_EX);
}

function boxYoutube(string $resource, array $params, ?int $ttlOverride = null): array {
    $key = boxYoutubeKey();
    if ($key === '') throw new RuntimeException('Arama servisi yapılandırılmamış.');
    $cacheKey = $resource . '?' . http_build_query($params);
    $ttl = $ttlOverride ?? max(60, (int)site('search_cache_seconds', '3600'));
    if ($cached = boxCacheGet($cacheKey, $ttl)) return $cached;

    $params['key'] = $key;
    $ch = curl_init('https://www.googleapis.com/youtube/v3/' . $resource . '?' . http_build_query($params));
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_CONNECTTIMEOUT => 8, CURLOPT_TIMEOUT => 15, CURLOPT_ENCODING => '', CURLOPT_HTTPHEADER => ['Accept: application/json'], CURLOPT_USERAGENT => 'Box/' . boxVersion()]);
    $response = curl_exec($ch);
    $status = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $error = curl_error($ch);
    curl_close($ch);

    if (!is_string($response)) {
        error_log('[Box] YouTube bağlantı hatası: ' . $error);
        throw new RuntimeException('Arama servisine ulaşılamadı.');
    }
    $data = json_decode($response, true);
    if (!is_array($data) || $status < 200 || $status >= 300) {
        $reason = (string)($data['error']['errors'][0]['reason'] ?? '');
        saveSite('yt_last_error', json_encode(['at' => date('Y-m-d H:i:s'), 'status' => $status, 'reason' => $reason, 'message' => mb_substr((string)($data['error']['message'] ?? ''), 0, 200)], JSON_UNESCAPED_UNICODE));
        if ($reason === 'quotaExceeded') secEvent('warn', 'yt_quota', 'YouTube API günlük kotası doldu; arama gece yarısı (Pasifik saati) sıfırlanana kadar çalışmaz.', null, 'ytq' . date('Y-m-d'), 12);
        throw new RuntimeException($reason === 'quotaExceeded' ? 'Arama şu an yoğun, biraz sonra tekrar dene.' : 'Arama şu an yapılamıyor.');
    }
    $units = $resource === 'search' ? 100 : 1;
    q("INSERT INTO site_settings(setting_key,setting_value) VALUES(?,?) ON DUPLICATE KEY UPDATE setting_value=setting_value+VALUES(setting_value)", ['yt_units_' . gmdate('Y-m-d', time() - 8 * 3600), (string)$units]);
    boxCachePut($cacheKey, $data);
    return $data;
}

function boxIsoSeconds(string $duration): int {
    if (!preg_match('/^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/', $duration, $m)) return 0;
    return ((int)($m[1] ?? 0)) * 86400 + ((int)($m[2] ?? 0)) * 3600 + ((int)($m[3] ?? 0)) * 60 + ((int)($m[4] ?? 0));
}

function boxCleanText(string $t): string { return trim(html_entity_decode($t, ENT_QUOTES | ENT_HTML5, 'UTF-8')); }

/** "Sanatçı - Şarkı (Official Video)" biçimindeki başlıkları ayırır, " - Topic" gibi kanal eklerini temizler. */
function boxSplitTitle(string $title, string $channel): array {
    $channel = trim(preg_replace('/\s*(-\s*Topic|VEVO|Official|Resmi|TV)$/iu', '', $channel));
    $clean = preg_replace('/\s*[\(\[](official|resmi|lyric|lyrics|audio|video|klip|music video|official video|official audio|şarkı sözleri|sözleri|hd|4k)[^\)\]]*[\)\]]/iu', '', $title);
    $clean = trim(preg_replace('/\s*(\||#).*$/u', '', (string)$clean));
    if (preg_match('/^(.{2,60}?)\s+[-–—]\s+(.{2,})$/u', $clean, $m)) {
        return [trim($m[2]), trim($m[1])];
    }
    return [$clean !== '' ? $clean : $title, $channel];
}

function boxNorm(string $s): string {
    return mb_strtolower(preg_replace('/[^\p{L}\p{N}]+/u', '', $s));
}

/** Video kimliklerinden süreli sonuç listesi üretir. $snippets: id => snippet */
function boxVideoResults(array $ids, array $snippets, ?int $ttl = null): array {
    $ids = array_values(array_unique(array_filter($ids, fn($id) => is_string($id) && preg_match(BOX_VIDEO_ID, $id))));
    $durations = []; $live = [];
    foreach (array_chunk($ids, 50) as $chunk) {
        $details = boxYoutube('videos', ['part' => 'contentDetails,snippet', 'id' => implode(',', $chunk)], $ttl);
        foreach (($details['items'] ?? []) as $item) {
            $durations[(string)$item['id']] = boxIsoSeconds((string)($item['contentDetails']['duration'] ?? ''));
            $live[(string)$item['id']] = ($item['snippet']['liveBroadcastContent'] ?? 'none') !== 'none';
        }
    }
    $out = [];
    foreach ($ids as $id) {
        if (!isset($durations[$id]) || !empty($live[$id])) continue; // silinmiş, gizli ya da canlı yayın
        $sn = $snippets[$id] ?? []; $th = $sn['thumbnails'] ?? [];
        [$title, $artist] = boxSplitTitle(boxCleanText((string)($sn['title'] ?? '')), boxCleanText((string)($sn['videoOwnerChannelTitle'] ?? $sn['channelTitle'] ?? '')));
        $out[] = [
            'id' => $id,
            'title' => $title,
            'channel' => $artist,
            'thumbnail' => $th['high']['url'] ?? $th['medium']['url'] ?? $th['default']['url'] ?? ('https://i.ytimg.com/vi/' . $id . '/hqdefault.jpg'),
            'duration' => $durations[$id],
        ];
    }
    return $out;
}

/* ---------------- YouTube Music (VDS üzerinden, kota harcamaz) ---------------- */

/** Arama kaynağı: "music" = VDS'deki YouTube Music (varsayılan), "api" = YouTube Data API. */
function boxMusicEnabled(): bool {
    return boxVdsKey() !== '' && site('search_source', 'music') === 'music';
}

function boxMusic(string $path, array $params, int $ttl): array {
    $cacheKey = 'music' . $path . '?' . http_build_query($params);
    if ($cached = boxCacheGet($cacheKey, $ttl)) return $cached;
    $exp = time() + 300;
    $url = boxVdsUrl() . $path . '?' . http_build_query($params + ['exp' => $exp, 'sig' => hash_hmac('sha256', 'music:' . $exp, boxVdsKey())]);
    $ch = curl_init($url);
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_CONNECTTIMEOUT => 5, CURLOPT_TIMEOUT => 25, CURLOPT_ENCODING => '', CURLOPT_USERAGENT => 'Box/' . boxVersion()]);
    $t = microtime(true);
    $body = curl_exec($ch);
    $status = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $err = curl_error($ch);
    curl_close($ch);
    $data = is_string($body) ? json_decode($body, true) : null;
    if (!is_array($data) || $status !== 200 || empty($data['ok'])) {
        $reason = is_array($data) ? (string)($data['detail'] ?? '') : ($err !== '' ? $err : 'HTTP ' . $status);
        saveSite('music_last_error', json_encode(['at' => date('Y-m-d H:i:s'), 'status' => $status, 'reason' => mb_substr($reason, 0, 200)], JSON_UNESCAPED_UNICODE));
        throw new RuntimeException('YouTube Music araması yapılamadı: ' . ($reason !== '' ? $reason : 'HTTP ' . $status));
    }
    q("INSERT INTO site_settings(setting_key,setting_value) VALUES(?,?) ON DUPLICATE KEY UPDATE setting_value=setting_value+VALUES(setting_value)", ['music_calls_' . date('Y-m-d'), '1']);
    saveSite('music_last_ok', json_encode(['at' => date('Y-m-d H:i:s'), 'ms' => (int)round((microtime(true) - $t) * 1000)]));
    // Boş sonuç önbelleğe yazılmaz (VDS geçici olarak boş dönerse saatlerce boş kalmasın).
    if (!array_key_exists('results', $data) || !empty($data['results'])) boxCachePut($cacheKey, $data);
    return $data;
}

/** VDS'nin döndürdüğü şarkıları uygulamanın beklediği biçime çevirir. */
function boxMusicResults(array $rows, bool $music): array {
    $out = []; $seen = [];
    foreach ($rows as $r) {
        $id = (string)($r['id'] ?? '');
        if (!preg_match(BOX_VIDEO_ID, $id) || isset($seen[$id])) continue;
        $title = boxCleanText((string)($r['title'] ?? ''));
        $artist = boxCleanText((string)($r['channel'] ?? ''));
        if (($r['kind'] ?? 'song') === 'video') {
            [$clean, $guess] = boxSplitTitle($title, $artist);
            $title = $clean;
            if ($artist === '') $artist = $guess;
        }
        $duration = (int)($r['duration'] ?? 0);
        if ($music && ($duration < 60 || $duration > 900)) continue;
        if ($title === '') continue;
        $seen[$id] = 1;
        $item = ['id' => $id, 'title' => $title, 'channel' => $artist, 'thumbnail' => $r['thumbnail'] ?? ('https://i.ytimg.com/vi/' . $id . '/hqdefault.jpg'), 'duration' => $duration];
        // Sanatçı ve albüm sayfasına gitmek için (uygulama 2.12+)
        foreach (['artist_id', 'album_id', 'album'] as $k) if (!empty($r[$k]) && is_string($r[$k])) $item[$k] = mb_substr($r[$k], 0, 200);
        $out[] = $item;
    }
    return $out;
}

function boxMusicId(string $id): bool { return (bool)preg_match('/^[A-Za-z0-9_-]{6,80}$/', $id); }

/** Sanatçı sayfası (id ya da ad ile). */
function boxArtistPage(string $id, string $name): array {
    $params = $id !== '' ? ['id' => $id] : ['q' => mb_substr($name, 0, 120)];
    $data = boxMusic('/stream/music/artist', $params, 43200);
    return [
        'artist' => $data['artist'] ?? null,
        'songs' => boxMusicResults($data['songs'] ?? [], false),
        'albums' => array_values($data['albums'] ?? []),
        'singles' => array_values($data['singles'] ?? []),
        'related' => array_values($data['related'] ?? []),
    ];
}

/** Albüm sayfası (id ya da "albüm sanatçı" ile). */
function boxAlbumPage(string $id, string $query): array {
    $params = $id !== '' ? ['id' => $id] : ['q' => mb_substr($query, 0, 160)];
    $data = boxMusic('/stream/music/album', $params, 86400);
    return ['album' => $data['album'] ?? null, 'tracks' => boxMusicResults($data['tracks'] ?? [], false)];
}

/** Aramada en üstte gösterilecek sanatçı (adı aramayla eşleşiyorsa). */
function boxTopArtist(string $query): ?array {
    if (!boxMusicEnabled()) return null;
    try { $data = boxMusic('/stream/music/artists', ['q' => mb_substr($query, 0, 120), 'limit' => 3], 43200); }
    catch (RuntimeException $e) { return null; }
    $q = boxNorm($query);
    foreach ($data['results'] ?? [] as $a) {
        $n = boxNorm((string)($a['name'] ?? ''));
        if ($n !== '' && $q !== '' && (str_contains($n, $q) || str_contains($q, $n))) return $a;
    }
    return null;
}

/** Türkiye listesi (YouTube Music). */
function boxCharts(): ?array {
    if (!boxMusicEnabled()) return null;
    try { $data = boxMusic('/stream/music/charts', ['country' => 'TR'], 21600); }
    catch (RuntimeException $e) { return null; }
    $items = boxMusicResults($data['tracks'] ?? [], false);
    return $items ? ['items' => $items, 'artists' => array_values($data['artists'] ?? [])] : null;
}

/** YouTube Music ruh hali / tür kategorileri; yoksa eski sabit liste. */
function boxMoods(): array {
    if (boxMusicEnabled()) {
        try {
            $data = boxMusic('/stream/music/moods', [], 86400);
            $out = [];
            foreach ($data['results'] ?? [] as $m) if (!empty($m['key']) && !empty($m['title'])) $out[] = ['key' => (string)$m['key'], 'title' => (string)$m['title']];
            if ($out) return $out;
        } catch (RuntimeException $e) {}
    }
    $out = [];
    foreach (boxGenres() as $key => [$title]) $out[] = ['key' => $key, 'title' => $title];
    return $out;
}

function boxMusicSearch(string $query, bool $music, int $max, ?int $ttl): array {
    $ttl ??= max(60, (int)site('search_cache_seconds', '21600'));
    $songs = boxMusic('/stream/music/search', ['q' => $query, 'limit' => min(40, $max), 'filter' => 'songs'], $ttl);
    $out = boxMusicResults($songs['results'] ?? [], $music);
    // Az şarkı çıkarsa (yeni çıkan, cover, remix) videolarla tamamla.
    if (!$music && count($out) < 8) {
        try {
            $videos = boxMusic('/stream/music/search', ['q' => $query, 'limit' => 15, 'filter' => 'videos'], $ttl);
            $have = array_flip(array_column($out, 'id'));
            foreach (boxMusicResults($videos['results'] ?? [], false) as $v) if (!isset($have[$v['id']])) $out[] = $v;
        } catch (RuntimeException $e) {}
    }
    return array_slice($out, 0, $max);
}

/** YouTube Music şarkı radyosu (gerçek benzer şarkılar). */
function boxMusicRadio(string $videoId, int $limit = 30): array {
    $data = boxMusic('/stream/music/radio', ['v' => $videoId, 'limit' => $limit], 43200);
    return boxMusicResults($data['results'] ?? [], true);
}

/** Karışık arama öğesi (şarkı, video, albüm, sanatçı, liste); uygulamanın beklediği biçimde. */
function boxMusicItem($r): ?array {
    if (!is_array($r)) return null;
    $type = (string)($r['type'] ?? '');
    $text = fn($v, int $max = 200): string => mb_substr(boxCleanText(is_scalar($v) ? (string)$v : ''), 0, $max);
    if ($type === 'song' || $type === 'video') {
        $rows = boxMusicResults([$r + ['kind' => $type]], false);
        if (!$rows) return null;
        $item = ['type' => $type] + $rows[0];
        foreach (['views' => 40, 'year' => 8] as $k => $max) if (!empty($r[$k])) $item[$k] = $text($r[$k], $max);
        return $item;
    }
    $id = (string)($r['id'] ?? '');
    if (!preg_match('/^[A-Za-z0-9_-]{6,80}$/', $id)) return null;
    $thumb = is_string($r['thumbnail'] ?? null) && str_starts_with($r['thumbnail'], 'https://') ? $r['thumbnail'] : null;
    $item = ['type' => $type, 'id' => $id, 'title' => $text($r['title'] ?? '', 300), 'thumbnail' => $thumb];
    switch ($type) {
        case 'album':
            $item += ['channel' => $text($r['channel'] ?? ''), 'year' => $text($r['year'] ?? '', 8), 'album_type' => $text($r['album_type'] ?? 'Album', 30)];
            if (!empty($r['artist_id'])) $item['artist_id'] = $text($r['artist_id'], 80);
            break;
        case 'artist':
            $item['subscribers'] = $text($r['subscribers'] ?? '', 30);
            break;
        case 'playlist':
            $item += ['author' => $text($r['author'] ?? ''), 'item_count' => $text($r['item_count'] ?? '', 20)];
            break;
        default:
            return null;
    }
    return $item['title'] !== '' ? $item : null;
}

/** YouTube Music'teki gibi karışık arama: en iyi sonuç (+ kartındaki şarkılar) ve diğer sonuçlar. */
function boxSearchAll(string $query): ?array {
    if (!boxMusicEnabled()) return null;
    $ttl = max(60, (int)site('search_cache_seconds', '21600'));
    try { $data = boxMusic('/stream/music/searchall', ['q' => $query], $ttl); }
    catch (RuntimeException $e) { return null; }
    $top = boxMusicItem($data['top'] ?? null);
    if ($top) {
        $top['children'] = array_values(array_filter(array_map('boxMusicItem', is_array($data['top']['children'] ?? null) ? $data['top']['children'] : [])));
    }
    $items = array_values(array_filter(array_map('boxMusicItem', is_array($data['items'] ?? null) ? $data['items'] : [])));
    if (!$top && !$items) return null;
    return ['top' => $top, 'items' => $items];
}

/** Tek türde arama (Şarkılar dışındaki filtre çipleri). */
function boxSearchKind(string $query, string $kind): array {
    $ttl = max(60, (int)site('search_cache_seconds', '21600'));
    $data = boxMusic('/stream/music/search', ['q' => $query, 'limit' => 30, 'filter' => $kind], $ttl);
    $type = ['videos' => 'video', 'albums' => 'album', 'artists' => 'artist', 'playlists' => 'playlist'][$kind];
    $out = [];
    foreach ($data['results'] ?? [] as $r) {
        if (is_array($r) && !isset($r['type'])) $r['type'] = $type;
        if ($item = boxMusicItem($r)) $out[] = $item;
    }
    return $out;
}

function boxSearch(string $query, bool $music = false, int $max = 25, ?int $ttl = null): array {
    if (boxMusicEnabled()) {
        try {
            $out = boxMusicSearch($query, $music, $max, $ttl);
            if ($out) return $out;
        } catch (RuntimeException $e) {
            error_log('[Box] ' . $e->getMessage() . ' (YouTube API ile devam ediliyor)');
        }
    }
    $params = ['part' => 'snippet', 'q' => $query, 'type' => 'video', 'maxResults' => max(1, min(50, $max)), 'regionCode' => 'TR', 'safeSearch' => 'none'];
    if ($music) $params['videoCategoryId'] = '10';
    $search = boxYoutube('search', $params, $ttl);
    $ids = []; $snippets = [];
    foreach (($search['items'] ?? []) as $item) {
        $id = $item['id']['videoId'] ?? null;
        if (!is_string($id)) continue;
        $ids[] = $id; $snippets[$id] = $item['snippet'] ?? [];
    }
    // Çok kısa (intro) ve çok uzun (saatlik derleme) videoları öneri listelerinden ayıkla.
    $results = boxVideoResults($ids, $snippets, $ttl);
    if ($music) $results = array_values(array_filter($results, fn($r) => $r['duration'] >= 60 && $r['duration'] <= 900));
    return $results;
}

/** Ana sayfadaki tür / ruh hali kategorileri. */
function boxGenres(): array {
    return [
        'turkce-pop' => ['Türkçe Pop', 'türkçe pop şarkılar yeni'],
        'rap' => ['Türkçe Rap', 'türkçe rap yeni şarkılar'],
        'arabesk' => ['Arabesk', 'arabesk şarkılar'],
        'rock' => ['Rock', 'türkçe rock şarkılar'],
        'enerjik' => ['Enerjik', 'enerjik hareketli şarkılar'],
        'keyifli' => ['Keyifli', 'keyifli neşeli şarkılar'],
        'rahatlama' => ['Rahatlama', 'sakin rahatlatıcı şarkılar'],
        'odaklanma' => ['Odaklanma', 'lofi odaklanma müzik'],
        'romantik' => ['Romantik', 'romantik aşk şarkıları'],
        'remix' => ['Remix', 'türkçe remix şarkılar'],
        'yabanci' => ['Yabancı Hit', 'top hits songs 2026'],
        'akustik' => ['Akustik', 'akustik cover şarkılar'],
    ];
}

/** Dinleme geçmişine göre karışık öneriler: tek sanatçının şarkıları yerine benzer sanatçılardan. */
function boxFeed(array $artists): array {
    $seeds = [];
    foreach (array_slice($artists, 0, 5) as $artist) {
        $artist = trim(preg_replace('/\s*-\s*Topic$/iu', '', mb_substr(trim((string)$artist), 0, 60)));
        if ($artist !== '' && mb_strtolower($artist) !== 'bilinmeyen sanatçı') $seeds[boxNorm($artist)] = $artist;
    }
    $isSeed = function (array $r) use ($seeds): bool {
        $hay = boxNorm($r['channel'] . ' ' . $r['title']);
        foreach (array_keys($seeds) as $k) if ($k !== '' && str_contains($hay, $k)) return true;
        return false;
    };
    $pick = function (array $pool, int $limit, ?callable $filter = null): array {
        $seen = []; $out = [];
        foreach ($pool as $r) {
            if ($filter && !$filter($r)) continue;
            $key = boxNorm($r['title']);
            $artistKey = boxNorm($r['channel']);
            if (isset($seen['t' . $key]) || ($seen['a' . $artistKey] ?? 0) >= 2) continue; // aynı sanatçıdan en fazla 2
            $seen['t' . $key] = 1; $seen['a' . $artistKey] = ($seen['a' . $artistKey] ?? 0) + 1;
            $out[] = $r;
            if (count($out) >= $limit) break;
        }
        return $out;
    };
    $daySeed = (int)date('Ymd');
    $sections = [];

    // 1) Benzer sanatçılar: tohum sanatçıların tarzındaki listelerden, tohumun kendisi hariç.
    $similar = [];
    foreach (array_values($seeds) as $artist) {
        if (boxMusicEnabled()) {
            // Sanatçının en bilinen şarkısının YouTube Music radyosu = gerçekten benzer şarkılar.
            try {
                $top = boxMusicSearch($artist, true, 3, 43200);
                if ($top) { $similar = array_merge($similar, boxMusicRadio($top[0]['id'], 40)); continue; }
            } catch (RuntimeException $e) {}
        }
        foreach ([$artist . ' tarzı şarkılar', $artist . ' benzeri şarkılar'] as $query) {
            try { $similar = array_merge($similar, boxSearch($query, true, 25, 43200)); } catch (RuntimeException $e) {}
        }
    }
    mt_srand($daySeed); shuffle($similar); mt_srand();
    $items = $pick($similar, 18, fn($r) => !$isSeed($r));
    if (count($items) >= 4) $sections[] = ['id' => 'similar', 'title' => 'Benzer sanatçılardan', 'subtitle' => 'Dinlediklerine göre', 'items' => $items];

    // 2) Karışık: sevdiğin sanatçılardan birkaç şarkı + benzerleri + günün türleri.
    $mix = [];
    foreach (array_values($seeds) as $artist) {
        try { $mix = array_merge($mix, array_slice(boxSearch($artist, true, 10, 43200), 0, 3)); } catch (RuntimeException $e) {}
    }
    $genres = boxGenres(); $keys = array_keys($genres); $day = (int)date('z');
    $todays = [$keys[$day % count($keys)], $keys[($day + 5) % count($keys)]];
    $genrePools = [];
    $moods = boxMusicEnabled() ? array_values(array_filter(boxMoods(), fn($m) => !isset($genres[$m['key']]))) : [];
    if (count($moods) >= 2) {
        // Günün iki ruh hali kategorisi, YouTube Music'in kendi listelerinden.
        $todays = [];
        foreach ([$moods[$day % count($moods)], $moods[($day + 7) % count($moods)]] as $m) {
            $key = 'm:' . $m['key'];
            if (isset($genrePools[$key])) continue;
            $todays[] = $key;
            $genres[$key] = [$m['title'], ''];
            try { $genrePools[$key] = boxMusicResults(boxMusic('/stream/music/mood', ['params' => $m['key']], 43200)['results'] ?? [], true); } catch (RuntimeException $e) { $genrePools[$key] = []; }
        }
    } else {
        foreach ($todays as $key) {
            try { $genrePools[$key] = boxSearch($genres[$key][1], true, 25, 43200); } catch (RuntimeException $e) { $genrePools[$key] = []; }
        }
    }
    $mix = array_merge($mix, array_slice($similar, 0, 12), array_slice($genrePools[$todays[0]], 0, 8));
    mt_srand($daySeed + 1); shuffle($mix); mt_srand();
    $items = $pick($mix, 20);
    if ($items) $sections[] = ['id' => 'mix', 'title' => 'Sana özel karışık', 'subtitle' => $seeds ? 'Her gün yenilenir' : 'Bugünün seçkisi', 'items' => $items];

    // Türkiye listesi (YouTube Music) — "Sana özel karışık" ve ruh hali kartlarından sonra görünür.
    if ($charts = boxCharts()) {
        $sections[] = ['id' => 'charts', 'title' => 'Türkiye\'de bu hafta', 'subtitle' => 'En çok dinlenenler', 'items' => array_slice($charts['items'], 0, 30)];
    }

    // 3) Günün türleri
    foreach ($todays as $key) {
        $pool = $genrePools[$key];
        mt_srand($daySeed + crc32($key)); shuffle($pool); mt_srand();
        $items = $pick($pool, 15);
        if ($items) $sections[] = ['id' => 'genre-' . substr(md5($key), 0, 10), 'title' => $genres[$key][0], 'subtitle' => 'Bugünün seçkisi', 'items' => $items];
    }
    return $sections;
}

/** Radyo: bir şarkıdan benzer şarkılar akışı (aynı sanatçıdan en fazla 3). */
function boxRadio(string $artist, string $title, array $exclude = []): array {
    $artist = trim(preg_replace('/\s*-\s*Topic$/iu', '', mb_substr($artist, 0, 60)));
    $title = mb_substr(trim($title), 0, 80);
    $pool = [];
    if (boxMusicEnabled() && ($title !== '' || $artist !== '')) {
        // YouTube Music'in kendi radyosu: şarkıyı bul, radyosunu al.
        try {
            $seed = boxMusicSearch(trim($title . ' ' . $artist), true, 3, 43200);
            if ($seed) $pool = boxMusicRadio($seed[0]['id'], 40);
        } catch (RuntimeException $e) { $pool = []; }
        if ($pool) {
            $skip = array_flip($exclude);
            $seen = []; $perArtist = []; $out = [];
            foreach ($pool as $r) {
                $key = boxNorm($r['title']);
                $a = boxNorm($r['channel']);
                if (isset($skip[$r['id']]) || isset($seen[$key]) || ($perArtist[$a] ?? 0) >= 3) continue;
                $seen[$key] = 1; $perArtist[$a] = ($perArtist[$a] ?? 0) + 1;
                $out[] = $r;
                if (count($out) >= 25) break;
            }
            if (count($out) >= 5) return $out;
            $pool = [];
        }
    }
    foreach (array_filter([$artist !== '' ? $artist . ' tarzı şarkılar' : '', $artist !== '' ? $artist . ' benzeri şarkılar' : '', $title !== '' ? $title . ' ' . $artist . ' radyo' : '', $artist]) as $query) {
        try { $pool = array_merge($pool, boxSearch($query, true, 25, 43200)); } catch (RuntimeException $e) {}
    }
    shuffle($pool);
    $skip = array_flip($exclude);
    $seen = []; $perArtist = []; $out = [];
    $titleKey = boxNorm($title);
    foreach ($pool as $r) {
        $key = boxNorm($r['title']);
        $a = boxNorm($r['channel']);
        if (isset($skip[$r['id']]) || isset($seen[$key]) || ($titleKey !== '' && $key === $titleKey) || ($perArtist[$a] ?? 0) >= 3) continue;
        $seen[$key] = 1; $perArtist[$a] = ($perArtist[$a] ?? 0) + 1;
        $out[] = $r;
        if (count($out) >= 25) break;
    }
    return $out;
}

/** Arama önerileri (otomatik tamamlama); YouTube API kotası harcamaz. */
function boxSuggest(string $q): array {
    $q = mb_substr(trim($q), 0, 80);
    if ($q === '') return [];
    $cacheKey = 'suggest?' . mb_strtolower($q);
    if ($cached = boxCacheGet($cacheKey, 86400)) return $cached;
    $ch = curl_init('https://suggestqueries.google.com/complete/search?' . http_build_query(['client' => 'firefox', 'ds' => 'yt', 'hl' => 'tr', 'gl' => 'tr', 'q' => $q]));
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_CONNECTTIMEOUT => 3, CURLOPT_TIMEOUT => 4, CURLOPT_USERAGENT => 'Mozilla/5.0']);
    $body = curl_exec($ch);
    curl_close($ch);
    if (is_string($body) && !mb_check_encoding($body, 'UTF-8')) $body = mb_convert_encoding($body, 'UTF-8', 'ISO-8859-9');
    $data = is_string($body) ? json_decode($body, true) : null;
    $out = [];
    foreach ((array)($data[1] ?? []) as $s) if (is_string($s) && $s !== '') $out[] = $s;
    $out = array_slice($out, 0, 8);
    boxCachePut($cacheKey, $out);
    return $out;
}

/** YouTube çalma listesi bağlantısı ya da kimliğinden liste kimliği. */
function boxPlaylistId(string $input): ?string {
    $input = trim($input);
    if (preg_match('/[?&]list=([A-Za-z0-9_-]{10,64})/', $input, $m)) return $m[1];
    if (preg_match('/^[A-Za-z0-9_-]{10,64}$/', $input)) return $input;
    return null;
}

function boxPlaylist(string $listId, int $limit = 200): array {
    if (str_starts_with($listId, 'RD')) throw new RuntimeException('YouTube\'un otomatik "Mix" listeleri içe aktarılamıyor. Normal bir çalma listesi bağlantısı dene.');
    $meta = boxYoutube('playlists', ['part' => 'snippet,contentDetails', 'id' => $listId], 1800);
    $info = $meta['items'][0] ?? null;
    if (!$info) throw new RuntimeException('Liste bulunamadı. Listenin "Herkese açık" ya da "Liste dışı" olduğundan emin ol.');
    $ids = []; $snippets = []; $page = null;
    do {
        $params = ['part' => 'snippet,contentDetails', 'playlistId' => $listId, 'maxResults' => 50];
        if ($page) $params['pageToken'] = $page;
        $data = boxYoutube('playlistItems', $params, 1800);
        foreach (($data['items'] ?? []) as $item) {
            $id = $item['contentDetails']['videoId'] ?? null;
            if (is_string($id)) { $ids[] = $id; $snippets[$id] = $item['snippet'] ?? []; }
        }
        $page = $data['nextPageToken'] ?? null;
    } while ($page && count($ids) < $limit);
    $sn = $info['snippet'] ?? [];
    return [
        'id' => $listId,
        'title' => boxCleanText((string)($sn['title'] ?? 'YouTube listesi')),
        'channel' => boxCleanText((string)($sn['channelTitle'] ?? '')),
        'thumbnail' => $sn['thumbnails']['high']['url'] ?? $sn['thumbnails']['medium']['url'] ?? null,
        'items' => boxVideoResults(array_slice($ids, 0, $limit), $snippets, 1800),
    ];
}

function boxYoutubeUnitsToday(): int {
    return (int)site('yt_units_' . gmdate('Y-m-d', time() - 8 * 3600), '0');
}

/* ---------------- VDS indirme servisi ---------------- */

function boxVdsUrl(): string { return rtrim(site('vds_url', 'https://yt2.aydworks.com.tr'), '/'); }
function boxVdsKey(): string { return secretSetting('vds_signing_key'); }

function boxSignedDownload(string $videoId, string $path = '/get', ?int $ttl = null): array {
    $key = boxVdsKey();
    if ($key === '') throw new RuntimeException('İndirme servisi yapılandırılmamış.');
    $ttl ??= max(60, min(3600, (int)site('download_link_ttl', '300')));
    $exp = time() + $ttl;
    return ['url' => boxVdsUrl() . $path . '?' . http_build_query(['v' => $videoId, 'exp' => $exp, 'sig' => hash_hmac('sha256', $videoId . ':' . $exp, $key)]), 'expires_at' => $exp];
}

/** VDS sağlık kontrolü: /health yanıtı ve süresi. */
function boxVdsHealth(): array {
    $ch = curl_init(boxVdsUrl() . '/health');
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_CONNECTTIMEOUT => 4, CURLOPT_TIMEOUT => 6, CURLOPT_USERAGENT => 'Box-Health/' . boxVersion()]);
    $t = microtime(true);
    $body = curl_exec($ch);
    $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $err = curl_error($ch);
    curl_close($ch);
    $ok = is_string($body) && $code === 200 && str_contains($body, 'ok');
    return ['at' => date('Y-m-d H:i:s'), 'ok' => $ok, 'ms' => (int)round((microtime(true) - $t) * 1000), 'code' => $code, 'error' => $ok ? '' : ($err !== '' ? $err : 'HTTP ' . $code)];
}

/** Saatlik servis izleme: VDS iki kontrol üst üste ulaşılamazsa uyarı üretir. */
/** VDS sayaçları (/stream/stats). */
function boxVdsStats(): ?array {
    if (boxVdsKey() === '') return null;
    $exp = time() + 120;
    $ch = curl_init(boxVdsUrl() . '/stream/stats?' . http_build_query(['exp' => $exp, 'sig' => hash_hmac('sha256', 'music:' . $exp, boxVdsKey())]));
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_CONNECTTIMEOUT => 4, CURLOPT_TIMEOUT => 6, CURLOPT_USERAGENT => 'Box-Health/' . boxVersion()]);
    $body = curl_exec($ch);
    $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    $data = is_string($body) ? json_decode($body, true) : null;
    return $code === 200 && is_array($data) && !empty($data['ok']) ? $data : null;
}

/** Saatlik VDS örneği: son saatteki istek/hata/süre (sayaçlar VDS açıldığından beri birikir, farkı alınır). */
function boxVdsSample(array $health): void {
    $stats = boxVdsStats();
    $last = json_decode(site('vds_stats_last'), true);
    $series = json_decode(site('vds_series'), true) ?: [];
    $point = ['at' => date('Y-m-d H:i'), 'ok' => $health['ok'] ? 1 : 0, 'ms' => (int)$health['ms']];
    if ($stats) {
        $restarted = !is_array($last) || (int)($stats['uptime'] ?? 0) < (int)($last['uptime'] ?? 0);
        foreach (['music', 'resolve'] as $k) {
            $now = $stats['stats'][$k] ?? ['n' => 0, 'err' => 0, 'avg_ms' => 0];
            $before = $restarted ? ['n' => 0, 'err' => 0, 'avg_ms' => 0] : ($last['stats'][$k] ?? ['n' => 0, 'err' => 0, 'avg_ms' => 0]);
            $n = max(0, (int)$now['n'] - (int)$before['n']);
            $err = max(0, (int)$now['err'] - (int)$before['err']);
            $totalNow = (int)$now['n'] * (int)$now['avg_ms']; $totalBefore = (int)$before['n'] * (int)$before['avg_ms'];
            $point[$k] = ['n' => $n, 'err' => $err, 'avg_ms' => $n > 0 ? (int)max(0, ($totalNow - $totalBefore) / $n) : 0];
        }
        $point['uptime'] = (int)($stats['uptime'] ?? 0);
        $point['music_ready'] = !empty($stats['music']) ? 1 : 0;
        saveSite('vds_stats_last', json_encode($stats));
        // YouTube Music hataları: son saatte en az 5 istek ve %30'dan fazlası hatalıysa bir kez haber ver.
        $m = $point['music'];
        $bad = $m['n'] >= 5 && $m['err'] / max(1, $m['n']) > 0.3;
        $wasBad = site('vds_music_bad') === '1';
        if ($bad && !$wasBad) staffAlert('services', "⚠️ YouTube Music araması hata veriyor: son saatte {$m['n']} istekten {$m['err']} tanesi başarısız. Arama yedek YouTube API ile yapılıyor.\nVDS'de: /opt/yt-api-venv/bin/pip install -U ytmusicapi && systemctl restart yt-stream");
        if (!$bad && $wasBad && $m['n'] > 0) staffAlert('services', '✅ YouTube Music araması yeniden düzgün çalışıyor.');
        saveSite('vds_music_bad', $bad ? '1' : ($m['n'] > 0 ? '0' : site('vds_music_bad')));
        if (empty($stats['music']) && site('vds_music_missing') !== '1') { staffAlert('services', '⚠️ VDS\'de ytmusicapi kurulu değil; arama YouTube API kotasından yapılıyor.'); saveSite('vds_music_missing', '1'); }
        if (!empty($stats['music'])) saveSite('vds_music_missing', '0');
    }
    $series[] = $point;
    saveSite('vds_series', json_encode(array_slice($series, -72)));
}

function boxServiceWatch(): void {
    $prev = json_decode(site('vds_health'), true);
    $now = boxVdsHealth();
    $now['fails'] = $now['ok'] ? 0 : (int)($prev['fails'] ?? 0) + 1;
    saveSite('vds_health', json_encode($now, JSON_UNESCAPED_UNICODE));
    try { boxVdsSample($now); } catch (Throwable $e) { error_log('vds sample: ' . $e->getMessage()); }
    if ($now['fails'] === 2) secEvent('critical', 'vds_down', 'VDS indirme servisine ulaşılamıyor (' . $now['error'] . '). Kullanıcılar şarkı indiremiyor. Panel > Servisler.', null, 'vds' . date('YmdH'), 6);
    if ($now['ok'] && (int)($prev['fails'] ?? 0) >= 2) staffAlert('services', '✅ VDS indirme servisi yeniden çalışıyor (' . $now['ms'] . ' ms).');
}

/** Uygulamadaki bildirim kutusuna yazar (telefona bildirim gitmese de kutuda durur). */
function boxInboxAdd(?int $userId, string $target, string $title, string $body, ?string $open = null): void {
    try {
        q('INSERT INTO notifications(user_id,target,title,body,open_to) VALUES(?,?,?,?,?)', [$userId, mb_substr($target, 0, 40), mb_substr($title, 0, 120), mb_substr($body, 0, 400), $open]);
    } catch (Throwable $e) { error_log('inbox: ' . $e->getMessage()); }
}

function boxInbox(array $u, int $limit = 50): array {
    $prem = boxIsPremium($u) ? 'premium' : 'free';
    $rows = q("SELECT id,title,body,open_to,created_at FROM notifications WHERE (user_id=? OR (user_id IS NULL AND target IN ('all', ?))) AND created_at>=? ORDER BY id DESC LIMIT " . max(1, min(100, $limit)), [$u['id'], $prem, $u['created_at']])->fetchAll();
    return array_map(fn($r) => ['id' => (int)$r['id'], 'title' => (string)$r['title'], 'body' => (string)$r['body'], 'open' => $r['open_to'], 'created_at' => date(DATE_ATOM, (int)strtotime((string)$r['created_at']))], $rows);
}

function boxDailyCleanup(): void {
    q('DELETE FROM notifications WHERE created_at<DATE_SUB(NOW(),INTERVAL 90 DAY)');
    q('DELETE FROM login_attempts WHERE attempted_at<DATE_SUB(NOW(),INTERVAL 2 DAY)');
    q('DELETE FROM tokens WHERE expires_at<NOW()');
    q('DELETE FROM search_log WHERE day<DATE_SUB(CURDATE(),INTERVAL 120 DAY)');
    q('DELETE FROM search_terms WHERE day<DATE_SUB(CURDATE(),INTERVAL 90 DAY)');
    q('DELETE FROM api_metrics WHERE bucket<DATE_SUB(NOW(),INTERVAL 30 DAY)');
    q("DELETE FROM site_settings WHERE setting_key LIKE 'yt\\_units\\_%' AND setting_key<?", ['yt_units_' . date('Y-m-d', strtotime('-40 days'))]);
    foreach (glob(nbPrivateDir('cache') . '/*.json') ?: [] as $f) if (time() - (int)@filemtime($f) > 86400) @unlink($f);
}

/* ---------------- API metrikleri ---------------- */

function boxApiMetric(int $status, float $started): void {
    try {
        $ms = (int)round((microtime(true) - $started) * 1000);
        $bucket = date('Y-m-d H:i:00', (int)(floor(time() / 300) * 300));
        q('INSERT INTO api_metrics(bucket,requests,client_errors,server_errors,total_ms,max_ms) VALUES(?,1,?,?,?,?) ON DUPLICATE KEY UPDATE requests=requests+1,client_errors=client_errors+VALUES(client_errors),server_errors=server_errors+VALUES(server_errors),total_ms=total_ms+VALUES(total_ms),max_ms=GREATEST(max_ms,VALUES(max_ms))',
            [$bucket, $status >= 400 && $status < 500 ? 1 : 0, $status >= 500 ? 1 : 0, $ms, $ms]);
    } catch (Throwable $e) {}
}

/* ---------------- Sürüm karşılaştırma ---------------- */

function boxVersionLess(string $a, string $b): bool {
    $na = array_map('intval', explode('.', preg_replace('/[^0-9.]/', '', $a) ?: '0'));
    $nb = array_map('intval', explode('.', preg_replace('/[^0-9.]/', '', $b) ?: '0'));
    for ($i = 0; $i < max(count($na), count($nb)); $i++) {
        $x = $na[$i] ?? 0; $y = $nb[$i] ?? 0;
        if ($x !== $y) return $x < $y;
    }
    return false;
}
