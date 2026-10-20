<?php
if (!defined('ROOT')) { http_response_code(404); exit; }




function h($value): string { return htmlspecialchars((string)$value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }
function requiredText(string $key, int $max = 255): string {
    $value = trim((string)($_POST[$key] ?? ''));
    if ($value === '' || mb_strlen($value) > $max) throw new RuntimeException('Alan boş ya da çok uzun: ' . fieldLabel($key));
    return $value;
}
function fieldLabel(string $key): string {
    return ['title' => 'başlık', 'message' => 'mesaj', 'username' => 'kullanıcı adı', 'email' => 'e-posta', 'item_key' => 'ürün anahtarı', 'name' => 'ad', 'note' => 'not', 'recipient' => 'alıcı', 'subject' => 'konu', 'smtp_host' => 'SMTP sunucusu', 'smtp_from' => 'gönderen', 'smtp_user' => 'SMTP kullanıcısı', 'site_name' => 'site adı', 'site_description' => 'açıklama', 'mail_footer' => 'e-posta alt bilgisi'][$key] ?? $key;
}
function loginBucket(): string { return hash('sha256', 'login|' . (string)($_SERVER['REMOTE_ADDR'] ?? 'local')); }
function nbNum($v, int $dec = 0): string { return number_format((float)$v, $dec, ',', '.'); }
function nbDate(?string $value, string $format = 'd.m.Y H:i'): string { return $value ? date($format, strtotime($value)) : '—'; }

function nbRemaining(int $seconds): string {
    $s = max(0, $seconds);
    if ($s >= 86400) return intdiv($s, 86400) . ' gün ' . intdiv($s % 86400, 3600) . ' sa';
    if ($s >= 3600) return intdiv($s, 3600) . ' sa ' . intdiv($s % 3600, 60) . ' dk';
    return max(1, intdiv($s, 60)) . ' dk';
}
function nbAgo(?string $value): string {
    if (!$value) return 'hiç';
    $d = time() - strtotime($value);
    if ($d < 60) return 'az önce';
    if ($d < 3600) return intdiv($d, 60) . ' dk önce';
    if ($d < 86400) return intdiv($d, 3600) . ' sa önce';
    if ($d < 86400 * 30) return intdiv($d, 86400) . ' gün önce';
    return date('d.m.Y', strtotime($value));
}


const NB_ROLES = ['admin' => 'Yönetici', 'support' => 'Destek', 'viewer' => 'İzleyici'];
const NB_ROLE_HINTS = [
    'admin' => 'Her şeye erişir: kullanıcılar, premium, uygulama ayarları, servisler, ekip ve güvenlik.',
    'support' => 'Kullanıcıları bulur, premium açar/uzatır, hesabı askıya alır ve not ekler. Ayarlara dokunamaz.',
    'viewer' => 'Her şeyi görür, hiçbir şeyi değiştiremez. Ortaklar ve muhasebe için.',
];

function panelPages(): array {
    $all = ['admin', 'support', 'viewer'];
    return [
        'dashboard' => ['grid', 'Kontrol merkezi', 'Genel', $all],
        'status' => ['shield', 'Güvenlik durumu', 'Genel', ['admin', 'viewer']],
        'users' => ['users', 'Kullanıcılar', 'Kullanıcılar', $all],
        'player' => ['users', 'Kullanıcı dosyası', null, $all],
        'premium' => ['bolt', 'Premium', 'Kullanıcılar', $all],
        'downloads' => ['download', 'İndirmeler', 'Kullanıcılar', $all],
        'stats' => ['chart', 'İstatistikler', 'Kullanıcılar', $all],
        'app' => ['sliders', 'Uygulama ayarları', 'Uygulama', ['admin']],
        'services' => ['server', 'Servisler', 'Uygulama', ['admin', 'viewer']],
        'health' => ['pulse', 'API sağlığı', 'Uygulama', ['admin', 'viewer']],
        'shield' => ['lock', 'Koruma ve yedek', 'Sistem', ['admin']],
        'team' => ['team', 'Ekip', 'Sistem', ['admin']],
        'audit' => ['list', 'Denetim günlüğü', 'Sistem', ['admin', 'viewer']],
        'errors' => ['bug', 'Hatalar', 'Sistem', ['admin']],
        'logs' => ['terminal', 'Sistem günlüğü', 'Sistem', ['admin']],
        'settings' => ['gear', 'Sistem ve sürüm', 'Sistem', ['admin']],
        'profile' => ['user', 'Hesabım', null, $all],
    ];
}

function canSee(array $admin, string $page): bool {
    $p = panelPages()[$page] ?? null;
    return $p !== null && in_array($admin['role'], $p[3], true);
}

function actionAllowed(string $role, string $action): bool {
    if ($role === 'admin') return true;
    $everyone = ['logout', 'profile', 'session_revoke', 'sessions_revoke', 'totp_begin', 'totp_enable', 'totp_disable', 'totp_regen', 'migration_ack', 'device_remove'];
    $map = [
        'support' => ['premium_grant', 'premium_revoke', 'user_note', 'user_ban', 'user_unban', 'user_logout_all', 'user_rename', 'user_quota'],
        'viewer' => [],
    ];
    return in_array($action, $everyone, true) || in_array($action, $map[$role] ?? [], true);
}

function can(string $action): bool { return actionAllowed((string)($GLOBALS['NB_ADMIN']['role'] ?? ''), $action); }

function panelUser(): ?array {
    if (empty($_SESSION['admin_id']) || !empty($_SESSION['pending_2fa'])) return null;
    $user = q('SELECT * FROM admins WHERE id=?', [$_SESSION['admin_id']])->fetch();
    $staff = $user && $user['status'] === 'active' && isset(NB_ROLES[$user['role']]);
    
    if (!$staff || !isset($_SESSION['auth_hash']) || !hash_equals((string)$_SESSION['auth_hash'], hash('sha256', $user['password'] . '|' . ($user['totp_enabled_at'] ?? '')))) { panelDropSession(); return null; }
    
    if (isset($_SESSION['ua']) && !hash_equals((string)$_SESSION['ua'], userAgentHash())) { panelDropSession(); return null; }
    $idle = !empty($_SESSION['remember']) ? 30 * 86400 : 2 * 3600;
    if (time() - (int)($_SESSION['last_seen'] ?? 0) > $idle) { panelDropSession(); return null; }
    if (time() - (int)($_SESSION['last_seen'] ?? 0) > 60) $_SESSION['last_seen'] = time();
    return $user;
}

function panelDropSession(): void {
    $_SESSION = [];
    if (session_status() === PHP_SESSION_ACTIVE) session_regenerate_id(true);
}

function panelSessionHash(array $user): string { return hash('sha256', $user['password'] . '|' . ($user['totp_enabled_at'] ?? '')); }

function panelStartSession(array $user, bool $remember): void {
    session_regenerate_id(true);
    $_SESSION = ['csrf' => bin2hex(random_bytes(24)), 'admin_id' => (int)$user['id'], 'auth_hash' => panelSessionHash($user), 'last_seen' => time(), 'login_at' => time(), 'ua' => userAgentHash()];
    if ($remember) { $_SESSION['remember'] = true; $_SESSION['cookie_refreshed'] = time(); sessionCookie(30); }
}


function loginLocked(string $login): ?string {
    $ip = clientIp();
    $ipFails = (int)q('SELECT COUNT(*) FROM admin_logins WHERE ip=? AND success=0 AND created_at>DATE_SUB(NOW(),INTERVAL 15 MINUTE)', [$ip])->fetchColumn();
    if ($ipFails >= 10) return 'Çok fazla hatalı deneme. 15 dakika sonra tekrar deneyin.';
    if ($login !== '') {
        $accFails = (int)q('SELECT COUNT(*) FROM admin_logins WHERE login=? AND success=0 AND created_at>DATE_SUB(NOW(),INTERVAL 15 MINUTE)', [mb_substr($login, 0, 120)])->fetchColumn();
        if ($accFails >= 8) return 'Bu hesap için çok fazla hatalı deneme yapıldı. 15 dakika sonra tekrar deneyin.';
    }
    return null;
}


function loginSlowdown(): void {
    $fails = (int)q('SELECT COUNT(*) FROM admin_logins WHERE ip=? AND success=0 AND created_at>DATE_SUB(NOW(),INTERVAL 15 MINUTE)', [clientIp()])->fetchColumn();
    if ($fails > 0) usleep(min(3000, 250 * $fails) * 1000);
}







function securityChecks(): array {
    static $cache = null;
    if ($cache !== null) return $cache;
    $c = [];
    $add = function (string $group, string $title, string $state, string $detail, string $link = '', string $fix = '') use (&$c): void { $c[] = compact('group', 'title', 'state', 'detail', 'link', 'fix'); };
    $json = fn(string $key): ?array => ($v = json_decode(site($key), true)) && is_array($v) ? $v : null;
    $hoursSince = fn(?string $at): ?float => $at ? (time() - strtotime($at)) / 3600 : null;

    $url = (string)cfg('app.url', '');
    $add('Sunucu', 'HTTPS', str_starts_with($url, 'https://') && isHttps() ? 'ok' : 'bad', str_starts_with($url, 'https://') && isHttps() ? 'Bağlantılar şifreli; tarayıcılara yalnızca HTTPS kullanmaları söyleniyor (HSTS).' : 'Site HTTPS üzerinden açılmıyor. Oturum çerezleri ve jetonlar açıkta gidebilir.', 'settings', 'Hosting panelinden SSL sertifikasını etkinleştirin ve site adresini https:// ile kaydedin.');
    $scan = $json('exposure_scan');
    if (!$scan) $add('Sunucu', 'Dışarıdan erişim taraması', 'warn', 'Henüz tarama yapılmadı. Gizli dosyaların (ayarlar, yedekler, günlükler) dışarıya kapalı olduğu doğrulanmadı.', 'status', 'Güvenlik durumu sayfasında "Şimdi tara" düğmesine basın.');
    elseif (!empty($scan['open'])) $add('Sunucu', 'Dışarıdan erişim taraması', 'bad', 'İçeriği dışarıdan okunabilen dosyalar: ' . implode(', ', array_map(fn($o) => rawurldecode($o['path']), $scan['open'])) . '.', 'status', 'Paketi yeniden yükleyip tekrar tarayın; düzelmezse hosting firmasına .htaccess desteğini sorun.');
    elseif (!empty($scan['error'])) $add('Sunucu', 'Dışarıdan erişim taraması', 'warn', (string)$scan['error'], 'status');
    else $add('Sunucu', 'Dışarıdan erişim taraması', ($hoursSince($scan['at']) ?? 999) > 72 ? 'warn' : 'ok', count($scan['checked'] ?? []) . ' gizli yol denendi, hiçbirinin içeriği dışarıdan okunamıyor. Son tarama: ' . nbAgo($scan['at']) . '.', 'status');
    $add('Sunucu', 'Kurulum sihirbazı', is_file(ROOT . '/storage/installed.php') ? 'ok' : 'warn', is_file(ROOT . '/storage/installed.php') ? 'Kilitli. Veritabanı boşalsa bile kimse siteyi yeniden kuramaz.' : 'Kilit dosyası yok; bir sonraki istekte oluşturulacak.', 'status');
    $oldFiles = array_values(array_filter(['_inc/core.php', 'install/index.php', 'install/index.php.disabled', 'box-api/config.php', 'assets/admin.css'], fn($f) => is_file(ROOT . '/' . $f)));
    if ($oldFiles) $add('Sunucu', 'Eski sürüm dosyaları', 'info', 'İlk panelden kalan dosyalar duruyor: ' . implode(', ', $oldFiles) . '. Dışarıya kapalılar ama silmen daha temiz.', 'settings', 'Ayarlar taşındıktan sonra hosting dosya yöneticisinden _inc, install ve box-api klasörlerini sil.');
    $add('Sunucu', 'PHP sürümü', version_compare(PHP_VERSION, '8.2.0', '>=') ? 'ok' : 'warn', 'PHP ' . PHP_VERSION . (version_compare(PHP_VERSION, '8.2.0', '>=') ? '' : '. Güvenlik güncellemesi alan bir sürüme (8.2+) geçin.'), '', 'Hosting panelinden PHP sürümünü 8.2 ya da üstüne çıkarın.');
    $key = (string)cfg('security.master_key', '');
    $add('Sunucu', 'Ana anahtar', strlen($key) >= 64 ? 'ok' : 'warn', strlen($key) >= 64 ? 'Güçlü (' . strlen($key) . ' karakter). Şifreli ayarlar ve denetim zinciri bundan türetilen ayrı anahtarları kullanır.' : 'Ana anahtar kısa. config.php içindeki master_key en az 64 rastgele karakter olmalı.');
    $free = @disk_free_space(ROOT);
    if ($free !== false) $add('Sunucu', 'Disk alanı', $free < 300 * 1048576 ? 'warn' : 'ok', nbNum($free / 1073741824, 1) . ' GB boş.');
    $migErr = $json('migration_error');
    if ($migErr) $add('Sunucu', 'Veritabanı güncellemesi', 'bad', 'Son güncelleme yarım kaldı: ' . $migErr['message'], 'logs', 'Sistem günlüğündeki hatayı inceleyin; sorun giderilince panel güncellemeyi kendisi tekrar dener.');
    else $add('Sunucu', 'Veritabanı güncellemesi', 'ok', 'Şema sürümü ' . site('schema_version', '?') . ', sunucu ' . boxVersion() . '.');

    // Servisler
    $vds = $json('vds_health');
    if (boxVdsKey() === '') $add('Servisler', 'VDS indirme servisi', 'bad', 'İmza anahtarı girilmemiş; premium kullanıcılar indirme yapamaz.', 'services', 'Servisler sayfasından VDS imza anahtarını gir.');
    elseif (!$vds) $add('Servisler', 'VDS indirme servisi', 'info', 'Henüz kontrol edilmedi. Servisler sayfasından "Şimdi kontrol et" de.', 'services');
    else $add('Servisler', 'VDS indirme servisi', $vds['ok'] ? 'ok' : ((int)($vds['fails'] ?? 1) >= 2 ? 'bad' : 'warn'), $vds['ok'] ? 'Çalışıyor, ' . (int)$vds['ms'] . ' ms (' . nbAgo($vds['at']) . ').' : 'Ulaşılamıyor: ' . $vds['error'] . ' (' . nbAgo($vds['at']) . ').', 'services', 'VDS\'de "systemctl status yt-api" ve nginx durumunu kontrol et.');
    $ytErr = $json('yt_last_error');
    if (boxYoutubeKey() === '') $add('Servisler', 'YouTube arama anahtarı', 'bad', 'Girilmemiş; premium kullanıcılar arama yapamaz.', 'services', 'Servisler sayfasından YouTube Data API anahtarını gir.');
    elseif ($ytErr && ($hoursSince($ytErr['at']) ?? 999) < 6) $add('Servisler', 'YouTube arama', 'warn', 'Son hata (' . nbAgo($ytErr['at']) . '): ' . ($ytErr['reason'] !== '' ? $ytErr['reason'] : 'HTTP ' . $ytErr['status']) . '.', 'services');
    else $add('Servisler', 'YouTube arama', 'ok', 'Anahtar tanımlı. Bugün yaklaşık ' . nbNum(boxYoutubeUnitsToday()) . ' / 10.000 kota birimi kullanıldı.', 'services');
    if (configBool('maintenance_mode')) $add('Servisler', 'Bakım modu', 'warn', 'Açık. Kullanıcılar şu an uygulamayı kullanamıyor.', 'app');

    // Panel
    $admins = q("SELECT id,username,totp_enabled_at FROM admins WHERE status='active'")->fetchAll();
    $no2fa = array_values(array_filter($admins, fn($a) => empty($a['totp_enabled_at'])));
    $add('Panel', 'İki adımlı giriş', $no2fa ? (staffTwoFactorRequired() ? 'info' : 'warn') : 'ok', $no2fa ? count($no2fa) . ' ekip hesabında kapalı' . (staffTwoFactorRequired() ? ' (ilk girişte açmak zorunda).' : '. Şifre çalınırsa panel açık kalır.') : 'Bütün ekip hesaplarında açık.', 'profile', 'Hesabım sayfasından iki adımlı girişi aç.');
    $fails = (int)q('SELECT COUNT(*) FROM admin_logins WHERE success=0 AND created_at>DATE_SUB(NOW(),INTERVAL 1 DAY)')->fetchColumn();
    $add('Panel', 'Hatalı girişler (24 saat)', $fails >= 25 ? 'bad' : ($fails >= 8 ? 'warn' : 'ok'), $fails . ' hatalı deneme' . ($fails >= 8 ? '. Panel adresine deneme yapılıyor olabilir; IP kısıtı açmayı düşün.' : '.'), 'shield');
    $add('Panel', 'Panel IP kısıtı', site('admin_ip_allowlist') !== '' ? 'ok' : 'info', site('admin_ip_allowlist') !== '' ? 'Panel yalnızca izin verilen adreslerden açılıyor.' : 'Kapalı. Sabit IP\'n varsa açmak saldırı yüzeyini küçültür.', 'shield');
    $audit = $json('audit_verify');
    if (!$audit || ($hoursSince($audit['at'] ?? null) ?? 99) > 1 || ($GLOBALS['NB_FRESH_CHECKS'] ?? false)) { $audit = ['at' => date('Y-m-d H:i:s')] + auditVerify(); saveSite('audit_verify', json_encode($audit)); }
    $add('Panel', 'Denetim günlüğü zinciri', $audit['ok'] ? 'ok' : 'bad', $audit['ok'] ? $audit['checked'] . ' kayıt doğrulandı, hiçbiri silinmemiş ya da değiştirilmemiş.' : '#' . $audit['broken_at'] . ' numaralı kayıtta zincir kırık: kayıtlar veritabanından değiştirilmiş ya da silinmiş.', 'audit');
    $wl = $json('watch_last');
    if ($wl && strtotime((string)$wl['at']) > time() - 7 * 86400) $add('Panel', 'Panel dışı değişiklik', 'bad', implode(', ', (array)$wl['changed']) . ' panel dışından değişti (' . nbAgo($wl['at']) . ').', 'status', 'Sen yapmadıysan veritabanı ve hosting şifrelerini değiştir.');
    else $add('Panel', 'Panel dışı değişiklik izleme', 'ok', 'Uygulama ayarları, ekip hesapları ve premium üyelikler izleniyor; panel dışından değişirse Telegram\'a uyarı gider.', 'status');
    $add('Panel', 'Yeni cihaz onayı', loginApprovalOn() ? 'ok' : 'info', loginApprovalOn() ? 'Panele yeni cihazdan girişte Telegram onayı isteniyor.' : (telegramConfigured() ? 'Kapalı.' : 'Telegram bağlı değil; yeni cihaz onayı çalışmıyor.'), 'shield');

    // Yedek ve uyarı
    $add('Yedek ve uyarı', 'Telegram uyarıları', telegramConfigured() ? 'ok' : 'warn', telegramConfigured() ? 'Bağlı. Yeni konumdan giriş, servis kesintisi ve güvenlik olayları anında gelir.' : 'Bağlı değil. Güvenlik olaylarından haberin olmaz.', 'shield', 'Koruma ve yedek sayfasından bot belirtecini ve sohbet kimliğini gir.');
    $last = site('backup_last'); $lastAt = $last !== '' ? substr($last, 0, 19) : null;
    if (site('backup_enabled', '0') !== '1') $add('Yedek ve uyarı', 'Günlük yedek', 'warn', 'Kapalı. Veritabanı kaybolursa geri dönüş yolu yok.', 'shield', 'Koruma ve yedek sayfasından günlük yedeği aç.');
    elseif (str_contains($last, 'HATA')) $add('Yedek ve uyarı', 'Günlük yedek', 'bad', 'Son yedek alınamadı: ' . $last, 'shield');
    else $add('Yedek ve uyarı', 'Günlük yedek', ($hoursSince($lastAt) ?? 999) > 36 ? 'warn' : 'ok', $lastAt ? 'Son yedek ' . nbAgo($lastAt) . '.' : 'Açık, henüz yedek alınmadı (gece 04:00\'ten sonra alınır).', 'shield');
    $add('Yedek ve uyarı', 'Yedek şifresi', decryptSecret(site('backup_password')) !== '' ? 'ok' : (site('backup_enabled', '0') === '1' ? 'warn' : 'info'), decryptSecret(site('backup_password')) !== '' ? 'Yedekler AES-256 ile şifreli gidiyor.' : 'Yedekler şifresiz gidiyor; Telegram hesabın ele geçirilirse kullanıcı verisi okunabilir.', 'shield');
    $cronAt = site('cron_real_run'); $lazyAt = site('cron_lazy_run');
    if (($hoursSince($cronAt ?: null) ?? 999) > 0.5 && $lazyAt !== '' && ($hoursSince($lazyAt) ?? 999) <= 1) $add('Yedek ve uyarı', 'Zamanlanmış görev', 'info', 'Hosting\'in görevi ulaşmıyor; görevler panel ve uygulama trafiğiyle çalışıyor (son ' . nbAgo($lazyAt) . '). Gece kimse kullanmazsa yedek gecikebilir.', 'settings', 'Sistem ve sürüm sayfasındaki cron komutunu hosting paneline ekle.');
    else $add('Yedek ve uyarı', 'Zamanlanmış görev', ($hoursSince($cronAt ?: null) ?? 999) <= 0.5 ? 'ok' : (($hoursSince($cronAt ?: null) ?? 999) <= 6 ? 'warn' : 'info'), $cronAt ? 'Son çalışma ' . nbAgo($cronAt) . '.' : 'Hosting cron\'u kurulmamış; süresi dolan premiumlar, yedek ve gece taramaları trafikle çalışır.', 'settings', 'Sistem ve sürüm sayfasındaki cron komutunu hosting paneline ekle (5 dakikada bir).');

    $crit = (int)q("SELECT COUNT(*) FROM security_events WHERE severity='critical' AND acknowledged_at IS NULL AND created_at>DATE_SUB(NOW(),INTERVAL 7 DAY)")->fetchColumn();
    $warns = (int)q("SELECT COUNT(*) FROM security_events WHERE severity='warn' AND acknowledged_at IS NULL AND created_at>DATE_SUB(NOW(),INTERVAL 7 DAY)")->fetchColumn();
    $add('Yedek ve uyarı', 'Güvenlik olayları (7 gün)', $crit ? 'bad' : ($warns ? 'warn' : 'ok'), $crit || $warns ? "$crit kritik, $warns uyarı incelenmeyi bekliyor." : 'İncelenmemiş olay yok.', 'status');
    return $cache = $c;
}

function checkSummary(array $checks): array {
    $n = ['ok' => 0, 'warn' => 0, 'bad' => 0, 'info' => 0];
    foreach ($checks as $c) $n[$c['state']]++;
    return $n;
}
