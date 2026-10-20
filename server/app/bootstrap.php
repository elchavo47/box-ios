<?php
declare(strict_types=1);

if (PHP_SAPI !== 'cli' && realpath((string)($_SERVER['SCRIPT_FILENAME'] ?? '')) === __FILE__) { http_response_code(404); exit; }

if (function_exists('header_remove')) header_remove('X-Powered-By');
header('X-Content-Type-Options: nosniff');
header('X-Frame-Options: DENY');
header('Referrer-Policy: same-origin');
header('Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=(), interest-cohort=()');
header('Cross-Origin-Opener-Policy: same-origin');
header('X-Permitted-Cross-Domain-Policies: none');
$boxHttps = (($_SERVER['HTTPS'] ?? '') !== '' && ($_SERVER['HTTPS'] ?? '') !== 'off') || strtolower((string)($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '')) === 'https' || (int)($_SERVER['SERVER_PORT'] ?? 0) === 443;
if ($boxHttps) header('Strict-Transport-Security: max-age=63072000; includeSubDomains');

define('ROOT', dirname(__DIR__));
const BOX_NAME = 'Box';

/*
 * Gizli klasör: yedekler ve günlükler web kökünün dışında (mümkünse) tutulur.
 * Dışarısı yazılamıyorsa storage altında tahmin edilemez adlı bir klasör kullanılır.
 */
function nbPrivateDir(string $sub = ''): string {
    static $base = null;
    if ($base === null) {
        $outside = dirname(ROOT) . '/box-private';
        if ((@is_dir($outside) || @mkdir($outside, 0700, true)) && @is_writable($outside)) $base = $outside;
        else {
            $map = ROOT . '/storage/private.php';
            $name = is_file($map) ? (string)(include $map) : '';
            if (!preg_match('/^p-[a-f0-9]{32}$/', $name)) {
                $name = 'p-' . bin2hex(random_bytes(16));
                @file_put_contents($map, "<?php\nif (!defined('ROOT')) { http_response_code(404); exit; }\nreturn '$name';\n", LOCK_EX);
            }
            $base = ROOT . '/storage/' . $name;
            if (!is_dir($base)) @mkdir($base, 0700, true);
            if (!is_file("$base/index.php")) @file_put_contents("$base/index.php", "<?php http_response_code(404);\n");
        }
    }
    if ($sub === '') return $base;
    $dir = $base . '/' . $sub;
    if (!is_dir($dir)) @mkdir($dir, 0700, true);
    return $dir;
}

ini_set('display_errors', '0');
ini_set('log_errors', '1');
if (is_writable(nbPrivateDir('logs'))) ini_set('error_log', nbPrivateDir('logs') . '/php-' . date('Y-m') . '.log');
$configFile = ROOT . '/config/config.php';
$CONFIG = file_exists($configFile) ? require $configFile : [];
if (!is_array($CONFIG)) $CONFIG = [];
date_default_timezone_set('Europe/Istanbul');

require_once ROOT . '/app/web.php';

set_exception_handler(function (Throwable $e): void {
    nbReport($e);
    if (str_starts_with(routePath(), '/api/') || str_starts_with(routePath(), '/box-api')) {
        jsonOut(['ok' => false, 'error' => 'Sunucu hatası, daha sonra tekrar dene.'], 500);
    }
    webError(500);
});

require_once ROOT . '/app/errors.php';

function cfg(string $path, mixed $default = null): mixed {
    global $CONFIG;
    $value = $CONFIG;
    foreach (explode('.', $path) as $key) {
        if (!is_array($value) || !array_key_exists($key, $value)) return $default;
        $value = $value[$key];
    }
    return $value;
}

function db(): PDO {
    static $pdo;
    if ($pdo instanceof PDO) return $pdo;
    $d = cfg('db');
    if (!is_array($d) || empty($d['name'])) throw new RuntimeException('Veritabanı ayarı yok; önce /install çalıştırılmalı.');
    $pdo = new PDO(
        "mysql:host={$d['host']};port={$d['port']};dbname={$d['name']};charset={$d['charset']}",
        $d['user'],
        $d['pass'],
        [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES => false,
        ]
    );
    try { $pdo->exec("SET time_zone='" . date('P') . "'"); } catch (PDOException $e) { nbReport($e); }
    return $pdo;
}

function q(string $sql, array $params = []): PDOStatement {
    $statement = db()->prepare($sql);
    $statement->execute($params);
    return $statement;
}

function jsonOut(mixed $data, int $code = 200): never {
    while (ob_get_level() > 0) ob_end_clean();
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE);
    exit;
}

function body(): array {
    static $cache = null;
    if ($cache !== null) return $cache;
    $raw = file_get_contents('php://input', false, null, 0, 256 * 1024 + 1);
    if ($raw === false || $raw === '') return $cache = $_POST;
    if (strlen($raw) > 256 * 1024) jsonOut(['ok' => false, 'error' => 'İstek boyutu çok büyük.'], 413);
    $value = json_decode($raw, true);
    return $cache = (is_array($value) ? $value : $_POST);
}

function routePath(): string {
    $path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
    return '/' . trim($path, '/');
}

/* ---------------- Uygulamanın uzaktan ayarları (app_config) ---------------- */

function &configCache(bool $reset = false): array {
    static $cache = null;
    if ($reset) $cache = null;
    if ($cache === null) {
        $cache = [];
        foreach (q('SELECT config_key,config_value FROM app_config')->fetchAll() as $row) $cache[$row['config_key']] = (string)$row['config_value'];
    }
    return $cache;
}

function configValue(string $key, mixed $default = null): mixed {
    $cache = &configCache();
    if (!array_key_exists($key, $cache)) return $default;
    $raw = $cache[$key];
    $decoded = json_decode($raw, true);
    return json_last_error() === JSON_ERROR_NONE ? $decoded : $raw;
}

function configBool(string $key, bool $default = false): bool {
    $value = configValue($key, $default);
    if (is_string($value)) return in_array(strtolower($value), ['1', 'true', 'yes', 'on'], true);
    return (bool)$value;
}

function saveConfigValue(string $key, mixed $value): void {
    $encoded = json_encode($value, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    q('INSERT INTO app_config(config_key,config_value) VALUES(?,?) ON DUPLICATE KEY UPDATE config_value=VALUES(config_value)', [$key, $encoded]);
    $cache = &configCache();
    $cache[$key] = (string)$encoded;
}

/* ---------------- Sunucu tarafı ayarlar (site_settings) ---------------- */

function site(string $key, string $default = ''): string {
    $value = q('SELECT setting_value FROM site_settings WHERE setting_key=?', [$key])->fetchColumn();
    return $value === false ? $default : (string)$value;
}

function saveSite(string $key, string $value): void {
    q('INSERT INTO site_settings(setting_key,setting_value) VALUES(?,?) ON DUPLICATE KEY UPDATE setting_value=VALUES(setting_value)', [$key, $value]);
}

/* ---------------- Anahtarlar ve şifreleme ---------------- */

function nbKey(string $purpose): string {
    static $cache = [];
    return $cache[$purpose] ??= hash_hkdf('sha256', (string)cfg('security.master_key'), 32, 'box/v1/' . $purpose);
}

function encryptSecret(string $value): string {
    if ($value === '') return '';
    $iv = random_bytes(12); $tag = '';
    $cipher = openssl_encrypt($value, 'aes-256-gcm', nbKey('secrets'), OPENSSL_RAW_DATA, $iv, $tag, 'box-secret');
    if ($cipher === false) throw new RuntimeException('Şifreleme başarısız.');
    return 'v2:' . base64_encode($iv . $tag . $cipher);
}

function decryptSecret(string $value): string {
    if ($value === '' || !str_starts_with($value, 'v2:')) return '';
    $raw = base64_decode(substr($value, 3), true);
    if ($raw === false || strlen($raw) < 28) return '';
    $plain = openssl_decrypt(substr($raw, 28), 'aes-256-gcm', nbKey('secrets'), OPENSSL_RAW_DATA, substr($raw, 0, 12), substr($raw, 12, 16), 'box-secret');
    return $plain === false ? '' : $plain;
}

/** Gizli site ayarı (şifreli saklanır). */
function secretSetting(string $key): string { return decryptSecret(site($key)); }
function saveSecretSetting(string $key, string $value): void { saveSite($key, $value === '' ? '' : encryptSecret($value)); }

/* ---------------- Hız sınırı ---------------- */

function clientIpHash(): string {
    return hash('sha256', (string)($_SERVER['REMOTE_ADDR'] ?? 'local'));
}

function throttle(string $bucket, int $limit, int $windowSeconds): void {
    $hash = hash('sha256', $bucket);
    $now = time();
    $cutoff = $now - $windowSeconds;
    try {
        q('INSERT INTO rate_limits(bucket,window_start,hits) VALUES(?,?,1) ON DUPLICATE KEY UPDATE hits=IF(window_start<=?,1,hits+1), window_start=IF(window_start<=?,?,window_start)', [$hash, $now, $cutoff, $cutoff, $now]);
        $hits = (int)q('SELECT hits FROM rate_limits WHERE bucket=?', [$hash])->fetchColumn();
        if (random_int(1, 200) === 1) q('DELETE FROM rate_limits WHERE window_start<?', [$now - 86400]);
    } catch (PDOException $e) {
        nbReport($e);
        return;
    }
    if ($hits > $limit) {
        header('Retry-After: ' . $windowSeconds);
        jsonOut(['ok' => false, 'error' => 'Çok fazla istek. Biraz sonra tekrar dene.'], 429);
    }
}

/* ---------------- Panel CSRF ---------------- */

function csrf(): string {
    if (empty($_SESSION['csrf'])) $_SESSION['csrf'] = bin2hex(random_bytes(24));
    return (string)$_SESSION['csrf'];
}

function checkCsrf(): void {
    if (empty($_SESSION['csrf']) || !is_string($_POST['csrf'] ?? null) || !hash_equals((string)$_SESSION['csrf'], (string)$_POST['csrf'])) {
        webError(419);
    }
}

/* ---------------- Zincirli denetim günlüğü ---------------- */

function auditRowHash(string $prev, array $row): string {
    return hash_hmac('sha256', implode('|', [$prev, (string)$row['admin_id'], (string)$row['action'], (string)$row['details'], (string)$row['ip'], (string)$row['created_at']]), nbKey('audit'));
}

function logAdmin(?int $id, string $action, array $details = []): void {
    $row = ['admin_id' => $id, 'action' => mb_substr($action, 0, 80), 'details' => json_encode($details, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), 'ip' => substr((string)($_SERVER['REMOTE_ADDR'] ?? 'cli'), 0, 45), 'created_at' => date('Y-m-d H:i:s')];
    $own = !db()->inTransaction();
    if ($own) db()->beginTransaction();
    try {
        $prev = (string)(q('SELECT row_hash FROM admin_audit_log WHERE row_hash IS NOT NULL ORDER BY id DESC LIMIT 1 FOR UPDATE')->fetchColumn() ?: 'genesis');
        q('INSERT INTO admin_audit_log(admin_id,action,details,ip,created_at,prev_hash,row_hash) VALUES(?,?,?,?,?,?,?)', [$row['admin_id'], $row['action'], $row['details'], $row['ip'], $row['created_at'], $prev, auditRowHash($prev, $row)]);
        if ($own) db()->commit();
    } catch (Throwable $e) {
        if ($own && db()->inTransaction()) db()->rollBack();
        throw $e;
    }
}

function auditVerify(int $limit = 50000): array {
    $prev = 'genesis'; $checked = 0;
    foreach (q('SELECT id,admin_id,action,details,ip,created_at,prev_hash,row_hash FROM admin_audit_log WHERE row_hash IS NOT NULL ORDER BY id ASC LIMIT ' . (int)$limit)->fetchAll() as $row) {
        $checked++;
        if (!hash_equals((string)$row['prev_hash'], $prev) || !hash_equals((string)$row['row_hash'], auditRowHash($prev, $row))) return ['ok' => false, 'checked' => $checked, 'broken_at' => (int)$row['id']];
        $prev = (string)$row['row_hash'];
    }
    return ['ok' => true, 'checked' => $checked, 'broken_at' => null];
}

require_once ROOT . '/app/setup.php';
require_once ROOT . '/app/security.php';
require_once ROOT . '/app/hardening.php';
require_once ROOT . '/app/guard.php';
require_once ROOT . '/app/box.php';
require_once ROOT . '/app/apple.php';

if (PHP_SAPI !== 'cli') {
    $setup = setupState();
    $installRoute = in_array(routePath(), ['/install', '/install.php'], true);
    if ($setup === 'unconfigured' && !nbInstalled()) {
        if (!$installRoute && !str_starts_with(routePath(), '/assets/')) {
            if (str_starts_with(routePath(), '/api/') || str_starts_with(routePath(), '/box-api')) jsonOut(['ok' => false, 'error' => 'Sunucu kurulumu tamamlanmadı.'], 503);
            header('Location: /install'); exit;
        }
    } elseif ($setup !== 'ready') {
        setupRecovery($setup);
    }
}
if ($CONFIG && setupState() === 'ready') ensureSchema();

/* ---------------- Panel oturumları veritabanında ---------------- */

final class DbSessionHandler implements SessionHandlerInterface {
    private static function key(string $id): string { return hash('sha256', $id); }
    public function open(string $path, string $name): bool { return true; }
    public function close(): bool { return true; }
    public function read(string $id): string|false {
        $data = q('SELECT data FROM admin_sessions WHERE id=? AND last_seen>DATE_SUB(NOW(),INTERVAL 30 DAY)', [self::key($id)])->fetchColumn();
        return $data === false ? '' : (string)$data;
    }
    public function write(string $id, string $data): bool {
        $uid = isset($_SESSION['admin_id']) ? (int)$_SESSION['admin_id'] : null;
        q('INSERT INTO admin_sessions(id,data,user_id,ip,user_agent,remember,last_seen) VALUES(?,?,?,?,?,?,NOW()) ON DUPLICATE KEY UPDATE data=VALUES(data),user_id=VALUES(user_id),ip=VALUES(ip),user_agent=VALUES(user_agent),remember=VALUES(remember),last_seen=NOW()',
            [self::key($id), $data, $uid, clientIp(), mb_substr((string)($_SERVER['HTTP_USER_AGENT'] ?? ''), 0, 250), !empty($_SESSION['remember']) ? 1 : 0]);
        return true;
    }
    public function destroy(string $id): bool { q('DELETE FROM admin_sessions WHERE id=?', [self::key($id)]); return true; }
    public function gc(int $max_lifetime): int|false {
        q('DELETE FROM admin_sessions WHERE last_seen<DATE_SUB(NOW(),INTERVAL 30 DAY) OR (user_id IS NULL AND last_seen<DATE_SUB(NOW(),INTERVAL 3 HOUR))');
        return 0;
    }
}

function sessionCookie(int $days): void {
    setcookie(session_name(), (string)session_id(), ['expires' => $days > 0 ? time() + $days * 86400 : 0, 'path' => '/', 'secure' => isHttps(), 'httponly' => true, 'samesite' => 'Lax']);
}

$boxPath = (string)parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);
if (PHP_SAPI !== 'cli' && session_status() !== PHP_SESSION_ACTIVE && (str_starts_with($boxPath, '/admin') || str_starts_with($boxPath, '/install') || $boxPath === '/' || $boxPath === '/approve')) {
    ini_set('session.use_strict_mode', '1');
    ini_set('session.use_only_cookies', '1');
    ini_set('session.gc_maxlifetime', (string)(30 * 86400));
    session_name(isHttps() ? '__Host-boxsid' : 'boxsid');
    session_set_cookie_params(['lifetime' => 0, 'httponly' => true, 'secure' => isHttps(), 'samesite' => 'Lax', 'path' => '/']);
    if ($CONFIG && setupState() === 'ready') session_set_save_handler(new DbSessionHandler(), true);
    session_start();
    if (!empty($_SESSION['remember']) && (int)($_SESSION['cookie_refreshed'] ?? 0) < time() - 86400) { $_SESSION['cookie_refreshed'] = time(); sessionCookie(30); }
}
if ($CONFIG && setupState() === 'ready' && strlen((string)cfg('security.master_key', '')) < 32) {
    throw new RuntimeException('config/config.php içinde güvenli bir master_key tanımlayın.');
}

function b64url(string $value): string {
    return rtrim(strtr(base64_encode($value), '+/', '-_'), '=');
}

function b64urlDecode(string $value): string|false {
    $padding = strlen($value) % 4;
    if ($padding) $value .= str_repeat('=', 4 - $padding);
    return base64_decode(strtr($value, '-_', '+/'), true);
}
