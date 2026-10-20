<?php

declare(strict_types=1);

/*
 * Box admin çekirdeği: oturum, güvenlik başlıkları, CSRF, giriş kilidi, 2FA, işlem kaydı.
 */

const ADMIN_IDLE_TIMEOUT = 1800;      // 30 dk hareketsizlikte çıkış
const ADMIN_ABSOLUTE_TIMEOUT = 43200; // 12 saatte bir zorunlu yeniden giriş
const ADMIN_MAX_FAILS_IP = 8;         // 15 dk içinde IP başına
const ADMIN_MAX_FAILS_USER = 5;       // 15 dk içinde kullanıcı adı başına

ob_start();
ini_set('display_errors', '0');
ini_set('log_errors', '1');

if (!is_file(__DIR__ . '/../box-api/config.php')) {
    header('Location: install/');
    exit;
}

require_once __DIR__ . '/../box-api/lib.php';
require_once __DIR__ . '/totp.php';

/* ---------------- Güvenlik başlıkları ---------------- */

function is_https(): bool
{
    return (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off')
        || (($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https')
        || ((int) ($_SERVER['SERVER_PORT'] ?? 0) === 443);
}

function csp_nonce(): string
{
    static $nonce = null;
    if ($nonce === null) {
        $nonce = base64_encode(random_bytes(16));
    }
    return $nonce;
}

function send_security_headers(): void
{
    $nonce = csp_nonce();
    header("Content-Security-Policy: default-src 'none'; script-src 'self' 'nonce-{$nonce}' https://cdnjs.cloudflare.com; style-src 'self' 'nonce-{$nonce}'; img-src 'self' data: https://i.ytimg.com; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'");
    header('X-Frame-Options: DENY');
    header('X-Content-Type-Options: nosniff');
    header('Referrer-Policy: same-origin');
    header('Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=()');
    header('Cross-Origin-Opener-Policy: same-origin');
    header('Cache-Control: no-store, max-age=0');
    header('X-Robots-Tag: noindex, nofollow');

    if (is_https()) {
        header('Strict-Transport-Security: max-age=31536000');
    }
}

/* ---------------- Oturum ---------------- */

function start_admin_session(): void
{
    $secure = is_https();
    session_name($secure ? '__Host-box_admin' : 'box_admin');
    session_set_cookie_params([
        'lifetime' => 0,
        'path' => '/',
        'secure' => $secure,
        'httponly' => true,
        'samesite' => 'Strict',
    ]);
    ini_set('session.use_strict_mode', '1');
    ini_set('session.use_only_cookies', '1');
    session_start();
}

function ua_fingerprint(): string
{
    return hash('sha256', (string) ($_SERVER['HTTP_USER_AGENT'] ?? ''));
}

/** Oturumdaki admini döndürür; geçersizse oturumu kapatıp null döner. */
function current_admin(): ?array
{
    static $admin = false;
    if ($admin !== false) {
        return $admin;
    }

    $admin = null;
    $id = (int) ($_SESSION['admin_id'] ?? 0);
    if ($id <= 0) {
        return null;
    }

    $now = time();
    $expired = $now - (int) ($_SESSION['last_seen'] ?? 0) > ADMIN_IDLE_TIMEOUT
        || $now - (int) ($_SESSION['logged_in_at'] ?? 0) > ADMIN_ABSOLUTE_TIMEOUT
        || !hash_equals((string) ($_SESSION['ua'] ?? ''), ua_fingerprint());

    $stmt = db()->prepare('SELECT * FROM admins WHERE id = ? LIMIT 1');
    $stmt->execute([$id]);
    $row = $stmt->fetch();

    if ($expired || !is_array($row) || (int) $row['session_version'] !== (int) ($_SESSION['session_version'] ?? -1)) {
        destroy_admin_session();
        $_SESSION['flash'] = ['warn', 'Oturum süren doldu, tekrar giriş yap.'];
        return null;
    }

    $_SESSION['last_seen'] = $now;
    $admin = $row;
    return $admin;
}

function login_admin(array $admin): void
{
    session_regenerate_id(true);
    $_SESSION = [
        'admin_id' => (int) $admin['id'],
        'session_version' => (int) $admin['session_version'],
        'logged_in_at' => time(),
        'last_seen' => time(),
        'ua' => ua_fingerprint(),
        'csrf' => bin2hex(random_bytes(32)),
    ];

    db()->prepare('UPDATE admins SET last_login_at = NOW(), last_login_ip = ? WHERE id = ?')
        ->execute([client_ip(), (int) $admin['id']]);
}

function destroy_admin_session(): void
{
    $_SESSION = [];
    if (ini_get('session.use_cookies')) {
        $p = session_get_cookie_params();
        setcookie(session_name(), '', [
            'expires' => time() - 3600,
            'path' => $p['path'],
            'secure' => $p['secure'],
            'httponly' => true,
            'samesite' => 'Strict',
        ]);
    }
    session_destroy();
    session_start();
    session_regenerate_id(true);
}

/* ---------------- CSRF ---------------- */

function csrf_token(): string
{
    if (empty($_SESSION['csrf'])) {
        $_SESSION['csrf'] = bin2hex(random_bytes(32));
    }
    return $_SESSION['csrf'];
}

function csrf_field(): string
{
    return '<input type="hidden" name="_csrf" value="' . e(csrf_token()) . '">';
}

function verify_post(): void
{
    if (strtoupper((string) ($_SERVER['REQUEST_METHOD'] ?? 'GET')) !== 'POST') {
        return;
    }

    // Aynı köken kontrolü (Origin/Referer)
    $origin = (string) ($_SERVER['HTTP_ORIGIN'] ?? '');
    if ($origin === '' || $origin === 'null') {
        $origin = (string) ($_SERVER['HTTP_REFERER'] ?? '');
    }
    $host = strtolower((string) parse_url('//' . ($_SERVER['HTTP_HOST'] ?? ''), PHP_URL_HOST));
    $originHost = strtolower((string) parse_url($origin, PHP_URL_HOST));
    if ($origin !== '' && $originHost !== '' && $originHost !== $host) {
        http_response_code(403);
        exit('Geçersiz istek kaynağı.');
    }

    $sent = $_POST['_csrf'] ?? '';
    if (!is_string($sent) || !hash_equals(csrf_token(), $sent)) {
        http_response_code(400);
        exit('Form süresi doldu. Sayfayı yenileyip tekrar dene.');
    }
}

/* ---------------- Giriş kilidi ---------------- */

function login_locked(string $username): bool
{
    $stmt = db()->prepare(
        'SELECT
            (SELECT COUNT(*) FROM admin_attempts WHERE ip = ? AND attempted_at > NOW() - INTERVAL 15 MINUTE),
            (SELECT COUNT(*) FROM admin_attempts WHERE username = ? AND attempted_at > NOW() - INTERVAL 15 MINUTE)'
    );
    $stmt->execute([client_ip(), mb_strtolower($username)]);
    [$byIp, $byUser] = array_map('intval', $stmt->fetch(PDO::FETCH_NUM));

    return $byIp >= ADMIN_MAX_FAILS_IP || $byUser >= ADMIN_MAX_FAILS_USER;
}

function record_failed_login(string $username): void
{
    db()->prepare('INSERT INTO admin_attempts (ip, username) VALUES (?, ?)')
        ->execute([client_ip(), mb_strtolower(mb_substr($username, 0, 60))]);
    db()->exec('DELETE FROM admin_attempts WHERE attempted_at < NOW() - INTERVAL 1 DAY');
}

function clear_failed_logins(string $username): void
{
    db()->prepare('DELETE FROM admin_attempts WHERE ip = ? OR username = ?')
        ->execute([client_ip(), mb_strtolower($username)]);
}

/** Kullanıcı yokken de aynı sürede yanıt vermek için sahte hash. */
function dummy_password_verify(string $password): void
{
    password_verify($password, '$2y$12$C6UzMDM.H6dfI/f/IKcEeO5bHdLTI4QNHf3qD3.y0p7QwYkzCZ7aG');
}

/* ---------------- İşlem kaydı ---------------- */

function audit(string $action, string $target = '', string $details = ''): void
{
    $admin = current_admin();
    db()->prepare(
        'INSERT INTO admin_audit (admin_id, admin_name, action, target, details, ip) VALUES (?, ?, ?, ?, ?, ?)'
    )->execute([
        $admin ? (int) $admin['id'] : null,
        $admin ? (string) $admin['username'] : '',
        $action,
        mb_substr($target, 0, 190),
        mb_substr($details, 0, 500),
        client_ip(),
    ]);
}

/* ---------------- Yardımcılar ---------------- */

function e(?string $value): string
{
    return htmlspecialchars((string) $value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function flash(string $type, string $message): void
{
    $_SESSION['flash'] = [$type, $message];
}

function take_flash(): ?array
{
    $f = $_SESSION['flash'] ?? null;
    unset($_SESSION['flash']);
    return is_array($f) ? $f : null;
}

function redirect(string $to): void
{
    while (ob_get_level() > 0) {
        ob_end_clean();
    }
    header('Location: ' . $to);
    exit;
}

function post_str(string $key, int $max = 255): string
{
    $v = $_POST[$key] ?? '';
    return is_string($v) ? mb_substr(trim($v), 0, $max) : '';
}

function get_str(string $key, int $max = 190): string
{
    $v = $_GET[$key] ?? '';
    return is_string($v) ? mb_substr(trim($v), 0, $max) : '';
}

function fmt_date(?string $value, string $format = 'd.m.Y H:i'): string
{
    if ($value === null || $value === '') {
        return '—';
    }
    $ts = strtotime($value);
    return $ts ? date($format, $ts) : '—';
}

function time_ago(?string $value): string
{
    if (!$value) {
        return 'hiç';
    }
    $diff = time() - (int) strtotime($value);
    if ($diff < 60) return 'az önce';
    if ($diff < 3600) return intdiv($diff, 60) . ' dk önce';
    if ($diff < 86400) return intdiv($diff, 3600) . ' sa önce';
    if ($diff < 86400 * 30) return intdiv($diff, 86400) . ' gün önce';
    return fmt_date($value, 'd.m.Y');
}

function password_problem(string $password): ?string
{
    if (strlen($password) < 12) {
        return 'Şifre en az 12 karakter olmalı.';
    }
    if (!preg_match('/[a-zçğıöşü]/u', $password) || !preg_match('/[A-ZÇĞİÖŞÜ]/u', $password) || !preg_match('/\d/', $password)) {
        return 'Şifrede büyük harf, küçük harf ve rakam olmalı.';
    }
    return null;
}

function hash_admin_password(string $password): string
{
    return defined('PASSWORD_ARGON2ID')
        ? password_hash($password, PASSWORD_ARGON2ID)
        : password_hash($password, PASSWORD_BCRYPT, ['cost' => 12]);
}

/* ---------------- Başlat ---------------- */

send_security_headers();
start_admin_session();
