<?php
if (!defined('ROOT')) { http_response_code(404); exit; }

/*
 * Apple ile giriş ve bildirimler (APNs).
 *
 * Ayarlar panelde Servisler > Apple bölümünden girilir: Team ID, Key ID ve .p8 anahtarı.
 * .p8 şifreli saklanır. Apple ile girişin doğrulanması için anahtar gerekmez (Apple'ın
 * açık anahtarlarıyla yapılır); anahtar hesap silinirken Apple bağlantısını iptal etmek
 * ve bildirim göndermek için gerekir.
 */

const BOX_BUNDLE_ID = 'com.aydworks.box';

function boxAppleConfig(): array {
    return [
        'team' => site('apple_team_id'),
        'key' => site('apple_key_id'),
        'p8' => secretSetting('apple_p8'),
        'bundle' => BOX_BUNDLE_ID,
    ];
}

function boxAppleConfigured(): bool {
    $c = boxAppleConfig();
    return $c['team'] !== '' && $c['key'] !== '' && $c['p8'] !== '';
}

/* ---------------- Ortak: ES256 imzalı JWT ---------------- */

/** openssl_sign'ın verdiği DER imzayı JWT'nin istediği 64 baytlık r||s biçimine çevirir. */
function boxDerToJose(string $der): string {
    $pos = 2;
    if ((ord($der[1]) & 0x80) !== 0) $pos += ord($der[1]) & 0x7f;
    $read = function () use ($der, &$pos): string {
        $pos++; // 0x02
        $len = ord($der[$pos++]);
        $v = substr($der, $pos, $len);
        $pos += $len;
        return str_pad(ltrim($v, "\x00"), 32, "\x00", STR_PAD_LEFT);
    };
    return $read() . $read();
}

function boxEs256(array $header, array $claims, string $pem): string {
    $input = b64url(json_encode($header)) . '.' . b64url(json_encode($claims));
    $key = openssl_pkey_get_private($pem);
    if ($key === false) throw new RuntimeException('Apple anahtarı (.p8) okunamadı.');
    if (!openssl_sign($input, $der, $key, OPENSSL_ALGO_SHA256)) throw new RuntimeException('Apple anahtarıyla imzalanamadı.');
    return $input . '.' . b64url(boxDerToJose($der));
}

function boxAppleHttp(string $url, ?array $form = null, array $headers = []): array {
    $ch = curl_init($url);
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 15, CURLOPT_CONNECTTIMEOUT => 6, CURLOPT_HTTPHEADER => $headers]);
    if ($form !== null) { curl_setopt($ch, CURLOPT_POST, true); curl_setopt($ch, CURLOPT_POSTFIELDS, http_build_query($form)); }
    $body = curl_exec($ch);
    $status = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $err = curl_error($ch);
    curl_close($ch);
    if ($body === false) throw new RuntimeException('Apple sunucusuna ulaşılamadı: ' . $err);
    return [$status, (string)$body];
}

/* ---------------- Apple ile giriş ---------------- */

/** Apple'ın kimlik doğrulama açık anahtarları (6 saat önbellekli). */
function boxAppleKeys(bool $refresh = false): array {
    $cached = json_decode(site('apple_jwks'), true);
    if (!$refresh && is_array($cached) && ($cached['at'] ?? 0) > time() - 21600 && !empty($cached['keys'])) return $cached['keys'];
    [$status, $body] = boxAppleHttp('https://appleid.apple.com/auth/keys');
    $data = json_decode($body, true);
    if ($status !== 200 || empty($data['keys'])) {
        if (is_array($cached) && !empty($cached['keys'])) return $cached['keys'];
        throw new RuntimeException('Apple anahtarları alınamadı.');
    }
    saveSite('apple_jwks', json_encode(['at' => time(), 'keys' => $data['keys']]));
    return $data['keys'];
}

/** JWK (n, e) → PEM açık anahtar. */
function boxJwkToPem(array $jwk): string {
    $n = b64urlDecode((string)$jwk['n']);
    $e = b64urlDecode((string)$jwk['e']);
    if ($n === false || $e === false) throw new RuntimeException('Apple anahtarı bozuk.');
    $int = function (string $v): string {
        if (ord($v[0]) > 0x7f) $v = "\x00" . $v;
        return "\x02" . boxDerLen(strlen($v)) . $v;
    };
    $rsa = "\x30" . boxDerLen(strlen($int($n) . $int($e))) . $int($n) . $int($e);
    $bit = "\x03" . boxDerLen(strlen($rsa) + 1) . "\x00" . $rsa;
    $alg = "\x30\x0d\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01\x05\x00";
    $spki = "\x30" . boxDerLen(strlen($alg . $bit)) . $alg . $bit;
    return "-----BEGIN PUBLIC KEY-----\n" . chunk_split(base64_encode($spki), 64, "\n") . "-----END PUBLIC KEY-----\n";
}

function boxDerLen(int $len): string {
    if ($len < 0x80) return chr($len);
    $bytes = ltrim(pack('N', $len), "\x00");
    return chr(0x80 | strlen($bytes)) . $bytes;
}

/**
 * Uygulamanın gönderdiği Apple kimlik belirtecini doğrular.
 * $rawNonce: uygulamanın ürettiği rastgele değer; belirteçte SHA-256'sı bulunmalı (tekrar kullanıma karşı).
 * Dönüş: ['sub' => ..., 'email' => ?string, 'email_verified' => bool, 'private_email' => bool]
 */
function boxVerifyAppleToken(string $jwt, string $rawNonce): array {
    $parts = explode('.', $jwt);
    if (count($parts) !== 3) throw new RuntimeException('Apple girişi okunamadı.');
    $header = json_decode((string)b64urlDecode($parts[0]), true);
    $claims = json_decode((string)b64urlDecode($parts[1]), true);
    $sig = b64urlDecode($parts[2]);
    if (!is_array($header) || !is_array($claims) || $sig === false || ($header['alg'] ?? '') !== 'RS256') throw new RuntimeException('Apple girişi okunamadı.');

    $find = function (array $keys) use ($header): ?array {
        foreach ($keys as $k) if (($k['kid'] ?? '') === ($header['kid'] ?? null)) return $k;
        return null;
    };
    $jwk = $find(boxAppleKeys()) ?? $find(boxAppleKeys(true));
    if (!$jwk) throw new RuntimeException('Apple girişi doğrulanamadı.');
    if (openssl_verify($parts[0] . '.' . $parts[1], $sig, boxJwkToPem($jwk), OPENSSL_ALGO_SHA256) !== 1) throw new RuntimeException('Apple girişi doğrulanamadı.');

    if (($claims['iss'] ?? '') !== 'https://appleid.apple.com') throw new RuntimeException('Apple girişi geçersiz.');
    $aud = (array)($claims['aud'] ?? []);
    if (!in_array(BOX_BUNDLE_ID, $aud, true)) throw new RuntimeException('Apple girişi bu uygulamaya ait değil.');
    if ((int)($claims['exp'] ?? 0) < time() - 30) throw new RuntimeException('Apple girişinin süresi doldu, tekrar dene.');
    if ($rawNonce === '' || !hash_equals(hash('sha256', $rawNonce), (string)($claims['nonce'] ?? ''))) throw new RuntimeException('Apple girişi doğrulanamadı.');
    $sub = (string)($claims['sub'] ?? '');
    if ($sub === '' || strlen($sub) > 120) throw new RuntimeException('Apple girişi geçersiz.');

    $email = isset($claims['email']) ? mb_strtolower((string)$claims['email']) : null;
    $verified = in_array($claims['email_verified'] ?? false, [true, 'true'], true);
    $private = in_array($claims['is_private_email'] ?? false, [true, 'true'], true);
    return ['sub' => $sub, 'email' => $email && filter_var($email, FILTER_VALIDATE_EMAIL) ? $email : null, 'email_verified' => $verified, 'private_email' => $private];
}

function boxAppleClientSecret(): string {
    $c = boxAppleConfig();
    if (!boxAppleConfigured()) throw new RuntimeException('Apple ayarları girilmemiş.');
    $now = time();
    return boxEs256(['alg' => 'ES256', 'kid' => $c['key']], ['iss' => $c['team'], 'iat' => $now, 'exp' => $now + 3600, 'aud' => 'https://appleid.apple.com', 'sub' => $c['bundle']], $c['p8']);
}

/**
 * Uygulamanın verdiği tek kullanımlık kodu Apple'da yenileme belirtecine çevirir.
 * Hesap silinirken Apple bağlantısını iptal etmek için saklanır. Ayar yoksa sessizce atlanır.
 */
function boxAppleExchangeCode(string $code): ?string {
    if ($code === '' || !boxAppleConfigured()) return null;
    try {
        [$status, $body] = boxAppleHttp('https://appleid.apple.com/auth/token', [
            'client_id' => BOX_BUNDLE_ID, 'client_secret' => boxAppleClientSecret(), 'code' => $code, 'grant_type' => 'authorization_code',
        ]);
        $data = json_decode($body, true);
        if ($status === 200 && !empty($data['refresh_token'])) return (string)$data['refresh_token'];
        error_log('Apple token exchange ' . $status . ': ' . mb_substr($body, 0, 300));
    } catch (Throwable $e) {
        error_log('Apple token exchange: ' . $e->getMessage());
    }
    return null;
}

/** Hesap silinirken Apple bağlantısını iptal eder (App Store kuralı). */
function boxAppleRevoke(array $u): void {
    $refresh = !empty($u['apple_refresh']) ? decryptSecret((string)$u['apple_refresh']) : '';
    if ($refresh === '' || !boxAppleConfigured()) return;
    try {
        [$status, $body] = boxAppleHttp('https://appleid.apple.com/auth/revoke', [
            'client_id' => BOX_BUNDLE_ID, 'client_secret' => boxAppleClientSecret(), 'token' => $refresh, 'token_type_hint' => 'refresh_token',
        ]);
        if ($status !== 200) error_log('Apple revoke ' . $status . ': ' . mb_substr($body, 0, 300));
    } catch (Throwable $e) {
        error_log('Apple revoke: ' . $e->getMessage());
    }
}

/* ---------------- Bildirimler (APNs) ---------------- */

function boxPushSupported(): bool {
    return function_exists('curl_version') && defined('CURL_VERSION_HTTP2') && (curl_version()['features'] & CURL_VERSION_HTTP2) !== 0;
}

/** APNs belirteci (Apple 20-60 dakikada bir yenilenmesini istiyor; 40 dakika saklanır). */
function boxApnsToken(): string {
    $cached = json_decode(site('apns_jwt'), true);
    $c = boxAppleConfig();
    if (is_array($cached) && ($cached['at'] ?? 0) > time() - 2400 && ($cached['kid'] ?? '') === $c['key']) return (string)$cached['jwt'];
    $jwt = boxEs256(['alg' => 'ES256', 'kid' => $c['key']], ['iss' => $c['team'], 'iat' => time()], $c['p8']);
    saveSite('apns_jwt', json_encode(['at' => time(), 'kid' => $c['key'], 'jwt' => $jwt]));
    return $jwt;
}

/**
 * Bildirimi cihazlara gönderir. $devices: push_devices satırları.
 * Geçersiz olan cihaz kayıtları silinir. Dönüş: ['sent' => n, 'failed' => n, 'removed' => n, 'error' => ?string]
 */
function boxPushSend(array $devices, string $title, string $body, array $data = []): array {
    $result = ['sent' => 0, 'failed' => 0, 'removed' => 0, 'error' => null];
    if (!$devices) return $result;
    if (!boxAppleConfigured()) { $result['error'] = 'Apple ayarları girilmemiş.'; $result['failed'] = count($devices); return $result; }
    if (!boxPushSupported()) { $result['error'] = 'Sunucudaki curl HTTP/2 desteklemiyor.'; $result['failed'] = count($devices); return $result; }

    $payload = json_encode(['aps' => ['alert' => ['title' => $title, 'body' => $body], 'sound' => 'default']] + $data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    $jwt = boxApnsToken();
    foreach (array_chunk($devices, 50) as $chunk) {
        $multi = curl_multi_init();
        $handles = [];
        foreach ($chunk as $d) {
            $host = ($d['environment'] ?? 'production') === 'sandbox' ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
            $ch = curl_init("https://$host/3/device/" . $d['token']);
            curl_setopt_array($ch, [
                CURLOPT_HTTP_VERSION => CURL_HTTP_VERSION_2_0, CURLOPT_POST => true, CURLOPT_POSTFIELDS => $payload,
                CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 15, CURLOPT_CONNECTTIMEOUT => 6,
                CURLOPT_HTTPHEADER => ['authorization: bearer ' . $jwt, 'apns-topic: ' . BOX_BUNDLE_ID, 'apns-push-type: alert', 'apns-priority: 10', 'content-type: application/json'],
            ]);
            curl_multi_add_handle($multi, $ch);
            $handles[] = [$ch, $d];
        }
        do { $status = curl_multi_exec($multi, $running); if ($running) curl_multi_select($multi, 1.0); } while ($running && $status === CURLM_OK);
        foreach ($handles as [$ch, $d]) {
            $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
            $reason = (string)(json_decode((string)curl_multi_getcontent($ch), true)['reason'] ?? '');
            if ($code === 200) {
                $result['sent']++;
            } else {
                $result['failed']++;
                if ($code === 410 || in_array($reason, ['BadDeviceToken', 'Unregistered', 'DeviceTokenNotForTopic'], true)) {
                    q('DELETE FROM push_devices WHERE id=?', [(int)$d['id']]);
                    $result['removed']++;
                } elseif ($result['error'] === null) {
                    $result['error'] = $reason !== '' ? $reason : ($code === 0 ? 'Apple sunucusuna ulaşılamadı: ' . curl_error($ch) : 'HTTP ' . $code);
                }
            }
            curl_multi_remove_handle($multi, $ch);
            curl_close($ch);
        }
        curl_multi_close($multi);
    }
    return $result;
}

/** Bir kullanıcının bütün cihazlarına bildirim (premium açıldı vb.). Hata uygulamayı durdurmaz. */
function boxNotifyUser(int $userId, string $title, string $body, array $data = []): array {
    if (function_exists('boxInboxAdd')) boxInboxAdd($userId, 'user:' . $userId, $title, $body, isset($data['box']['open']) ? (string)$data['box']['open'] : null);
    try {
        $devices = q('SELECT * FROM push_devices WHERE user_id=?', [$userId])->fetchAll();
        return boxPushSend($devices, $title, $body, $data);
    } catch (Throwable $e) {
        error_log('push: ' . $e->getMessage());
        return ['sent' => 0, 'failed' => 0, 'removed' => 0, 'error' => $e->getMessage()];
    }
}

/** Kitle seçimi: all, premium, free ya da tek kullanıcı. */
function boxPushAudience(string $target, ?int $userId = null): array {
    $prem = '(u.is_premium=1 AND (u.premium_until IS NULL OR u.premium_until>NOW()))';
    return match ($target) {
        'premium' => q("SELECT d.* FROM push_devices d JOIN users u ON u.id=d.user_id WHERE u.is_banned=0 AND $prem")->fetchAll(),
        'free' => q("SELECT d.* FROM push_devices d JOIN users u ON u.id=d.user_id WHERE u.is_banned=0 AND NOT $prem")->fetchAll(),
        'user' => q('SELECT * FROM push_devices WHERE user_id=?', [(int)$userId])->fetchAll(),
        default => q('SELECT d.* FROM push_devices d JOIN users u ON u.id=d.user_id WHERE u.is_banned=0')->fetchAll(),
    };
}

/** Premium'u 3 gün içinde bitecek olanlara bir kez hatırlatma (cron). */
function boxNotifyExpiringPremiums(): int {
    if (!boxAppleConfigured() || site('push_auto_expiring', '1') !== '1') return 0;
    $rows = q('SELECT id,premium_until FROM users WHERE is_premium=1 AND premium_until BETWEEN NOW() AND DATE_ADD(NOW(),INTERVAL 3 DAY) AND (expiry_notified_for IS NULL OR expiry_notified_for<>premium_until) LIMIT 200')->fetchAll();
    $n = 0;
    foreach ($rows as $r) {
        q('UPDATE users SET expiry_notified_for=premium_until WHERE id=?', [(int)$r['id']]);
        $days = max(1, (int)ceil((strtotime((string)$r['premium_until']) - time()) / 86400));
        $res = boxNotifyUser((int)$r['id'], 'Premium\'un bitmek üzere', "Premium üyeliğin $days gün içinde bitiyor. İndirdiğin şarkılar kitaplığında kalır.", ['box' => ['open' => 'account']]);
        $n += $res['sent'];
    }
    return $n;
}

/** Ayarları denemek için: sahte bir cihaza gönderir. Apple "BadDeviceToken" derse anahtar doğrudur. */
function boxPushSelfTest(): string {
    if (!boxAppleConfigured()) throw new RuntimeException('Önce Team ID, Key ID ve .p8 anahtarını kaydet.');
    if (!boxPushSupported()) throw new RuntimeException('Sunucudaki curl HTTP/2 desteklemiyor; bildirim gönderilemez. Hosting firmasına sor.');
    $ch = curl_init('https://api.push.apple.com/3/device/' . str_repeat('0', 64));
    curl_setopt_array($ch, [
        CURLOPT_HTTP_VERSION => CURL_HTTP_VERSION_2_0, CURLOPT_POST => true, CURLOPT_POSTFIELDS => '{"aps":{"alert":"test"}}',
        CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 15,
        CURLOPT_HTTPHEADER => ['authorization: bearer ' . boxApnsToken(), 'apns-topic: ' . BOX_BUNDLE_ID, 'apns-push-type: alert'],
    ]);
    $body = curl_exec($ch);
    $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $err = curl_error($ch);
    curl_close($ch);
    if ($body === false) throw new RuntimeException('Apple bildirim sunucusuna ulaşılamadı: ' . $err);
    $reason = (string)(json_decode((string)$body, true)['reason'] ?? '');
    if ($reason === 'BadDeviceToken') return 'Apple ayarları doğru: bildirim sunucusu anahtarı kabul etti.';
    if (in_array($reason, ['InvalidProviderToken', 'ExpiredProviderToken'], true)) { saveSite('apns_jwt', ''); throw new RuntimeException('Apple anahtarı reddetti (' . $reason . '). Team ID, Key ID ve .p8 dosyasını kontrol et.'); }
    if ($reason === 'TopicDisallowed') throw new RuntimeException('Bu anahtar com.aydworks.box için bildirim gönderemiyor. Anahtarda APNs açık mı?');
    throw new RuntimeException('Beklenmeyen yanıt: HTTP ' . $code . ($reason !== '' ? ' (' . $reason . ')' : ''));
}
