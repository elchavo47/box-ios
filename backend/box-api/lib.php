<?php

declare(strict_types=1);

if (!is_file(__DIR__ . '/config.php')) {
    http_response_code(500);
    header('Content-Type: application/json; charset=UTF-8');
    echo '{"ok":false,"error":"config.php bulunamadı."}';
    exit;
}

require_once __DIR__ . '/config.php';

// PHP ve MySQL aynı saati kullansın (Türkiye: sabit UTC+3)
date_default_timezone_set('Europe/Istanbul');

final class ApiError extends RuntimeException
{
    public int $status;

    public function __construct(string $message, int $status = 400)
    {
        parent::__construct($message);
        $this->status = $status;
    }
}

function db(): PDO
{
    static $pdo = null;

    if ($pdo instanceof PDO) {
        return $pdo;
    }

    $pdo = new PDO(
        'mysql:host=' . DB_HOST . ';dbname=' . DB_NAME . ';charset=utf8mb4',
        DB_USER,
        DB_PASS,
        [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES => false,
        ]
    );

    $pdo->exec("SET time_zone = '+03:00'");

    return $pdo;
}

function json_out(array $data, int $status = 200): void
{
    while (ob_get_level() > 0) {
        ob_end_clean();
    }

    http_response_code($status);
    header('Content-Type: application/json; charset=UTF-8');
    header('Cache-Control: no-store');
    header('X-Content-Type-Options: nosniff');

    $json = json_encode(
        $data,
        JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE
    );

    echo $json !== false ? $json : '{"ok":false,"error":"JSON oluşturulamadı."}';
    exit;
}

function require_method(string $method): void
{
    if (strtoupper((string) ($_SERVER['REQUEST_METHOD'] ?? 'GET')) !== $method) {
        throw new ApiError('Bu işlem için ' . $method . ' isteği gerekli.', 405);
    }
}

function input_json(): array
{
    static $data = null;

    if (is_array($data)) {
        return $data;
    }

    $raw = file_get_contents('php://input');
    $decoded = is_string($raw) && $raw !== '' ? json_decode($raw, true) : null;
    $data = is_array($decoded) ? $decoded : $_POST;

    return $data;
}

function input_string(string $key, int $maxLength = 255): string
{
    $value = input_json()[$key] ?? '';

    if (!is_string($value)) {
        return '';
    }

    $value = trim($value);

    return mb_substr($value, 0, $maxLength);
}

function client_ip(): string
{
    $ip = (string) ($_SERVER['REMOTE_ADDR'] ?? '0.0.0.0');
    return substr($ip, 0, 45);
}

function bearer_token(): ?string
{
    $candidates = [
        $_SERVER['HTTP_AUTHORIZATION'] ?? null,
        $_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ?? null,
    ];

    if (function_exists('getallheaders')) {
        foreach ((array) getallheaders() as $name => $value) {
            if (strtolower((string) $name) === 'authorization') {
                $candidates[] = $value;
            }
        }
    }

    foreach ($candidates as $header) {
        if (is_string($header) && preg_match('/^Bearer\s+([a-f0-9]{64})$/i', trim($header), $m)) {
            return strtolower($m[1]);
        }
    }

    // Bazı paylaşımlı hostingler Authorization başlığını siler; yedek başlık.
    $fallback = $_SERVER['HTTP_X_BOX_TOKEN'] ?? '';
    if (is_string($fallback) && preg_match('/^[a-f0-9]{64}$/i', trim($fallback))) {
        return strtolower(trim($fallback));
    }

    return null;
}

function issue_token(int $userId): string
{
    $token = bin2hex(random_bytes(32));
    $expires = (new DateTimeImmutable('now'))
        ->modify('+' . (int) TOKEN_TTL_DAYS . ' days')
        ->format('Y-m-d H:i:s');

    db()->prepare('INSERT INTO tokens (user_id, token_hash, expires_at) VALUES (?, ?, ?)')
        ->execute([$userId, hash('sha256', $token), $expires]);

    return $token;
}

function current_user(): array
{
    $token = bearer_token();

    if ($token === null) {
        throw new ApiError('Oturum açman gerekiyor.', 401);
    }

    $stmt = db()->prepare(
        'SELECT u.*, t.id AS token_id, t.last_used_at AS token_last_used
           FROM tokens t
           JOIN users u ON u.id = t.user_id
          WHERE t.token_hash = ? AND t.expires_at > NOW()
          LIMIT 1'
    );
    $stmt->execute([hash('sha256', $token)]);
    $user = $stmt->fetch();

    if (!is_array($user)) {
        throw new ApiError('Oturumun sona erdi, tekrar giriş yap.', 401);
    }

    if ((int) $user['is_banned'] === 1) {
        throw new ApiError('Hesabın askıya alındı.', 403);
    }

    $lastUsed = $user['token_last_used'] ? strtotime((string) $user['token_last_used']) : 0;
    if (time() - (int) $lastUsed > 600) {
        db()->prepare('UPDATE tokens SET last_used_at = NOW() WHERE id = ?')
            ->execute([(int) $user['token_id']]);
    }

    return $user;
}

function is_premium(array $user): bool
{
    if ((int) $user['is_premium'] !== 1) {
        return false;
    }

    if ($user['premium_until'] === null) {
        return true;
    }

    return strtotime((string) $user['premium_until']) > time();
}

function require_premium(array $user): void
{
    if (!is_premium($user)) {
        throw new ApiError('Bu özellik premium üyelere açık.', 403);
    }
}

function user_public(array $user): array
{
    return [
        'id' => (int) $user['id'],
        'email' => (string) $user['email'],
        'name' => (string) $user['display_name'],
        'premium' => is_premium($user),
        'premium_until' => $user['premium_until'] !== null
            ? date(DATE_ATOM, (int) strtotime((string) $user['premium_until']))
            : null,
        'created_at' => date(DATE_ATOM, (int) strtotime((string) $user['created_at'])),
    ];
}

function find_user_by_email(string $email): ?array
{
    $stmt = db()->prepare('SELECT * FROM users WHERE email = ? LIMIT 1');
    $stmt->execute([$email]);
    $user = $stmt->fetch();

    return is_array($user) ? $user : null;
}

function find_user_by_id(int $id): ?array
{
    $stmt = db()->prepare('SELECT * FROM users WHERE id = ? LIMIT 1');
    $stmt->execute([$id]);
    $user = $stmt->fetch();

    return is_array($user) ? $user : null;
}

/* ---------------- YouTube Data API ---------------- */

function cache_get(string $key): ?array
{
    $file = rtrim(CACHE_DIR, '/') . '/' . hash('sha256', $key) . '.json';

    if (!is_file($file) || time() - (int) @filemtime($file) >= CACHE_TIME) {
        return null;
    }

    $data = json_decode((string) @file_get_contents($file), true);
    return is_array($data) ? $data : null;
}

function cache_put(string $key, array $data): void
{
    $dir = rtrim(CACHE_DIR, '/');

    if (!is_dir($dir) && !@mkdir($dir, 0750, true) && !is_dir($dir)) {
        return;
    }

    $json = json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    if ($json !== false) {
        @file_put_contents($dir . '/' . hash('sha256', $key) . '.json', $json, LOCK_EX);
    }
}

function youtube_get(string $resource, array $params): array
{
    if (YT_DATA_API_KEY === '' || YT_DATA_API_KEY === 'GOOGLE_API_ANAHTARI') {
        throw new ApiError('Arama servisi yapılandırılmamış.', 500);
    }

    $cacheKey = $resource . '?' . http_build_query($params);
    $cached = cache_get($cacheKey);
    if ($cached !== null) {
        return $cached;
    }

    $params['key'] = YT_DATA_API_KEY;
    $ch = curl_init('https://www.googleapis.com/youtube/v3/' . $resource . '?' . http_build_query($params));

    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CONNECTTIMEOUT => 10,
        CURLOPT_TIMEOUT => 20,
        CURLOPT_SSL_VERIFYPEER => true,
        CURLOPT_SSL_VERIFYHOST => 2,
        CURLOPT_ENCODING => '',
        CURLOPT_HTTPHEADER => ['Accept: application/json'],
        CURLOPT_USERAGENT => 'Box-API/1.0',
    ]);

    $response = curl_exec($ch);
    $status = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $error = curl_error($ch);
    curl_close($ch);

    if (!is_string($response)) {
        error_log('[Box] YouTube cURL hatası: ' . $error);
        throw new ApiError('Arama servisine ulaşılamadı.', 502);
    }

    $data = json_decode($response, true);

    if (!is_array($data) || $status < 200 || $status >= 300) {
        error_log('[Box] YouTube HTTP ' . $status . ': ' . substr($response, 0, 300));
        throw new ApiError('Arama şu an yapılamıyor.', 502);
    }

    cache_put($cacheKey, $data);
    return $data;
}

function iso8601_seconds(string $duration): int
{
    if (!preg_match('/^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/', $duration, $m)) {
        return 0;
    }

    return ((int) ($m[1] ?? 0)) * 86400
        + ((int) ($m[2] ?? 0)) * 3600
        + ((int) ($m[3] ?? 0)) * 60
        + ((int) ($m[4] ?? 0));
}

function clean_text(string $text): string
{
    return trim(html_entity_decode($text, ENT_QUOTES | ENT_HTML5, 'UTF-8'));
}
