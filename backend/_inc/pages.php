<?php

declare(strict_types=1);

/* =====================================================================
 * Giriş ve 2FA
 * ===================================================================== */

function page_login(bool $isPost): void
{
    $error = '';
    $username = '';

    if ($isPost) {
        $username = post_str('username', 60);
        $password = (string) ($_POST['password'] ?? '');

        if (login_locked($username)) {
            $error = 'Çok fazla hatalı deneme. 15 dakika sonra tekrar dene.';
        } else {
            $stmt = db()->prepare('SELECT * FROM admins WHERE username = ? LIMIT 1');
            $stmt->execute([mb_strtolower($username)]);
            $admin = $stmt->fetch();

            if (!is_array($admin)) {
                dummy_password_verify($password);
                $ok = false;
            } else {
                $ok = password_verify($password, (string) $admin['password_hash']);
            }

            if (!$ok) {
                record_failed_login($username);
                usleep(random_int(300000, 700000));
                $error = 'Kullanıcı adı veya şifre hatalı.';
                db()->prepare(
                    'INSERT INTO admin_audit (admin_name, action, target, ip) VALUES (?, ?, ?, ?)'
                )->execute([mb_substr($username, 0, 60), 'login_failed', '', client_ip()]);
            } else {
                if (password_needs_rehash((string) $admin['password_hash'], defined('PASSWORD_ARGON2ID') ? PASSWORD_ARGON2ID : PASSWORD_BCRYPT)) {
                    db()->prepare('UPDATE admins SET password_hash = ? WHERE id = ?')
                        ->execute([hash_admin_password($password), (int) $admin['id']]);
                }

                if ((int) $admin['totp_enabled'] === 1) {
                    session_regenerate_id(true);
                    $_SESSION['pending_admin'] = (int) $admin['id'];
                    $_SESSION['pending_at'] = time();
                    $_SESSION['pending_ua'] = ua_fingerprint();
                    redirect('?p=2fa');
                }

                clear_failed_logins($username);
                login_admin($admin);
                audit('login');
                redirect('./');
            }
        }
    }

    bare_start('Giriş');
    $flash = take_flash();
    ?>
    <form class="auth" method="post" action="?p=login" autocomplete="on">
        <div class="head">
            <?= box_logo(64) ?>
            <h1>BOX ADMIN</h1>
            <p class="sub">Yönetim paneline giriş yap</p>
        </div>
        <?php if ($flash): ?><div class="flash <?= e($flash[0]) ?>"><?= e($flash[1]) ?></div><?php endif; ?>
        <?php if ($error !== ''): ?><div class="flash err"><?= e($error) ?></div><?php endif; ?>
        <?= csrf_field() ?>
        <div class="field">
            <label for="u">Kullanıcı adı</label>
            <input id="u" name="username" value="<?= e($username) ?>" autocomplete="username" autocapitalize="none" spellcheck="false" required autofocus>
        </div>
        <div class="field">
            <label for="pw">Şifre</label>
            <input id="pw" name="password" type="password" autocomplete="current-password" required>
        </div>
        <button class="btn primary full" type="submit">Giriş yap</button>
    </form>
    <?php
    bare_end();
}

function page_two_factor(bool $isPost): void
{
    $id = (int) ($_SESSION['pending_admin'] ?? 0);
    $fresh = time() - (int) ($_SESSION['pending_at'] ?? 0) < 300
        && hash_equals((string) ($_SESSION['pending_ua'] ?? ''), ua_fingerprint());

    if ($id <= 0 || !$fresh) {
        unset($_SESSION['pending_admin'], $_SESSION['pending_at'], $_SESSION['pending_ua']);
        flash('warn', 'Doğrulama süresi doldu, tekrar giriş yap.');
        redirect('./');
    }

    $error = '';

    if ($isPost) {
        $stmt = db()->prepare('SELECT * FROM admins WHERE id = ? LIMIT 1');
        $stmt->execute([$id]);
        $admin = $stmt->fetch();

        if (!is_array($admin) || login_locked((string) $admin['username'])) {
            $error = 'Çok fazla hatalı deneme. 15 dakika sonra tekrar dene.';
        } else {
            $step = totp_verify((string) $admin['totp_secret'], post_str('code', 12), (int) $admin['totp_last_step']);

            if ($step === null) {
                record_failed_login((string) $admin['username']);
                $error = 'Kod hatalı ya da süresi geçmiş.';
            } else {
                db()->prepare('UPDATE admins SET totp_last_step = ? WHERE id = ?')->execute([$step, $id]);
                clear_failed_logins((string) $admin['username']);
                login_admin($admin);
                audit('login', '', '2FA ile');
                redirect('./');
            }
        }
    }

    bare_start('Doğrulama');
    ?>
    <form class="auth" method="post" action="?p=2fa" autocomplete="off">
        <div class="head">
            <?= box_logo(56) ?>
            <h1>İki adımlı doğrulama</h1>
            <p class="sub">Doğrulama uygulamandaki 6 haneli kodu gir.</p>
        </div>
        <?php if ($error !== ''): ?><div class="flash err"><?= e($error) ?></div><?php endif; ?>
        <?= csrf_field() ?>
        <div class="field">
            <input class="code-input" name="code" inputmode="numeric" pattern="[0-9 ]*" maxlength="7" autocomplete="one-time-code" required autofocus>
        </div>
        <button class="btn primary full" type="submit">Doğrula</button>
        <p class="hint"><a href="./">← Girişe dön</a></p>
    </form>
    <?php
    bare_end();
}

/* =====================================================================
 * Genel bakış
 * ===================================================================== */

function daily_series(string $table, int $days = 14): array
{
    $series = [];
    for ($i = $days - 1; $i >= 0; $i--) {
        $series[date('Y-m-d', strtotime("-{$i} days"))] = 0;
    }

    $stmt = db()->prepare(
        "SELECT DATE(created_at) d, COUNT(*) c FROM {$table}
          WHERE created_at >= CURDATE() - INTERVAL " . ($days - 1) . " DAY GROUP BY DATE(created_at)"
    );
    $stmt->execute();
    foreach ($stmt->fetchAll() as $row) {
        if (isset($series[$row['d']])) {
            $series[$row['d']] = (int) $row['c'];
        }
    }
    return $series;
}

function vds_health(): array
{
    $url = rtrim((string) VDS_BASE_URL, '/') . '/health';
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CONNECTTIMEOUT => 4,
        CURLOPT_TIMEOUT => 6,
        CURLOPT_SSL_VERIFYPEER => true,
    ]);
    $start = microtime(true);
    $body = curl_exec($ch);
    $code = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);

    $ok = is_string($body) && $code === 200 && str_contains($body, 'ok');
    return [$ok, (int) round((microtime(true) - $start) * 1000)];
}

function page_dashboard(bool $isPost): void
{
    $s = db()->query(
        "SELECT
            (SELECT COUNT(*) FROM users) total,
            (SELECT COUNT(*) FROM users WHERE is_premium = 1 AND (premium_until IS NULL OR premium_until > NOW())) premium,
            (SELECT COUNT(*) FROM users WHERE created_at > NOW() - INTERVAL 7 DAY) week,
            (SELECT COUNT(*) FROM users WHERE is_banned = 1) banned,
            (SELECT COUNT(*) FROM downloads WHERE created_at > NOW() - INTERVAL 1 DAY) dl_day,
            (SELECT COUNT(*) FROM downloads) dl_total,
            (SELECT COUNT(DISTINCT user_id) FROM tokens WHERE last_used_at > NOW() - INTERVAL 1 DAY) active_day"
    )->fetch();

    $recentUsers = db()->query('SELECT * FROM users ORDER BY id DESC LIMIT 6')->fetchAll();
    $recentDl = db()->query(
        'SELECT d.*, u.email FROM downloads d JOIN users u ON u.id = d.user_id ORDER BY d.id DESC LIMIT 6'
    )->fetchAll();

    [$vdsOk, $vdsMs] = vds_health();
    $ytOk = YT_DATA_API_KEY !== '' && YT_DATA_API_KEY !== 'GOOGLE_API_ANAHTARI';
    $signOk = VDS_SIGNING_KEY !== '' && VDS_SIGNING_KEY !== 'VDS_DEKI_YT_API_KEY_ILE_AYNI';
    $admin = current_admin();

    page_start('Genel bakış', 'dashboard');
    ?>
    <div class="grid g4">
        <?= stat_card('Toplam kullanıcı', (string) $s['total'], 'users', '+' . $s['week'] . ' bu hafta') ?>
        <?= stat_card('Premium', (string) $s['premium'], 'bolt', $s['total'] > 0 ? '%' . round($s['premium'] * 100 / $s['total']) . ' oran' : '') ?>
        <?= stat_card('Bugün indirme', (string) $s['dl_day'], 'download', $s['dl_total'] . ' toplam') ?>
        <?= stat_card('Son 24 sa aktif', (string) $s['active_day'], 'server', $s['banned'] . ' askıda') ?>
    </div>

    <div class="grid g2 mt">
        <div class="card">
            <h2><?= icon('users') ?> Yeni kayıtlar · 14 gün</h2>
            <?= bar_chart(daily_series('users'), 'Yeni kayıtlar') ?>
        </div>
        <div class="card">
            <h2><?= icon('download') ?> İndirmeler · 14 gün</h2>
            <?= bar_chart(daily_series('downloads'), 'İndirmeler') ?>
        </div>
    </div>

    <div class="grid g3 mt">
        <div class="stack">
            <div class="card">
                <h2><?= icon('users') ?> Son kayıt olanlar <a class="push" href="?p=users">Tümü →</a></h2>
                <div class="list">
                    <?php if (!$recentUsers): ?><div class="empty">Henüz kullanıcı yok.</div><?php endif; ?>
                    <?php foreach ($recentUsers as $u): ?>
                        <a class="row" href="?p=user&amp;id=<?= (int) $u['id'] ?>">
                            <div class="avatar sm"><?= e(mb_strtoupper(mb_substr((string) $u['display_name'], 0, 1))) ?></div>
                            <div class="grow"><b><?= e($u['display_name']) ?></b><small class="muted"><?= e($u['email']) ?></small></div>
                            <?= is_premium($u) ? '<span class="badge b-pro">PRO</span>' : '' ?>
                            <small class="muted"><?= e(time_ago($u['created_at'])) ?></small>
                        </a>
                    <?php endforeach; ?>
                </div>
            </div>
            <div class="card">
                <h2><?= icon('download') ?> Son indirmeler <a class="push" href="?p=downloads">Tümü →</a></h2>
                <div class="list">
                    <?php if (!$recentDl): ?><div class="empty">Henüz indirme yok.</div><?php endif; ?>
                    <?php foreach ($recentDl as $d): ?>
                        <div class="row">
                            <img class="thumb" src="https://i.ytimg.com/vi/<?= e($d['video_id']) ?>/default.jpg" alt="" loading="lazy">
                            <div class="grow"><b><?= e($d['title'] !== '' ? $d['title'] : $d['video_id']) ?></b><small class="muted"><?= e($d['email']) ?></small></div>
                            <small class="muted"><?= e(time_ago($d['created_at'])) ?></small>
                        </div>
                    <?php endforeach; ?>
                </div>
            </div>
        </div>

        <div class="stack">
            <div class="card">
                <h2><?= icon('server') ?> Sistem durumu</h2>
                <div class="health">
                    <div><span>Veritabanı</span><span class="badge b-ok">BAĞLI</span></div>
                    <div><span>VDS indirme servisi</span><?= $vdsOk ? '<span class="badge b-ok">ÇALIŞIYOR · ' . $vdsMs . ' ms</span>' : '<span class="badge b-ban">ULAŞILAMIYOR</span>' ?></div>
                    <div><span>YouTube arama anahtarı</span><?= $ytOk ? '<span class="badge b-ok">TANIMLI</span>' : '<span class="badge b-warn">EKSİK</span>' ?></div>
                    <div><span>İmza anahtarı</span><?= $signOk ? '<span class="badge b-ok">TANIMLI</span>' : '<span class="badge b-warn">EKSİK</span>' ?></div>
                    <div><span>HTTPS</span><?= is_https() ? '<span class="badge b-ok">AÇIK</span>' : '<span class="badge b-ban">KAPALI</span>' ?></div>
                    <div><span>Kurulum klasörü</span><?= is_dir(__DIR__ . '/../install') ? '<span class="badge b-warn">DURUYOR</span>' : '<span class="badge b-ok">SİLİNMİŞ</span>' ?></div>
                </div>
            </div>
            <div class="card">
                <h2><?= icon('shield') ?> Hesabın</h2>
                <div class="health">
                    <div><span>İki adımlı doğrulama</span><?= (int) $admin['totp_enabled'] === 1 ? '<span class="badge b-ok">AÇIK</span>' : '<a class="badge b-warn" href="?p=security">KAPALI · AÇ</a>' ?></div>
                    <div><span>Son giriş IP</span><span class="mono"><?= e($admin['last_login_ip'] ?? '—') ?></span></div>
                </div>
            </div>
        </div>
    </div>
    <?php
    page_end();
}

/* =====================================================================
 * Kullanıcılar
 * ===================================================================== */

/** Kullanıcı üzerinde yapılan işlemler (liste ve detay sayfası ortak). */
function handle_user_action(): void
{
    $id = (int) ($_POST['id'] ?? 0);
    $do = post_str('do', 30);
    $back = post_str('back', 300);
    $back = preg_match('#^\?p=(users|user)(&[A-Za-z0-9_=&%.+-]*)?$#', $back) ? $back : '?p=users';

    $user = find_user_by_id($id);
    if ($user === null) {
        flash('err', 'Kullanıcı bulunamadı.');
        redirect($back);
    }

    $label = (string) $user['email'];

    switch ($do) {
        case 'premium_on':
            $days = (int) ($_POST['days'] ?? 0);
            if (!in_array($days, [0, 7, 30, 90, 180, 365], true)) {
                $days = 30;
            }
            if ($days > 0) {
                db()->prepare('UPDATE users SET is_premium = 1, premium_until = NOW() + INTERVAL ? DAY WHERE id = ?')->execute([$days, $id]);
            } else {
                db()->prepare('UPDATE users SET is_premium = 1, premium_until = NULL WHERE id = ?')->execute([$id]);
            }
            audit('premium_on', $label, $days > 0 ? $days . ' gün' : 'süresiz');
            flash('ok', $label . ' için premium açıldı (' . ($days > 0 ? $days . ' gün' : 'süresiz') . ').');
            break;

        case 'premium_off':
            db()->prepare('UPDATE users SET is_premium = 0, premium_until = NULL WHERE id = ?')->execute([$id]);
            audit('premium_off', $label);
            flash('ok', $label . ' için premium kapatıldı.');
            break;

        case 'ban':
            db()->prepare('UPDATE users SET is_banned = 1 WHERE id = ?')->execute([$id]);
            db()->prepare('DELETE FROM tokens WHERE user_id = ?')->execute([$id]);
            audit('ban', $label);
            flash('ok', $label . ' askıya alındı ve tüm cihazlardan çıkarıldı.');
            break;

        case 'unban':
            db()->prepare('UPDATE users SET is_banned = 0 WHERE id = ?')->execute([$id]);
            audit('unban', $label);
            flash('ok', $label . ' tekrar aktif.');
            break;

        case 'logout_all':
            db()->prepare('DELETE FROM tokens WHERE user_id = ?')->execute([$id]);
            audit('user_logout_all', $label);
            flash('ok', $label . ' tüm cihazlardan çıkarıldı.');
            break;

        case 'update':
            $name = post_str('name', 60);
            $email = mb_strtolower(post_str('email', 190));
            if ($name === '' || !filter_var($email, FILTER_VALIDATE_EMAIL)) {
                flash('err', 'Geçerli bir isim ve e-posta gir.');
                break;
            }
            $exists = find_user_by_email($email);
            if ($exists !== null && (int) $exists['id'] !== $id) {
                flash('err', 'Bu e-posta başka bir hesapta kullanılıyor.');
                break;
            }
            db()->prepare('UPDATE users SET display_name = ?, email = ? WHERE id = ?')->execute([$name, $email, $id]);
            audit('user_update', $label, $label !== $email ? 'yeni e-posta: ' . $email : 'isim');
            flash('ok', 'Bilgiler güncellendi.');
            break;

        case 'reset_password':
            $new = rtrim(strtr(base64_encode(random_bytes(9)), '+/', 'Kx'), '=');
            db()->prepare('UPDATE users SET password_hash = ? WHERE id = ?')->execute([password_hash($new, PASSWORD_DEFAULT), $id]);
            db()->prepare('DELETE FROM tokens WHERE user_id = ?')->execute([$id]);
            audit('user_password_reset', $label);
            flash('ok', 'Yeni geçici şifre: ' . $new . '  (kullanıcıya ilet, bir daha gösterilmeyecek)');
            break;

        case 'delete':
            if (post_str('confirm', 190) !== $label) {
                flash('err', 'Silmek için e-posta adresini aynen yazmalısın.');
                break;
            }
            db()->prepare('DELETE FROM users WHERE id = ?')->execute([$id]);
            audit('user_delete', $label);
            flash('ok', $label . ' kalıcı olarak silindi.');
            redirect('?p=users');

        default:
            flash('err', 'Bilinmeyen işlem.');
    }

    redirect($back);
}

function premium_form(array $u, string $back): string
{
    $hidden = csrf_field() . '<input type="hidden" name="id" value="' . (int) $u['id'] . '"><input type="hidden" name="back" value="' . e($back) . '">';

    if (is_premium($u)) {
        return '<form method="post" action="?p=users">' . $hidden . '<input type="hidden" name="do" value="premium_off"><button class="btn sm">Premium kapat</button></form>';
    }

    return '<form method="post" action="?p=users">' . $hidden . '<input type="hidden" name="do" value="premium_on">'
        . '<select name="days" aria-label="Süre"><option value="30">30 gün</option><option value="90">90 gün</option><option value="365">1 yıl</option><option value="7">7 gün</option><option value="0">Süresiz</option></select>'
        . '<button class="btn sm primary">' . icon('bolt') . ' Premium</button></form>';
}

function page_users(bool $isPost): void
{
    if ($isPost) {
        handle_user_action();
    }

    $q = get_str('q', 100);
    $filter = get_str('f', 10) ?: 'all';
    $page = max(1, (int) ($_GET['page'] ?? 1));
    $per = 30;

    $where = [];
    $params = [];
    if ($q !== '') {
        $where[] = '(email LIKE ? OR display_name LIKE ?)';
        $like = '%' . addcslashes($q, '%_\\') . '%';
        array_push($params, $like, $like);
    }
    if ($filter === 'pro') {
        $where[] = 'is_premium = 1 AND (premium_until IS NULL OR premium_until > NOW())';
    } elseif ($filter === 'free') {
        $where[] = '(is_premium = 0 OR (premium_until IS NOT NULL AND premium_until <= NOW()))';
    } elseif ($filter === 'ban') {
        $where[] = 'is_banned = 1';
    }
    $sql = $where ? ' WHERE ' . implode(' AND ', $where) : '';

    $count = db()->prepare('SELECT COUNT(*) FROM users' . $sql);
    $count->execute($params);
    $total = (int) $count->fetchColumn();
    $pages = max(1, (int) ceil($total / $per));
    $page = min($page, $pages);

    $list = db()->prepare(
        'SELECT u.*, (SELECT COUNT(*) FROM downloads d WHERE d.user_id = u.id) dl
           FROM users u' . $sql . ' ORDER BY u.id DESC LIMIT ' . $per . ' OFFSET ' . (($page - 1) * $per)
    );
    $list->execute($params);
    $users = $list->fetchAll();

    $base = ['p' => 'users', 'q' => $q, 'f' => $filter === 'all' ? '' : $filter];
    $link = static fn (array $extra = []): string => '?' . http_build_query(array_filter(array_merge($base, $extra), static fn ($v) => $v !== '' && $v !== null));
    $back = $link(['page' => $page > 1 ? $page : null]);

    page_start('Kullanıcılar', 'users');
    ?>
    <div class="card">
        <form class="inline" method="get">
            <input type="hidden" name="p" value="users">
            <input name="q" value="<?= e($q) ?>" placeholder="E-posta veya isimle ara" aria-label="Ara">
            <select name="f" aria-label="Filtre">
                <?php foreach (['all' => 'Hepsi', 'pro' => 'Premium', 'free' => 'Ücretsiz', 'ban' => 'Askıda'] as $k => $v): ?>
                    <option value="<?= $k ?>" <?= $filter === $k ? 'selected' : '' ?>><?= $v ?></option>
                <?php endforeach; ?>
            </select>
            <button class="btn" type="submit"><?= icon('search') ?> Ara</button>
            <span class="muted push"><?= $total ?> kullanıcı</span>
        </form>
    </div>

    <div class="card mt">
        <?php if (!$users): ?>
            <div class="empty">Kullanıcı bulunamadı.</div>
        <?php else: ?>
        <div class="table-wrap">
            <table class="table">
                <thead><tr><th>Kullanıcı</th><th>Durum</th><th>Kayıt</th><th>Son giriş</th><th>İndirme</th><th></th></tr></thead>
                <tbody>
                <?php foreach ($users as $u): ?>
                    <tr>
                        <td>
                            <a class="user-cell" href="?p=user&amp;id=<?= (int) $u['id'] ?>">
                                <div class="avatar"><?= e(mb_strtoupper(mb_substr((string) $u['display_name'], 0, 1))) ?></div>
                                <div><b><?= e($u['display_name']) ?></b><small><?= e($u['email']) ?></small></div>
                            </a>
                        </td>
                        <td>
                            <?php if ((int) $u['is_banned'] === 1): ?><span class="badge b-ban"><?= icon('ban') ?> ASKIDA</span>
                            <?php elseif (is_premium($u)): ?><span class="badge b-pro"><?= icon('bolt') ?> PREMIUM</span>
                                <?php if ($u['premium_until']): ?><small class="muted block"><?= e(fmt_date($u['premium_until'], 'd.m.Y')) ?>'e kadar</small><?php endif; ?>
                            <?php else: ?><span class="badge b-free">ÜCRETSİZ</span><?php endif; ?>
                        </td>
                        <td class="muted"><?= e(fmt_date($u['created_at'], 'd.m.Y')) ?></td>
                        <td class="muted"><?= e(time_ago($u['last_login_at'])) ?></td>
                        <td class="mono"><?= (int) $u['dl'] ?></td>
                        <td><div class="actions"><?= premium_form($u, $back) ?><a class="btn sm ghost" href="?p=user&amp;id=<?= (int) $u['id'] ?>"><?= icon('chevron') ?></a></div></td>
                    </tr>
                <?php endforeach; ?>
                </tbody>
            </table>
        </div>
        <?php endif; ?>

        <?php if ($pages > 1): ?>
            <div class="pager">
                <?php if ($page > 1): ?><a class="btn sm" href="<?= e($link(['page' => $page - 1])) ?>">← Önceki</a><?php endif; ?>
                <span class="muted"><?= $page ?> / <?= $pages ?></span>
                <?php if ($page < $pages): ?><a class="btn sm" href="<?= e($link(['page' => $page + 1])) ?>">Sonraki →</a><?php endif; ?>
            </div>
        <?php endif; ?>
    </div>
    <?php
    page_end();
}

function page_user(bool $isPost): void
{
    if ($isPost) {
        handle_user_action();
    }

    $id = (int) ($_GET['id'] ?? 0);
    $u = find_user_by_id($id);
    if ($u === null) {
        flash('err', 'Kullanıcı bulunamadı.');
        redirect('?p=users');
    }

    $stmt = db()->prepare('SELECT COUNT(*) FROM tokens WHERE user_id = ? AND expires_at > NOW()');
    $stmt->execute([$id]);
    $sessions = (int) $stmt->fetchColumn();

    $stmt = db()->prepare('SELECT * FROM downloads WHERE user_id = ? ORDER BY id DESC LIMIT 25');
    $stmt->execute([$id]);
    $downloads = $stmt->fetchAll();

    $stmt = db()->prepare('SELECT COUNT(*) FROM downloads WHERE user_id = ?');
    $stmt->execute([$id]);
    $dlTotal = (int) $stmt->fetchColumn();

    $back = '?p=user&id=' . $id;
    $hidden = csrf_field() . '<input type="hidden" name="id" value="' . $id . '"><input type="hidden" name="back" value="' . e($back) . '">';

    page_start($u['display_name'], 'users');
    ?>
    <p><a href="?p=users">← Kullanıcılar</a></p>
    <div class="grid g3">
        <div class="stack">
            <div class="card">
                <h2><?= icon('users') ?> Profil</h2>
                <dl class="kv">
                    <dt>Durum</dt>
                    <dd>
                        <?php if ((int) $u['is_banned'] === 1): ?><span class="badge b-ban">ASKIDA</span>
                        <?php elseif (is_premium($u)): ?><span class="badge b-pro"><?= icon('bolt') ?> PREMIUM</span> <span class="muted"><?= $u['premium_until'] ? e(fmt_date($u['premium_until'])) . "'e kadar" : 'süresiz' ?></span>
                        <?php else: ?><span class="badge b-free">ÜCRETSİZ</span><?php endif; ?>
                    </dd>
                    <dt>Kullanıcı no</dt><dd class="mono">#<?= $id ?></dd>
                    <dt>Kayıt</dt><dd><?= e(fmt_date($u['created_at'])) ?></dd>
                    <dt>Son giriş</dt><dd><?= e(fmt_date($u['last_login_at'])) ?> <span class="muted">(<?= e(time_ago($u['last_login_at'])) ?>)</span></dd>
                    <dt>Açık oturum</dt><dd><?= $sessions ?> cihaz</dd>
                    <dt>Toplam indirme</dt><dd><?= $dlTotal ?></dd>
                </dl>
                <div class="sep"></div>
                <form method="post" action="?p=user&amp;id=<?= $id ?>">
                    <?= $hidden ?><input type="hidden" name="do" value="update">
                    <div class="two">
                        <div class="field"><label for="n">İsim</label><input id="n" name="name" value="<?= e($u['display_name']) ?>" maxlength="60" required></div>
                        <div class="field"><label for="m">E-posta</label><input id="m" name="email" type="email" value="<?= e($u['email']) ?>" maxlength="190" required></div>
                    </div>
                    <button class="btn" type="submit">Kaydet</button>
                </form>
            </div>

            <div class="card">
                <h2><?= icon('download') ?> Son indirmeleri</h2>
                <div class="list">
                    <?php if (!$downloads): ?><div class="empty">İndirme yok.</div><?php endif; ?>
                    <?php foreach ($downloads as $d): ?>
                        <div class="row">
                            <img class="thumb" src="https://i.ytimg.com/vi/<?= e($d['video_id']) ?>/default.jpg" alt="" loading="lazy">
                            <div class="grow"><b><?= e($d['title'] !== '' ? $d['title'] : $d['video_id']) ?></b><small class="muted mono"><?= e($d['video_id']) ?></small></div>
                            <small class="muted"><?= e(fmt_date($d['created_at'])) ?></small>
                        </div>
                    <?php endforeach; ?>
                </div>
            </div>
        </div>

        <div class="stack">
            <div class="card">
                <h2><?= icon('bolt') ?> Premium</h2>
                <div class="actions start"><?= premium_form($u, $back) ?></div>
            </div>
            <div class="card">
                <h2><?= icon('key') ?> Hesap işlemleri</h2>
                <div class="stack sm">
                    <form method="post" action="?p=user&amp;id=<?= $id ?>" data-confirm="Kullanıcı tüm cihazlardan çıkarılsın mı?"><?= $hidden ?><input type="hidden" name="do" value="logout_all"><button class="btn full">Tüm oturumları kapat</button></form>
                    <form method="post" action="?p=user&amp;id=<?= $id ?>" data-confirm="Yeni geçici şifre oluşturulsun mu? Kullanıcı tüm cihazlardan çıkarılır."><?= $hidden ?><input type="hidden" name="do" value="reset_password"><button class="btn full">Şifre sıfırla</button></form>
                    <?php if ((int) $u['is_banned'] === 1): ?>
                        <form method="post" action="?p=user&amp;id=<?= $id ?>"><?= $hidden ?><input type="hidden" name="do" value="unban"><button class="btn full">Askıdan al</button></form>
                    <?php else: ?>
                        <form method="post" action="?p=user&amp;id=<?= $id ?>" data-confirm="Kullanıcı askıya alınsın mı?"><?= $hidden ?><input type="hidden" name="do" value="ban"><button class="btn danger full"><?= icon('ban') ?> Askıya al</button></form>
                    <?php endif; ?>
                </div>
            </div>
            <div class="card danger-zone">
                <h2><?= icon('trash') ?> Kalıcı silme</h2>
                <form method="post" action="?p=user&amp;id=<?= $id ?>">
                    <?= $hidden ?><input type="hidden" name="do" value="delete">
                    <div class="field">
                        <label for="c">Onay için e-postayı yaz</label>
                        <input id="c" name="confirm" placeholder="<?= e($u['email']) ?>" autocomplete="off">
                    </div>
                    <button class="btn danger full" type="submit">Kullanıcıyı sil</button>
                </form>
            </div>
        </div>
    </div>
    <?php
    page_end();
}

/* =====================================================================
 * İndirmeler ve işlem kaydı
 * ===================================================================== */

function page_downloads(bool $isPost): void
{
    $q = get_str('q', 100);
    $page = max(1, (int) ($_GET['page'] ?? 1));
    $per = 50;
    $params = [];
    $sql = '';
    if ($q !== '') {
        $like = '%' . addcslashes($q, '%_\\') . '%';
        $sql = ' WHERE d.title LIKE ? OR u.email LIKE ? OR d.video_id = ?';
        $params = [$like, $like, $q];
    }

    $count = db()->prepare('SELECT COUNT(*) FROM downloads d JOIN users u ON u.id = d.user_id' . $sql);
    $count->execute($params);
    $total = (int) $count->fetchColumn();
    $pages = max(1, (int) ceil($total / $per));
    $page = min($page, $pages);

    $list = db()->prepare(
        'SELECT d.*, u.email, u.id uid FROM downloads d JOIN users u ON u.id = d.user_id' . $sql
        . ' ORDER BY d.id DESC LIMIT ' . $per . ' OFFSET ' . (($page - 1) * $per)
    );
    $list->execute($params);
    $rows = $list->fetchAll();

    page_start('İndirmeler', 'downloads');
    ?>
    <div class="card">
        <form class="inline" method="get">
            <input type="hidden" name="p" value="downloads">
            <input name="q" value="<?= e($q) ?>" placeholder="Şarkı adı, e-posta veya video ID" aria-label="Ara">
            <button class="btn" type="submit"><?= icon('search') ?> Ara</button>
            <span class="muted push"><?= $total ?> kayıt</span>
        </form>
    </div>
    <div class="card mt">
        <?php if (!$rows): ?><div class="empty">Kayıt yok.</div><?php else: ?>
        <div class="table-wrap">
            <table class="table">
                <thead><tr><th>Şarkı</th><th>Kullanıcı</th><th>Tarih</th></tr></thead>
                <tbody>
                <?php foreach ($rows as $d): ?>
                    <tr>
                        <td><div class="user-cell"><img class="thumb" src="https://i.ytimg.com/vi/<?= e($d['video_id']) ?>/default.jpg" alt="" loading="lazy"><div><b><?= e($d['title'] !== '' ? $d['title'] : '—') ?></b><small class="mono"><?= e($d['video_id']) ?></small></div></div></td>
                        <td><a href="?p=user&amp;id=<?= (int) $d['uid'] ?>"><?= e($d['email']) ?></a></td>
                        <td class="muted"><?= e(fmt_date($d['created_at'])) ?></td>
                    </tr>
                <?php endforeach; ?>
                </tbody>
            </table>
        </div>
        <?php endif; ?>
        <?php if ($pages > 1): ?>
            <div class="pager">
                <?php if ($page > 1): ?><a class="btn sm" href="?p=downloads&amp;q=<?= e(urlencode($q)) ?>&amp;page=<?= $page - 1 ?>">← Önceki</a><?php endif; ?>
                <span class="muted"><?= $page ?> / <?= $pages ?></span>
                <?php if ($page < $pages): ?><a class="btn sm" href="?p=downloads&amp;q=<?= e(urlencode($q)) ?>&amp;page=<?= $page + 1 ?>">Sonraki →</a><?php endif; ?>
            </div>
        <?php endif; ?>
    </div>
    <?php
    page_end();
}

function audit_label(string $action): string
{
    return [
        'login' => 'Giriş yaptı', 'login_failed' => 'Hatalı giriş denemesi', 'logout' => 'Çıkış yaptı',
        'premium_on' => 'Premium açtı', 'premium_off' => 'Premium kapattı', 'ban' => 'Askıya aldı', 'unban' => 'Askıdan aldı',
        'user_logout_all' => 'Oturumları kapattı', 'user_update' => 'Kullanıcıyı düzenledi', 'user_password_reset' => 'Şifre sıfırladı',
        'user_delete' => 'Kullanıcı sildi', 'admin_password' => 'Şifresini değiştirdi', 'totp_on' => '2FA açtı', 'totp_off' => '2FA kapattı',
        'admin_create' => 'Admin ekledi', 'admin_delete' => 'Admin sildi', 'sessions_revoke' => 'Tüm admin oturumlarını kapattı',
        'settings' => 'Ayarları değiştirdi', 'install' => 'Kurulumu tamamladı',
    ][$action] ?? $action;
}

function page_audit(bool $isPost): void
{
    $page = max(1, (int) ($_GET['page'] ?? 1));
    $per = 50;
    $total = (int) db()->query('SELECT COUNT(*) FROM admin_audit')->fetchColumn();
    $pages = max(1, (int) ceil($total / $per));
    $page = min($page, $pages);
    $rows = db()->query('SELECT * FROM admin_audit ORDER BY id DESC LIMIT ' . $per . ' OFFSET ' . (($page - 1) * $per))->fetchAll();

    page_start('İşlem kaydı', 'audit');
    ?>
    <div class="card">
        <?php if (!$rows): ?><div class="empty">Kayıt yok.</div><?php else: ?>
        <div class="table-wrap">
            <table class="table">
                <thead><tr><th>Zaman</th><th>Admin</th><th>İşlem</th><th>Hedef</th><th>IP</th></tr></thead>
                <tbody>
                <?php foreach ($rows as $r): ?>
                    <tr>
                        <td class="muted"><?= e(fmt_date($r['created_at'], 'd.m.Y H:i:s')) ?></td>
                        <td><b><?= e($r['admin_name'] !== '' ? $r['admin_name'] : '—') ?></b></td>
                        <td><?= $r['action'] === 'login_failed' ? '<span class="badge b-ban">' . e(audit_label($r['action'])) . '</span>' : e(audit_label($r['action'])) ?><?= $r['details'] !== '' ? ' <small class="muted">· ' . e($r['details']) . '</small>' : '' ?></td>
                        <td><?= e($r['target']) ?></td>
                        <td class="mono muted"><?= e($r['ip']) ?></td>
                    </tr>
                <?php endforeach; ?>
                </tbody>
            </table>
        </div>
        <?php endif; ?>
        <?php if ($pages > 1): ?>
            <div class="pager">
                <?php if ($page > 1): ?><a class="btn sm" href="?p=audit&amp;page=<?= $page - 1 ?>">← Önceki</a><?php endif; ?>
                <span class="muted"><?= $page ?> / <?= $pages ?></span>
                <?php if ($page < $pages): ?><a class="btn sm" href="?p=audit&amp;page=<?= $page + 1 ?>">Sonraki →</a><?php endif; ?>
            </div>
        <?php endif; ?>
    </div>
    <?php
    page_end();
}

/* =====================================================================
 * Güvenlik: şifre, 2FA, adminler, oturumlar
 * ===================================================================== */

function require_password_confirm(array $admin): bool
{
    $pw = (string) ($_POST['current_password'] ?? '');
    if (!password_verify($pw, (string) $admin['password_hash'])) {
        record_failed_login((string) $admin['username']);
        flash('err', 'Mevcut şifren hatalı.');
        return false;
    }
    return true;
}

function page_security(bool $isPost): void
{
    $admin = current_admin();
    $id = (int) $admin['id'];

    if ($isPost) {
        $do = post_str('do', 30);

        if ($do === 'totp_start') {
            $_SESSION['totp_setup'] = totp_new_secret();
            redirect('?p=security#totp');
        }

        if ($do === 'totp_confirm') {
            $secret = (string) ($_SESSION['totp_setup'] ?? '');
            $step = $secret !== '' ? totp_verify($secret, post_str('code', 12)) : null;
            if ($step === null) {
                flash('err', 'Kod doğrulanamadı. Telefonunun saatinin doğru olduğundan emin ol.');
            } else {
                db()->prepare('UPDATE admins SET totp_secret = ?, totp_enabled = 1, totp_last_step = ? WHERE id = ?')->execute([$secret, $step, $id]);
                unset($_SESSION['totp_setup']);
                audit('totp_on');
                flash('ok', 'İki adımlı doğrulama açıldı.');
            }
            redirect('?p=security');
        }

        if ($do === 'totp_off' && require_password_confirm($admin)) {
            db()->prepare('UPDATE admins SET totp_secret = NULL, totp_enabled = 0, totp_last_step = 0 WHERE id = ?')->execute([$id]);
            audit('totp_off');
            flash('ok', 'İki adımlı doğrulama kapatıldı.');
        }

        if ($do === 'password' && require_password_confirm($admin)) {
            $new = (string) ($_POST['new_password'] ?? '');
            if ($new !== (string) ($_POST['new_password2'] ?? '')) {
                flash('err', 'Yeni şifreler eşleşmiyor.');
            } elseif ($problem = password_problem($new)) {
                flash('err', $problem);
            } else {
                db()->prepare('UPDATE admins SET password_hash = ?, session_version = session_version + 1 WHERE id = ?')
                    ->execute([hash_admin_password($new), $id]);
                audit('admin_password');
                $_SESSION['session_version'] = (int) $admin['session_version'] + 1;
                flash('ok', 'Şifren değişti. Diğer cihazlardaki oturumların kapatıldı.');
            }
        }

        if ($do === 'revoke' && require_password_confirm($admin)) {
            db()->prepare('UPDATE admins SET session_version = session_version + 1 WHERE id = ?')->execute([$id]);
            audit('sessions_revoke');
            $_SESSION['session_version'] = (int) $admin['session_version'] + 1;
            flash('ok', 'Diğer tüm cihazlardaki oturumların kapatıldı.');
        }

        if ($do === 'admin_create' && require_password_confirm($admin)) {
            $name = mb_strtolower(post_str('username', 60));
            $pw = (string) ($_POST['password'] ?? '');
            if (!preg_match('/^[a-z0-9._-]{3,60}$/', $name)) {
                flash('err', 'Kullanıcı adı 3-60 karakter; harf, rakam, nokta, tire olabilir.');
            } elseif ($problem = password_problem($pw)) {
                flash('err', $problem);
            } else {
                try {
                    db()->prepare('INSERT INTO admins (username, password_hash) VALUES (?, ?)')->execute([$name, hash_admin_password($pw)]);
                    audit('admin_create', $name);
                    flash('ok', $name . ' admin olarak eklendi.');
                } catch (PDOException $ex) {
                    flash('err', 'Bu kullanıcı adı zaten var.');
                }
            }
        }

        if ($do === 'admin_delete' && require_password_confirm($admin)) {
            $target = (int) ($_POST['id'] ?? 0);
            if ($target === $id) {
                flash('err', 'Kendi hesabını silemezsin.');
            } else {
                $stmt = db()->prepare('SELECT username FROM admins WHERE id = ?');
                $stmt->execute([$target]);
                $name = (string) $stmt->fetchColumn();
                db()->prepare('DELETE FROM admins WHERE id = ?')->execute([$target]);
                audit('admin_delete', $name);
                flash('ok', $name . ' silindi.');
            }
        }

        redirect('?p=security');
    }

    $admins = db()->query('SELECT id, username, totp_enabled, last_login_at, last_login_ip, created_at FROM admins ORDER BY id')->fetchAll();
    $setup = $_SESSION['totp_setup'] ?? null;
    $confirmField = '<div class="field"><label>Mevcut şifren</label><input name="current_password" type="password" autocomplete="current-password" required></div>';

    page_start('Güvenlik', 'security');
    ?>
    <div class="grid g2">
        <div class="stack">
            <div class="card" id="totp">
                <h2><?= icon('shield') ?> İki adımlı doğrulama (2FA)</h2>
                <?php if ((int) $admin['totp_enabled'] === 1): ?>
                    <p><span class="badge b-ok">AÇIK</span> Girişte doğrulama uygulamandaki kod da isteniyor.</p>
                    <form method="post" action="?p=security" data-confirm="2FA kapatılsın mı? Hesabın daha az güvenli olur.">
                        <?= csrf_field() ?><input type="hidden" name="do" value="totp_off">
                        <?= $confirmField ?>
                        <button class="btn danger">2FA'yı kapat</button>
                    </form>
                <?php elseif (is_string($setup)): ?>
                    <p class="muted">Google Authenticator, Authy ya da 1Password ile QR kodu okut, sonra uygulamanın gösterdiği 6 haneli kodu gir.</p>
                    <div id="qr" class="qr" data-uri="<?= e(totp_uri($setup, (string) $admin['username'])) ?>"></div>
                    <p class="hint">QR okutamıyorsan bu anahtarı elle gir:</p>
                    <div class="secret"><?= e(trim(chunk_split($setup, 4, ' '))) ?></div>
                    <form method="post" action="?p=security" class="mt">
                        <?= csrf_field() ?><input type="hidden" name="do" value="totp_confirm">
                        <div class="field"><input class="code-input" name="code" inputmode="numeric" maxlength="7" autocomplete="one-time-code" placeholder="000000" required></div>
                        <button class="btn primary full">Doğrula ve aç</button>
                    </form>
                    <script nonce="<?= e(csp_nonce()) ?>" src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
                <?php else: ?>
                    <p><span class="badge b-warn">KAPALI</span> Şifren çalınsa bile hesabına girilemesin diye 2FA'yı aç.</p>
                    <form method="post" action="?p=security"><?= csrf_field() ?><input type="hidden" name="do" value="totp_start"><button class="btn primary"><?= icon('shield') ?> 2FA kur</button></form>
                <?php endif; ?>
            </div>

            <div class="card">
                <h2><?= icon('key') ?> Şifre değiştir</h2>
                <form method="post" action="?p=security">
                    <?= csrf_field() ?><input type="hidden" name="do" value="password">
                    <?= $confirmField ?>
                    <div class="two">
                        <div class="field"><label>Yeni şifre</label><input name="new_password" type="password" autocomplete="new-password" minlength="12" required></div>
                        <div class="field"><label>Yeni şifre (tekrar)</label><input name="new_password2" type="password" autocomplete="new-password" minlength="12" required></div>
                    </div>
                    <p class="hint">En az 12 karakter; büyük harf, küçük harf ve rakam içermeli.</p>
                    <button class="btn">Şifreyi değiştir</button>
                </form>
            </div>

            <div class="card">
                <h2><?= icon('logout') ?> Diğer oturumlar</h2>
                <p class="muted">Bu cihaz dışındaki tüm admin oturumlarını anında kapatır.</p>
                <form method="post" action="?p=security">
                    <?= csrf_field() ?><input type="hidden" name="do" value="revoke">
                    <?= $confirmField ?>
                    <button class="btn">Diğer oturumları kapat</button>
                </form>
            </div>
        </div>

        <div class="stack">
            <div class="card">
                <h2><?= icon('users') ?> Adminler</h2>
                <div class="list">
                    <?php foreach ($admins as $a): ?>
                        <div class="row">
                            <div class="avatar sm"><?= e(mb_strtoupper(mb_substr((string) $a['username'], 0, 1))) ?></div>
                            <div class="grow"><b><?= e($a['username']) ?><?= (int) $a['id'] === $id ? ' <small class="muted">(sen)</small>' : '' ?></b>
                                <small class="muted">Son giriş: <?= e(time_ago($a['last_login_at'])) ?><?= $a['last_login_ip'] ? ' · ' . e($a['last_login_ip']) : '' ?></small></div>
                            <?= (int) $a['totp_enabled'] === 1 ? '<span class="badge b-ok">2FA</span>' : '<span class="badge b-warn">2FA YOK</span>' ?>
                        </div>
                    <?php endforeach; ?>
                </div>
                <div class="sep"></div>
                <form method="post" action="?p=security">
                    <?= csrf_field() ?><input type="hidden" name="do" value="admin_create">
                    <div class="two">
                        <div class="field"><label>Yeni admin kullanıcı adı</label><input name="username" autocomplete="off" autocapitalize="none" required></div>
                        <div class="field"><label>Şifresi</label><input name="password" type="password" autocomplete="new-password" minlength="12" required></div>
                    </div>
                    <?= $confirmField ?>
                    <button class="btn">Admin ekle</button>
                </form>
                <?php if (count($admins) > 1): ?>
                    <div class="sep"></div>
                    <form method="post" action="?p=security" data-confirm="Seçilen admin silinsin mi?">
                        <?= csrf_field() ?><input type="hidden" name="do" value="admin_delete">
                        <div class="field"><label>Admin sil</label>
                            <select name="id"><?php foreach ($admins as $a): if ((int) $a['id'] === $id) continue; ?><option value="<?= (int) $a['id'] ?>"><?= e($a['username']) ?></option><?php endforeach; ?></select>
                        </div>
                        <?= $confirmField ?>
                        <button class="btn danger">Sil</button>
                    </form>
                <?php endif; ?>
            </div>

            <div class="card">
                <h2><?= icon('shield') ?> Aktif korumalar</h2>
                <div class="health">
                    <div><span>Şifreleme</span><span class="badge b-ok"><?= defined('PASSWORD_ARGON2ID') ? 'ARGON2ID' : 'BCRYPT' ?></span></div>
                    <div><span>Kaba kuvvet kilidi</span><span class="badge b-ok">15 DK</span></div>
                    <div><span>CSRF + köken kontrolü</span><span class="badge b-ok">AÇIK</span></div>
                    <div><span>Oturum zaman aşımı</span><span class="badge b-ok">30 DK / 12 SA</span></div>
                    <div><span>CSP / clickjacking koruması</span><span class="badge b-ok">AÇIK</span></div>
                    <div><span>İşlem kaydı</span><span class="badge b-ok">AÇIK</span></div>
                </div>
            </div>
        </div>
    </div>
    <?php
    page_end();
}

/* =====================================================================
 * Ayarlar
 * ===================================================================== */

function mask_secret(string $value): string
{
    if ($value === '') return 'tanımlı değil';
    return str_repeat('•', 8) . mb_substr($value, -4);
}

function page_settings(bool $isPost): void
{
    require_once __DIR__ . '/../box-api/config_writer.php';
    $admin = current_admin();
    $cfg = box_current_config();

    if ($isPost) {
        if (require_password_confirm($admin)) {
            $new = $cfg;
            $changed = [];

            $yt = post_str('yt_key', 200);
            if ($yt !== '') { $new['YT_DATA_API_KEY'] = $yt; $changed[] = 'YouTube anahtarı'; }

            $sign = post_str('vds_key', 300);
            if ($sign !== '') { $new['VDS_SIGNING_KEY'] = $sign; $changed[] = 'imza anahtarı'; }

            $url = rtrim(post_str('vds_url', 200), '/');
            if ($url !== '' && $url !== $cfg['VDS_BASE_URL']) {
                if (!preg_match('#^https://[a-z0-9.-]+(:\d+)?$#i', $url)) {
                    flash('err', 'VDS adresi https:// ile başlayan bir alan adı olmalı.');
                    redirect('?p=settings');
                }
                $new['VDS_BASE_URL'] = $url;
                $changed[] = 'VDS adresi';
            }

            foreach (['TOKEN_TTL_DAYS' => [1, 3650, 'oturum süresi'], 'DOWNLOAD_LINK_TTL' => [60, 3600, 'link süresi'], 'CACHE_TIME' => [60, 86400, 'önbellek süresi']] as $key => [$min, $max, $label]) {
                $v = (int) ($_POST[strtolower($key)] ?? $cfg[$key]);
                $v = max($min, min($max, $v));
                if ($v !== (int) $cfg[$key]) { $new[$key] = $v; $changed[] = $label; }
            }

            if ($changed) {
                try {
                    box_write_config($new);
                    audit('settings', '', implode(', ', $changed));
                    flash('ok', 'Kaydedildi: ' . implode(', ', $changed) . '.');
                } catch (Throwable $ex) {
                    flash('err', $ex->getMessage());
                }
            } else {
                flash('warn', 'Değişiklik yok.');
            }
        }
        redirect('?p=settings');
    }

    page_start('Ayarlar', 'settings');
    ?>
    <form method="post" action="?p=settings" class="grid g2">
        <?= csrf_field() ?>
        <div class="card">
            <h2><?= icon('search') ?> YouTube arama</h2>
            <div class="field">
                <label>YouTube Data API v3 anahtarı</label>
                <input name="yt_key" autocomplete="off" placeholder="Değiştirmek için yeni anahtarı yaz">
                <p class="hint">Şu an: <span class="mono"><?= e(mask_secret((string) $cfg['YT_DATA_API_KEY'])) ?></span></p>
            </div>
            <div class="field">
                <label>Arama önbelleği (saniye)</label>
                <input name="cache_time" type="number" min="60" max="86400" value="<?= (int) $cfg['CACHE_TIME'] ?>">
            </div>
        </div>
        <div class="card">
            <h2><?= icon('server') ?> VDS indirme servisi</h2>
            <div class="field">
                <label>VDS adresi</label>
                <input name="vds_url" value="<?= e((string) $cfg['VDS_BASE_URL']) ?>" placeholder="https://yt2.aydworks.com.tr">
            </div>
            <div class="field">
                <label>İmza anahtarı (VDS'deki YT_API_KEY)</label>
                <input name="vds_key" autocomplete="off" placeholder="Değiştirmek için yeni anahtarı yaz">
                <p class="hint">Şu an: <span class="mono"><?= e(mask_secret((string) $cfg['VDS_SIGNING_KEY'])) ?></span></p>
            </div>
            <div class="field">
                <label>İndirme linki geçerlilik süresi (saniye)</label>
                <input name="download_link_ttl" type="number" min="60" max="3600" value="<?= (int) $cfg['DOWNLOAD_LINK_TTL'] ?>">
            </div>
        </div>
        <div class="card">
            <h2><?= icon('users') ?> Uygulama oturumları</h2>
            <div class="field">
                <label>Uygulamada oturum süresi (gün)</label>
                <input name="token_ttl_days" type="number" min="1" max="3650" value="<?= (int) $cfg['TOKEN_TTL_DAYS'] ?>">
                <p class="hint">Yalnızca bundan sonra açılan oturumları etkiler.</p>
            </div>
        </div>
        <div class="card">
            <h2><?= icon('key') ?> Kaydet</h2>
            <?= str_replace('<label>', '<label>', '<div class="field"><label>Mevcut şifren</label><input name="current_password" type="password" autocomplete="current-password" required></div>') ?>
            <button class="btn primary full" type="submit">Ayarları kaydet</button>
            <p class="hint">Veritabanı bilgileri güvenlik için buradan değiştirilemez.</p>
        </div>
    </form>
    <?php
    page_end();
}
