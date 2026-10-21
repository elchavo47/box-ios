<?php
declare(strict_types=1);

/*
 * Uygulama içi satın alma (App Store, StoreKit 2).
 *
 * Satın almanın neyi açacağı panelden seçilir (Uygulama > "App Store satın alımı", app_config.store_unlocks):
 *   'browser' → yalnızca BOX_STORE_FEATURES (tarayıcıdan indirme). YouTube özellikleri panelden
 *               kullanıcı bazında elle açılır (users.premium_on). Varsayılan budur.
 *   'all'     → bütün premium özellikleri (panelden verilen premium gibi).
 * Her iki durumda da kullanıcı bazında kapatılan özellikler (users.premium_off) kapalı kalır.
 *
 * Doğrulama: Apple'ın imzaladığı JWS. x5c zincirinin her halkası bir sonrakince imzalanmış,
 * tarihleri geçerli ve kök sertifika Apple Root CA - G3 olmalı; imza zincirin ilk sertifikasıyla
 * (ES256) doğrulanır.
 */

const BOX_APPLE_ROOT_G3_SHA256 = '63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179';
const BOX_BUNDLE_ID = 'com.aydworks.box';
const BOX_STORE_PRODUCTS = [
    'com.aydworks.box.premium.monthly' => ['Aylık', 'subscription'],
    'com.aydworks.box.premium.yearly' => ['Yıllık', 'subscription'],
    'com.aydworks.box.premium.lifetime' => ['Ömür boyu', 'lifetime'],
];
/** Satın almayla gelen özellikler (YouTube özellikleri burada yok). */
const BOX_STORE_FEATURES = ['browser', 'eq', 'vault'];
/** Panelde seçilebilen satın alma kapsamları. */
const BOX_STORE_UNLOCKS = [
    'browser' => 'Yalnızca tarayıcıdan indirme',
    'all' => 'Bütün premium özellikleri',
];

/** Paneldeki ayar: satın alma neyi açıyor ('browser' ya da 'all'). */
function boxStoreUnlocks(): string {
    $mode = (string)configValue('store_unlocks', 'browser');
    return isset(BOX_STORE_UNLOCKS[$mode]) ? $mode : 'browser';
}

/** Satın alan kullanıcıya gelen özellikler (ayara göre). */
function boxStoreFeatures(): array {
    return boxStoreUnlocks() === 'all' ? array_keys(BOX_PREMIUM_FEATURES) : BOX_STORE_FEATURES;
}

function boxB64Url(string $value): string|false {
    $value = strtr($value, '-_', '+/');
    return base64_decode($value . str_repeat('=', (4 - strlen($value) % 4) % 4), true);
}

/** ES256 imzası (R||S, 64 bayt) → OpenSSL'in beklediği DER. */
function boxEcdsaRawToDer(string $raw): string {
    if (strlen($raw) !== 64) throw new RuntimeException('İmza biçimi geçersiz.');
    $int = function (string $b): string {
        $b = ltrim($b, "\x00");
        if ($b === '' || (ord($b[0]) & 0x80)) $b = "\x00" . $b;
        return "\x02" . chr(strlen($b)) . $b;
    };
    $seq = $int(substr($raw, 0, 32)) . $int(substr($raw, 32));
    return "\x30" . chr(strlen($seq)) . $seq;
}

/** Apple JWS'ini doğrular, yükü (payload) dizi olarak döner. */
function boxVerifyAppleJws(string $jws): array {
    $parts = explode('.', trim($jws));
    if (count($parts) !== 3) throw new RuntimeException('Satın alma bilgisi okunamadı.');
    [$h64, $p64, $s64] = $parts;
    $header = json_decode((string)boxB64Url($h64), true);
    if (!is_array($header) || ($header['alg'] ?? '') !== 'ES256' || empty($header['x5c']) || !is_array($header['x5c'])) {
        throw new RuntimeException('Satın alma bilgisi okunamadı.');
    }
    $certs = [];
    foreach ($header['x5c'] as $der64) {
        $pem = "-----BEGIN CERTIFICATE-----\n" . chunk_split((string)$der64, 64, "\n") . "-----END CERTIFICATE-----\n";
        $cert = openssl_x509_read($pem);
        if ($cert === false) throw new RuntimeException('Satın alma sertifikası okunamadı.');
        $certs[] = $cert;
    }
    if (count($certs) < 2) throw new RuntimeException('Satın alma sertifika zinciri eksik.');
    $now = time();
    foreach ($certs as $cert) {
        $info = openssl_x509_parse($cert);
        if (!$info || $now < (int)$info['validFrom_time_t'] || $now > (int)$info['validTo_time_t']) {
            throw new RuntimeException('Satın alma sertifikasının süresi geçersiz.');
        }
    }
    for ($i = 0; $i < count($certs) - 1; $i++) {
        $issuerKey = openssl_pkey_get_public($certs[$i + 1]);
        if ($issuerKey === false || openssl_x509_verify($certs[$i], $issuerKey) !== 1) {
            throw new RuntimeException('Satın alma sertifika zinciri doğrulanamadı.');
        }
    }
    $rootFingerprint = strtolower((string)openssl_x509_fingerprint($certs[count($certs) - 1], 'sha256'));
    if (!hash_equals(BOX_APPLE_ROOT_G3_SHA256, $rootFingerprint)) {
        throw new RuntimeException('Satın alma Apple tarafından imzalanmamış.');
    }
    $signature = boxB64Url($s64);
    $leafKey = openssl_pkey_get_public($certs[0]);
    if ($signature === false || $leafKey === false || openssl_verify($h64 . '.' . $p64, boxEcdsaRawToDer($signature), $leafKey, OPENSSL_ALGO_SHA256) !== 1) {
        throw new RuntimeException('Satın alma imzası doğrulanamadı.');
    }
    $payload = json_decode((string)boxB64Url($p64), true);
    if (!is_array($payload)) throw new RuntimeException('Satın alma bilgisi okunamadı.');
    return $payload;
}

/** Satın alma hesabın kimliğine bağlansın diye StoreKit'e verilen UUID (appAccountToken). */
function boxStoreToken(array $u): string {
    $existing = (string)($u['store_token'] ?? '');
    if (preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/', $existing)) return $existing;
    $b = random_bytes(16);
    $b[6] = chr((ord($b[6]) & 0x0f) | 0x40);
    $b[8] = chr((ord($b[8]) & 0x3f) | 0x80);
    $token = vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($b), 4));
    q('UPDATE users SET store_token=? WHERE id=? AND (store_token IS NULL OR store_token=\'\')', [$token, (int)$u['id']]);
    return (string)(q('SELECT store_token FROM users WHERE id=?', [(int)$u['id']])->fetchColumn() ?: $token);
}

function boxMsDate(mixed $ms): ?string {
    return is_numeric($ms) && (int)$ms > 0 ? date('Y-m-d H:i:s', intdiv((int)$ms, 1000)) : null;
}

/**
 * Doğrulanmış bir işlemi kaydeder. $userId null ise (bildirim) işlem daha önce bağlandığı hesaba uygulanır.
 * Döner: ['user_id', 'status' => new|renew|revoke|same, 'row'].
 */
function boxApplyStoreTransaction(array $tx, ?int $userId, ?string $expectToken = null): array {
    if (($tx['bundleId'] ?? '') !== BOX_BUNDLE_ID) throw new RuntimeException('Bu satın alma Box\'a ait değil.');
    $product = (string)($tx['productId'] ?? '');
    if (!isset(BOX_STORE_PRODUCTS[$product])) throw new RuntimeException('Bilinmeyen ürün.', 1);
    $original = preg_replace('/[^0-9A-Za-z]/', '', (string)($tx['originalTransactionId'] ?? ''));
    $current = preg_replace('/[^0-9A-Za-z]/', '', (string)($tx['transactionId'] ?? ''));
    if ($original === '' || $current === '') throw new RuntimeException('Satın alma bilgisi eksik.');
    if ($expectToken !== null && !empty($tx['appAccountToken']) && strtolower((string)$tx['appAccountToken']) !== strtolower($expectToken)) {
        throw new RuntimeException('Bu satın alma başka bir Box hesabına ait.', 1);
    }
    $existing = q('SELECT * FROM store_purchases WHERE original_tx=?', [$original])->fetch() ?: null;
    if ($existing && $userId !== null && (int)$existing['user_id'] !== $userId) {
        throw new RuntimeException('Bu satın alma başka bir Box hesabına ait.', 1);
    }
    $owner = $existing ? (int)$existing['user_id'] : $userId;
    if ($owner === null) throw new RuntimeException('Satın almanın hesabı bulunamadı.');

    $env = ($tx['environment'] ?? 'Production') === 'Sandbox' ? 'sandbox' : 'production';
    $expires = BOX_STORE_PRODUCTS[$product][1] === 'lifetime' ? null : boxMsDate($tx['expiresDate'] ?? null);
    $revoked = boxMsDate($tx['revocationDate'] ?? null);
    $purchased = boxMsDate($tx['originalPurchaseDate'] ?? ($tx['purchaseDate'] ?? null)) ?? date('Y-m-d H:i:s');

    if (!$existing) {
        q('INSERT INTO store_purchases(user_id,original_tx,last_tx,product_id,environment,purchased_at,expires_at,revoked_at,updated_at) VALUES(?,?,?,?,?,?,?,?,NOW())',
            [$owner, $original, $current, $product, $env, $purchased, $expires, $revoked]);
        $status = $revoked ? 'revoke' : 'new';
    } else {
        // Eski bir işlem yenisinin üstüne yazmasın: bitiş tarihi yalnızca ileri gider (iade hariç).
        $newer = $expires === null || $existing['expires_at'] === null || strtotime($expires) >= strtotime((string)$existing['expires_at']);
        if ($revoked) {
            q('UPDATE store_purchases SET revoked_at=?, last_tx=?, updated_at=NOW() WHERE id=?', [$revoked, $current, (int)$existing['id']]);
            $status = $existing['revoked_at'] ? 'same' : 'revoke';
        } elseif ($newer) {
            q('UPDATE store_purchases SET last_tx=?, product_id=?, expires_at=?, revoked_at=NULL, environment=?, updated_at=NOW() WHERE id=?', [$current, $product, $expires, $env, (int)$existing['id']]);
            $status = $existing['last_tx'] === $current ? 'same' : 'renew';
        } else {
            $status = 'same';
        }
    }
    $row = q('SELECT * FROM store_purchases WHERE original_tx=?', [$original])->fetch();
    return ['user_id' => $owner, 'status' => $status, 'row' => $row];
}

/** Kullanıcının etkin mağaza satın alımı (yoksa null). */
function boxStoreEntitlement(array $u): ?array {
    static $cache = [];
    $id = (int)$u['id'];
    if (!array_key_exists($id, $cache)) {
        try {
            $cache[$id] = q('SELECT * FROM store_purchases WHERE user_id=? AND revoked_at IS NULL AND (expires_at IS NULL OR expires_at>NOW()) ORDER BY (expires_at IS NULL) DESC, expires_at DESC LIMIT 1', [$id])->fetch() ?: null;
        } catch (Throwable $e) {
            $cache[$id] = null; // tablo henüz yoksa
        }
    }
    return $cache[$id];
}

function boxStoreActive(array $u): bool { return boxStoreEntitlement($u) !== null; }

function boxStorePurchases(int $userId): array {
    try { return q('SELECT * FROM store_purchases WHERE user_id=? ORDER BY updated_at DESC', [$userId])->fetchAll(); }
    catch (Throwable $e) { return []; }
}

function boxStoreProductName(string $id): string { return BOX_STORE_PRODUCTS[$id][0] ?? $id; }

/** Telegram ve kayıt için kısa açıklama. */
function boxStoreAlert(int $userId, string $status, array $row): void {
    $u = boxFindUser($userId);
    $who = $u ? $u['display_name'] . ' (' . $u['email'] . ')' : '#' . $userId;
    $env = $row['environment'] === 'sandbox' ? ' · test (sandbox)' : '';
    $product = boxStoreProductName((string)$row['product_id']);
    $until = $row['expires_at'] ? "\nBitiş: " . date('d.m.Y H:i', strtotime((string)$row['expires_at'])) : "\nSüre: ömür boyu";
    $text = match ($status) {
        'new' => "💳 Yeni satın alma: {$who}\nPaket: {$product}{$env}{$until}",
        'renew' => "🔁 Abonelik yenilendi: {$who}\nPaket: {$product}{$env}{$until}",
        'revoke' => "↩️ İade / iptal: {$who}\nPaket: {$product}{$env}",
        'expired' => "⌛ Abonelik bitti: {$who}\nPaket: {$product}{$env}",
        default => '',
    };
    if ($text !== '') staffAlert('store', $text);
}

/** App Store Server Notifications V2. */
function boxHandleStoreNotification(string $signedPayload): array {
    $note = boxVerifyAppleJws($signedPayload);
    $type = (string)($note['notificationType'] ?? '');
    $subtype = (string)($note['subtype'] ?? '');
    $data = is_array($note['data'] ?? null) ? $note['data'] : [];
    if ($type === 'TEST') return ['type' => $type];
    if (($data['bundleId'] ?? BOX_BUNDLE_ID) !== BOX_BUNDLE_ID) throw new RuntimeException('Bu bildirim Box\'a ait değil.');
    if (empty($data['signedTransactionInfo'])) return ['type' => $type, 'subtype' => $subtype];
    $tx = boxVerifyAppleJws((string)$data['signedTransactionInfo']);
    $original = preg_replace('/[^0-9A-Za-z]/', '', (string)($tx['originalTransactionId'] ?? ''));
    $known = q('SELECT user_id FROM store_purchases WHERE original_tx=?', [$original])->fetchColumn();
    if ($known === false) {
        // Uygulama henüz sunucuya bildirmediyse, StoreKit'e verdiğimiz kimlikten hesabı bul.
        $token = strtolower((string)($tx['appAccountToken'] ?? ''));
        $known = $token !== '' ? q('SELECT id FROM users WHERE store_token=?', [$token])->fetchColumn() : false;
        if ($known === false) return ['type' => $type, 'subtype' => $subtype, 'skipped' => 'unknown account'];
    }
    $result = boxApplyStoreTransaction($tx, (int)$known);
    $status = $result['status'];
    if ($type === 'EXPIRED') $status = 'expired';
    if (in_array($type, ['REFUND', 'REVOKE'], true)) $status = 'revoke';
    if ($status !== 'same') boxStoreAlert((int)$result['user_id'], $status, $result['row']);
    return ['type' => $type, 'subtype' => $subtype, 'status' => $status];
}
