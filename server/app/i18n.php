<?php
if (!defined('ROOT')) { http_response_code(404); exit; }

/*
 * Sunucu metinlerinin çevirisi (uygulama 3.0+). Kaynak dil Türkçe; anahtar metnin kendisidir.
 * Uygulama her istekte X-Box-Lang başlığıyla dilini gönderir. Panel (tarayıcı) her zaman Türkçedir.
 * Çeviriler app/i18n/<kod>.json; {0}, {1} yer tutucuları.
 */

const BOX_LANGS = ['tr', 'en', 'de', 'fr', 'es', 'it', 'pt-BR', 'nl', 'ru', 'uk', 'pl', 'az', 'ar', 'fa', 'hi', 'id', 'ja', 'ko', 'zh-Hans', 'zh-Hant', 'sv', 'el', 'ro', 'cs', 'hu', 'vi', 'th'];

function boxLangMatch(?string $raw): ?string {
    $raw = strtolower(str_replace('_', '-', trim((string)$raw)));
    if ($raw === '') return null;
    if (str_starts_with($raw, 'zh')) return (str_contains($raw, 'hant') || preg_match('/-(tw|hk|mo)$/', $raw)) ? 'zh-Hant' : 'zh-Hans';
    if (str_starts_with($raw, 'pt')) return 'pt-BR';
    $base = explode('-', $raw)[0];
    return in_array($base, BOX_LANGS, true) ? $base : null;
}

/** Bu isteğin dili: yalnızca uygulamadan gelen X-Box-Lang (panel Türkçe kalsın). */
function boxLang(): string {
    static $lang = null;
    if ($lang === null) $lang = boxLangMatch($_SERVER['HTTP_X_BOX_LANG'] ?? null) ?? 'tr';
    return $lang;
}

/** YouTube Music arayüz dili (ruh hali başlıkları için); desteklemediği dillerde İngilizce. */
function boxYtmLang(string $lang): string {
    return match ($lang) {
        'tr', 'en', 'de', 'fr', 'es', 'it', 'nl', 'ru', 'ar', 'hi', 'ja', 'ko', 'cs' => $lang,
        'pt-BR' => 'pt', 'zh-Hans' => 'zh_CN', 'zh-Hant' => 'zh_TW',
        default => 'en',
    };
}

function boxI18nTable(string $lang): array {
    static $tables = [];
    if (!isset($tables[$lang])) {
        $file = ROOT . '/app/i18n/' . $lang . '.json';
        $data = is_file($file) ? json_decode((string)file_get_contents($file), true) : null;
        $tables[$lang] = is_array($data) ? $data : [];
    }
    return $tables[$lang];
}

/** Türkçe metni verilen dile (yoksa isteğin diline) çevirir. */
function __t(string $key, array $args = [], ?string $lang = null): string {
    $lang ??= boxLang();
    $text = $key;
    if ($lang !== 'tr') {
        $entry = boxI18nTable($lang)[$key] ?? null;
        if (is_string($entry) && $entry !== '') $text = $entry;
        elseif (is_array($entry)) {
            $n = 0;
            foreach ($args as $a) if (is_int($a) || is_float($a)) { $n = $a; break; }
            $text = $entry[boxPluralCategory($n, $lang)] ?? $entry['other'] ?? $key;
        }
    }
    foreach (array_values($args) as $i => $a) $text = str_replace('{' . $i . '}', (string)$a, $text);
    return $text;
}

function boxPluralCategory(float $n, string $lang): string {
    $i = (int)abs($n);
    $base = explode('-', $lang)[0];
    switch ($base) {
        case 'ja': case 'ko': case 'zh': case 'vi': case 'th': case 'id': return 'other';
        case 'fr': case 'pt': case 'hi': case 'fa': return $i <= 1 ? 'one' : 'other';
        case 'ru': case 'uk':
            if ($i % 10 === 1 && $i % 100 !== 11) return 'one';
            if ($i % 10 >= 2 && $i % 10 <= 4 && ($i % 100 < 12 || $i % 100 > 14)) return 'few';
            return 'many';
        case 'pl':
            if ($i === 1) return 'one';
            if ($i % 10 >= 2 && $i % 10 <= 4 && ($i % 100 < 12 || $i % 100 > 14)) return 'few';
            return 'many';
        case 'cs': return $i === 1 ? 'one' : ($i >= 2 && $i <= 4 ? 'few' : 'other');
        case 'ro': return $i === 1 ? 'one' : (($i === 0 || ($i % 100 >= 1 && $i % 100 <= 19)) ? 'few' : 'other');
        case 'ar':
            if ($i === 0) return 'zero';
            if ($i === 1) return 'one';
            if ($i === 2) return 'two';
            if ($i % 100 >= 3 && $i % 100 <= 10) return 'few';
            if ($i % 100 >= 11) return 'many';
            return 'other';
        default: return $i === 1 ? 'one' : 'other';
    }
}

/** Kullanıcının son kullandığı dil (bildirimler bu dilde gider). */
function boxUserLang(int $userId): string {
    try { return boxLangMatch((string)q('SELECT lang FROM users WHERE id=?', [$userId])->fetchColumn()) ?? 'tr'; }
    catch (Throwable $e) { return 'tr'; }
}

/** Tarihi kullanıcının dilinde kısa yazar (ör. 21 Eki 2026 / Oct 21, 2026). */
function boxLocalDate(string $datetime, string $lang): string {
    $ts = strtotime($datetime) ?: time();
    if (class_exists('IntlDateFormatter')) {
        $locale = match ($lang) { 'zh-Hans' => 'zh_CN', 'zh-Hant' => 'zh_TW', 'pt-BR' => 'pt_BR', default => $lang };
        $f = new IntlDateFormatter($locale, IntlDateFormatter::MEDIUM, IntlDateFormatter::NONE);
        $out = $f->format($ts);
        if (is_string($out) && $out !== '') return $out;
    }
    return date('d.m.Y', $ts);
}
