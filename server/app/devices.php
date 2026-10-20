<?php
if (!defined('ROOT')) { http_response_code(404); exit; }

/*
 * Oturum açılan cihazlar. Uygulama 3.0+ her istekte cihaz bilgisini başlıklarla gönderir:
 *   X-Box-Device-ID  cihaza özel sabit kimlik (uygulama silinince değişir)
 *   X-Box-Device     model kodu (iPhone17,1)
 *   X-Box-OS         "iOS 26.0"
 *   X-Box-Version    "3.0 (31)"
 * Eski sürümler yalnızca User-Agent gönderir ("Box/25 CFNetwork/… Darwin/…").
 */

function boxClientDevice(): array {
    $clean = fn(string $key, int $max, string $pattern = '/[^0-9A-Za-z.,() _-]/'): string => mb_substr(preg_replace($pattern, '', (string)($_SERVER[$key] ?? '')), 0, $max);
    $id = strtolower($clean('HTTP_X_BOX_DEVICE_ID', 64, '/[^0-9A-Fa-f-]/'));
    return [
        'device_id' => strlen($id) >= 16 ? $id : null,
        'model' => $clean('HTTP_X_BOX_DEVICE', 40) ?: null,
        'os' => $clean('HTTP_X_BOX_OS', 30) ?: null,
        'app' => ($v = $clean('HTTP_X_BOX_VERSION', 12)) !== '' ? $v . (($b = $clean('HTTP_X_BOX_BUILD', 6, '/[^0-9]/')) !== '' ? " ($b)" : '') : null,
        'ua' => mb_substr((string)($_SERVER['HTTP_USER_AGENT'] ?? ''), 0, 120),
    ];
}

/** Apple model kodu → satıştaki adı. */
function boxModelName(?string $code): ?string {
    if (!$code) return null;
    static $map = [
        'iPhone10,1' => 'iPhone 8', 'iPhone10,4' => 'iPhone 8', 'iPhone10,2' => 'iPhone 8 Plus', 'iPhone10,5' => 'iPhone 8 Plus',
        'iPhone10,3' => 'iPhone X', 'iPhone10,6' => 'iPhone X', 'iPhone11,2' => 'iPhone XS', 'iPhone11,4' => 'iPhone XS Max', 'iPhone11,6' => 'iPhone XS Max',
        'iPhone11,8' => 'iPhone XR', 'iPhone12,1' => 'iPhone 11', 'iPhone12,3' => 'iPhone 11 Pro', 'iPhone12,5' => 'iPhone 11 Pro Max',
        'iPhone12,8' => 'iPhone SE (2. nesil)', 'iPhone13,1' => 'iPhone 12 mini', 'iPhone13,2' => 'iPhone 12', 'iPhone13,3' => 'iPhone 12 Pro',
        'iPhone13,4' => 'iPhone 12 Pro Max', 'iPhone14,4' => 'iPhone 13 mini', 'iPhone14,5' => 'iPhone 13', 'iPhone14,2' => 'iPhone 13 Pro',
        'iPhone14,3' => 'iPhone 13 Pro Max', 'iPhone14,6' => 'iPhone SE (3. nesil)', 'iPhone14,7' => 'iPhone 14', 'iPhone14,8' => 'iPhone 14 Plus',
        'iPhone15,2' => 'iPhone 14 Pro', 'iPhone15,3' => 'iPhone 14 Pro Max', 'iPhone15,4' => 'iPhone 15', 'iPhone15,5' => 'iPhone 15 Plus',
        'iPhone16,1' => 'iPhone 15 Pro', 'iPhone16,2' => 'iPhone 15 Pro Max', 'iPhone17,3' => 'iPhone 16', 'iPhone17,4' => 'iPhone 16 Plus',
        'iPhone17,1' => 'iPhone 16 Pro', 'iPhone17,2' => 'iPhone 16 Pro Max', 'iPhone17,5' => 'iPhone 16e',
        'iPhone18,1' => 'iPhone 17 Pro', 'iPhone18,2' => 'iPhone 17 Pro Max', 'iPhone18,3' => 'iPhone 17', 'iPhone18,4' => 'iPhone Air',
        'arm64' => 'Simülatör', 'x86_64' => 'Simülatör',
    ];
    if (isset($map[$code])) return $map[$code];
    if (str_starts_with($code, 'iPad')) return 'iPad';
    if (str_starts_with($code, 'iPhone')) return 'iPhone (' . $code . ')';
    return $code;
}

/** Cihaz satırını okunur hale getirir (panel ve uygulama için). */
function boxDeviceRow(array $t): array {
    $name = boxModelName($t['model'] ?? null);
    $os = $t['os'] ?? null;
    $app = $t['app_version'] ?? null;
    if (!$name) {
        // Eski sürüm: "Box/25 CFNetwork/3896.100.1.2.1 Darwin/27.0.0"
        $ua = (string)($t['device'] ?? '');
        $name = str_contains($ua, 'iPad') ? 'iPad' : 'iPhone';
        if (!$app && preg_match('#^Box/(\d+)#', $ua, $m)) $app = 'derleme ' . $m[1];
    }
    return [
        'id' => (int)$t['id'],
        'name' => $name,
        'os' => $os,
        'app' => $app,
        'created_at' => $t['created_at'],
        'last_used_at' => $t['last_used_at'] ?? $t['created_at'],
        'legacy' => empty($t['model']),
    ];
}

/** Yeni oturum. Aynı cihazdan tekrar giriş yapılınca o cihazın eski oturumu kapanır (tek satır kalır). */
function boxIssueToken(int $userId, string $device = ''): string {
    $info = boxClientDevice();
    $token = bin2hex(random_bytes(32));
    $days = max(1, (int)site('token_ttl_days', '180'));
    if ($info['device_id']) q('DELETE FROM tokens WHERE user_id=? AND device_id=?', [$userId, $info['device_id']]);
    q('INSERT INTO tokens(user_id,token_hash,device,device_id,model,os,app_version,last_used_at,expires_at) VALUES(?,?,?,?,?,?,?,NOW(),DATE_ADD(NOW(),INTERVAL ? DAY))',
        [$userId, hash('sha256', $token), $device !== '' ? mb_substr($device, 0, 120) : ($info['ua'] ?: null), $info['device_id'], $info['model'], $info['os'], $info['app'], $days]);
    return $token;
}

/** Her istekte (10 dakikada bir) cihaz bilgisini güncelle: uygulama güncellenince sürüm de güncellenir. */
function boxTouchDevice(int $tokenId): void {
    $info = boxClientDevice();
    if (!$info['model'] && !$info['app']) return;
    q('UPDATE tokens SET device_id=COALESCE(?,device_id), model=COALESCE(?,model), os=COALESCE(?,os), app_version=COALESCE(?,app_version) WHERE id=?', [$info['device_id'], $info['model'], $info['os'], $info['app'], $tokenId]);
}

/** Bir cihazın oturumunu kapat; o cihazın bildirim kaydı da silinir. */
function boxLogoutDevice(int $userId, int $tokenId): bool {
    $row = q('SELECT device_id FROM tokens WHERE id=? AND user_id=?', [$tokenId, $userId])->fetch();
    if (!$row) return false;
    q('DELETE FROM tokens WHERE id=? AND user_id=?', [$tokenId, $userId]);
    if (!empty($row['device_id'])) q('DELETE FROM push_devices WHERE user_id=? AND device_id=?', [$userId, $row['device_id']]);
    return true;
}

function boxUserDevices(int $userId): array {
    return array_map('boxDeviceRow', q('SELECT id,device,device_id,model,os,app_version,created_at,last_used_at FROM tokens WHERE user_id=? AND expires_at>NOW() ORDER BY COALESCE(last_used_at,created_at) DESC', [$userId])->fetchAll());
}
