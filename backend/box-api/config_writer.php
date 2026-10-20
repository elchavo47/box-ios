<?php

declare(strict_types=1);

/**
 * api/config.php dosyasını güvenli şekilde (atomik, var_export ile kaçışlanmış) yazar.
 * Kurulum sihirbazı ve admin ayarlar sayfası kullanır.
 */
function box_write_config(array $c): void
{
    $str = static fn (string $key): string => var_export((string) ($c[$key] ?? ''), true);
    $int = static fn (string $key, int $default): string => (string) max(1, (int) ($c[$key] ?? $default));

    $php = "<?php\n"
        . "/*\n * Box ayarları. Kurulum sihirbazı / admin paneli tarafından oluşturuldu.\n"
        . " * Elle düzenleyeceksen dosyanın ilk satırı <?php olmalı, öncesinde boşluk olmamalı.\n */\n\n"
        . "declare(strict_types=1);\n\n"
        . "const DB_HOST = " . $str('DB_HOST') . ";\n"
        . "const DB_NAME = " . $str('DB_NAME') . ";\n"
        . "const DB_USER = " . $str('DB_USER') . ";\n"
        . "const DB_PASS = " . $str('DB_PASS') . ";\n\n"
        . "const YT_DATA_API_KEY = " . $str('YT_DATA_API_KEY') . ";\n\n"
        . "const VDS_BASE_URL = " . $str('VDS_BASE_URL') . ";\n"
        . "const VDS_SIGNING_KEY = " . $str('VDS_SIGNING_KEY') . ";\n"
        . "const DOWNLOAD_LINK_TTL = " . $int('DOWNLOAD_LINK_TTL', 300) . ";\n\n"
        . "const TOKEN_TTL_DAYS = " . $int('TOKEN_TTL_DAYS', 180) . ";\n\n"
        . "const CACHE_DIR = __DIR__ . '/cache';\n"
        . "const CACHE_TIME = " . $int('CACHE_TIME', 3600) . ";\n";

    $target = __DIR__ . '/config.php';
    $temp = __DIR__ . '/.config.' . bin2hex(random_bytes(6)) . '.tmp';

    if (@file_put_contents($temp, $php, LOCK_EX) === false) {
        throw new RuntimeException('config.php yazılamadı. api klasörünün yazma iznini kontrol et.');
    }

    @chmod($temp, 0640);

    if (!@rename($temp, $target)) {
        @unlink($temp);
        throw new RuntimeException('config.php güncellenemedi.');
    }

    if (function_exists('opcache_invalidate')) {
        @opcache_invalidate($target, true);
    }
}

/** Mevcut config sabitlerini dizi olarak döndürür. */
function box_current_config(): array
{
    $keys = ['DB_HOST', 'DB_NAME', 'DB_USER', 'DB_PASS', 'YT_DATA_API_KEY', 'VDS_BASE_URL', 'VDS_SIGNING_KEY', 'DOWNLOAD_LINK_TTL', 'TOKEN_TTL_DAYS', 'CACHE_TIME'];
    $out = [];
    foreach ($keys as $key) {
        $out[$key] = defined($key) ? constant($key) : '';
    }
    return $out;
}
