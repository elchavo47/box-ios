<?php
if (!defined('ROOT')) { http_response_code(404); exit; }

if (!adminIpAllowed()) { http_response_code(403); header('Content-Type: text/plain; charset=utf-8'); echo 'Bu adresten panele erişim kapalı.'; exit; }
require ROOT . '/app/panel/core.php';
require ROOT . '/app/panel/ui.php';
require ROOT . '/app/panel/actions.php';
header('Cache-Control: no-store, private');
header('X-Robots-Tag: noindex, nofollow');
header("Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; font-src 'self'; img-src 'self' data: https://i.ytimg.com; connect-src 'self'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'");

$isAjax = ($_SERVER['HTTP_X_REQUESTED_WITH'] ?? '') === 'nb-ajax';
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
function panelJson(array $data, int $code = 200): never {
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}
function csrfValid(): bool { return !empty($_SESSION['csrf']) && is_string($_POST['csrf'] ?? null) && hash_equals((string)$_SESSION['csrf'], (string)$_POST['csrf']); }

$admin = panelUser();
if ($admin && empty($_SESSION['ip0'])) $_SESSION['ip0'] = clientIp(); 
$GLOBALS['NB_ADMIN'] = $admin;


function panelFinishLogin(array $user, bool $remember, array $details = []): never {
    if (loginApprovalOn() && !knownDevice((int)$user['id'])) {
        $tok = loginApprovalStart($user, $remember);
        session_regenerate_id(true);
        $_SESSION = ['csrf' => bin2hex(random_bytes(24)), 'pending_approval' => $tok, 'pending_at' => time()];
        recordAdminLogin($user, (string)$user['username'], true);
        logAdmin((int)$user['id'], 'login_approval_wait', $details);
        header('Location: /admin'); exit;
    }
    panelStartSession($user, $remember);
    recordAdminLogin($user, (string)$user['username'], true);
    q('UPDATE admins SET last_login_at=NOW(),last_login_ip=? WHERE id=?', [clientIp(), $user['id']]);
    logAdmin((int)$user['id'], 'login', $details);
    watchRefresh();
    header('Location: /admin'); exit;
}


if (!$admin) {
    if ($isAjax && $method !== 'POST') panelJson(['ok' => false, 'message' => 'Oturum süresi doldu. Yeniden giriş yapın.', 'redirect' => '/admin'], 401);
    if ($isAjax && $method === 'POST' && !in_array((string)($_POST['action'] ?? ''), ['login', 'login_2fa'], true)) panelJson(['ok' => false, 'message' => 'Oturum süresi doldu. Yeniden giriş yapın.', 'redirect' => '/admin'], 401);
    $error = '';
    
    $approval = isset($_SESSION['pending_approval']) ? loginApprovalState((string)$_SESSION['pending_approval']) : null;
    if (isset($_SESSION['pending_approval'])) {
        if ($method === 'POST' && ($_POST['action'] ?? '') === 'login_cancel') { panelDropSession(); header('Location: /admin'); exit; }
        if ($approval && $approval['status'] === 'approved') {
            $user = q('SELECT * FROM admins WHERE id=?', [$approval['user_id']])->fetch();
            q('DELETE FROM admin_login_approvals WHERE token_hash=?', [$approval['token_hash']]);
            if ($user && $user['status'] === 'active' && isset(NB_ROLES[$user['role']])) {
                rememberDevice((int)$user['id']);
                panelStartSession($user, (bool)$approval['remember']);
                q('UPDATE admins SET last_login_at=NOW(),last_login_ip=? WHERE id=?', [clientIp(), $user['id']]);
                logAdmin((int)$user['id'], 'login', ['approved' => 'telegram']);
                header('Location: /admin'); exit;
            }
        }
        if (!$approval || in_array($approval['status'], ['denied', 'expired'], true)) {
            panelDropSession();
            $error = $approval && $approval['status'] === 'denied' ? 'Giriş Telegram\'dan reddedildi.' : 'Onay süresi doldu. Yeniden giriş yapın.';
            if ($approval && $approval['status'] === 'denied') securityAlert("⛔ Reddedilen panel girişi\nIP: " . ($approval['ip'] ?? '?'));
            $approval = null;
        } else {
            $waiting = true;
            require ROOT . '/app/panel/login.php';
            exit;
        }
    }
    $pending = $_SESSION['pending_2fa'] ?? null;
    if ($pending && time() - (int)($_SESSION['pending_at'] ?? 0) > 300) { panelDropSession(); $pending = null; $error = 'Doğrulama süresi doldu. Yeniden giriş yapın.'; }

    if ($method === 'POST' && ($_POST['action'] ?? '') === 'login_cancel') { panelDropSession(); header('Location: /admin'); exit; }
    if ($method === 'POST' && !csrfValid()) { $error = 'Sayfanın süresi dolmuş. Tekrar deneyin.'; }
    elseif ($method === 'POST' && $pending && ($_POST['action'] ?? '') === 'login_2fa') {
        $user = q('SELECT * FROM admins WHERE id=?', [(int)$pending])->fetch();
        $code = trim((string)($_POST['code'] ?? ''));
        $_SESSION['pending_tries'] = (int)($_SESSION['pending_tries'] ?? 0) + 1;
        $step = $user ? totpVerify(decryptSecret((string)$user['totp_secret']), $code, (int)$user['totp_last_step']) : null;
        $viaRecovery = false;
        if ($user && $step === null && strlen($code) > 6 && totpUseRecovery($user, $code)) $viaRecovery = true;
        if ($user && ($step !== null || $viaRecovery) && $user['status'] === 'active' && isset(NB_ROLES[$user['role']])) {
            if ($step !== null) q('UPDATE admins SET totp_last_step=? WHERE id=?', [$step, $user['id']]);
            $remember = !empty($_SESSION['pending_remember']);
            if ($viaRecovery) securityAlert("Kurtarma koduyla giriş yapıldı: {$user['username']}\nIP: " . clientIp());
            panelFinishLogin($user, $remember, ['2fa' => $viaRecovery ? 'recovery' : 'totp']);
        }
        recordAdminLogin($user ?: null, (string)($user['username'] ?? ''), false);
        loginSlowdown();
        if ((int)$_SESSION['pending_tries'] >= 5) { panelDropSession(); $pending = null; $error = 'Çok fazla hatalı kod. Yeniden giriş yapın.'; }
        else $error = 'Kod doğru değil. Uygulamadaki güncel kodu girin.';
    } elseif ($method === 'POST' && ($_POST['action'] ?? '') === 'login') {
        $login = mb_substr(trim((string)($_POST['login'] ?? '')), 0, 190);
        $password = (string)($_POST['password'] ?? '');
        if ($locked = loginLocked($login)) { $error = $locked; recordAdminLogin(null, $login, false); }
        else {
            $user = $login !== '' ? q('SELECT * FROM admins WHERE username=? OR (email IS NOT NULL AND email=?) LIMIT 1', [mb_strtolower($login), mb_strtolower($login)])->fetch() : false;
            
            $valid = password_verify($password, $user ? (string)$user['password'] : '$2y$10$aEfbUMLzcrPAJLWv.suOb.zIrNmwBkoU14U9Cxh/ny/QX4eKnHch.');
            if (!$user || !$valid || $user['status'] !== 'active') {
                recordAdminLogin($user ?: null, $login, false);
                loginSlowdown();
                $error = 'Kullanıcı adı ya da şifre hatalı.';
            } else {
                if (password_needs_rehash((string)$user['password'], PASSWORD_DEFAULT)) { q('UPDATE admins SET password=? WHERE id=?', [password_hash($password, PASSWORD_DEFAULT), $user['id']]); $user = q('SELECT * FROM admins WHERE id=?', [$user['id']])->fetch(); }
                if (!empty($user['totp_enabled_at'])) {
                    session_regenerate_id(true);
                    $_SESSION = ['csrf' => bin2hex(random_bytes(24)), 'pending_2fa' => (int)$user['id'], 'pending_at' => time(), 'pending_tries' => 0, 'pending_remember' => isset($_POST['remember'])];
                    header('Location: /admin'); exit;
                }
                panelFinishLogin($user, isset($_POST['remember']));
            }
        }
    }
    require ROOT . '/app/panel/login.php';
    exit;
}



if (preg_match('#^/admin/static/(deck|qrcode)\.js$#', routePath(), $m)) {
    
    
    $file = ROOT . '/app/panel/static/' . $m[1] . '.php';
    $code = is_file($file) ? (string)(require $file) : (is_file($dev = ROOT . '/app/panel/static/' . $m[1] . '.js') ? (string)file_get_contents($dev) : '');
    if ($code === '') { http_response_code(404); exit; }
    header('Content-Type: application/javascript; charset=utf-8');
    header('Cache-Control: private, max-age=86400');
    header('X-Content-Type-Options: nosniff');
    echo $code; exit;
}

watchCheck();
lazyCronTick();
$pages = panelPages();
$page = (string)($_GET['p'] ?? 'dashboard');
if (!isset($pages[$page])) $page = 'dashboard';

$force2fa = staffTwoFactorRequired() && empty($admin['totp_enabled_at']);
if ($force2fa && $page !== 'profile') $page = 'profile';
if ($force2fa && $method === 'POST' && !in_array((string)($_POST['action'] ?? ''), ['totp_begin', 'totp_enable', 'logout'], true)) {
    if ($isAjax) panelJson(['ok' => false, 'message' => 'Önce iki adımlı girişi açman gerekiyor (Profil sayfası).'], 403);
    http_response_code(403); exit;
}
if (!canSee($admin, $page)) {
    if ($isAjax && $method !== 'POST') panelJson(['ok' => false, 'message' => 'Bu sayfaya erişiminiz yok.'], 403);
    $page = 'dashboard';
}


if ($isAjax && isset($_GET['search'])) {
    $term = mb_substr(trim((string)$_GET['search']), 0, 60);
    if (mb_strlen($term) < 2 && !ctype_digit($term)) panelJson(['ok' => true, 'players' => []]);
    $like = '%' . addcslashes($term, '%_\\') . '%';
    $where = ['display_name LIKE ?', 'email LIKE ?']; $args = [$like, $like];
    if (ctype_digit($term)) { $where[] = 'id=?'; $args[] = (int)$term; }
    $rows = q('SELECT id,display_name,email,is_banned,is_premium,premium_until FROM users WHERE ' . implode(' OR ', $where) . ' ORDER BY (id=' . (ctype_digit($term) ? (int)$term : 0) . ') DESC,last_seen_at DESC LIMIT 8', $args)->fetchAll();
    $out = [];
    foreach ($rows as $r) $out[] = ['id' => (int)$r['id'], 'username' => (string)$r['display_name'], 'status' => (int)$r['is_banned'] ? 'suspended' : 'active', 'level' => boxIsPremium($r) ? 'Premium' : 'Ücretsiz', 'email' => (string)$r['email']];
    panelJson(['ok' => true, 'players' => $out]);
}


if (($_GET['export'] ?? '') === 'audit' && canSee($admin, 'audit')) {
    logAdmin((int)$admin['id'], 'audit_export');
    header('Content-Type: text/csv; charset=utf-8');
    header('Content-Disposition: attachment; filename="box-denetim-' . date('Ymd-His') . '.csv"');
    $out = fopen('php://output', 'w');
    fwrite($out, "\xEF\xBB\xBF");
    fputcsv($out, ['id', 'tarih', 'yetkili', 'işlem', 'ayrıntı', 'ip', 'özet']);
    foreach (q('SELECT l.*,u.username FROM admin_audit_log l LEFT JOIN admins u ON u.id=l.admin_id ORDER BY l.id DESC LIMIT 20000')->fetchAll() as $r) {
        
        $cells = array_map(fn($v) => preg_match('/^[=+\-@\t\r]/', (string)$v) ? "'" . $v : (string)$v, [$r['id'], $r['created_at'], $r['username'] ?? '', $r['action'], $r['details'] ?? '', $r['ip'] ?? '', $r['row_hash'] ?? '']);
        fputcsv($out, $cells);
    }
    exit;
}

if ($method === 'POST') {
    $notice = ''; $error = ''; $data = null; $silent = false;
    if (!csrfValid()) {
        if ($isAjax) panelJson(['ok' => false, 'message' => 'Güvenlik doğrulaması başarısız. Sayfayı yenileyip tekrar deneyin.'], 403);
        http_response_code(403); exit('Güvenlik doğrulaması başarısız.');
    }
    
    $stepAction = (string)($_POST['action'] ?? '');
    if (stepUpRequired($admin, $stepAction) && actionAllowed((string)$admin['role'], $stepAction)) {
        $step = stepUpCheck($admin, $stepAction);
        if ($step !== true) {
            if ($isAjax) panelJson(['ok' => false, 'step_up' => true, 'message' => $step, 'label' => NB_STEP_UP_ACTIONS[$stepAction] ?? '']);
            $_SESSION['flash'] = ['type' => 'error', 'text' => $step];
            header('Location: /admin?p=' . urlencode($page)); exit;
        }
    }
    try {
        $result = panelAction($admin);
        watchRefresh(); 
        if (is_array($result)) { $notice = (string)($result['message'] ?? ''); $data = $result['data'] ?? null; $silent = !empty($result['silent']); }
        else $notice = $result;
    } catch (Throwable $e) {
        $error = $e instanceof RuntimeException ? $e->getMessage() : 'İşlem tamamlanamadı. Ayrıntı sistem günlüğünde.';
        if (!($e instanceof RuntimeException)) nbReport($e);
    }
    $action = (string)($_POST['action'] ?? '');
    $leaves = $error === '' && $action === 'logout';
    if ($isAjax) panelJson(['ok' => $error === '', 'message' => $error !== '' ? $error : $notice, 'data' => $data, 'silent' => $silent] + ($leaves ? ['redirect' => '/admin'] : []));
    if ($leaves) { header('Location: /admin'); exit; }
    $_SESSION['flash'] = ['type' => $error ? 'error' : 'success', 'text' => $error ?: $notice];
    header('Location: /admin?p=' . urlencode($page) . (in_array($page, ['player'], true) ? '&id=' . (int)($_GET['id'] ?? 0) : '')); exit;
}

$flash = $_SESSION['flash'] ?? null; unset($_SESSION['flash']);
if ($force2fa && !$flash) $flash = ['type' => 'error', 'text' => 'Ekip hesaplarında iki adımlı giriş zorunlu. Devam etmek için aşağıdan aç.'];
require ROOT . '/app/panel/layout.php';
