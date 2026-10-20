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
    ];
}

function boxIssueToken(int $userId, string $device = ''): string {
    $token = bin2hex(random_bytes(32));
    $days = max(1, (int)site('token_ttl_days', '180'));
    q('INSERT INTO tokens(user_id,token_hash,device,expires_at) VALUES(?,?,?,DATE_ADD(NOW(),INTERVAL ? DAY))', [$userId, hash('sha256', $token), $device !== '' ? mb_substr($device, 0, 120) : null, $days]);
    return $token;
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

function boxSearch(string $query, bool $music = false, int $max = 25, ?int $ttl = null): array {
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
    foreach ($todays as $key) {
        try { $genrePools[$key] = boxSearch($genres[$key][1], true, 25, 43200); } catch (RuntimeException $e) { $genrePools[$key] = []; }
    }
    $mix = array_merge($mix, array_slice($similar, 0, 12), array_slice($genrePools[$todays[0]], 0, 8));
    mt_srand($daySeed + 1); shuffle($mix); mt_srand();
    $items = $pick($mix, 20);
    if ($items) $sections[] = ['id' => 'mix', 'title' => 'Sana özel karışık', 'subtitle' => $seeds ? 'Her gün yenilenir' : 'Bugünün seçkisi', 'items' => $items];

    // 3) Günün türleri
    foreach ($todays as $key) {
        $pool = $genrePools[$key];
        mt_srand($daySeed + crc32($key)); shuffle($pool); mt_srand();
        $items = $pick($pool, 15);
        if ($items) $sections[] = ['id' => 'genre-' . $key, 'title' => $genres[$key][0], 'subtitle' => 'Bugünün seçkisi', 'items' => $items];
    }
    return $sections;
}

/** Radyo: bir şarkıdan benzer şarkılar akışı (aynı sanatçıdan en fazla 3). */
function boxRadio(string $artist, string $title, array $exclude = []): array {
    $artist = trim(preg_replace('/\s*-\s*Topic$/iu', '', mb_substr($artist, 0, 60)));
    $title = mb_substr(trim($title), 0, 80);
    $pool = [];
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
function boxServiceWatch(): void {
    $prev = json_decode(site('vds_health'), true);
    $now = boxVdsHealth();
    $now['fails'] = $now['ok'] ? 0 : (int)($prev['fails'] ?? 0) + 1;
    saveSite('vds_health', json_encode($now, JSON_UNESCAPED_UNICODE));
    if ($now['fails'] === 2) secEvent('critical', 'vds_down', 'VDS indirme servisine ulaşılamıyor (' . $now['error'] . '). Kullanıcılar şarkı indiremiyor. Panel > Servisler.', null, 'vds' . date('YmdH'), 6);
    if ($now['ok'] && (int)($prev['fails'] ?? 0) >= 2) staffAlert('services', '✅ VDS indirme servisi yeniden çalışıyor (' . $now['ms'] . ' ms).');
}

function boxDailyCleanup(): void {
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
