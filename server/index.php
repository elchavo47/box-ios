<?php
require __DIR__ . '/app/bootstrap.php';
$path = routePath();

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
    echo "User-agent: *\nDisallow: /\n";
    exit;
}
if ($path === '/approve') { require ROOT . '/app/panel/approve.php'; exit; }
if ($path === '/' || $path === '/index.php') { header('Location: /admin', true, 302); exit; }
if ($path === '/admin' || str_starts_with($path, '/admin/')) { require ROOT . '/app/admin.php'; exit; }
if (str_starts_with($path, '/api/') || str_starts_with($path, '/box-api') || in_array($path, ['/health', '/cron'], true)) { require ROOT . '/app/api.php'; exit; }

http_response_code(404);
header('Content-Type: text/plain; charset=utf-8');
echo 'Bulunamadı.';
