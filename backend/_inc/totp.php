<?php

declare(strict_types=1);

/* RFC 6238 TOTP (Google Authenticator, Authy, 1Password uyumlu) */

function totp_new_secret(): string
{
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    $secret = '';
    $bytes = random_bytes(20);
    for ($i = 0; $i < 32; $i++) {
        $secret .= $alphabet[ord($bytes[$i % 20]) % 32];
    }
    return $secret;
}

function base32_decode_str(string $input): string
{
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    $input = strtoupper(preg_replace('/[^A-Za-z2-7]/', '', $input) ?? '');
    $bits = '';
    foreach (str_split($input) as $char) {
        $bits .= str_pad(decbin((int) strpos($alphabet, $char)), 5, '0', STR_PAD_LEFT);
    }
    $out = '';
    foreach (str_split($bits, 8) as $byte) {
        if (strlen($byte) === 8) {
            $out .= chr((int) bindec($byte));
        }
    }
    return $out;
}

function totp_code(string $secret, int $step): string
{
    $key = base32_decode_str($secret);
    $hash = hash_hmac('sha1', pack('N*', 0) . pack('N*', $step), $key, true);
    $offset = ord($hash[19]) & 0x0f;
    $value = ((ord($hash[$offset]) & 0x7f) << 24)
        | ((ord($hash[$offset + 1]) & 0xff) << 16)
        | ((ord($hash[$offset + 2]) & 0xff) << 8)
        | (ord($hash[$offset + 3]) & 0xff);

    return str_pad((string) ($value % 1000000), 6, '0', STR_PAD_LEFT);
}

/**
 * Kodu ±1 adım toleransla doğrular. Eşleşen adımı döndürür (tekrar kullanımı engellemek için),
 * eşleşme yoksa null.
 */
function totp_verify(string $secret, string $code, int $lastStep = 0): ?int
{
    $code = preg_replace('/\D/', '', $code) ?? '';
    if (strlen($code) !== 6) {
        return null;
    }

    $now = intdiv(time(), 30);
    for ($i = -1; $i <= 1; $i++) {
        $step = $now + $i;
        if ($step > $lastStep && hash_equals(totp_code($secret, $step), $code)) {
            return $step;
        }
    }
    return null;
}

function totp_uri(string $secret, string $account): string
{
    return 'otpauth://totp/' . rawurlencode('Box Admin:' . $account)
        . '?secret=' . $secret . '&issuer=' . rawurlencode('Box Admin') . '&digits=6&period=30';
}
