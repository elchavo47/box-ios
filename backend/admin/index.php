<?php

declare(strict_types=1);

require __DIR__ . '/_inc/core.php';
require __DIR__ . '/_inc/layout.php';
require __DIR__ . '/_inc/pages.php';

$page = get_str('p', 30) ?: 'dashboard';
$isPost = strtoupper((string) ($_SERVER['REQUEST_METHOD'] ?? 'GET')) === 'POST';

verify_post();

/* ---------------- Oturum açmamış ziyaretçi ---------------- */

$admin = current_admin();

if ($admin === null) {
    if ($page === '2fa') {
        page_two_factor($isPost);
    } else {
        page_login($isPost);
    }
    exit;
}

/* ---------------- Oturum açmış admin ---------------- */

if ($page === 'logout' && $isPost) {
    audit('logout');
    destroy_admin_session();
    flash('ok', 'Çıkış yapıldı.');
    redirect('./');
}

$routes = [
    'dashboard' => 'page_dashboard',
    'users' => 'page_users',
    'user' => 'page_user',
    'downloads' => 'page_downloads',
    'audit' => 'page_audit',
    'security' => 'page_security',
    'settings' => 'page_settings',
];

$handler = $routes[$page] ?? 'page_dashboard';
$handler($isPost);
