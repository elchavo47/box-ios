<?php
if (!defined('ROOT')) { http_response_code(404); exit; }






function nbPasswordStrong(string $password): bool {
    if (strlen($password) < 12 || strlen($password) > 200) return false;
    if (!preg_match('/\p{L}/u', $password) || !preg_match('/\d/', $password)) return false;
    $lower = mb_strtolower($password);
    foreach (['password', 'sifre', 'şifre', 'parola', 'qwerty', '123456', 'boxadmin', 'aydworks', 'admin123', 'letmein'] as $weak) if (str_contains($lower, $weak)) return false;
    return count(array_unique(mb_str_split($password))) >= 6;
}


const NB_B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

function totpNewSecret(): string {
    $bytes = random_bytes(20); $bits = '';
    foreach (str_split($bytes) as $c) $bits .= str_pad(decbin(ord($c)), 8, '0', STR_PAD_LEFT);
    $out = '';
    foreach (str_split($bits, 5) as $chunk) $out .= NB_B32[bindec(str_pad($chunk, 5, '0'))];
    return $out;
}

function totpDecode(string $b32): string {
    $b32 = strtoupper(preg_replace('/[^A-Za-z2-7]/', '', $b32)); $bits = '';
    foreach (str_split($b32) as $c) $bits .= str_pad(decbin(strpos(NB_B32, $c)), 5, '0', STR_PAD_LEFT);
    $out = '';
    foreach (str_split($bits, 8) as $byte) if (strlen($byte) === 8) $out .= chr(bindec($byte));
    return $out;
}

function totpCode(string $secret, int $step): string {
    $hash = hash_hmac('sha1', pack('N*', 0, $step), totpDecode($secret), true);
    $o = ord($hash[19]) & 0x0f;
    $num = ((ord($hash[$o]) & 0x7f) << 24) | (ord($hash[$o + 1]) << 16) | (ord($hash[$o + 2]) << 8) | ord($hash[$o + 3]);
    return str_pad((string)($num % 1000000), 6, '0', STR_PAD_LEFT);
}


function totpVerify(string $secret, string $code, int $lastStep = 0): ?int {
    $code = preg_replace('/\D/', '', $code);
    if (strlen($code) !== 6 || $secret === '') return null;
    $now = intdiv(time(), 30);
    foreach ([0, -1, 1] as $d) {
        $step = $now + $d;
        if ($step <= $lastStep) continue; 
        if (hash_equals(totpCode($secret, $step), $code)) return $step;
    }
    return null;
}

function totpUri(string $secret, string $account): string {
    return 'otpauth://totp/' . rawurlencode('Box Panel:' . $account) . '?secret=' . $secret . '&issuer=' . rawurlencode('Box Panel') . '&algorithm=SHA1&digits=6&period=30';
}


function totpRecoveryCodes(): array {
    $plain = []; $hashes = [];
    for ($i = 0; $i < 8; $i++) {
        $code = strtoupper(substr(bin2hex(random_bytes(5)), 0, 5) . '-' . substr(bin2hex(random_bytes(5)), 0, 5));
        $plain[] = $code; $hashes[] = password_hash($code, PASSWORD_DEFAULT);
    }
    return [$plain, json_encode($hashes)];
}

function totpUseRecovery(array $user, string $code): bool {
    $code = strtoupper(trim($code));
    $list = json_decode((string)($user['totp_recovery'] ?? '[]'), true) ?: [];
    foreach ($list as $i => $hash) {
        if (password_verify($code, (string)$hash)) {
            unset($list[$i]);
            q('UPDATE admins SET totp_recovery=? WHERE id=?', [json_encode(array_values($list)), $user['id']]);
            return true;
        }
    }
    return false;
}



function nbNameFold(string $name): string {
    $s = mb_strtolower($name, 'UTF-8');
    $s = strtr($s, ['ı' => 'i', 'İ' => 'i', 'ş' => 's', 'ğ' => 'g', 'ü' => 'u', 'ö' => 'o', 'ç' => 'c', 'â' => 'a', 'î' => 'i', 'û' => 'u',
        '0' => 'o', '1' => 'i', '3' => 'e', '4' => 'a', '5' => 's', '7' => 't', '8' => 'b', '@' => 'a', '$' => 's', '!' => 'i', '|' => 'i']);
    $s = preg_replace('/[^a-z]/', '', $s);
    return preg_replace('/(.)\1+/', '$1', $s);
}


function nbNameAllowed(string $name): bool {
    $folded = nbNameFold($name);
    if ($folded === '') return true;
    $reserved = ['admin', 'administrator', 'moderator', 'moderatör', 'yetkili', 'yonetici', 'destek', 'support', 'staff', 'official', 'resmi', 'boxadmin', 'aydworks', 'system', 'sistem', 'apple', 'developer', 'gelistirici'];
    $bad = ['amk', 'aminako', 'amina', 'orospu', 'orosbu', 'pic', 'yarak', 'yarrak', 'sik', 'sikerim', 'sikis', 'gotveren', 'gavat', 'kahpe', 'pezevenk', 'ibne', 'yavsak', 'serefsiz', 'kasar', 'fuck', 'fuk', 'shit', 'bitch', 'nigger', 'niga', 'nazi', 'hitler', 'porn', 'porno', 'cunt', 'dick', 'pussy', 'whore', 'rape'];
    foreach ($reserved as $w) if (str_contains($folded, nbNameFold($w))) return false;
    foreach ($bad as $w) {
        $w = nbNameFold($w);
        
        if (strlen($w) <= 3) { foreach (preg_split('/[\s_.\-]+/u', $name) as $part) if (nbNameFold($part) === $w) return false; continue; }
        if (str_contains($folded, $w)) return false;
    }
    foreach (array_filter(array_map('trim', preg_split('/[\n,]+/', site('name_blocklist')))) as $w) if (($fw = nbNameFold($w)) !== '' && str_contains($folded, $fw)) return false;
    return true;
}






function secEvent(string $severity, string $kind, string $message, ?int $userId = null, ?string $fingerprintSeed = null, int $quietHours = 6): bool {
    try {
        $fp = $fingerprintSeed !== null ? sha1($kind . '|' . $fingerprintSeed) : null;
        if ($fp !== null && q('SELECT 1 FROM security_events WHERE fingerprint=? AND created_at>DATE_SUB(NOW(),INTERVAL ' . max(1, $quietHours) . ' HOUR) LIMIT 1', [$fp])->fetchColumn()) return false;
        q('INSERT INTO security_events(severity,kind,message,user_id,fingerprint) VALUES(?,?,?,?,?)', [$severity, $kind, mb_substr($message, 0, 500), $userId, $fp]);
        if ($severity !== 'info') securityAlert(($severity === 'critical' ? '🚨 ' : '⚠️ ') . $message);
        if (random_int(1, 100) === 1) q('DELETE FROM security_events WHERE created_at<DATE_SUB(NOW(),INTERVAL 180 DAY)');
        return true;
    } catch (Throwable $e) { nbReport($e); return false; }
}



function apiIpThrottle(): void {
    $limit = (int)configValue('api_ip_limit_per_min', 600);
    if ($limit > 0) throttle('apiip:' . clientIpHash(), $limit, 60);
}






function exposureTargets(): array {
    $starts = function (string $file): callable {
        $head = is_file($file) ? substr(trim((string)file_get_contents($file, false, null, 0, 300)), 0, 60) : '';
        return fn(string $body): bool => $head !== '' && str_starts_with(ltrim($body), $head);
    };
    $phpSource = fn(string $body): bool => str_contains($body, '<?php') || str_contains($body, 'jwt_secret') || str_contains($body, 'function ');
    $listing = fn(string $body): bool => (bool)preg_match('/Index of \/|<title>Index of/i', $body);
    $accessLog = fn(string $body): bool => (bool)preg_match('/\b\d{1,3}(\.\d{1,3}){3}\b.*"(GET|POST) \//', $body) || (bool)preg_match('/\[(error|warn|notice)\]|PHP (Warning|Fatal|Notice)/i', $body);
    $t = [
        '/config/config.php' => ['Ayar dosyası', $phpSource],
        '/app/bootstrap.php' => ['Uygulama kodu', $phpSource],
        '/database/schema.php' => ['Veritabanı şeması', fn($b) => str_contains($b, 'CREATE TABLE')],
        '/storage/installed.php' => ['Kurulum kilidi', fn($b) => str_contains($b, 'kurulumu tamamlandı')],
        '/_inc/core.php' => ['Eski panel kodu', $phpSource],
        '/storage/private.php' => ['Gizli klasör adı', fn($b) => (bool)preg_match('/p-[a-f0-9]{32}/', $b)],
        '/bin/unlock.php' => ['Komut satırı araçları', $phpSource],
        '/box-api/config.php' => ['Eski sürüm ayar dosyası', $phpSource],
        '/config.php' => ['Kök dizindeki ayar dosyası', fn($b) => str_contains($b, '<?php') || (bool)preg_match('/YT_(AUDIO_)?API_KEY/', $b)],
        '/app/panel/static/deck.js' => ['Panel betiği (eski kopya)', fn($b) => str_contains($b, 'nb-ajax')],
        '/app/panel/static/deck.php' => ['Panel betiği (yalnızca girişle)', fn($b) => str_contains($b, 'nb-ajax')],
        '/.git/HEAD' => ['Git deposu', fn($b) => str_starts_with(ltrim($b), 'ref:')],
        '/.env' => ['.env dosyası', fn($b) => !preg_match('/<html|<!doctype/i', $b) && (bool)preg_match('/^[A-Z_]{3,}=/m', $b)],
        '/logs/' => ['Hosting günlük klasörü', $listing],
        '/storage/' => ['Depolama klasörü', $listing],
    ];
    
    foreach (['/database/schema.sql' => 'Eski veritabanı şeması', '/schema.sql' => 'Eski veritabanı şeması', '/box-api/install.lock' => 'Eski kurulum kilidi'] as $rel => $label) if (is_file(ROOT . $rel)) $t[$rel] = [$label, $starts(ROOT . $rel)];
    
    foreach (array_slice(array_filter(glob(ROOT . '/logs/*') ?: [], fn($f) => is_file($f) && filesize($f) > 0), 0, 3) as $f) $t['/logs/' . rawurlencode(basename($f))] = ['Hosting günlüğü (' . basename($f) . ')', $accessLog];
    foreach (array_slice(array_filter(glob(ROOT . '/logs/*') ?: [], fn($f) => is_file($f) && filesize($f) === 0), 0, 1) as $f) $t['/logs/' . rawurlencode(basename($f))] = ['Hosting günlüğü (' . basename($f) . ', boş)', fn($b) => false];
    
    $priv = nbPrivateDir();
    if (str_starts_with($priv, ROOT . '/')) {
        $rel = substr($priv, strlen(ROOT));
        foreach (array_slice(glob($priv . '/logs/*.log') ?: [], 0, 1) as $f) $t[$rel . '/logs/' . basename($f)] = ['Uygulama hata günlüğü', $accessLog];
    }
    return $t;
}


function runExposureScan(): array {
    $base = rtrim((string)cfg('app.url', ''), '/');
    $result = ['at' => date('Y-m-d H:i:s'), 'ok' => true, 'open' => [], 'checked' => [], 'error' => null];
    if ($base === '' || !function_exists('curl_multi_init')) { $result['error'] = 'Tarama için site adresi ve PHP cURL gerekli.'; $result['ok'] = false; return $result; }
    $targets = exposureTargets();
    $mh = curl_multi_init(); $handles = [];
    foreach ($targets as $path => [$label, $verify]) {
        $ch = curl_init($base . $path);
        curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_RANGE => '0-4095', CURLOPT_FOLLOWLOCATION => false, CURLOPT_CONNECTTIMEOUT => 5, CURLOPT_TIMEOUT => 10, CURLOPT_USERAGENT => 'Box-SelfScan/2.0', CURLOPT_ENCODING => '']);
        curl_multi_add_handle($mh, $ch); $handles[$path] = $ch;
    }
    do { $status = curl_multi_exec($mh, $running); if ($running) curl_multi_select($mh, 1.0); } while ($running && $status === CURLM_OK);
    $reached = 0;
    foreach ($handles as $path => $ch) {
        [$label, $verify] = $targets[$path];
        $code = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE); $body = (string)curl_multi_getcontent($ch);
        if ($code > 0) $reached++;
        
        $open = in_array($code, [200, 206], true) && trim($body) !== '' && $verify($body);
        $note = $open ? 'Dosyanın içeriği dışarıdan okunabiliyor' : ($code === 0 ? 'Yanıt yok' : (in_array($code, [200, 206], true) && trim($body) !== '' ? 'Başka bir sayfa döndü (güvenlik duvarı ya da 404 sayfası), dosya içeriği yok' : 'HTTP ' . $code));
        $result['checked'][] = ['path' => $path, 'label' => $label, 'code' => $code, 'open' => $open, 'note' => $note];
        if ($open) $result['open'][] = ['path' => $path, 'label' => $label, 'code' => $code];
        curl_multi_remove_handle($mh, $ch); curl_close($ch);
    }
    curl_multi_close($mh);
    if ($reached === 0) { $result['ok'] = false; $result['error'] = 'Site kendi adresine ulaşamadı (sunucu dışarıya istek atamıyor olabilir).'; }
    elseif ($result['open']) {
        $result['ok'] = false;
        secEvent('critical', 'exposure', 'Dışarıdan okunabilen dosya: ' . implode(', ', array_map(fn($o) => rawurldecode($o['path']), $result['open'])) . '. Panel > Güvenlik durumu.', null, implode(',', array_column($result['open'], 'path')), 24);
    }
    saveSite('exposure_scan', json_encode($result, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
    return $result;
}


function runSecurityCron(): void {
    if (site('sec_cron_hourly') !== date('Y-m-d H')) {
        saveSite('sec_cron_hourly', date('Y-m-d H'));
        watchCheck();
        try { boxServiceWatch(); } catch (Throwable $e) { nbReport($e, 'Servis izleme'); }
    }
    if (site('sec_cron_daily') !== date('Y-m-d') && (int)date('G') >= 3) {
        saveSite('sec_cron_daily', date('Y-m-d'));
        try { staffInactiveSweep(); } catch (Throwable $e) { nbReport($e); }
        try { errorCleanup(); } catch (Throwable $e) { nbReport($e); }
        try { boxDailyCleanup(); } catch (Throwable $e) { nbReport($e); }
        try { $a = auditVerify(); saveSite('audit_verify', json_encode(['at' => date('Y-m-d H:i:s')] + $a)); if (!$a['ok']) secEvent('critical', 'audit_chain', 'Denetim günlüğü zinciri #' . $a['broken_at'] . ' numaralı kayıtta kırık. Kayıtlar silinmiş ya da değiştirilmiş olabilir.', null, 'audit' . $a['broken_at'], 24); } catch (Throwable $e) { nbReport($e); }
        try { runExposureScan(); } catch (Throwable $e) { nbReport($e); }
    }
}
