<?php
require __DIR__ . '/app/bootstrap.php';
$path = routePath();

// Apache ErrorDocument ile gelen hatalar (ör. kapalı klasörler için 403).
$redirectStatus = (int)($_SERVER['REDIRECT_STATUS'] ?? 200);
if ($redirectStatus >= 400 && $redirectStatus < 600) webError($redirectStatus);

if (str_starts_with($path, '/install')) { require ROOT . '/app/installer.php'; exit; }

if ($path === '/admin/manifest.json') {
    header('Content-Type: application/manifest+json; charset=utf-8');
    header('Cache-Control: public, max-age=86400');
    echo json_encode(['name' => 'Box Control Deck', 'short_name' => 'Box Panel', 'start_url' => '/admin', 'scope' => '/admin', 'display' => 'standalone', 'background_color' => '#0B0F0D', 'theme_color' => '#0B0F0D', 'lang' => 'tr',
        'icons' => [['src' => '/assets/panel-192.png', 'sizes' => '192x192', 'type' => 'image/png'], ['src' => '/assets/panel-512.png', 'sizes' => '512x512', 'type' => 'image/png'], ['src' => '/assets/panel-maskable.png', 'sizes' => '512x512', 'type' => 'image/png', 'purpose' => 'maskable']]], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
}
if ($path === '/robots.txt') {
    header('Content-Type: text/plain; charset=utf-8');
    echo "User-agent: *\nAllow: /\$\nDisallow: /admin\nDisallow: /api/\nDisallow: /install\nDisallow: /approve\n";
    exit;
}
if ($path === '/approve') { require ROOT . '/app/panel/approve.php'; exit; }
if ($path === '/' || $path === '/index.php') webLanding();
if (in_array($path, ['/gizlilik', '/privacy'], true)) webPrivacy();
if ($path === '/admin' || str_starts_with($path, '/admin/')) { require ROOT . '/app/admin.php'; exit; }
if (str_starts_with($path, '/api/') || str_starts_with($path, '/box-api') || in_array($path, ['/health', '/cron'], true)) { require ROOT . '/app/api.php'; exit; }

webError(404);
