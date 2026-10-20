<?php

/**
 * Box kurulum sihirbazı
 * Veritabanı tablolarını oluşturur, ilk admin hesabını açar ve box-api/config.php dosyasını yazar.
 * Kurulum bittikten sonra kendini kilitler; bu klasörü silmen önerilir.
 */

declare(strict_types=1);

ob_start();
ini_set('display_errors', '0');
date_default_timezone_set('Europe/Istanbul');

$root = dirname(__DIR__);
$apiDir = $root . '/box-api';
$lockFile = $apiDir . '/install.lock';

header('X-Frame-Options: DENY');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: no-referrer');
header('Cache-Control: no-store');
header("Content-Security-Policy: default-src 'none'; style-src 'self'; script-src 'self'; img-src 'self' data:; form-action 'self'; frame-ancestors 'none'; base-uri 'none'");

function e(?string $v): string
{
    return htmlspecialchars((string) $v, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function box_logo(int $size): string
{
    return '<svg class="logo" width="' . $size . '" height="' . $size . '" viewBox="0 0 100 100" fill="none" stroke="currentColor" stroke-width="6.5" stroke-linejoin="round" stroke-linecap="round"><path d="M50 12 L86 31 L50 50 L14 31 Z"/><path d="M12 41 L44 58 L44 92 L12 75 Z"/><path d="M88 41 L56 58 L56 92 L88 75 Z"/></svg>';
}

function shell(string $title, callable $body): void
{
    while (ob_get_level() > 0) {
        ob_end_clean();
    }
    ?><!doctype html>
<html lang="tr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex, nofollow">
<title><?= e($title) ?> · Box Kurulum</title><link rel="stylesheet" href="../assets/admin.css?v=3"></head>
<body class="bare"><div class="grid-bg"></div><?php $body(); ?></body></html>
<?php
    exit;
}

/* ---------------- Kilit: kurulum yapılmışsa çalışmaz ---------------- */

if (is_file($lockFile) || is_file($apiDir . '/config.php')) {
    http_response_code(403);
    shell('Kurulum tamamlandı', function (): void {
        ?>
        <div class="auth">
            <div class="head"><?= box_logo(56) ?><h1>Kurulum zaten yapılmış</h1>
                <p class="sub">Güvenlik için sihirbaz kilitlendi. Bu <b>install</b> klasörünü sunucudan silebilirsin.</p></div>
            <a class="btn primary full" href="../">Admin paneline git</a>
        </div>
        <?php
    });
}

/* ---------------- Oturum + CSRF ---------------- */

$https = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') || (($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https');
session_name('box_install');
session_set_cookie_params(['lifetime' => 0, 'path' => '/', 'secure' => $https, 'httponly' => true, 'samesite' => 'Strict']);
session_start();
if (empty($_SESSION['csrf'])) {
    $_SESSION['csrf'] = bin2hex(random_bytes(32));
}

/* ---------------- Gereksinimler ---------------- */

$checks = [
    'PHP 8.0 veya üstü' => version_compare(PHP_VERSION, '8.0.0', '>='),
    'PDO MySQL eklentisi' => extension_loaded('pdo_mysql'),
    'cURL eklentisi' => extension_loaded('curl'),
    'mbstring eklentisi' => extension_loaded('mbstring'),
    'box-api klasörü yazılabilir' => is_dir($apiDir) && is_writable($apiDir),
    'HTTPS bağlantı' => $https,
];
$ready = !in_array(false, array_slice($checks, 0, 5, true), true);

/* ---------------- Şema ---------------- */

$schema = <<<'SQL'
CREATE TABLE IF NOT EXISTS users (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT, email VARCHAR(190) NOT NULL, password_hash VARCHAR(255) NOT NULL,
    display_name VARCHAR(60) NOT NULL, is_premium TINYINT(1) NOT NULL DEFAULT 0, premium_until DATETIME NULL DEFAULT NULL,
    is_banned TINYINT(1) NOT NULL DEFAULT 0, created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, last_login_at DATETIME NULL DEFAULT NULL,
    PRIMARY KEY (id), UNIQUE KEY uq_users_email (email)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE IF NOT EXISTS tokens (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT, user_id INT UNSIGNED NOT NULL, token_hash CHAR(64) NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, last_used_at DATETIME NULL DEFAULT NULL, expires_at DATETIME NOT NULL,
    PRIMARY KEY (id), UNIQUE KEY uq_tokens_hash (token_hash), KEY idx_tokens_user (user_id),
    CONSTRAINT fk_tokens_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE IF NOT EXISTS login_attempts (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT, ip VARCHAR(45) NOT NULL, attempted_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id), KEY idx_attempts_ip_time (ip, attempted_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE IF NOT EXISTS downloads (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT, user_id INT UNSIGNED NOT NULL, video_id CHAR(11) NOT NULL,
    title VARCHAR(255) NOT NULL DEFAULT '', created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id), KEY idx_downloads_user (user_id), KEY idx_downloads_time (created_at),
    CONSTRAINT fk_downloads_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE IF NOT EXISTS admins (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT, username VARCHAR(60) NOT NULL, password_hash VARCHAR(255) NOT NULL,
    totp_secret VARCHAR(64) NULL DEFAULT NULL, totp_enabled TINYINT(1) NOT NULL DEFAULT 0, totp_last_step BIGINT NOT NULL DEFAULT 0,
    session_version INT UNSIGNED NOT NULL DEFAULT 1, last_login_at DATETIME NULL DEFAULT NULL, last_login_ip VARCHAR(45) NULL DEFAULT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (id), UNIQUE KEY uq_admins_username (username)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE IF NOT EXISTS admin_attempts (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT, ip VARCHAR(45) NOT NULL, username VARCHAR(60) NOT NULL DEFAULT '',
    attempted_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (id),
    KEY idx_admin_attempts_ip (ip, attempted_at), KEY idx_admin_attempts_user (username, attempted_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE IF NOT EXISTS admin_audit (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT, admin_id INT UNSIGNED NULL DEFAULT NULL, admin_name VARCHAR(60) NOT NULL DEFAULT '',
    action VARCHAR(60) NOT NULL, target VARCHAR(190) NOT NULL DEFAULT '', details VARCHAR(500) NOT NULL DEFAULT '',
    ip VARCHAR(45) NOT NULL DEFAULT '', created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (id), KEY idx_audit_time (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
SQL;

/* ---------------- Gönderim ---------------- */

$v = [
    'db_host' => 'localhost', 'db_name' => '', 'db_user' => '', 'admin_user' => 'admin',
    'yt_key' => '', 'vds_url' => 'https://yt2.aydworks.com.tr',
];
$errors = [];

if (($_SERVER['REQUEST_METHOD'] ?? 'GET') === 'POST') {
    if (!hash_equals($_SESSION['csrf'], (string) ($_POST['_csrf'] ?? ''))) {
        $errors[] = 'Form süresi doldu, sayfayı yenile.';
    }

    foreach ($v as $k => $_) {
        $v[$k] = trim((string) ($_POST[$k] ?? ''));
    }
    $dbPass = (string) ($_POST['db_pass'] ?? '');
    $adminPass = (string) ($_POST['admin_pass'] ?? '');
    $adminPass2 = (string) ($_POST['admin_pass2'] ?? '');
    $vdsKey = trim((string) ($_POST['vds_key'] ?? ''));
    $v['admin_user'] = mb_strtolower($v['admin_user']);
    $v['vds_url'] = rtrim($v['vds_url'], '/');

    if (!$ready) $errors[] = 'Sunucu gereksinimleri karşılanmıyor.';
    if ($v['db_name'] === '' || $v['db_user'] === '') $errors[] = 'Veritabanı adı ve kullanıcısı gerekli.';
    if (!preg_match('/^[a-z0-9._-]{3,60}$/', $v['admin_user'])) $errors[] = 'Admin kullanıcı adı 3-60 karakter; harf, rakam, nokta, tire olabilir.';
    if (strlen($adminPass) < 12 || !preg_match('/[a-zçğıöşü]/u', $adminPass) || !preg_match('/[A-ZÇĞİÖŞÜ]/u', $adminPass) || !preg_match('/\d/', $adminPass)) {
        $errors[] = 'Admin şifresi en az 12 karakter olmalı; büyük harf, küçük harf ve rakam içermeli.';
    }
    if ($adminPass !== $adminPass2) $errors[] = 'Admin şifreleri eşleşmiyor.';
    if (!preg_match('#^https://[a-z0-9.-]+(:\d+)?$#i', $v['vds_url'])) $errors[] = 'VDS adresi https:// ile başlamalı.';

    $pdo = null;
    if (!$errors) {
        try {
            $pdo = new PDO('mysql:host=' . $v['db_host'] . ';dbname=' . $v['db_name'] . ';charset=utf8mb4', $v['db_user'], $dbPass, [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_EMULATE_PREPARES => false,
            ]);
            $pdo->exec("SET time_zone = '+03:00'");
        } catch (Throwable $ex) {
            $errors[] = 'Veritabanına bağlanılamadı. Bilgileri kontrol et.';
            error_log('[Box install] DB: ' . $ex->getMessage());
        }
    }

    if (!$errors && $pdo) {
        try {
            foreach (array_filter(array_map('trim', explode(';', $schema))) as $statement) {
                $pdo->exec($statement);
            }

            $hash = defined('PASSWORD_ARGON2ID') ? password_hash($adminPass, PASSWORD_ARGON2ID) : password_hash($adminPass, PASSWORD_BCRYPT, ['cost' => 12]);
            $exists = $pdo->prepare('SELECT id FROM admins WHERE username = ?');
            $exists->execute([$v['admin_user']]);
            if ($exists->fetchColumn()) {
                $pdo->prepare('UPDATE admins SET password_hash = ?, session_version = session_version + 1 WHERE username = ?')->execute([$hash, $v['admin_user']]);
            } else {
                $pdo->prepare('INSERT INTO admins (username, password_hash) VALUES (?, ?)')->execute([$v['admin_user'], $hash]);
            }

            require_once $apiDir . '/config_writer.php';
            box_write_config([
                'DB_HOST' => $v['db_host'], 'DB_NAME' => $v['db_name'], 'DB_USER' => $v['db_user'], 'DB_PASS' => $dbPass,
                'YT_DATA_API_KEY' => $v['yt_key'], 'VDS_BASE_URL' => $v['vds_url'], 'VDS_SIGNING_KEY' => $vdsKey,
                'DOWNLOAD_LINK_TTL' => 300, 'TOKEN_TTL_DAYS' => 180, 'CACHE_TIME' => 3600,
            ]);

            file_put_contents($lockFile, date(DATE_ATOM) . "\n", LOCK_EX);
            @chmod($lockFile, 0640);

            $pdo->prepare('INSERT INTO admin_audit (admin_name, action, ip) VALUES (?, ?, ?)')
                ->execute([$v['admin_user'], 'install', substr((string) ($_SERVER['REMOTE_ADDR'] ?? ''), 0, 45)]);

            // Sihirbaz kendini devre dışı bırakmayı dener
            @rename(__FILE__, __DIR__ . '/index.php.disabled');

            session_destroy();
            shell('Kurulum tamamlandı', function () use ($v): void {
                ?>
                <div class="auth">
                    <div class="steps"><i class="on"></i><i class="on"></i><i class="on"></i></div>
                    <div class="head"><?= box_logo(64) ?><h1>Box hazır</h1>
                        <p class="sub">Tablolar oluşturuldu, <b><?= e($v['admin_user']) ?></b> admin hesabı açıldı ve ayarlar kaydedildi.</p></div>
                    <div class="flash warn">Güvenlik için sunucudan <b>install</b> klasörünü sil. Girişten sonra ilk iş <b>Güvenlik</b> sayfasından 2FA'yı aç.</div>
                    <a class="btn primary full" href="../">Admin paneline giriş yap</a>
                </div>
                <?php
            });
        } catch (Throwable $ex) {
            error_log('[Box install] ' . $ex->getMessage());
            $errors[] = 'Kurulum tamamlanamadı: ' . $ex->getMessage();
        }
    }
}

/* ---------------- Form ---------------- */

shell('Kurulum', function () use ($checks, $ready, $v, $errors): void {
    ?>
    <form class="auth wide" method="post" autocomplete="off">
        <div class="steps"><i class="on"></i><i class="on"></i><i></i></div>
        <div class="head"><?= box_logo(64) ?><h1>Box kurulumu</h1><p class="sub">Birkaç bilgiyle paneli ve uygulama API'sini hazırlayalım.</p></div>

        <div class="checks">
            <?php foreach ($checks as $label => $ok): ?>
                <div><span><?= e($label) ?></span><?= $ok ? '<span class="badge b-ok">TAMAM</span>' : ($label === 'HTTPS bağlantı' ? '<span class="badge b-warn">ÖNERİLİR</span>' : '<span class="badge b-ban">EKSİK</span>') ?></div>
            <?php endforeach; ?>
        </div>

        <?php foreach ($errors as $err): ?><div class="flash err"><?= e($err) ?></div><?php endforeach; ?>

        <input type="hidden" name="_csrf" value="<?= e($_SESSION['csrf']) ?>">

        <fieldset><legend>Veritabanı</legend>
            <div class="two">
                <div class="field"><label>Sunucu</label><input name="db_host" value="<?= e($v['db_host']) ?>" required></div>
                <div class="field"><label>Veritabanı adı</label><input name="db_name" value="<?= e($v['db_name']) ?>" required></div>
                <div class="field"><label>Kullanıcı</label><input name="db_user" value="<?= e($v['db_user']) ?>" required></div>
                <div class="field"><label>Şifre</label><input name="db_pass" type="password" autocomplete="new-password"></div>
            </div>
            <p class="hint">Hosting panelinden boş bir MySQL veritabanı açıp bilgilerini gir. Tablolar otomatik oluşturulur.</p>
        </fieldset>

        <fieldset><legend>Admin hesabı</legend>
            <div class="field"><label>Kullanıcı adı</label><input name="admin_user" value="<?= e($v['admin_user']) ?>" autocapitalize="none" required></div>
            <div class="two">
                <div class="field"><label>Şifre</label><input name="admin_pass" type="password" minlength="12" autocomplete="new-password" required></div>
                <div class="field"><label>Şifre (tekrar)</label><input name="admin_pass2" type="password" minlength="12" autocomplete="new-password" required></div>
            </div>
            <p class="hint">En az 12 karakter; büyük harf, küçük harf ve rakam.</p>
        </fieldset>

        <fieldset><legend>Servisler</legend>
            <div class="field"><label>YouTube Data API v3 anahtarı</label><input name="yt_key" value="<?= e($v['yt_key']) ?>"></div>
            <div class="field"><label>VDS adresi</label><input name="vds_url" value="<?= e($v['vds_url']) ?>" required></div>
            <div class="field"><label>VDS imza anahtarı</label><input name="vds_key" type="password" autocomplete="off">
                <p class="hint">VDS'deki /etc/yt-api.env dosyasındaki YT_API_KEY değeri. Sonradan panelden de değiştirilebilir.</p></div>
        </fieldset>

        <button class="btn primary full" type="submit" <?= $ready ? '' : 'disabled' ?>>Kurulumu tamamla</button>
    </form>
    <?php
});
