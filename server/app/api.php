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

// Profil fotoğrafı (adı tahmin edilemez, herkese açık önbelleklenebilir)
if (preg_match('#^/api/v1/avatar/([a-f0-9]{32}\.(jpg|png))$#', $path, $am)) {
    $file = boxAvatarDir() . '/' . $am[1];
    if (!is_file($file)) { http_response_code(404); exit; }
    header('Content-Type: ' . ($am[2] === 'png' ? 'image/png' : 'image/jpeg'));
    header('Content-Length: ' . filesize($file));
    header('Cache-Control: public, max-age=31536000, immutable');
    header_remove('Content-Security-Policy');
    readfile($file);
    exit;
}

// Çalma listesi kapağı (adı tahmin edilemez)
if (preg_match('#^/api/v1/pcover/([a-f0-9]{32}\.jpg)$#', $path, $cm)) {
    $file = boxLibCoverDir() . '/' . $cm[1];
    if (!is_file($file)) { http_response_code(404); exit; }
    header('Content-Type: image/jpeg');
    header('Content-Length: ' . filesize($file));
    header('Cache-Control: public, max-age=31536000, immutable');
    header_remove('Content-Security-Policy');
    readfile($file);
    exit;
}

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
        'announcement' => configBool('announcement_on') && boxAnnouncementVisible(boxOptionalUser()) ? ['title' => (string)configValue('announcement_title', ''), 'body' => (string)configValue('announcement_body', ''), 'id' => substr(sha1((string)configValue('announcement_title', '') . (string)configValue('announcement_body', '')), 0, 12)] : null,
        'support_email' => (string)configValue('support_email', ''),
        'browser_shortcuts' => boxBrowserShortcuts(),
    ]);
}

/* App Store Server Notifications V2: abonelik yenilendi, bitti, iade edildi. Bakımda da işlenir. */
if ($route === 'appstore/notify' && $method === 'POST') {
    $body = json_decode((string)file_get_contents('php://input', false, null, 0, 200000), true);
    $signed = is_array($body) ? (string)($body['signedPayload'] ?? '') : '';
    try {
        $result = boxHandleStoreNotification($signed);
        error_log('[Box] App Store bildirimi: ' . json_encode($result, JSON_UNESCAPED_UNICODE));
        jsonOut(['ok' => true]);
    } catch (Throwable $e) {
        error_log('[Box] App Store bildirimi reddedildi: ' . $e->getMessage());
        // Apple doğrulanamayan bildirimi tekrar denemesin diye 200; içerik işlenmedi.
        jsonOut(['ok' => false]);
    }
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

    case 'auth/apple':
        // Apple ile giriş: hesap varsa açar, yoksa oluşturur.
        $need('POST');
        throttle('apple:' . clientIpHash(), 20, 600);
        try { $apple = boxVerifyAppleToken((string)(body()['identity_token'] ?? ''), (string)(body()['nonce'] ?? '')); }
        catch (RuntimeException $e) { jsonOut(['ok' => false, 'error' => $e->getMessage()], 401); }
        $u = q('SELECT * FROM users WHERE apple_sub=? LIMIT 1', [$apple['sub']])->fetch() ?: null;
        $created = false;
        if (!$u) {
            if (!configBool('registration_open', true)) jsonOut(['ok' => false, 'error' => 'Yeni kayıtlar şu an kapalı.'], 403);
            $email = $apple['email'];
            if ($email !== null && boxFindUserByEmail($email)) {
                // Otomatik birleştirme yok: aynı e-postayla şifreli hesap açıp bekleyen biri başkasının hesabını ele geçirmesin.
                jsonOut(['ok' => false, 'code' => 'email_exists', 'error' => 'Bu e-postayla kayıtlı bir Box hesabın var. E-posta ve şifrenle giriş yap, sonra Profil > Apple\'ı bağla.'], 409);
            }
            if ($email === null) $email = 'apple-' . substr(hash('sha256', $apple['sub']), 0, 16) . '@apple.box';
            $name = $str('name', 60);
            if ($name === '') $name = $apple['private_email'] || str_ends_with($email, '@apple.box') ? 'Box dinleyicisi' : mb_substr(explode('@', $email)[0], 0, 60);
            $refresh = boxAppleExchangeCode((string)(body()['authorization_code'] ?? ''));
            q('INSERT INTO users(email,password_hash,has_password,apple_sub,apple_refresh,display_name,last_login_at,last_seen_at) VALUES(?,?,0,?,?,?,NOW(),NOW())',
                [$email, password_hash(bin2hex(random_bytes(24)), PASSWORD_DEFAULT), $apple['sub'], $refresh ? encryptSecret($refresh) : null, $name]);
            $id = (int)db()->lastInsertId();
            $trial = (int)configValue('new_user_premium_days', 0);
            if ($trial > 0) boxGrantPremium($id, $trial, null, 'trial');
            $u = boxFindUser($id);
            $created = true;
        } else {
            if ((int)$u['is_banned'] === 1) jsonOut(['ok' => false, 'error' => 'Hesabın askıya alındı.', 'reason' => (string)($u['ban_reason'] ?? '')], 403);
            if (empty($u['apple_refresh']) && ($refresh = boxAppleExchangeCode((string)(body()['authorization_code'] ?? '')))) q('UPDATE users SET apple_refresh=? WHERE id=?', [encryptSecret($refresh), $u['id']]);
            q('UPDATE users SET last_login_at=NOW(), last_seen_at=NOW() WHERE id=?', [$u['id']]);
        }
        jsonOut(['ok' => true, 'created' => $created, 'token' => boxIssueToken((int)$u['id'], (string)($_SERVER['HTTP_USER_AGENT'] ?? '')), 'user' => boxUserPublic(boxFindUser((int)$u['id']))], $created ? 201 : 200);

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

    case 'me/avatar':
        $need('POST');
        $u = boxApiUser();
        throttle('avatar:' . $u['id'], 10, 3600);
        $data = body()['image'] ?? '';
        if ((body()['remove'] ?? false) === true) {
            boxDeleteAvatarFile($u['avatar_file'] ?? null);
            q('UPDATE users SET avatar_file=NULL WHERE id=?', [$u['id']]);
        } else {
            $binary = is_string($data) ? base64_decode($data, true) : false;
            if ($binary === false) jsonOut(['ok' => false, 'error' => 'Fotoğraf okunamadı.'], 400);
            try { boxSetAvatar($u, $binary); }
            catch (RuntimeException $e) { jsonOut(['ok' => false, 'error' => $e->getMessage()], 400); }
        }
        jsonOut(['ok' => true, 'user' => boxUserPublic(boxFindUser((int)$u['id']))]);

    case 'me/apple':
        // Var olan hesaba Apple ile girişi bağla ya da kaldır.
        $need('POST');
        $u = boxApiUser();
        if ((body()['remove'] ?? false) === true) {
            if ((int)($u['has_password'] ?? 1) !== 1) jsonOut(['ok' => false, 'error' => 'Bu hesap yalnızca Apple ile açılıyor; bağlantı kaldırılırsa giriş yapamazsın.'], 400);
            boxAppleRevoke($u);
            q('UPDATE users SET apple_sub=NULL, apple_refresh=NULL WHERE id=?', [$u['id']]);
            jsonOut(['ok' => true, 'user' => boxUserPublic(boxFindUser((int)$u['id']))]);
        }
        throttle('apple-link:' . $u['id'], 10, 600);
        try { $apple = boxVerifyAppleToken((string)(body()['identity_token'] ?? ''), (string)(body()['nonce'] ?? '')); }
        catch (RuntimeException $e) { jsonOut(['ok' => false, 'error' => $e->getMessage()], 401); }
        $owner = q('SELECT id FROM users WHERE apple_sub=? LIMIT 1', [$apple['sub']])->fetchColumn();
        if ($owner && (int)$owner !== (int)$u['id']) jsonOut(['ok' => false, 'error' => 'Bu Apple hesabı başka bir Box hesabına bağlı.'], 409);
        $refresh = boxAppleExchangeCode((string)(body()['authorization_code'] ?? ''));
        q('UPDATE users SET apple_sub=?, apple_refresh=COALESCE(?,apple_refresh) WHERE id=?', [$apple['sub'], $refresh ? encryptSecret($refresh) : null, $u['id']]);
        jsonOut(['ok' => true, 'user' => boxUserPublic(boxFindUser((int)$u['id']))]);

    case 'me/push':
        // Bildirim için cihaz kaydı (ya da çıkışta silme).
        $need('POST');
        $u = boxApiUser();
        $token = strtolower(preg_replace('/[^0-9a-fA-F]/', '', (string)(body()['token'] ?? '')));
        if (strlen($token) < 32 || strlen($token) > 200) jsonOut(['ok' => false, 'error' => 'Geçersiz cihaz kimliği.'], 400);
        if ((body()['remove'] ?? false) === true) {
            q('DELETE FROM push_devices WHERE token=? AND user_id=?', [$token, $u['id']]);
            jsonOut(['ok' => true]);
        }
        $env = (body()['environment'] ?? '') === 'sandbox' ? 'sandbox' : 'production';
        $ver = mb_substr(preg_replace('/[^0-9A-Za-z.() -]/', '', (string)($_SERVER['HTTP_X_BOX_VERSION'] ?? '')), 0, 20);
        q('INSERT INTO push_devices(user_id,token,environment,app_version,device_id,last_seen_at) VALUES(?,?,?,?,?,NOW()) ON DUPLICATE KEY UPDATE user_id=VALUES(user_id), environment=VALUES(environment), app_version=VALUES(app_version), device_id=COALESCE(VALUES(device_id),device_id), last_seen_at=NOW()', [$u['id'], $token, $env, $ver, boxClientDevice()['device_id']]);
        jsonOut(['ok' => true]);

    case 'me/purchase':
        $u = boxApiUser();
        if ($method !== 'POST') jsonOut(['ok' => false, 'error' => 'Geçersiz işlem.'], 405);
        throttle('purchase:' . $u['id'], 30, 3600);
        $data = body(64 * 1024);
        $items = is_array($data['transactions'] ?? null) ? $data['transactions'] : [(string)($data['jws'] ?? '')];
        $applied = 0; $errors = [];
        foreach (array_slice($items, 0, 20) as $jws) {
            try {
                $tx = boxVerifyAppleJws((string)$jws);
                $result = boxApplyStoreTransaction($tx, (int)$u['id'], boxStoreToken($u));
                if ($result['status'] !== 'same') boxStoreAlert((int)$u['id'], $result['status'], $result['row']);
                $applied++;
            } catch (RuntimeException $e) {
                // Kullanıcıya yalnızca anlamlı hatalar; imza/sertifika ayrıntısı sistem günlüğüne.
                if ($e->getCode() !== 1) error_log('[Box] Satın alma doğrulanamadı: ' . $e->getMessage());
                $errors[] = $e->getCode() === 1 ? $e->getMessage() : 'Satın alma doğrulanamadı.';
            }
        }
        if ($applied === 0) jsonOut(['ok' => false, 'error' => $errors[0] ?? 'Satın alma doğrulanamadı.'], 422);
        $u = boxFindUser((int)$u['id']);
        jsonOut(['ok' => true, 'user' => boxUserPublic($u)]);

    case 'me/devices':
        // Oturum açık cihazlar; POST {id} o cihazdan, {others:true} bu cihaz dışındakilerden çıkış.
        $u = boxApiUser();
        if ($method === 'POST') {
            throttle('devices:' . $u['id'], 30, 600);
            if ((body()['others'] ?? false) === true) {
                foreach (q('SELECT id FROM tokens WHERE user_id=? AND id<>?', [$u['id'], $u['token_id']])->fetchAll(PDO::FETCH_COLUMN) as $tid) boxLogoutDevice((int)$u['id'], (int)$tid);
            } else {
                $tid = (int)(body()['id'] ?? 0);
                if ($tid === (int)$u['token_id']) jsonOut(['ok' => false, 'error' => 'Bu cihazdan çıkmak için Hesap sayfasındaki Çıkış yap düğmesini kullan.'], 400);
                if (!boxLogoutDevice((int)$u['id'], $tid)) jsonOut(['ok' => false, 'error' => 'Cihaz bulunamadı.'], 404);
            }
        }
        $devices = array_map(fn($d) => array_merge($d, ['current' => $d['id'] === (int)$u['token_id'], 'last_used_at' => date(DATE_ATOM, (int)strtotime((string)$d['last_used_at'])), 'created_at' => date(DATE_ATOM, (int)strtotime((string)$d['created_at']))]), boxUserDevices((int)$u['id']));
        jsonOut(['ok' => true, 'devices' => $devices]);

    case 'me/library':
        // Hesaba bağlı kitaplık: GET güncel hali, POST değişiklikleri uygula ve güncel hali dön.
        if ($method === 'POST') {
            $b = body(6 * 1024 * 1024);
            $u = boxApiUser();
            throttle('library:' . $u['id'], 120, 600);
            try { boxLibApply((int)$u['id'], $b); }
            catch (PDOException $e) { nbReport($e); jsonOut(['ok' => false, 'error' => 'Kitaplık kaydedilemedi, birazdan tekrar denenecek.'], 500); }
        } else {
            $u = boxApiUser();
            throttle('library-get:' . $u['id'], 120, 600);
        }
        jsonOut(['ok' => true] + boxLibState((int)$u['id']));

    case 'me/library/cover':
        $need('POST');
        $b = body(2 * 1024 * 1024);
        $u = boxApiUser();
        throttle('pcover:' . $u['id'], 60, 3600);
        $pid = boxLibUuid($b['id'] ?? null);
        if (!$pid) jsonOut(['ok' => false, 'error' => 'Liste bulunamadı.'], 404);
        try {
            if (($b['remove'] ?? false) === true) $url = boxLibSetCover((int)$u['id'], $pid, null);
            else {
                $binary = is_string($b['image'] ?? null) ? base64_decode($b['image'], true) : false;
                if ($binary === false) jsonOut(['ok' => false, 'error' => 'Kapak okunamadı.'], 400);
                $url = boxLibSetCover((int)$u['id'], $pid, $binary);
            }
        } catch (RuntimeException $e) { jsonOut(['ok' => false, 'error' => $e->getMessage()], 400); }
        jsonOut(['ok' => true, 'cover_url' => $url]);

    case 'me/delete':
        $need('POST');
        $u = boxApiUser();
        if ((int)($u['has_password'] ?? 1) === 1) {
            if (!password_verify((string)(body()['password'] ?? ''), (string)$u['password_hash'])) jsonOut(['ok' => false, 'error' => 'Şifre hatalı.'], 401);
        } elseif ((body()['confirm'] ?? '') !== 'SIL') {
            jsonOut(['ok' => false, 'error' => 'Silmeyi onaylaman gerekiyor.'], 400);
        }
        boxAppleRevoke($u);
        boxDeleteAvatarFile($u['avatar_file'] ?? null);
        boxLibDeleteUserFiles((int)$u['id']);
        q('DELETE FROM users WHERE id=?', [$u['id']]);
        // Silinen premium üye izleme parmak izini değiştirir; kendi işlemimiz olduğunu bildir (yanlış alarm olmasın).
        if ((int)$u['is_premium'] === 1) watchRefresh();
        jsonOut(['ok' => true]);

    /* ---------------- Premium ---------------- */

    case 'search':
        $u = boxApiUser();
        boxRequireFeature($u, 'search');
        throttle('search:' . $u['id'], 30, 60);
        $q = isset($_GET['q']) && is_string($_GET['q']) ? trim($_GET['q']) : '';
        if ($q === '' || mb_strlen($q) > 200) jsonOut(['ok' => false, 'error' => 'Arama metni gerekli.'], 400);
        // Filtre çipleri (Videolar, Albümler, Sanatçılar, Listeler): aynı aramanın parçası, hak düşmez.
        $kind = (string)($_GET['filter'] ?? '');
        if (in_array($kind, ['videos', 'albums', 'artists', 'playlists'], true)) {
            if (!boxMusicEnabled()) jsonOut(['ok' => true, 'results' => [], 'items' => []]);
            try { $items = boxSearchKind($q, $kind); }
            catch (RuntimeException $e) { jsonOut(['ok' => false, 'error' => 'Sonuçlar alınamadı, birazdan tekrar dene.'], 502); }
            jsonOut(['ok' => true, 'results' => array_values(array_filter($items, fn($i) => in_array($i['type'], ['song', 'video'], true))), 'items' => $items]);
        }
        $limit = (int)configValue('premium_daily_searches', 400);
        if ($limit > 0 && boxTodaySearches((int)$u['id']) >= $limit) jsonOut(['ok' => false, 'error' => 'Bugünlük arama hakkın doldu, yarın tekrar dene.'], 429);
        try { $results = boxSearch($q); }
        catch (RuntimeException $e) { jsonOut(['ok' => false, 'error' => $e->getMessage()], 502); }
        q('INSERT INTO search_log(day,user_id,n) VALUES(CURDATE(),?,1) ON DUPLICATE KEY UPDATE n=n+1', [$u['id']]);
        $term = mb_substr(mb_strtolower(preg_replace('/\s+/u', ' ', $q)), 0, 120);
        if ($term !== '') q('INSERT INTO search_terms(day,term,n) VALUES(CURDATE(),?,1) ON DUPLICATE KEY UPDATE n=n+1', [$term]);
        $out = ['ok' => true, 'results' => $results];
        // Uygulama 3.0+: YouTube Music düzeni (en iyi sonuç + karışık sonuçlar)
        if (($_GET['mode'] ?? '') === 'all' && ($all = boxSearchAll($q))) {
            $out['top'] = $all['top'];
            $out['items'] = $all['items'];
        } elseif ($top = boxTopArtist($q)) {
            $out['artist'] = $top;
        }
        jsonOut($out);

    case 'match':
        // Paylaşılan listedeki (bu cihazda olmayan) şarkıları YouTube Music'te bul. Arama hakkından düşmez.
        $need('POST');
        $u = boxApiUser();
        boxRequireFeature($u, 'match');
        throttle('match:' . $u['id'], 20, 600);
        $items = is_array(body()['items'] ?? null) ? array_slice(body()['items'], 0, 25) : [];
        $out = [];
        foreach ($items as $i => $item) {
            $title = is_array($item) ? mb_substr(trim((string)($item['title'] ?? '')), 0, 150) : '';
            $artist = is_array($item) ? mb_substr(trim((string)($item['artist'] ?? '')), 0, 100) : '';
            $duration = is_array($item) ? (int)($item['duration'] ?? 0) : 0;
            if ($title === '') { $out[] = null; continue; }
            try { $found = boxSearch(trim($title . ' ' . $artist), true, 5, 7 * 86400); }
            catch (RuntimeException $e) { $out[] = null; continue; }
            $best = null;
            foreach ($found as $r) {
                // Süresi çok farklıysa (canlı kayıt, uzun versiyon) başka sonucu tercih et.
                if ($duration > 0 && !empty($r['duration']) && abs((int)$r['duration'] - $duration) > max(8, (int)($duration * 0.08))) { $best ??= $r; continue; }
                $best = $r; break;
            }
            $out[] = $best;
        }
        jsonOut(['ok' => true, 'results' => $out]);

    case 'artist':
        // Sanatçı sayfası (YouTube Music): ?id=… ya da ?name=…
        $u = boxApiUser();
        boxRequireFeature($u, 'search');
        throttle('browse:' . $u['id'], 40, 60);
        $id = (string)($_GET['id'] ?? ''); $name = trim(mb_substr((string)($_GET['name'] ?? ''), 0, 120));
        if (($id === '' || !boxMusicId($id)) && $name === '') jsonOut(['ok' => false, 'error' => 'Sanatçı gerekli.'], 400);
        if (!boxMusicEnabled()) jsonOut(['ok' => false, 'error' => 'Sanatçı sayfası şu an kullanılamıyor.'], 503);
        try { $page = boxArtistPage(boxMusicId($id) ? $id : '', $name); }
        catch (RuntimeException $e) { jsonOut(['ok' => false, 'error' => str_contains($e->getMessage(), 'bulunamadı') ? 'Sanatçı bulunamadı.' : 'Sanatçı sayfası açılamadı.'], 502); }
        if (!$page['artist']) jsonOut(['ok' => false, 'error' => 'Sanatçı bulunamadı.'], 404);
        jsonOut(['ok' => true] + $page);

    case 'album':
        // Albüm sayfası (YouTube Music): ?id=… ya da ?name=…&artist=…
        $u = boxApiUser();
        boxRequireFeature($u, 'search');
        throttle('browse:' . $u['id'], 40, 60);
        $id = (string)($_GET['id'] ?? '');
        $query = trim(mb_substr((string)($_GET['name'] ?? '') . ' ' . (string)($_GET['artist'] ?? ''), 0, 160));
        if (($id === '' || !boxMusicId($id)) && $query === '') jsonOut(['ok' => false, 'error' => 'Albüm gerekli.'], 400);
        if (!boxMusicEnabled()) jsonOut(['ok' => false, 'error' => 'Albüm sayfası şu an kullanılamıyor.'], 503);
        try { $page = boxAlbumPage(boxMusicId($id) ? $id : '', $query); }
        catch (RuntimeException $e) { jsonOut(['ok' => false, 'error' => 'Albüm açılamadı.'], 502); }
        if (!$page['album']) jsonOut(['ok' => false, 'error' => 'Albüm bulunamadı.'], 404);
        jsonOut(['ok' => true] + $page);

    case 'me/notifications':
        $u = boxApiUser();
        jsonOut(['ok' => true, 'items' => boxInbox($u)]);

    case 'feed':
        $u = boxApiUser();
        boxRequireFeature($u, 'search');
        throttle('feed:' . $u['id'], 20, 60);
        $artists = array_filter(array_map('trim', explode('|', mb_substr((string)($_GET['artists'] ?? ''), 0, 300))));
        try { $sections = boxFeed(array_values($artists)); }
        catch (RuntimeException $e) { jsonOut(['ok' => false, 'error' => $e->getMessage()], 502); }
        // Bölüm başlıkları uygulamanın dilinde (ruh hali başlıkları YouTube Music'ten o dilde gelir).
        foreach ($sections as &$section) {
            if (isset($section['title'])) $section['title'] = __t((string)$section['title']);
            if (isset($section['subtitle'])) $section['subtitle'] = __t((string)$section['subtitle']);
        }
        unset($section);
        jsonOut(['ok' => true, 'sections' => $sections, 'genres' => boxMoods()]);

    case 'feed/genre':
        $u = boxApiUser();
        boxRequireFeature($u, 'search');
        throttle('feed:' . $u['id'], 20, 60);
        $key = (string)($_GET['key'] ?? '');
        $genre = boxGenres()[$key] ?? null;
        if (!$genre && boxMusicEnabled() && preg_match('/^[A-Za-z0-9_%=-]{6,200}$/', $key)) {
            // YouTube Music ruh hali kategorisi: kategorinin listelerinden şarkılar.
            $title = __t('Ruh hali');
            foreach (boxMoods() as $m) if ($m['key'] === $key) { $title = $m['title']; break; }
            try { $data = boxMusic('/stream/music/mood', ['params' => $key], 43200); }
            catch (RuntimeException $e) { jsonOut(['ok' => false, 'error' => 'Bu kategori şu an açılamıyor.'], 502); }
            $items = boxMusicResults($data['results'] ?? [], false);
            mt_srand((int)date('Ymd')); shuffle($items); mt_srand();
            jsonOut(['ok' => true, 'title' => $title, 'results' => array_slice($items, 0, 50)]);
        }
        if (!$genre) jsonOut(['ok' => false, 'error' => 'Bilinmeyen tür.'], 404);
        try { $items = boxSearch($genre[1], true, 30, 43200); }
        catch (RuntimeException $e) { jsonOut(['ok' => false, 'error' => $e->getMessage()], 502); }
        jsonOut(['ok' => true, 'title' => __t($genre[0]), 'results' => $items]);

    case 'radio':
        $u = boxApiUser();
        boxRequireFeature($u, 'radio');
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
        boxRequireFeature($u, 'playlist');
        throttle('playlist:' . $u['id'], 10, 60);
        $listId = boxPlaylistId((string)($_GET['url'] ?? ''));
        if (!$listId) jsonOut(['ok' => false, 'error' => 'Geçerli bir YouTube çalma listesi bağlantısı yapıştır (içinde "list=" olmalı).'], 400);
        try { $playlist = boxPlaylist($listId); }
        catch (RuntimeException $e) { jsonOut(['ok' => false, 'error' => $e->getMessage()], 422); }
        jsonOut(['ok' => true, 'playlist' => $playlist]);

    case 'stream':
        // İndirmeden dinleme: imzalı bağlantı verir, indirme kotasından düşmez.
        $u = boxApiUser();
        boxRequireFeature($u, 'stream');
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
        boxRequireFeature($u, 'download');
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
