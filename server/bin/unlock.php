<?php








if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
require dirname(__DIR__) . '/app/bootstrap.php';
$cmd = $argv[1] ?? ''; $name = $argv[2] ?? '';
$staff = fn(string $n) => q('SELECT * FROM admins WHERE username=?', [$n])->fetch();
switch ($cmd) {
    case 'ip':
        saveSite('admin_ip_allowlist', ''); logAdmin(null, 'cli_unlock_ip'); securityAlert('Sunucudan panel IP kısıtı kaldırıldı (bin/unlock.php).');
        echo "Panel IP kısıtı kaldırıldı.\n"; break;
    case '2fa':
        $u = $staff($name); if (!$u) { fwrite(STDERR, "Ekip hesabı bulunamadı: $name\n"); exit(1); }
        q('UPDATE admins SET totp_secret=NULL,totp_enabled_at=NULL,totp_recovery=NULL,totp_last_step=0 WHERE id=?', [$u['id']]); q('DELETE FROM admin_sessions WHERE user_id=?', [$u['id']]);
        logAdmin(null, 'cli_reset_2fa', ['target_id' => (int)$u['id']]); securityAlert("Sunucudan iki adımlı giriş kapatıldı: {$u['username']}");
        echo "{$u['username']} için iki adımlı giriş kapatıldı.\n"; break;
    case 'password':
        $u = $staff($name); if (!$u) { fwrite(STDERR, "Ekip hesabı bulunamadı: $name\n"); exit(1); }
        $new = 'Box-' . bin2hex(random_bytes(8)) . '7';
        q('UPDATE admins SET password=? WHERE id=?', [password_hash($new, PASSWORD_DEFAULT), $u['id']]); q('DELETE FROM admin_sessions WHERE user_id=?', [$u['id']]);
        logAdmin(null, 'cli_reset_password', ['target_id' => (int)$u['id']]); securityAlert("Sunucudan panel şifresi sıfırlandı: {$u['username']}");
        echo "{$u['username']} için yeni şifre: $new\nGiriş yaptıktan sonra Hesabım sayfasından değiştir.\n"; break;
    case 'sessions':
        q('DELETE FROM admin_sessions'); logAdmin(null, 'cli_kill_sessions'); echo "Bütün panel oturumları kapatıldı.\n"; break;
    default:
        echo "Kullanım: php bin/unlock.php ip | 2fa <kullanıcı> | password <kullanıcı> | sessions\n"; exit(1);
}
