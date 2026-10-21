<?php
if (!defined('ROOT')) { http_response_code(404); exit; }
$search = mb_substr(trim((string)($_GET['q'] ?? '')), 0, 80);
$status = (string)($_GET['status'] ?? '');
$sort = (string)($_GET['sort'] ?? 'new');
$prem = "(is_premium=1 AND (premium_until IS NULL OR premium_until>NOW()))";
$where = ['1=1']; $args = [];
if ($search !== '') {
    $like = '%' . addcslashes($search, '%_\\') . '%';
    $where[] = '(display_name LIKE ? OR email LIKE ? OR id=?)';
    array_push($args, $like, $like, ctype_digit($search) ? (int)$search : 0);
}
$filters = ['premium' => $prem, 'free' => "NOT $prem AND is_banned=0", 'banned' => 'is_banned=1', 'idle' => '(last_seen_at IS NULL OR last_seen_at<DATE_SUB(NOW(),INTERVAL 30 DAY))'];
if (isset($filters[$status])) $where[] = $filters[$status];
$orders = ['new' => 'id DESC', 'seen' => 'last_seen_at IS NULL, last_seen_at DESC', 'dl' => 'dl DESC', 'name' => 'display_name ASC'];
$sql = ' WHERE ' . implode(' AND ', $where);
$total = (int)q('SELECT COUNT(*) FROM users' . $sql, $args)->fetchColumn();
$per = 30; $pn = max(1, (int)($_GET['n'] ?? 1)); $offset = ($pn - 1) * $per;
$rows = q('SELECT id,display_name,email,avatar_file,is_premium,premium_until,is_banned,ban_reason,app_version,created_at,last_seen_at,(SELECT COUNT(*) FROM downloads d WHERE d.user_id=users.id) dl FROM users' . $sql . ' ORDER BY ' . ($orders[$sort] ?? $orders['new']) . " LIMIT $per OFFSET $offset", $args)->fetchAll();
$counts = [];
foreach ($filters as $k => $w) $counts[$k] = (int)q("SELECT COUNT(*) FROM users WHERE $w")->fetchColumn();
$qs = fn(array $over) => h(http_build_query(array_filter(array_merge(['p' => 'users', 'q' => $search, 'status' => $status, 'sort' => $sort, 'n' => $pn], $over), fn($v) => $v !== '' && $v !== null)));
?>
<form method="get" class="toolbar">
  <input type="hidden" name="p" value="users">
  <label class="search-field"><?=icon('search')?><input class="input" name="q" value="<?=h($search)?>" placeholder="İsim, e-posta ya da numara" aria-label="Kullanıcı ara"></label>
  <div class="seg" role="group" aria-label="Durum">
    <?php foreach (['' => 'Tümü', 'premium' => 'Premium', 'free' => 'Ücretsiz', 'banned' => 'Askıda', 'idle' => '30 gündür yok'] as $k => $v): ?>
    <a class="<?=$status === $k ? 'on' : ''?>" href="/admin?<?=$qs(['status' => $k, 'n' => 1])?>"><?=h($v)?><?php if ($k !== ''): ?><em><?=nbNum($counts[$k])?></em><?php endif ?></a>
    <?php endforeach ?>
  </div>
  <?php selectField('Sırala', 'sort', ['new' => 'En yeni', 'seen' => 'Son görülme', 'dl' => 'En çok indiren', 'name' => 'İsim'], $sort); ?>
  <input type="hidden" name="status" value="<?=h($status)?>">
  <?=button('Uygula', 'ghost')?>
</form>
<?php
card(nbNum($total) . ' kullanıcı', $search !== '' ? '"' . $search . '" araması' : '');
tableView(['Kullanıcı', 'Üyelik', ['İndirme', 'num'], 'Sürüm', 'Son görülme', ''], $rows, function ($u) {
    $p = boxIsPremium($u);
    echo '<td>' . userCell($u, (int)$u['id'], $u['email'] . ' · #' . $u['id']) . '</td>';
    $st = !$p ? boxStoreEntitlement($u) : null;
    $sub = $p ? ($u['premium_until'] ? nbDate($u['premium_until'], 'd.m.Y') . ' tarihine kadar' : 'Süresiz') : ($st ? 'App Store · ' . ($st['expires_at'] ? nbDate($st['expires_at'], 'd.m.Y') . ' tarihine kadar' : 'ömür boyu') : '');
    echo '<td>' . ((int)$u['is_banned'] ? pill('Askıda', 'bad') : statusPill($p || $st ? 'premium' : 'free')) . ($sub !== '' ? '<small class="muted block">' . h($sub) . '</small>' : '') . '</td>';
    echo '<td class="num">' . nbNum($u['dl']) . '</td><td>' . h($u['app_version'] ?: '—') . '</td><td class="nowrap">' . h(nbAgo($u['last_seen_at'])) . '</td>';
    echo '<td class="end"><a class="btn small ghost" href="/admin?p=player&amp;id=' . (int)$u['id'] . '">Aç</a></td>';
}, $search !== '' ? 'Bu aramayla eşleşen kullanıcı yok.' : 'Henüz kullanıcı yok. Uygulamadan ilk hesap açıldığında burada görünür.');
?>
<nav class="pager">
  <span><?=nbNum(min($total, $offset + 1))?>–<?=nbNum(min($total, $offset + $per))?> / <?=nbNum($total)?></span>
  <?php if ($pn > 1): ?><a class="btn small ghost" href="/admin?<?=$qs(['n' => $pn - 1])?>"><?=icon('back')?> Önceki</a><?php endif ?>
  <?php if ($offset + $per < $total): ?><a class="btn small ghost" href="/admin?<?=$qs(['n' => $pn + 1])?>">Sonraki <?=icon('arrow')?></a><?php endif ?>
</nav>
<?php cardEnd(); ?>
