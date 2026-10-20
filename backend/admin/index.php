<?php

/**
 * Box admin paneli
 * Kullanıcıları listeler, premium açar/kapatır, banlar, siler.
 */

declare(strict_types=1);

ob_start();
ini_set('display_errors', '0');
ini_set('log_errors', '1');

if (!is_file(__DIR__ . '/../api/config.php')) {
    exit('api/config.php bulunamadı.');
}

require __DIR__ . '/../api/lib.php';

header('X-Frame-Options: DENY');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: no-referrer');
header('Cache-Control: no-store');

session_name('box_admin');
session_set_cookie_params([
    'lifetime' => 0,
    'path' => '/',
    'secure' => !empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off',
    'httponly' => true,
    'samesite' => 'Strict',
]);
session_start();

function h(?string $value): string
{
    return htmlspecialchars((string) $value, ENT_QUOTES, 'UTF-8');
}

function csrf(): string
{
    if (empty($_SESSION['csrf'])) {
        $_SESSION['csrf'] = bin2hex(random_bytes(16));
    }

    return $_SESSION['csrf'];
}

function check_csrf(): void
{
    $sent = $_POST['csrf'] ?? '';
    if (!is_string($sent) || !hash_equals(csrf(), $sent)) {
        http_response_code(400);
        exit('Geçersiz form, sayfayı yenileyip tekrar dene.');
    }
}

function redirect_back(string $message = ''): void
{
    if ($message !== '') {
        $_SESSION['flash'] = $message;
    }

    $query = [];
    foreach (['q', 'page', 'filter'] as $key) {
        if (isset($_POST[$key]) && is_string($_POST[$key]) && $_POST[$key] !== '') {
            $query[$key] = $_POST[$key];
        }
    }

    header('Location: index.php' . ($query ? '?' . http_build_query($query) : ''));
    exit;
}

$configured = strlen(ADMIN_PASSWORD) >= 10 && ADMIN_PASSWORD !== 'GUCLU_BIR_ADMIN_SIFRESI';

/* ---------------- Giriş / çıkış ---------------- */

if (($_GET['logout'] ?? '') === '1') {
    $_SESSION = [];
    session_destroy();
    header('Location: index.php');
    exit;
}

$loginError = '';

if (empty($_SESSION['admin']) && $_SERVER['REQUEST_METHOD'] === 'POST' && ($_POST['do'] ?? '') === 'login') {
    check_csrf();

    $user = (string) ($_POST['username'] ?? '');
    $pass = (string) ($_POST['password'] ?? '');

    if ($configured && hash_equals(ADMIN_USERNAME, $user) && hash_equals(ADMIN_PASSWORD, $pass)) {
        session_regenerate_id(true);
        $_SESSION['admin'] = true;
        header('Location: index.php');
        exit;
    }

    sleep(2);
    $loginError = $configured ? 'Kullanıcı adı veya şifre hatalı.' : 'Admin şifresi config.php içinde ayarlanmamış (en az 10 karakter).';
}

/* ---------------- İşlemler ---------------- */

if (!empty($_SESSION['admin']) && $_SERVER['REQUEST_METHOD'] === 'POST') {
    check_csrf();

    $do = (string) ($_POST['do'] ?? '');
    $id = (int) ($_POST['id'] ?? 0);
    $target = $id > 0 ? find_user_by_id($id) : null;

    if ($target === null) {
        redirect_back('Kullanıcı bulunamadı.');
    }

    $label = $target['email'];

    switch ($do) {
        case 'premium_on':
            $days = (int) ($_POST['days'] ?? 0);
            $until = $days > 0 ? (new DateTimeImmutable('now'))->modify('+' . $days . ' days')->format('Y-m-d H:i:s') : null;
            db()->prepare('UPDATE users SET is_premium = 1, premium_until = ? WHERE id = ?')->execute([$until, $id]);
            redirect_back($label . ' için premium açıldı' . ($days > 0 ? ' (' . $days . ' gün).' : ' (süresiz).'));

        case 'premium_off':
            db()->prepare('UPDATE users SET is_premium = 0, premium_until = NULL WHERE id = ?')->execute([$id]);
            redirect_back($label . ' için premium kapatıldı.');

        case 'ban':
            db()->prepare('UPDATE users SET is_banned = 1 WHERE id = ?')->execute([$id]);
            db()->prepare('DELETE FROM tokens WHERE user_id = ?')->execute([$id]);
            redirect_back($label . ' askıya alındı.');

        case 'unban':
            db()->prepare('UPDATE users SET is_banned = 0 WHERE id = ?')->execute([$id]);
            redirect_back($label . ' tekrar aktif.');

        case 'logout_all':
            db()->prepare('DELETE FROM tokens WHERE user_id = ?')->execute([$id]);
            redirect_back($label . ' tüm cihazlardan çıkarıldı.');

        case 'delete':
            db()->prepare('DELETE FROM users WHERE id = ?')->execute([$id]);
            redirect_back($label . ' silindi.');

        default:
            redirect_back();
    }
}

/* ---------------- Sayfa ---------------- */

$flash = $_SESSION['flash'] ?? '';
unset($_SESSION['flash']);

?><!doctype html>
<html lang="tr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Box Admin</title>
<style>
:root{--bg:#07090a;--card:#111517;--line:#1f2629;--text:#e8f0ea;--muted:#8a9a90;--neon:#5cff2e;--danger:#ff4d5e;--warn:#ffb020}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
a{color:var(--neon);text-decoration:none}
.wrap{max-width:1100px;margin:0 auto;padding:20px 16px 60px}
header{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:20px}
.brand{display:flex;align-items:center;gap:10px;font-weight:700;font-size:20px;letter-spacing:.5px}
.brand svg{filter:drop-shadow(0 0 6px var(--neon))}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:20px}
.stat{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px}
.stat b{display:block;font-size:26px;color:var(--neon)}
.stat span{color:var(--muted);font-size:13px}
.flash{background:rgba(92,255,46,.1);border:1px solid rgba(92,255,46,.4);padding:10px 14px;border-radius:12px;margin-bottom:16px}
.err{background:rgba(255,77,94,.1);border-color:rgba(255,77,94,.5)}
form.search{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:14px}
input,select,button{font:inherit;border-radius:10px;border:1px solid var(--line);background:#0c1012;color:var(--text);padding:9px 12px}
input:focus,select:focus{outline:none;border-color:var(--neon)}
button{cursor:pointer;background:#162017;border-color:#24361f}
button:hover{border-color:var(--neon)}
button.primary{background:var(--neon);color:#041004;border-color:var(--neon);font-weight:700}
button.danger{background:transparent;border-color:rgba(255,77,94,.5);color:var(--danger)}
.users{display:flex;flex-direction:column;gap:10px}
.user{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px;display:grid;grid-template-columns:1fr auto;gap:10px;align-items:center}
.user .meta{color:var(--muted);font-size:13px}
.badge{display:inline-block;font-size:12px;padding:2px 8px;border-radius:999px;margin-left:6px;vertical-align:middle}
.badge.pro{background:rgba(92,255,46,.15);color:var(--neon);border:1px solid rgba(92,255,46,.4)}
.badge.ban{background:rgba(255,77,94,.15);color:var(--danger);border:1px solid rgba(255,77,94,.4)}
.actions{display:flex;gap:6px;flex-wrap:wrap;justify-content:flex-end}
.actions form{display:inline-flex;gap:6px}
.pager{display:flex;gap:8px;justify-content:center;margin-top:18px}
.login{max-width:360px;margin:12vh auto;background:var(--card);border:1px solid var(--line);border-radius:18px;padding:26px;display:flex;flex-direction:column;gap:12px}
@media (max-width:700px){.user{grid-template-columns:1fr}.actions{justify-content:flex-start}}
</style>
</head>
<body>
<div class="wrap">
<?php
$logo = '<svg width="28" height="28" viewBox="0 0 100 100" fill="none" stroke="#5cff2e" stroke-width="7" stroke-linejoin="round"><path d="M50 10 L88 30 L50 50 L12 30 Z"/><path d="M10 40 L44 58 L44 92 L10 74 Z"/><path d="M90 40 L56 58 L56 92 L90 74 Z"/></svg>';

if (empty($_SESSION['admin'])): ?>
    <form class="login" method="post">
        <div class="brand"><?= $logo ?> Box Admin</div>
        <?php if ($loginError !== ''): ?><div class="flash err"><?= h($loginError) ?></div><?php endif; ?>
        <input type="hidden" name="csrf" value="<?= h(csrf()) ?>">
        <input type="hidden" name="do" value="login">
        <input name="username" placeholder="Kullanıcı adı" autocomplete="username" required>
        <input name="password" type="password" placeholder="Şifre" autocomplete="current-password" required>
        <button class="primary" type="submit">Giriş yap</button>
    </form>
<?php else:
    $q = isset($_GET['q']) && is_string($_GET['q']) ? trim($_GET['q']) : '';
    $filter = isset($_GET['filter']) && is_string($_GET['filter']) ? $_GET['filter'] : 'all';
    $page = max(1, (int) ($_GET['page'] ?? 1));
    $perPage = 50;

    $where = [];
    $params = [];

    if ($q !== '') {
        $where[] = '(email LIKE ? OR display_name LIKE ?)';
        $params[] = '%' . $q . '%';
        $params[] = '%' . $q . '%';
    }

    if ($filter === 'premium') {
        $where[] = 'is_premium = 1 AND (premium_until IS NULL OR premium_until > NOW())';
    } elseif ($filter === 'free') {
        $where[] = '(is_premium = 0 OR (premium_until IS NOT NULL AND premium_until <= NOW()))';
    } elseif ($filter === 'banned') {
        $where[] = 'is_banned = 1';
    }

    $whereSql = $where ? 'WHERE ' . implode(' AND ', $where) : '';

    $countStmt = db()->prepare('SELECT COUNT(*) FROM users ' . $whereSql);
    $countStmt->execute($params);
    $total = (int) $countStmt->fetchColumn();
    $pages = max(1, (int) ceil($total / $perPage));
    $page = min($page, $pages);

    $listStmt = db()->prepare(
        'SELECT u.*, (SELECT COUNT(*) FROM downloads d WHERE d.user_id = u.id) AS download_count
           FROM users u ' . $whereSql . '
          ORDER BY u.id DESC
          LIMIT ' . $perPage . ' OFFSET ' . (($page - 1) * $perPage)
    );
    $listStmt->execute($params);
    $users = $listStmt->fetchAll();

    $stats = db()->query(
        "SELECT
            (SELECT COUNT(*) FROM users) AS total,
            (SELECT COUNT(*) FROM users WHERE is_premium = 1 AND (premium_until IS NULL OR premium_until > NOW())) AS premium,
            (SELECT COUNT(*) FROM users WHERE created_at > NOW() - INTERVAL 7 DAY) AS week,
            (SELECT COUNT(*) FROM downloads WHERE created_at > NOW() - INTERVAL 1 DAY) AS today_dl"
    )->fetch();

    $keep = function (array $extra = []) use ($q, $filter): string {
        return http_build_query(array_filter(array_merge(['q' => $q, 'filter' => $filter === 'all' ? '' : $filter], $extra), fn ($v) => $v !== '' && $v !== null));
    };
?>
    <header>
        <div class="brand"><?= $logo ?> Box Admin</div>
        <a href="?logout=1">Çıkış</a>
    </header>

    <?php if ($flash !== ''): ?><div class="flash"><?= h($flash) ?></div><?php endif; ?>

    <div class="stats">
        <div class="stat"><b><?= (int) $stats['total'] ?></b><span>Toplam kullanıcı</span></div>
        <div class="stat"><b><?= (int) $stats['premium'] ?></b><span>Premium</span></div>
        <div class="stat"><b><?= (int) $stats['week'] ?></b><span>Son 7 günde kayıt</span></div>
        <div class="stat"><b><?= (int) $stats['today_dl'] ?></b><span>Son 24 saatte indirme</span></div>
    </div>

    <form class="search" method="get">
        <input name="q" value="<?= h($q) ?>" placeholder="E-posta veya isim ara" style="flex:1;min-width:200px">
        <select name="filter">
            <option value="all" <?= $filter === 'all' ? 'selected' : '' ?>>Hepsi</option>
            <option value="premium" <?= $filter === 'premium' ? 'selected' : '' ?>>Premium</option>
            <option value="free" <?= $filter === 'free' ? 'selected' : '' ?>>Ücretsiz</option>
            <option value="banned" <?= $filter === 'banned' ? 'selected' : '' ?>>Askıda</option>
        </select>
        <button type="submit">Filtrele</button>
    </form>

    <div class="users">
    <?php if (!$users): ?>
        <div class="stat"><span>Kullanıcı bulunamadı.</span></div>
    <?php endif; ?>

    <?php foreach ($users as $u):
        $premium = is_premium($u);
        $hidden = '<input type="hidden" name="csrf" value="' . h(csrf()) . '">'
            . '<input type="hidden" name="id" value="' . (int) $u['id'] . '">'
            . '<input type="hidden" name="q" value="' . h($q) . '">'
            . '<input type="hidden" name="filter" value="' . h($filter) . '">'
            . '<input type="hidden" name="page" value="' . (int) $page . '">';
    ?>
        <div class="user">
            <div>
                <div>
                    <b><?= h($u['display_name']) ?></b>
                    <?php if ($premium): ?><span class="badge pro">PREMIUM<?= $u['premium_until'] ? ' · ' . h(date('d.m.Y', (int) strtotime((string) $u['premium_until']))) . "'e kadar" : '' ?></span><?php endif; ?>
                    <?php if ((int) $u['is_banned'] === 1): ?><span class="badge ban">ASKIDA</span><?php endif; ?>
                </div>
                <div class="meta"><?= h($u['email']) ?></div>
                <div class="meta">
                    #<?= (int) $u['id'] ?> · Kayıt: <?= h(date('d.m.Y H:i', (int) strtotime((string) $u['created_at']))) ?>
                    · Son giriş: <?= $u['last_login_at'] ? h(date('d.m.Y H:i', (int) strtotime((string) $u['last_login_at']))) : '-' ?>
                    · İndirme: <?= (int) $u['download_count'] ?>
                </div>
            </div>
            <div class="actions">
                <?php if ($premium): ?>
                    <form method="post"><?= $hidden ?><input type="hidden" name="do" value="premium_off"><button type="submit">Premium kapat</button></form>
                <?php else: ?>
                    <form method="post"><?= $hidden ?><input type="hidden" name="do" value="premium_on">
                        <select name="days">
                            <option value="0">Süresiz</option>
                            <option value="30">30 gün</option>
                            <option value="90">90 gün</option>
                            <option value="365">1 yıl</option>
                        </select>
                        <button class="primary" type="submit">Premium aç</button>
                    </form>
                <?php endif; ?>

                <?php if ((int) $u['is_banned'] === 1): ?>
                    <form method="post"><?= $hidden ?><input type="hidden" name="do" value="unban"><button type="submit">Askıdan al</button></form>
                <?php else: ?>
                    <form method="post"><?= $hidden ?><input type="hidden" name="do" value="ban"><button type="submit">Askıya al</button></form>
                <?php endif; ?>

                <form method="post"><?= $hidden ?><input type="hidden" name="do" value="logout_all"><button type="submit">Oturumları kapat</button></form>
                <form method="post" onsubmit="return confirm('Bu kullanıcı kalıcı olarak silinsin mi?')"><?= $hidden ?><input type="hidden" name="do" value="delete"><button class="danger" type="submit">Sil</button></form>
            </div>
        </div>
    <?php endforeach; ?>
    </div>

    <?php if ($pages > 1): ?>
    <div class="pager">
        <?php if ($page > 1): ?><a href="?<?= h($keep(['page' => $page - 1])) ?>">← Önceki</a><?php endif; ?>
        <span><?= $page ?> / <?= $pages ?></span>
        <?php if ($page < $pages): ?><a href="?<?= h($keep(['page' => $page + 1])) ?>">Sonraki →</a><?php endif; ?>
    </div>
    <?php endif; ?>
<?php endif; ?>
</div>
</body>
</html>
