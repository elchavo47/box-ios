<?php
if (!defined('ROOT')) { http_response_code(404); exit; }

/*
 * Kurulum durumu, sürüm ve otomatik veritabanı güncellemesi.
 * Yeni sürüm zip'i sunucuya açıldığında ilk istekte ensureSchema() eksik tablo ve sütunları
 * oluşturur, mevcut veriye dokunmaz ve panelde "Güncelleme tamamlandı" raporu gösterir.
 */

const BOX_SCHEMA_VERSION = 12;

function boxVersion(): string {
    static $version = null;
    if ($version === null) $version = is_file(ROOT . '/app/version.php') ? (string)(require ROOT . '/app/version.php') : '1.0.0';
    return $version;
}
function neonBreakVersion(): string { return boxVersion(); }

function setupState(bool $refresh = false): string {
    static $state = null;
    if (!$refresh && $state !== null) return $state;
    if (!is_file(ROOT . '/config/config.php')) return $state = 'unconfigured';
    try {
        $tables = db()->query("SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_TYPE='BASE TABLE'")->fetchAll(PDO::FETCH_COLUMN);
        if (!$tables) return $state = 'empty';
        return $state = array_diff(['users', 'admins'], $tables) ? 'partial' : 'ready';
    } catch (PDOException $e) {
        nbReport($e);
        return $state = (int)($e->errorInfo[1] ?? 0) === 1049 ? 'missing_database' : 'unreachable';
    }
}

function setupRecovery(string $state): never {
    http_response_code(503);
    header('Content-Type: text/html; charset=utf-8');
    header('Cache-Control: no-store');
    header("Content-Security-Policy: default-src 'none'; style-src 'self'; font-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'");
    if (str_starts_with(routePath(), '/api/') || str_starts_with(routePath(), '/box-api')) {
        header('Content-Type: application/json; charset=utf-8');
        echo '{"ok":false,"error":"Sunucu bakımda, birazdan tekrar dene."}';
        exit;
    }
    $messages = [
        'partial' => ['Veritabanı eksik görünüyor', 'Temel tablolar bulunamadı. Veri kaybını önlemek için site durduruldu. Hosting panelinden veritabanı yedeğini geri yükleyin.'],
        'empty' => ['Veritabanı boş', 'Bu site daha önce kurulmuş ama veritabanında hiç tablo yok. Güvenlik nedeniyle kurulum sihirbazı açılmaz. Yedeği geri yükleyin ya da sıfırdan kurmak için config/config.php ve storage/installed.php dosyalarını hosting dosya yöneticisinden silin.'],
        'missing_database' => ['Veritabanı bulunamadı', 'config/config.php içindeki veritabanı adı sunucuda yok. Hosting panelinizdeki veritabanı adını kontrol edin.'],
        'unreachable' => ['Veritabanına ulaşılamıyor', 'Veritabanı sunucusu yanıt vermiyor ya da bağlantı bilgileri hatalı. Birkaç dakika sonra tekrar deneyin; düzelmezse config/config.php ile hosting panelinizi karşılaştırın.'],
        'unconfigured' => ['Kurulum kilitli', 'Bu sunucu daha önce kurulmuş (storage/installed.php var) ama config/config.php bulunamadı. config.php dosyasını yedekten geri yükleyin.'],
    ];
    [$title, $message] = $messages[$state] ?? $messages['unreachable'];
    $e = fn(string $v): string => htmlspecialchars($v, ENT_QUOTES, 'UTF-8');
    echo '<!doctype html><html lang="tr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>Box · Bakım</title><link rel="stylesheet" href="/assets/site.css"></head><body class="plain"><main class="plain-card"><h1>' . $e($title) . '</h1><p>' . $e($message) . '</p></main></body></html>';
    exit;
}

/** Uygulamanın uzaktan ayarlarının varsayılanları. Eksik olanlar güncellemede eklenir, mevcut değerlere dokunulmaz. */
function boxConfigDefaults(): array {
    return [
        'maintenance_mode' => false,
        'maintenance_message' => 'Kısa bir bakım yapıyoruz, birazdan geri döneceğiz.',
        'registration_open' => true,
        'min_app_version' => '1.0',
        'announcement_on' => false,
        'announcement_title' => '',
        'announcement_body' => '',
        'premium_daily_downloads' => 150,
        'premium_daily_searches' => 400,
        'new_user_premium_days' => 0,
        'support_email' => '',
    ];
}

function ensureSchema(bool $force = false): void {
    try {
        $current = (int)(q("SELECT setting_value FROM site_settings WHERE setting_key='schema_version'")->fetchColumn() ?: 0);
        $storedApp = (string)(q("SELECT setting_value FROM site_settings WHERE setting_key='app_version'")->fetchColumn() ?: '');
    } catch (PDOException $e) { $current = 0; $storedApp = ''; }
    if (!$force && $current >= BOX_SCHEMA_VERSION && $storedApp === boxVersion()) return;

    if (!(int)q("SELECT GET_LOCK('box_schema', 15)")->fetchColumn()) return;
    $report = []; $started = microtime(true);
    $note = function (string $what, string $name) use (&$report): void { $report[] = ['what' => $what, 'name' => $name]; };
    $tableExists = fn(string $table): bool => (bool)q("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=?", [$table])->fetchColumn();
    $has = fn(string $table, string $column): bool => (bool)q("SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=? AND COLUMN_NAME=?", [$table, $column])->fetchColumn();
    $hasIndex = fn(string $table, string $index): bool => (bool)q("SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=? AND INDEX_NAME=?", [$table, $index])->fetchColumn();
    $mk = function (string $table, string $ddl) use ($tableExists, $note): void { if ($tableExists($table)) return; q($ddl); $note('Tablo oluşturuldu', $table); };
    $add = function (string $table, string $column, string $ddl) use ($has, $note): void { if ($has($table, $column)) return; q("ALTER TABLE `$table` ADD COLUMN $ddl"); $note('Sütun eklendi', "$table.$column"); };
    try {
        // 1) Şemadaki bütün tablolar (yoksa oluştur)
        foreach (array_filter(array_map('trim', preg_split('/;\s*(?:\r?\n|$)/', (string)(require ROOT . '/database/schema.php')))) as $statement) {
            if (preg_match('/^CREATE TABLE\s+`?(\w+)`?/i', $statement, $tm)) $mk($tm[1], preg_replace('/^CREATE TABLE\s+/i', 'CREATE TABLE IF NOT EXISTS ', $statement));
        }

        // 2) Box 1.0 (ilk sürüm) veritabanından gelen tabloları yeni yapıya getir
        $add('users', 'premium_since', 'premium_since DATETIME NULL DEFAULT NULL AFTER premium_until');
        $add('users', 'ban_reason', 'ban_reason VARCHAR(255) NULL DEFAULT NULL AFTER is_banned');
        $add('users', 'note', 'note TEXT NULL AFTER ban_reason');
        $add('users', 'app_version', 'app_version VARCHAR(20) NULL DEFAULT NULL AFTER note');
        $add('users', 'last_seen_at', 'last_seen_at DATETIME NULL DEFAULT NULL AFTER last_login_at');
        $add('users', 'daily_downloads', 'daily_downloads INT UNSIGNED NULL DEFAULT NULL AFTER app_version');
        $add('users', 'avatar_file', 'avatar_file VARCHAR(64) NULL DEFAULT NULL AFTER daily_downloads');
        if (!$hasIndex('users', 'idx_users_premium')) { q('ALTER TABLE users ADD INDEX idx_users_premium(is_premium,premium_until)'); $note('Dizin eklendi', 'users.idx_users_premium'); }
        if (!$hasIndex('users', 'idx_users_seen')) { q('ALTER TABLE users ADD INDEX idx_users_seen(last_seen_at)'); $note('Dizin eklendi', 'users.idx_users_seen'); }
        $add('tokens', 'device', 'device VARCHAR(120) NULL DEFAULT NULL AFTER token_hash');

        // Eski admin tablosu: password_hash -> password, rol/durum/2FA alanları
        if ($has('admins', 'password_hash') && !$has('admins', 'password')) { q('ALTER TABLE admins CHANGE password_hash password VARCHAR(255) NOT NULL'); $note('Sütun yeniden adlandırıldı', 'admins.password'); }
        $add('admins', 'email', 'email VARCHAR(190) NULL DEFAULT NULL AFTER username');
        $add('admins', 'role', "role VARCHAR(20) NOT NULL DEFAULT 'admin' AFTER password");
        $add('admins', 'status', "status VARCHAR(20) NOT NULL DEFAULT 'active' AFTER role");
        $add('admins', 'totp_recovery', 'totp_recovery TEXT NULL AFTER totp_last_step');
        $add('admins', 'totp_enabled_at', 'totp_enabled_at DATETIME NULL DEFAULT NULL AFTER totp_recovery');
        $add('admins', 'avatar_url', 'avatar_url VARCHAR(255) NULL DEFAULT NULL AFTER totp_enabled_at');
        if ($has('admins', 'totp_enabled')) {
            // Eski sürümde 2FA sırrı düz metin tutuluyordu: şifrele ve yeni alana taşı
            foreach (q("SELECT id,totp_secret FROM admins WHERE totp_enabled=1 AND totp_secret IS NOT NULL AND totp_secret NOT LIKE 'v2:%'")->fetchAll() as $a) {
                q('UPDATE admins SET totp_secret=?,totp_enabled_at=COALESCE(totp_enabled_at,NOW()) WHERE id=?', [encryptSecret((string)$a['totp_secret']), $a['id']]);
                $note('2FA sırrı şifrelendi', 'admins #' . $a['id']);
            }
            q("UPDATE admins SET totp_secret=NULL WHERE totp_enabled=0 AND totp_enabled_at IS NULL");
            q('ALTER TABLE admins DROP COLUMN totp_enabled');
            $note('Eski sütun kaldırıldı', 'admins.totp_enabled');
        }
        if ($has('admins', 'session_version')) { q('ALTER TABLE admins DROP COLUMN session_version'); $note('Eski sütun kaldırıldı', 'admins.session_version'); }

        // Eski sürümün işlem kaydı ve giriş denemeleri: yeni zincirli günlüğe özet olarak aktar
        if ($tableExists('admin_audit') && !site('legacy_audit_imported')) {
            $n = (int)q('SELECT COUNT(*) FROM admin_audit')->fetchColumn();
            if ($n > 0) logAdmin(null, 'legacy_import', ['eski_kayit' => $n, 'not' => 'Box 1.0 işlem kaydı korunuyor (admin_audit tablosu).']);
            saveSite('legacy_audit_imported', date('Y-m-d H:i:s'));
        }

        // 3) Uygulama ayarlarının varsayılanları
        $existing = array_flip(q('SELECT config_key FROM app_config')->fetchAll(PDO::FETCH_COLUMN));
        foreach (boxConfigDefaults() as $key => $value) {
            if (isset($existing[$key])) continue;
            q('INSERT INTO app_config(config_key,config_value) VALUES(?,?)', [$key, json_encode($value, JSON_UNESCAPED_UNICODE)]);
            $note('Ayar eklendi', $key);
        }

        // 4) Box 1.0'ın box-api/config.php dosyasındaki servis anahtarlarını panele taşı
        $legacy = boxLegacyConfig();
        if ($legacy) {
            if (secretSetting('yt_api_key') === '' && $legacy['YT_DATA_API_KEY'] !== '') { saveSecretSetting('yt_api_key', $legacy['YT_DATA_API_KEY']); $note('Ayar taşındı', 'YouTube API anahtarı'); }
            if (secretSetting('vds_signing_key') === '' && $legacy['VDS_SIGNING_KEY'] !== '') { saveSecretSetting('vds_signing_key', $legacy['VDS_SIGNING_KEY']); $note('Ayar taşındı', 'VDS imza anahtarı'); }
            if (site('vds_url') === '' && $legacy['VDS_BASE_URL'] !== '') { saveSite('vds_url', $legacy['VDS_BASE_URL']); $note('Ayar taşındı', 'VDS adresi'); }
        }
        if (site('vds_url') === '') saveSite('vds_url', 'https://yt2.aydworks.com.tr');

        $from = $current; $fromApp = $storedApp;
        q("INSERT INTO site_settings(setting_key,setting_value) VALUES('schema_version',?) ON DUPLICATE KEY UPDATE setting_value=VALUES(setting_value)", [(string)BOX_SCHEMA_VERSION]);
        q("INSERT INTO site_settings(setting_key,setting_value) VALUES('app_version',?) ON DUPLICATE KEY UPDATE setting_value=VALUES(setting_value)", [boxVersion()]);
        foreach (nbRelocateSensitiveFiles() as $done) $note('Güvenlik', $done);
        nbMarkInstalled();
        if ($fromApp !== '' || $report) {
            $payload = ['id' => bin2hex(random_bytes(6)), 'at' => date('Y-m-d H:i:s'), 'from_app' => $fromApp !== '' ? $fromApp : 'ilk kurulum', 'to_app' => boxVersion(), 'from_schema' => $from, 'to_schema' => BOX_SCHEMA_VERSION, 'items' => $report, 'ms' => (int)round((microtime(true) - $started) * 1000)];
            q("INSERT INTO site_settings(setting_key,setting_value) VALUES('migration_report',?) ON DUPLICATE KEY UPDATE setting_value=VALUES(setting_value)", [json_encode($payload, JSON_UNESCAPED_UNICODE)]);
        }
    } catch (Throwable $e) {
        nbReport($e, 'Şema güncellemesi');
        try { q("INSERT INTO site_settings(setting_key,setting_value) VALUES('migration_error',?) ON DUPLICATE KEY UPDATE setting_value=VALUES(setting_value)", [json_encode(['at' => date('Y-m-d H:i:s'), 'message' => mb_substr($e->getMessage(), 0, 400), 'items' => $report], JSON_UNESCAPED_UNICODE)]); } catch (Throwable $ignored) {}
        throw $e;
    } finally {
        q("SELECT RELEASE_LOCK('box_schema')");
    }
    try { q("DELETE FROM site_settings WHERE setting_key='migration_error'"); } catch (Throwable $ignored) {}
}

/** Box 1.0 kurulumunun ayar dosyası (box-api/config.php) varsa sabitlerini okur; dosyayı çalıştırmaz. */
function boxLegacyConfig(): ?array {
    $file = ROOT . '/box-api/config.php';
    if (!is_file($file)) return null;
    $src = (string)@file_get_contents($file);
    $out = [];
    foreach (['DB_HOST', 'DB_NAME', 'DB_USER', 'DB_PASS', 'YT_DATA_API_KEY', 'VDS_BASE_URL', 'VDS_SIGNING_KEY'] as $k) {
        $out[$k] = preg_match("/const\s+$k\s*=\s*'((?:[^'\\\\]|\\\\.)*)'\s*;/", $src, $m) ? stripcslashes($m[1]) : '';
    }
    foreach (['YT_DATA_API_KEY' => 'GOOGLE_API_ANAHTARI', 'VDS_SIGNING_KEY' => 'VDS_DEKI_YT_API_KEY_ILE_AYNI'] as $k => $placeholder) if ($out[$k] === $placeholder) $out[$k] = '';
    return $out;
}

function nbMarkInstalled(): void {
    $file = ROOT . '/storage/installed.php';
    if (!is_file($file)) @file_put_contents($file, "<?php\n// Box kurulumu tamamlandı: " . date('c') . "\n// Sıfırdan kurulum için (yalnızca boş veritabanına) bu dosyayı ve config/config.php dosyasını silin.\nhttp_response_code(404);\n", LOCK_EX);
}
function nbInstalled(): bool { return is_file(ROOT . '/storage/installed.php') || is_file(ROOT . '/config/config.php'); }

/** Web kökünden okunabilecek hassas dosyaları kaldırır ya da gizli klasöre taşır. */
function nbRelocateSensitiveFiles(): array {
    $done = [];
    foreach (['/database/schema.sql', '/schema.sql', '/box-api/install.lock'] as $rel) {
        if (is_file(ROOT . $rel) && @unlink(ROOT . $rel)) $done[] = 'Dışarıdan okunabilen dosya kaldırıldı: ' . ltrim($rel, '/');
    }
    foreach (['logs' => glob(ROOT . '/storage/logs/*.log') ?: [], 'backups' => array_merge(glob(ROOT . '/storage/backups/*.zip') ?: [], glob(ROOT . '/storage/backups/*.gz') ?: [])] as $kind => $files) {
        $n = 0;
        foreach ($files as $f) if (@rename($f, nbPrivateDir($kind) . '/' . basename($f)) || @unlink($f)) $n++;
        if ($n) $done[] = $n . ($kind === 'logs' ? ' hata günlüğü' : ' yedek dosyası') . ' gizli klasöre taşındı';
    }
    return $done;
}
