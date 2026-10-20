<?php
if (!defined('ROOT')) { http_response_code(404); exit; }

/*
 * Ek korumalar: panel dışı değişiklik izleme, yeni cihaz onayı, kritik işlem onayı (step-up),
 * pasif ekip hesaplarının askıya alınması ve trafiğe bağlı yedek zamanlayıcı.
 */

function watchFingerprint(): array {
    $h = function (string $sql): string { $c = hash_init('sha256'); foreach (q($sql)->fetchAll(PDO::FETCH_NUM) as $row) hash_update($c, json_encode($row, JSON_UNESCAPED_UNICODE) . "\n"); return hash_final($c); };
    return [
        'config' => $h('SELECT config_key,config_value FROM app_config ORDER BY config_key'),
        'staff' => $h('SELECT id,username,email,role,status,password,totp_secret,totp_enabled_at FROM admins ORDER BY id'),
        'premium' => $h('SELECT id,is_premium,premium_until FROM users WHERE is_premium=1 ORDER BY id'),
    ];
}

function watchRefresh(): void {
    try { saveSite('watch_fp', json_encode(watchFingerprint())); } catch (Throwable $e) { nbReport($e); }
}


function watchCheck(): array {
    try {
        $saved = json_decode(site('watch_fp'), true);
        $now = watchFingerprint();
        if (!is_array($saved)) { saveSite('watch_fp', json_encode($now)); return []; }
        $labels = ['config' => 'Uygulama ayarları (app_config)', 'staff' => 'Ekip hesapları', 'premium' => 'Premium üyelikler'];
        $changed = [];
        foreach ($now as $k => $v) if (($saved[$k] ?? '') !== $v) $changed[] = $labels[$k] ?? $k;
        if ($changed) {
            secEvent('critical', 'db_tamper', 'Panel dışından veritabanı değişikliği: ' . implode(', ', $changed) . '. Bu değişikliği sen yapmadıysan hemen şifreleri değiştir ve hosting erişimini kontrol et.', null, 'db' . implode(',', $changed) . date('YmdH'), 1);
            saveSite('watch_fp', json_encode($now));
            saveSite('watch_last', json_encode(['at' => date('Y-m-d H:i:s'), 'changed' => $changed], JSON_UNESCAPED_UNICODE));
        }
        return $changed;
    } catch (Throwable $e) { nbReport($e); return []; }
}



const NB_DEVICE_COOKIE = 'box_dev';

function loginApprovalOn(): bool { return site('login_approval', '1') === '1' && telegramConfigured(); }

function knownDevice(int $userId): bool {
    $tok = (string)($_COOKIE[NB_DEVICE_COOKIE] ?? '');
    if (!preg_match('/^[A-Za-z0-9_-]{40,64}$/', $tok)) return false;
    $id = q('SELECT id FROM admin_devices WHERE user_id=? AND token_hash=?', [$userId, hash('sha256', $tok)])->fetchColumn();
    if ($id) { q('UPDATE admin_devices SET last_seen_at=NOW(),last_ip=? WHERE id=?', [clientIp(), $id]); return true; }
    return false;
}

function rememberDevice(int $userId): void {
    $tok = b64url(random_bytes(32));
    q('INSERT INTO admin_devices(user_id,token_hash,label,last_ip,last_seen_at) VALUES(?,?,?,?,NOW())', [$userId, hash('sha256', $tok), mb_substr(deviceLabel(), 0, 120), clientIp()]);
    setcookie(NB_DEVICE_COOKIE, $tok, ['expires' => time() + 365 * 86400, 'path' => '/admin', 'secure' => isHttps(), 'httponly' => true, 'samesite' => 'Strict']);
}


function deviceLabel(): string {
    $ua = (string)($_SERVER['HTTP_USER_AGENT'] ?? '');
    $b = preg_match('/Edg\//', $ua) ? 'Edge' : (preg_match('/OPR\//', $ua) ? 'Opera' : (preg_match('/Firefox\//', $ua) ? 'Firefox' : (preg_match('/CriOS|Chrome\//', $ua) ? 'Chrome' : (preg_match('/Safari\//', $ua) ? 'Safari' : 'Tarayıcı'))));
    $o = preg_match('/iPhone|iPad/', $ua) ? 'iOS' : (preg_match('/Android/', $ua) ? 'Android' : (preg_match('/Windows/', $ua) ? 'Windows' : (preg_match('/Mac OS X/', $ua) ? 'macOS' : (preg_match('/Linux/', $ua) ? 'Linux' : 'bilinmeyen sistem'))));
    return $b . ' · ' . $o;
}


function loginApprovalStart(array $user, bool $remember): string {
    $tok = b64url(random_bytes(32));
    q('INSERT INTO admin_login_approvals(token_hash,user_id,ip,label,remember) VALUES(?,?,?,?,?)', [hash('sha256', $tok), $user['id'], clientIp(), mb_substr(deviceLabel(), 0, 120), $remember ? 1 : 0]);
    $url = rtrim((string)cfg('app.url', ''), '/') . '/approve?t=' . $tok;
    telegramSend("🔐 Panele yeni cihazdan giriş isteniyor\nHesap: {$user['username']}\nCihaz: " . deviceLabel() . "\nIP: " . clientIp() . "\n\nSen değilsen onaylama, şifreni değiştir.\nOnay / ret: " . $url);
    q('DELETE FROM admin_login_approvals WHERE created_at<DATE_SUB(NOW(),INTERVAL 1 DAY)');
    return $tok;
}

function loginApprovalState(string $tok): ?array {
    $r = q('SELECT * FROM admin_login_approvals WHERE token_hash=?', [hash('sha256', $tok)])->fetch();
    if (!$r) return null;
    if ($r['status'] === 'pending' && strtotime((string)$r['created_at']) < time() - 600) $r['status'] = 'expired';
    return $r;
}




function staffInactiveSweep(): int {
    $days = max(0, (int)site('staff_inactive_days', '90'));
    if ($days === 0) return 0;
    $rows = q("SELECT id,username FROM admins WHERE role IN ('support','viewer') AND status='active' AND COALESCE(last_login_at,created_at)<DATE_SUB(NOW(),INTERVAL ? DAY)", [$days])->fetchAll();
    foreach ($rows as $r) {
        q("UPDATE admins SET status='suspended' WHERE id=?", [$r['id']]);
        logAdmin(null, 'staff_auto_suspend', ['user' => $r['username'], 'days' => $days]);
        securityAlert("🧹 Ekip hesabı askıya alındı: {$r['username']} ({$days} gündür giriş yok). Panel > Ekip'ten yeniden açabilirsin.");
    }
    if ($rows) watchRefresh();
    return count($rows);
}

function staffTwoFactorRequired(): bool { return site('staff_require_2fa', '0') === '1'; }






function lazyCronTick(): void {
    static $armed = false;
    if ($armed) return;
    $real = strtotime(site('cron_real_run', '2000-01-01 00:00:00')) ?: 0;
    if (time() - $real < 900) return;
    $lazy = strtotime(site('cron_lazy_run', '2000-01-01 00:00:00')) ?: 0;
    if (time() - $lazy < 300) return;
    $armed = true;
    register_shutdown_function(function (): void {
        if (function_exists('fastcgi_finish_request')) @fastcgi_finish_request();
        try {
            if ((int)q("SELECT GET_LOCK('box_lazy_cron',0)")->fetchColumn() !== 1) return;
            try {
                $lazy = strtotime(site('cron_lazy_run', '2000-01-01 00:00:00')) ?: 0;
                if (time() - $lazy >= 300) {
                    saveSite('cron_lazy_run', date('Y-m-d H:i:s'));
                    @set_time_limit(300); @ignore_user_abort(true);
                    boxExpirePremiums();
                    runDailyBackup();
                    runSecurityCron();
                }
            } finally { q("SELECT RELEASE_LOCK('box_lazy_cron')"); }
        } catch (Throwable $e) { nbReport($e, 'Yedek zamanlayıcı'); }
    });
}






const NB_STEP_UP_ACTIONS = [
    'team_create' => 'Ekip hesabı oluşturma', 'team_update' => 'Ekip üyesinin rolünü / durumunu değiştirme',
    'team_reset_password' => 'Ekip üyesinin şifresini sıfırlama', 'team_reset_2fa' => 'Ekip üyesinin iki adımlı girişini sıfırlama',
    'user_delete' => 'Kullanıcı hesabını silme', 'premium_bulk' => 'Toplu premium verme',
    'backup_restore' => 'Yedekten geri yükleme', 'security_save' => 'Güvenlik ayarlarını değiştirme', 'guard_save' => 'Ek koruma ayarlarını değiştirme',
    'services_save' => 'Servis anahtarlarını değiştirme', 'totp_disable' => 'İki adımlı girişi kapatma',
];

function stepUpMode(): string { $m = site('step_up_mode', 'new'); return in_array($m, ['new', 'always', 'off'], true) ? $m : 'new'; }


function stepUpTrustedDevice(int $userId): bool {
    $tok = (string)($_COOKIE[NB_DEVICE_COOKIE] ?? '');
    if (!preg_match('/^[A-Za-z0-9_-]{40,64}$/', $tok)) return false;
    $created = q('SELECT created_at FROM admin_devices WHERE user_id=? AND token_hash=?', [$userId, hash('sha256', $tok)])->fetchColumn();
    if (!$created || strtotime((string)$created) > time() - 3 * 86400) return false;
    return empty($_SESSION['ip0']) || $_SESSION['ip0'] === clientIp();
}


function stepUpRequired(array $admin, string $action): bool {
    if (!isset(NB_STEP_UP_ACTIONS[$action]) || stepUpMode() === 'off' || !telegramConfigured()) return false;
    if ((int)($_SESSION['stepup_until'] ?? 0) > time() && ($_SESSION['stepup_ip'] ?? '') === clientIp()) return false;
    return stepUpMode() === 'always' || !stepUpTrustedDevice((int)$admin['id']);
}


function stepUpCheck(array $admin, string $action): bool|string {
    $label = NB_STEP_UP_ACTIONS[$action] ?? $action;
    $code = preg_replace('/\D/', '', (string)($_POST['tg_code'] ?? ''));
    $p = $_SESSION['stepup'] ?? null;
    
    if ($code !== '' && !empty($admin['totp_enabled_at']) && ($stepNo = totpVerify(decryptSecret((string)$admin['totp_secret']), $code, (int)$admin['totp_last_step'])) !== null) {
        q('UPDATE admins SET totp_last_step=? WHERE id=?', [$stepNo, $admin['id']]);
        unset($_SESSION['stepup']);
        $_SESSION['stepup_until'] = time() + 900; $_SESSION['stepup_ip'] = clientIp();
        logAdmin((int)$admin['id'], 'step_up_ok', ['action' => $action, 'via' => 'totp']);
        return true;
    }
    if ($code !== '' && is_array($p)) {
        if ($p['exp'] < time()) { unset($_SESSION['stepup']); return 'Kodun süresi doldu. Yeni kod Telegram\'a gönderilsin diye işlemi tekrar dene.'; }
        if (($p['tries'] ?? 0) >= 5) { unset($_SESSION['stepup']); securityAlert("⛔ Kritik işlem onayında 5 hatalı kod\nHesap: {$admin['username']}\nIP: " . clientIp()); return 'Çok fazla hatalı kod. İşlemi baştan başlat.'; }
        if (hash_equals((string)$p['hash'], hash('sha256', $code . '|' . session_id())) && $p['action'] === $action) {
            unset($_SESSION['stepup']);
            $_SESSION['stepup_until'] = time() + 900; $_SESSION['stepup_ip'] = clientIp();
            logAdmin((int)$admin['id'], 'step_up_ok', ['action' => $action]);
            return true;
        }
        $_SESSION['stepup']['tries'] = (int)($p['tries'] ?? 0) + 1;
        return 'Kod yanlış. Telegram\'daki son kodu gir.';
    }
    
    if (is_array($p) && $p['action'] === $action && $p['exp'] - 240 > time()) return 'Onay kodu Telegram\'a gönderildi. Kodu gir.';
    $new = str_pad((string)random_int(0, 999999), 6, '0', STR_PAD_LEFT);
    $_SESSION['stepup'] = ['hash' => hash('sha256', $new . '|' . session_id()), 'action' => $action, 'exp' => time() + 300, 'tries' => 0];
    [$ok, $err] = telegramSend("🛡️ Panel işlem onayı\nİşlem: {$label}\nHesap: {$admin['username']}\nCihaz: " . deviceLabel() . "\nIP: " . clientIp() . "\n\nKod: {$new}\n(5 dakika geçerli)\n\nBu işlemi sen başlatmadıysan kodu kimseye verme ve hemen şifreni değiştir.");
    logAdmin((int)$admin['id'], 'step_up_sent', ['action' => $action]);
    if ($ok) return 'Bu işlem için onay gerekiyor. Telegram\'a gelen 6 haneli kodu gir' . (!empty($admin['totp_enabled_at']) ? ' (ya da iki adımlı giriş uygulamandaki kodu).' : '.');
    if (!empty($admin['totp_enabled_at'])) return 'Telegram\'a ulaşılamadı. İki adımlı giriş uygulamandaki (Google Authenticator) kodu gir.';
    
    unset($_SESSION['stepup']);
    logAdmin((int)$admin['id'], 'step_up_skipped', ['action' => $action, 'reason' => mb_substr($err, 0, 120)]);
    return true;
}
