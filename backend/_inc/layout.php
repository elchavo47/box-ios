<?php

declare(strict_types=1);

function icon(string $name): string
{
    $paths = [
        'dashboard' => '<rect x="3" y="3" width="7" height="9" rx="2"/><rect x="14" y="3" width="7" height="5" rx="2"/><rect x="14" y="12" width="7" height="9" rx="2"/><rect x="3" y="16" width="7" height="5" rx="2"/>',
        'users' => '<circle cx="9" cy="8" r="4"/><path d="M2 21c0-4 3-6 7-6s7 2 7 6"/><path d="M16 4a4 4 0 0 1 0 8M22 21c0-3-2-5-5-6"/>',
        'download' => '<path d="M12 3v12M7 10l5 5 5-5"/><path d="M4 21h16"/>',
        'shield' => '<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/><path d="M9 12l2 2 4-4"/>',
        'log' => '<path d="M5 4h14v16H5z"/><path d="M9 8h6M9 12h6M9 16h4"/>',
        'settings' => '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>',
        'logout' => '<path d="M15 4h4v16h-4"/><path d="M10 8l-4 4 4 4M6 12h11"/>',
        'bolt' => '<path d="M13 2L4 14h7l-1 8 9-12h-7z"/>',
        'search' => '<circle cx="11" cy="11" r="7"/><path d="M20 20l-4-4"/>',
        'menu' => '<path d="M4 6h16M4 12h16M4 18h16"/>',
        'ban' => '<circle cx="12" cy="12" r="9"/><path d="M6 6l12 12"/>',
        'trash' => '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"/>',
        'key' => '<circle cx="8" cy="15" r="4"/><path d="M11 12l9-9M16 7l3 3"/>',
        'chevron' => '<path d="M9 6l6 6-6 6"/>',
        'server' => '<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 8h.01M7 17h.01"/>',
    ];

    return '<svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
        . ($paths[$name] ?? '') . '</svg>';
}

function box_logo(int $size = 34): string
{
    return '<svg class="logo" width="' . $size . '" height="' . $size . '" viewBox="0 0 100 100" fill="none" stroke="currentColor" stroke-width="6.5" stroke-linejoin="round" stroke-linecap="round" aria-hidden="true">'
        . '<path d="M50 12 L86 31 L50 50 L14 31 Z"/><path d="M12 41 L44 58 L44 92 L12 75 Z"/><path d="M88 41 L56 58 L56 92 L88 75 Z"/></svg>';
}

function page_start(string $title, string $active): void
{
    $admin = current_admin();
    $nav = [
        'dashboard' => ['Genel bakış', 'dashboard'],
        'users' => ['Kullanıcılar', 'users'],
        'downloads' => ['İndirmeler', 'download'],
        'audit' => ['İşlem kaydı', 'log'],
        'security' => ['Güvenlik', 'shield'],
        'settings' => ['Ayarlar', 'settings'],
    ];
    ?><!doctype html>
<html lang="tr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="robots" content="noindex, nofollow">
<meta name="theme-color" content="#06080a">
<title><?= e($title) ?> · Box Admin</title>
<link rel="stylesheet" href="assets/admin.css?v=3">
</head>
<body>
<div class="app">
    <aside class="side" id="side">
        <a class="brand" href="./"><?= box_logo() ?><span>BOX<small>admin</small></span></a>
        <nav>
            <?php foreach ($nav as $key => [$label, $ic]): ?>
                <a href="?p=<?= $key ?>" class="<?= $active === $key ? 'on' : '' ?>"><?= icon($ic) ?><span><?= e($label) ?></span></a>
            <?php endforeach; ?>
        </nav>
        <div class="side-foot">
            <div class="me">
                <div class="avatar"><?= e(mb_strtoupper(mb_substr((string) $admin['username'], 0, 1))) ?></div>
                <div>
                    <b><?= e($admin['username']) ?></b>
                    <small><?= (int) $admin['totp_enabled'] === 1 ? '2FA açık' : '2FA kapalı' ?></small>
                </div>
            </div>
            <form method="post" action="?p=logout">
                <?= csrf_field() ?>
                <button class="btn ghost full" type="submit"><?= icon('logout') ?> Çıkış</button>
            </form>
        </div>
    </aside>
    <div class="scrim" id="scrim"></div>
    <main class="main">
        <header class="top">
            <button class="iconbtn only-mobile" id="menuBtn" type="button" aria-label="Menü"><?= icon('menu') ?></button>
            <h1><?= e($title) ?></h1>
            <span class="pill live"><i></i> Canlı</span>
        </header>
        <?php if ($f = take_flash()): ?>
            <div class="flash <?= e($f[0]) ?>"><?= e($f[1]) ?></div>
        <?php endif; ?>
<?php
}

function page_end(): void
{
    ?>
    </main>
</div>
<script src="assets/admin.js?v=3"></script>
</body>
</html>
<?php
}

function bare_start(string $title): void
{
    ?><!doctype html>
<html lang="tr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<meta name="theme-color" content="#06080a">
<title><?= e($title) ?> · Box Admin</title>
<link rel="stylesheet" href="assets/admin.css?v=3">
</head>
<body class="bare">
<div class="grid-bg"></div>
<?php
}

function bare_end(): void
{
    ?>
<script src="assets/admin.js?v=3"></script>
</body>
</html>
<?php
}

function stat_card(string $label, string $value, string $ic, string $sub = ''): string
{
    return '<div class="card stat">' . icon($ic) . '<div><span>' . e($label) . '</span><b>' . e($value) . '</b>'
        . ($sub !== '' ? '<small>' . e($sub) . '</small>' : '') . '</div></div>';
}

/** Son N günün değerlerinden sunucu tarafında SVG çubuk grafik üretir. */
function bar_chart(array $series, string $label): string
{
    $max = max(1, ...array_values($series));
    $n = count($series);
    $w = 600;
    $h = 160;
    $gap = 6;
    $bw = ($w - $gap * ($n - 1)) / max(1, $n);
    $bars = '';
    $i = 0;

    foreach ($series as $day => $value) {
        $bh = max(2, ($value / $max) * ($h - 24));
        $x = $i * ($bw + $gap);
        $y = $h - 18 - $bh;
        $bars .= sprintf(
            '<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="4" class="bar"><title>%s: %d</title></rect>',
            $x, $y, $bw, $bh, e(date('d.m', (int) strtotime((string) $day))), (int) $value
        );
        if ($i % 2 === 0 || $n <= 7) {
            $bars .= sprintf('<text x="%.1f" y="%d" class="axis">%s</text>', $x + $bw / 2, $h - 4, e(date('d', (int) strtotime((string) $day))));
        }
        $i++;
    }

    return '<svg class="chart" viewBox="0 0 ' . $w . ' ' . $h . '" role="img" aria-label="' . e($label) . '">'
        . '<defs><linearGradient id="g" x1="0" x2="0" y1="0" y2="1"><stop offset="0" stop-color="#5cff2e"/><stop offset="1" stop-color="#5cff2e" stop-opacity=".15"/></linearGradient></defs>'
        . $bars . '</svg>';
}
