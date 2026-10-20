<?php
if (!defined('ROOT')) { http_response_code(404); exit; }

/*
 * Box uygulama API'si.
 *   /api/v1/config            GET   uzaktan ayarlar (bakım, duyuru, minimum sürüm)
 *   /api/v1/auth/register     POST  {email,password,name}
 *   /api/v1/auth/login        POST  {email,password}
 *   /api/v1/auth/logout       POST
 *   /api/v1/me                GET   kullanıcı + kota | POST {name}
 *   /api/v1/me/delete         POST  {password}
 *   /api/v1/search?q=         GET   (premium)
 *   /api/v1/download?video_id GET   (premium) VDS'den indirme için imzalı bağlantı
 *   /health, /cron
 * Eski sürüm uyumluluğu: /box-api/index.php?action=... aynı işleyicilere yönlenir.
 * Yanıt biçimi: {"ok": true, ...} ya da {"ok": false, "error": "..."}
 */

$started = microtime(true);
header('Cache-Control: no-store');
header("Content-Security-Policy: default-src 'none'; frame-ancestors 'none'");
$method = strtoupper((string)($_SERVER['REQUEST_METHOD'] ?? 'GET'));
$path = routePath();

register_shutdown_function(function () use ($started, $path): void {
    if (str_starts_with($path, '/api/') || str_starts_with($path, '/box-api')) boxApiMetric(http_response_code() ?: 200, $started);
});

if ($path === '/health') {
    jsonOut(['ok' => true, 'service' => 'box', 'version' => boxVersion(), 'time' => time()]);
}

if ($path === '/cron') {
    $key = (string)($_GET['key'] ?? '');
    $expected = site('cron_key');
    if ($expected === '' || !hash_equals($expected, $key)) jsonOut(['ok' => false, 'error' => 'Yetkisiz.'], 403);
    @set_time_limit(300); @ignore_user_abort(true);
    jsonOut(['ok' => true] + runCron());
}

if ($method === 'OPTIONS') { http_response_code(204); exit; }

apiIpThrottle();

/* ---------------- Rota çözümü ---------------- */

$legacy = str_starts_with($path, '/box-api');
if ($legacy) {
    $action = (string)($_GET['action'] ?? '');
    $route = [
        'register' => 'auth/register', 'login' => 'auth/login', 'logout' => 'auth/logout', 'me' => 'me',
        'update_profile' => 'me', 'delete_account' => 'me/delete', 'search' => 'search', 'download_link' => 'download', 'ping' => 'ping', 'config' => 'config',
    ][$action] ?? '';
} else {
    $route = preg_match('#^/api/v1/(.+)$#', $path, $m) ? $m[1] : '';
}

$need = function (string $verb) use ($method): void {
    if ($method !== $verb) jsonOut(['ok' => false, 'error' => 'Bu işlem için ' . $verb . ' isteği gerekli.'], 405);
};
$str = function (string $key, int $max = 255): string {
    $v = body()[$key] ?? '';
    return is_string($v) ? mb_substr(trim($v), 0, $max) : '';
};

/* ---------------- Herkese açık ---------------- */

if ($route === 'ping') jsonOut(['ok' => true, 'service' => 'box', 'time' => time()]);

if ($route === 'config') {
    jsonOut([
        'ok' => true,
        'server_version' => boxVersion(),
        'maintenance' => ['on' => configBool('maintenance_mode'), 'message' => (string)configValue('maintenance_message', '')],
        'min_app_version' => (string)configValue('min_app_version', '1.0'),
        'registration_open' => configBool('registration_open', true),
        'announcement' => configBool('announcement_on') ? ['title' => (string)configValue('announcement_title', ''), 'body' => (string)configValue('announcement_body', ''), 'id' => substr(sha1((string)configValue('announcement_title', '') . (string)configValue('announcement_body', '')), 0, 12)] : null,
        'support_email' => (string)configValue('support_email', ''),
    ]);
}

/* Bakım modu ve zorunlu güncelleme (config dışındaki bütün istekler) */
if (configBool('maintenance_mode')) {
    jsonOut(['ok' => false, 'maintenance' => true, 'error' => (string)configValue('maintenance_message', 'Bakım yapılıyor, birazdan tekrar dene.')], 503);
}
$clientVersion = (string)($_SERVER['HTTP_X_BOX_VERSION'] ?? '');
$minVersion = (string)configValue('min_app_version', '1.0');
if ($clientVersion !== '' && boxVersionLess(preg_replace('/\s.*$/', '', $clientVersion), $minVersion)) {
    jsonOut(['ok' => false, 'update_required' => true, 'error' => 'Uygulamanın yeni sürümünü yüklemen gerekiyor.'], 426);
}

/* ---------------- Hesap ---------------- */

switch ($route) {
    case 'auth/register':
        $need('POST');
        throttle('register:' . clientIpHash(), 8, 3600);
        if (!configBool('registration_open', true)) jsonOut(['ok' => false, 'error' => 'Yeni kayıtlar şu an kapalı.'], 403);
        $email = mb_strtolower($str('email', 190));
        $password = (string)(body()['password'] ?? '');
        $name = $str('name', 60);
        if (!filter_var($email, FILTER_VALIDATE_EMAIL)) jsonOut(['ok' => false, 'error' => 'Geçerli bir e-posta adresi gir.'], 400);
        if (strlen($password) < 8 || strlen($password) > 200) jsonOut(['ok' => false, 'error' => 'Şifre en az 8 karakter olmalı.'], 400);
        if ($name === '') $name = mb_substr(explode('@', $email)[0], 0, 60);
        if (boxFindUserByEmail($email)) jsonOut(['ok' => false, 'error' => 'Bu e-posta ile zaten bir hesap var.'], 409);
        q('INSERT INTO users(email,password_hash,display_name,last_login_at,last_seen_at) VALUES(?,?,?,NOW(),NOW())', [$email, password_hash($password, PASSWORD_DEFAULT), $name]);
        $id = (int)db()->lastInsertId();
        $trial = (int)configValue('new_user_premium_days', 0);
        if ($trial > 0) boxGrantPremium($id, $trial, null, 'trial');
        jsonOut(['ok' => true, 'token' => boxIssueToken($id, (string)($_SERVER['HTTP_USER_AGENT'] ?? '')), 'user' => boxUserPublic(boxFindUser($id))], 201);

    case 'auth/login':
        $need('POST');
        $ip = clientIp();
        if ((int)q('SELECT COUNT(*) FROM login_attempts WHERE ip=? AND attempted_at>DATE_SUB(NOW(),INTERVAL 15 MINUTE)', [$ip])->fetchColumn() >= 10) {
            jsonOut(['ok' => false, 'error' => 'Çok fazla deneme yaptın, 15 dakika sonra tekrar dene.'], 429);
        }
        $email = mb_strtolower($str('email', 190));
        $password = (string)(body()['password'] ?? '');
        $u = boxFindUserByEmail($email);
        $valid = password_verify($password, $u ? (string)$u['password_hash'] : '$2y$10$aEfbUMLzcrPAJLWv.suOb.zIrNmwBkoU14U9Cxh/ny/QX4eKnHch.');
        if (!$u || !$valid) {
            q('INSERT INTO login_attempts(ip) VALUES(?)', [$ip]);
            jsonOut(['ok' => false, 'error' => 'E-posta veya şifre hatalı.'], 401);
        }
        if ((int)$u['is_banned'] === 1) jsonOut(['ok' => false, 'error' => 'Hesabın askıya alındı.', 'reason' => (string)($u['ban_reason'] ?? '')], 403);
        if (password_needs_rehash((string)$u['password_hash'], PASSWORD_DEFAULT)) q('UPDATE users SET password_hash=? WHERE id=?', [password_hash($password, PASSWORD_DEFAULT), $u['id']]);
        q('UPDATE users SET last_login_at=NOW(), last_seen_at=NOW() WHERE id=?', [$u['id']]);
        q('DELETE FROM login_attempts WHERE ip=?', [$ip]);
        jsonOut(['ok' => true, 'token' => boxIssueToken((int)$u['id'], (string)($_SERVER['HTTP_USER_AGENT'] ?? '')), 'user' => boxUserPublic(boxFindUser((int)$u['id']))]);

    case 'auth/logout':
        $need('POST');
        if ($t = boxBearer()) q('DELETE FROM tokens WHERE token_hash=?', [hash('sha256', $t)]);
        jsonOut(['ok' => true]);

    case 'me':
        $u = boxApiUser();
        if ($method === 'POST') {
            $name = $str('name', 60);
            if ($name === '') jsonOut(['ok' => false, 'error' => 'İsim boş olamaz.'], 400);
            q('UPDATE users SET display_name=? WHERE id=?', [$name, $u['id']]);
            $u = boxFindUser((int)$u['id']);
        }
        $out = ['ok' => true, 'user' => boxUserPublic($u)];
        if (boxIsPremium($u)) $out['quota'] = boxQuota($u);
        jsonOut($out);

    case 'me/delete':
        $need('POST');
        $u = boxApiUser();
        if (!password_verify((string)(body()['password'] ?? ''), (string)$u['password_hash'])) jsonOut(['ok' => false, 'error' => 'Şifre hatalı.'], 401);
        q('DELETE FROM users WHERE id=?', [$u['id']]);
        jsonOut(['ok' => true]);

    /* ---------------- Premium ---------------- */

    case 'search':
        $u = boxApiUser();
        if (!boxIsPremium($u)) jsonOut(['ok' => false, 'error' => 'Bu özellik premium üyelere açık.'], 403);
        throttle('search:' . $u['id'], 30, 60);
        $q = isset($_GET['q']) && is_string($_GET['q']) ? trim($_GET['q']) : '';
        if ($q === '' || mb_strlen($q) > 200) jsonOut(['ok' => false, 'error' => 'Arama metni gerekli.'], 400);
        $limit = (int)configValue('premium_daily_searches', 400);
        if ($limit > 0 && boxTodaySearches((int)$u['id']) >= $limit) jsonOut(['ok' => false, 'error' => 'Bugünlük arama hakkın doldu, yarın tekrar dene.'], 429);
        try { $results = boxSearch($q); }
        catch (RuntimeException $e) { jsonOut(['ok' => false, 'error' => $e->getMessage()], 502); }
        q('INSERT INTO search_log(day,user_id,n) VALUES(CURDATE(),?,1) ON DUPLICATE KEY UPDATE n=n+1', [$u['id']]);
        $term = mb_substr(mb_strtolower(preg_replace('/\s+/u', ' ', $q)), 0, 120);
        if ($term !== '') q('INSERT INTO search_terms(day,term,n) VALUES(CURDATE(),?,1) ON DUPLICATE KEY UPDATE n=n+1', [$term]);
        jsonOut(['ok' => true, 'results' => $results]);

    case 'feed':
        $u = boxApiUser();
        if (!boxIsPremium($u)) jsonOut(['ok' => false, 'error' => 'Bu özellik premium üyelere açık.'], 403);
        throttle('feed:' . $u['id'], 20, 60);
        $artists = array_filter(array_map('trim', explode('|', mb_substr((string)($_GET['artists'] ?? ''), 0, 300))));
        try { $sections = boxFeed(array_values($artists)); }
        catch (RuntimeException $e) { jsonOut(['ok' => false, 'error' => $e->getMessage()], 502); }
        $genres = [];
        foreach (boxGenres() as $key => [$title]) $genres[] = ['key' => $key, 'title' => $title];
        jsonOut(['ok' => true, 'sections' => $sections, 'genres' => $genres]);

    case 'feed/genre':
        $u = boxApiUser();
        if (!boxIsPremium($u)) jsonOut(['ok' => false, 'error' => 'Bu özellik premium üyelere açık.'], 403);
        throttle('feed:' . $u['id'], 20, 60);
        $genre = boxGenres()[(string)($_GET['key'] ?? '')] ?? null;
        if (!$genre) jsonOut(['ok' => false, 'error' => 'Bilinmeyen tür.'], 404);
        try { $items = boxSearch($genre[1], true, 30, 43200); }
        catch (RuntimeException $e) { jsonOut(['ok' => false, 'error' => $e->getMessage()], 502); }
        jsonOut(['ok' => true, 'title' => $genre[0], 'results' => $items]);

    case 'radio':
        $u = boxApiUser();
        if (!boxIsPremium($u)) jsonOut(['ok' => false, 'error' => 'Bu özellik premium üyelere açık.'], 403);
        throttle('radio:' . $u['id'], 20, 60);
        $exclude = array_values(array_filter(explode(',', mb_substr((string)($_GET['exclude'] ?? ''), 0, 1200)), fn($id) => preg_match(BOX_VIDEO_ID, $id)));
        try { $items = boxRadio((string)($_GET['artist'] ?? ''), (string)($_GET['title'] ?? ''), $exclude); }
        catch (RuntimeException $e) { jsonOut(['ok' => false, 'error' => $e->getMessage()], 502); }
        jsonOut(['ok' => true, 'results' => $items]);

    case 'suggest':
        $u = boxApiUser();
        throttle('suggest:' . $u['id'], 120, 60);
        jsonOut(['ok' => true, 'suggestions' => boxSuggest((string)($_GET['q'] ?? ''))]);

    case 'playlist':
        $u = boxApiUser();
        if (!boxIsPremium($u)) jsonOut(['ok' => false, 'error' => 'Bu özellik premium üyelere açık.'], 403);
        throttle('playlist:' . $u['id'], 10, 60);
        $listId = boxPlaylistId((string)($_GET['url'] ?? ''));
        if (!$listId) jsonOut(['ok' => false, 'error' => 'Geçerli bir YouTube çalma listesi bağlantısı yapıştır (içinde "list=" olmalı).'], 400);
        try { $playlist = boxPlaylist($listId); }
        catch (RuntimeException $e) { jsonOut(['ok' => false, 'error' => $e->getMessage()], 422); }
        jsonOut(['ok' => true, 'playlist' => $playlist]);

    case 'stream':
        // İndirmeden dinleme: imzalı bağlantı verir, indirme kotasından düşmez.
        $u = boxApiUser();
        if (!boxIsPremium($u)) jsonOut(['ok' => false, 'error' => 'Bu özellik premium üyelere açık.'], 403);
        throttle('stream:' . $u['id'], 30, 60);
        throttle('stream-day:' . $u['id'], 800, 86400);
        $videoId = isset($_GET['video_id']) && is_string($_GET['video_id']) ? $_GET['video_id'] : '';
        if (!preg_match(BOX_VIDEO_ID, $videoId)) jsonOut(['ok' => false, 'error' => 'Geçersiz video.'], 400);
        try {
            $file = boxSignedDownload($videoId);
            $live = boxSignedDownload($videoId, '/stream', 6 * 3600);
        } catch (RuntimeException $e) { jsonOut(['ok' => false, 'error' => $e->getMessage()], 503); }
        // url: anında çalma (VDS /stream, parça parça), file_url: tam dosya (önbellek için)
        jsonOut(['ok' => true, 'url' => $live['url'], 'video_url' => $live['url'] . '&kind=video', 'file_url' => $file['url'], 'expires_at' => $live['expires_at']]);

    case 'download':
        $u = boxApiUser();
        if (!boxIsPremium($u)) jsonOut(['ok' => false, 'error' => 'Bu özellik premium üyelere açık.'], 403);
        throttle('download:' . $u['id'], 90, 60);
        $videoId = isset($_GET['video_id']) && is_string($_GET['video_id']) ? $_GET['video_id'] : '';
        if (!preg_match(BOX_VIDEO_ID, $videoId)) jsonOut(['ok' => false, 'error' => 'Geçersiz video.'], 400);
        $limit = boxQuota($u)['downloads_limit'];
        if ($limit > 0 && boxTodayDownloads((int)$u['id']) >= $limit) jsonOut(['ok' => false, 'error' => 'Bugünlük indirme hakkın doldu, yarın tekrar dene.'], 429);
        try { $link = boxSignedDownload($videoId); }
        catch (RuntimeException $e) { jsonOut(['ok' => false, 'error' => $e->getMessage()], 503); }
        $title = isset($_GET['title']) && is_string($_GET['title']) ? mb_substr(trim($_GET['title']), 0, 255) : '';
        q('INSERT INTO downloads(user_id,video_id,title) VALUES(?,?,?)', [$u['id'], $videoId, $title]);
        jsonOut(['ok' => true, 'url' => $link['url'], 'expires_at' => $link['expires_at']]);
}

jsonOut(['ok' => false, 'error' => 'Geçersiz işlem.'], 404);
