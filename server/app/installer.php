<?php
if (!defined('ROOT')) { http_response_code(404); exit; }

/*
 * Box kurulum sihirbazı.
 * - Boş veritabanı: bütün tabloları kurar, ilk yönetici hesabını açar.
 * - Box 1.x veritabanı (users + admins tabloları var): veriyi korur, yapıyı günceller,
 *   eski admin hesapları aynı şifreyle çalışmaya devam eder; istenirse yeni yönetici eklenir.
 * Kurulum bittikten sonra kalıcı olarak kilitlenir.
 */

if (nbInstalled()) { if (setupState() === 'ready') { header('Location: /admin'); exit; } setupRecovery(setupState()); }
header('Cache-Control: no-store');
header("Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; font-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'");
header('X-Robots-Tag: noindex');

$legacyCfg = boxLegacyConfig();
$host = preg_replace('/[^A-Za-z0-9.:-]/', '', (string)($_SERVER['HTTP_HOST'] ?? 'localhost'));
$error = '';
$values = [
    'app_url' => (isHttps() ? 'https://' : 'http://') . $host,
    'db_host' => $legacyCfg['DB_HOST'] ?? 'localhost',
    'db_port' => '3306',
    'db_name' => $legacyCfg['DB_NAME'] ?? '',
    'db_user' => $legacyCfg['DB_USER'] ?? '',
    'admin_user' => '',
    'admin_email' => '',
];
function installH($v): string { return htmlspecialchars((string)$v, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }

$requirements = [
    'PHP 8.1 veya üstü' => version_compare(PHP_VERSION, '8.1.0', '>='),
    'PDO MySQL' => extension_loaded('pdo_mysql'),
    'mbstring' => extension_loaded('mbstring'),
    'OpenSSL' => extension_loaded('openssl'),
    'cURL' => extension_loaded('curl'),
    'config ve storage yazılabilir' => is_writable(ROOT . '/config') && is_writable(ROOT . '/storage'),
];
$ready = !in_array(false, $requirements, true);

if (($_SERVER['REQUEST_METHOD'] ?? 'GET') === 'POST') {
    checkCsrf();
    foreach ($values as $key => $default) $values[$key] = trim((string)($_POST[$key] ?? $default));
    $lock = null;
    try {
        if (!$ready) throw new RuntimeException('Sunucu gereksinimleri karşılanmıyor (yukarıdaki listeye bak).');
        $dbHost = $values['db_host'];
        $port = filter_var($values['db_port'], FILTER_VALIDATE_INT);
        $name = $values['db_name'];
        $user = $values['db_user'];
        $pass = (string)($_POST['db_pass'] ?? '');
        if ($pass === '' && $legacyCfg && ($legacyCfg['DB_PASS'] ?? '') !== '' && $user === ($legacyCfg['DB_USER'] ?? '')) $pass = $legacyCfg['DB_PASS'];
        $admin = mb_strtolower($values['admin_user']);
        $email = strtolower($values['admin_email']);
        $password = (string)($_POST['admin_pass'] ?? '');
        $url = rtrim($values['app_url'], '/');

        if (!preg_match('/^[a-zA-Z0-9_.:-]+$/', $dbHost) || !$port || $port < 1 || $port > 65535 || !preg_match('/^[a-zA-Z0-9_]{1,64}$/', $name) || $user === '') throw new RuntimeException('Veritabanı bilgilerini kontrol edin.');
        if (!filter_var($url, FILTER_VALIDATE_URL) || !in_array(parse_url($url, PHP_URL_SCHEME), ['http', 'https'], true)) throw new RuntimeException('Geçerli bir HTTP/HTTPS site adresi girin.');

        $lock = fopen(nbPrivateDir() . '/install.lock', 'c');
        if (!$lock || !flock($lock, LOCK_EX | LOCK_NB)) throw new RuntimeException('Başka bir kurulum devam ediyor.');

        $pdo = new PDO("mysql:host=$dbHost;port=$port;dbname=$name;charset=utf8mb4", $user, $pass, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
        $tables = $pdo->query('SHOW TABLES')->fetchAll(PDO::FETCH_COLUMN);
        $legacy = in_array('users', $tables, true) && in_array('admins', $tables, true);
        if ($tables && !$legacy) throw new RuntimeException('Bu veritabanı boş değil ve Box veritabanına benzemiyor. Box için boş bir veritabanı seç.');
        $existingAdmins = $legacy ? (int)$pdo->query('SELECT COUNT(*) FROM admins')->fetchColumn() : 0;

        $wantsAdmin = $admin !== '' || $password !== '';
        if (!$existingAdmins || $wantsAdmin) {
            if (!preg_match('/^[a-z0-9._-]{3,32}$/', $admin)) throw new RuntimeException('Yönetici kullanıcı adı 3-32 karakter olmalı; harf, rakam, nokta, tire.');
            if ($email !== '' && !filter_var($email, FILTER_VALIDATE_EMAIL)) throw new RuntimeException('Yönetici e-postası geçerli değil.');
            if (!nbPasswordStrong($password)) throw new RuntimeException('Şifre en az 12 karakter olmalı, harf ve rakam içermeli; yaygın şifreler kabul edilmez.');
            if ($legacy && (int)$pdo->query('SELECT COUNT(*) FROM admins WHERE username=' . $pdo->quote($admin))->fetchColumn()) throw new RuntimeException('Bu yönetici adı zaten var. Mevcut hesabınla giriş yapmak için bu alanları boş bırak.');
        }

        $cfg = [
            'app' => ['name' => 'Box', 'url' => $url],
            'db' => ['host' => $dbHost, 'port' => $port, 'name' => $name, 'user' => $user, 'pass' => $pass, 'charset' => 'utf8mb4'],
            'security' => ['master_key' => bin2hex(random_bytes(48))],
        ];
        $contents = "<?php\n// Box sunucu ayarları. Bu dosyayı kimseyle paylaşma; master_key kaybolursa şifreli ayarlar (Telegram, servis anahtarları) okunamaz.\nreturn " . var_export($cfg, true) . ";\n";
        $temp = ROOT . '/config/.install-' . bin2hex(random_bytes(8)) . '.tmp';
        if (file_put_contents($temp, $contents, LOCK_EX) === false) throw new RuntimeException('Ayar dosyası oluşturulamadı.');
        chmod($temp, 0600);
        if (!rename($temp, ROOT . '/config/config.php')) throw new RuntimeException('Ayar dosyası kaydedilemedi.');

        // Yeni ayarlarla şemayı kur / güncelle
        $GLOBALS['CONFIG'] = $cfg;
        ensureSchema(true);
        if (!$existingAdmins || $wantsAdmin) {
            q("INSERT INTO admins(username,email,password,role,status) VALUES(?,?,?,'admin','active')", [$admin, $email !== '' ? $email : null, password_hash($password, PASSWORD_DEFAULT)]);
        }
        saveSite('cron_key', bin2hex(random_bytes(20)));
        logAdmin(null, 'install', ['mode' => $legacy ? 'upgrade' : 'fresh', 'version' => boxVersion()]);
        watchRefresh();
        nbMarkInstalled();

        session_regenerate_id(true);
        $_SESSION['csrf'] = bin2hex(random_bytes(24));
        header('Location: /admin');
        exit;
    } catch (Throwable $e) {
        nbReport($e);
        // Yarım kalan denemeyi geri al ki sihirbaz tekrar açılabilsin (bu istekten önce kurulum yoktu).
        @unlink(ROOT . '/config/config.php'); @unlink(ROOT . '/storage/installed.php');
        $error = $e instanceof RuntimeException && !($e instanceof PDOException) ? $e->getMessage() : ($e instanceof PDOException ? 'Veritabanına bağlanılamadı ya da tablo oluşturulamadı: ' . $e->getMessage() : 'Kurulum tamamlanamadı. Ayrıntı PHP hata günlüğünde.');
    } finally {
        if (is_resource($lock)) { flock($lock, LOCK_UN); fclose($lock); }
    }
}
$mark = '<svg class="box-mark lg" viewBox="0 0 48 48" aria-hidden="true"><path class="t" d="M24 6 41 15 24 24 7 15Z"/><path class="l" d="M6 19 22 28v15L6 34Z"/><path class="r" d="M42 19 26 28v15l16-9Z"/></svg>';
?>
<!doctype html>
<html lang="tr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>Kurulum · Box</title><link rel="icon" href="/assets/favicon.svg" type="image/svg+xml"><link rel="stylesheet" href="/assets/deck.css?v=<?=installH(boxVersion())?>"><script src="/assets/theme.js?v=<?=installH(boxVersion())?>"></script></head>
<body class="setup"><main class="card setup-card">
<header class="card-head"><div class="auth-brand"><?=$mark?><span>Box<small><?=$legacyCfg ? 'Yükseltme' : 'İlk kurulum'?></small></span></div></header>
<?php if ($legacyCfg): ?>
<h1>Box'ı yeni panele taşıyalım</h1><p class="muted">Mevcut kurulumun bulundu. Kullanıcılar, premium üyelikler, indirme geçmişi ve admin hesapların korunur; veritabanı bilgileri eski ayar dosyasından dolduruldu.</p>
<?php else: ?>
<h1>Sunucuyu ayağa kaldıralım</h1><p class="muted">Boş bir veritabanı, site adresi ve ilk yönetici hesabı. Kurulum bittikten sonra bu sayfa kalıcı olarak kilitlenir.</p>
<?php endif ?>
<ul class="req-list">
<?php foreach ($requirements as $label => $ok): ?><li class="<?=$ok ? 'ok' : 'bad'?>"><span class="dot <?=$ok ? 'ok' : 'bad'?>"></span><?=installH($label)?><?php if (!$ok && $label === 'PHP 8.1 veya üstü'): ?> <small>(şu an <?=installH(PHP_VERSION)?>)</small><?php endif ?></li><?php endforeach ?>
</ul>
<?php if ($error): ?><div class="notice bad" role="alert"><span><?=installH($error)?></span></div><?php endif ?>
<form method="post" action="/install" class="grid-fields" data-noajax><input type="hidden" name="csrf" value="<?=installH(csrf())?>">
<?php foreach (['app_url' => 'Site adresi', 'db_host' => 'Veritabanı sunucusu', 'db_port' => 'Veritabanı portu', 'db_name' => $legacyCfg ? 'Veritabanı adı' : 'Boş veritabanı adı', 'db_user' => 'Veritabanı kullanıcı adı'] as $key => $label): ?><label class="field"><span class="field-label"><?=installH($label)?></span><input class="input" name="<?=$key?>" value="<?=installH($values[$key])?>" type="<?=$key === 'db_port' ? 'number' : ($key === 'app_url' ? 'url' : 'text')?>" required></label><?php endforeach ?>
<label class="field"><span class="field-label">Veritabanı şifresi</span><input class="input" name="db_pass" type="password" autocomplete="off"<?=$legacyCfg ? ' placeholder="Boş bırakırsan eski ayardaki şifre kullanılır"' : ''?>></label>
<label class="field"><span class="field-label">Yönetici kullanıcı adı</span><input class="input" name="admin_user" value="<?=installH($values['admin_user'])?>" maxlength="32"<?=$legacyCfg ? '' : ' minlength="3" required'?> autocapitalize="none"><?php if ($legacyCfg): ?><span class="field-hint">Mevcut admin hesabınla giriş yapacaksan boş bırak.</span><?php endif ?></label>
<label class="field"><span class="field-label">Yönetici e-posta <small class="muted">(isteğe bağlı)</small></span><input class="input" name="admin_email" value="<?=installH($values['admin_email'])?>" type="email"></label>
<label class="field"><span class="field-label">Yönetici şifresi</span><input class="input" name="admin_pass" type="password"<?=$legacyCfg ? '' : ' minlength="12" required'?> autocomplete="new-password"><span class="field-hint">En az 12 karakter, harf ve rakam.</span></label>
<p class="field-hint wide">Kurulumdan sonra panel <b>/admin</b> adresinde açılır. Servis anahtarları (YouTube, VDS) panelde <b>Servisler</b> sayfasından yönetilir<?=$legacyCfg ? '; eski kurulumdaki anahtarlar otomatik taşınır' : ''?>.</p>
<button class="btn primary"<?=$ready ? '' : ' disabled'?>><?=$legacyCfg ? 'Yükseltmeyi tamamla' : 'Kurulumu tamamla'?></button></form></main></body></html>
