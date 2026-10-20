<?php
if (!defined('ROOT')) { http_response_code(404); exit; }
$v = (string)($_GET['v'] ?? 'active');
$prem = "is_premium=1 AND (premium_until IS NULL OR premium_until>NOW())";
$one = fn(string $sql) => (int)q($sql)->fetchColumn();
$k = [
    'active' => $one("SELECT COUNT(*) FROM users WHERE $prem"),
    'forever' => $one('SELECT COUNT(*) FROM users WHERE is_premium=1 AND premium_until IS NULL'),
    'expiring' => $one('SELECT COUNT(*) FROM users WHERE is_premium=1 AND premium_until BETWEEN NOW() AND DATE_ADD(NOW(),INTERVAL 7 DAY)'),
    'month' => $one("SELECT COUNT(*) FROM premium_log WHERE action IN ('grant','trial') AND created_at>=DATE_SUB(NOW(),INTERVAL 30 DAY)"),
];
?>
<section class="kpis">
  <?=kpi('Aktif premium', nbNum($k['active']), nbNum($k['forever']) . ' tanesi süresiz', 'good')?>
  <?=kpi('7 gün içinde bitecek', nbNum($k['expiring']), 'Süre eklemek için kullanıcıyı aç', $k['expiring'] ? 'warn' : '')?>
  <?=kpi('Son 30 günde açılan', nbNum($k['month']))?>
</section>
<?php if (can('premium_grant')): card('Hızlı premium', 'E-posta ya da kullanıcı numarasıyla bul, aç.'); ?>
<form method="get" class="toolbar"><input type="hidden" name="p" value="users"><input type="hidden" name="status" value="free"><label class="search-field"><?=icon('search')?><input class="input" name="q" placeholder="E-posta ya da numara" aria-label="Kullanıcı ara"></label><?=button('Bul', 'primary')?></form>
<?php cardEnd(); endif ?>
<div class="seg tabs-seg" role="tablist">
  <?php foreach (['active' => 'Aktif üyeler', 'expiring' => 'Bitmek üzere', 'log' => 'Geçmiş'] as $key => $label): ?><a class="<?=$v === $key ? 'on' : ''?>" href="/admin?p=premium&amp;v=<?=$key?>"><?=h($label)?></a><?php endforeach ?>
</div>
<?php
if ($v === 'log') {
    $labels = ['grant' => 'Açıldı', 'extend' => 'Uzatıldı', 'revoke' => 'Kapatıldı', 'trial' => 'Deneme', 'expire' => 'Süresi doldu'];
    $rows = q('SELECT p.*,u.display_name,u.email,u.avatar_file,a.username admin_name FROM premium_log p LEFT JOIN users u ON u.id=p.user_id LEFT JOIN admins a ON a.id=p.admin_id ORDER BY p.id DESC LIMIT 150')->fetchAll();
    card('Premium geçmişi', 'Son 150 işlem');
    tableView(['Kullanıcı', 'İşlem', 'Bitiş', 'Kim', 'Zaman'], $rows, function ($r) use ($labels) {
        echo '<td>' . ($r['email'] ? userCell($r, (int)$r['user_id']) : '<span class="muted">Silinmiş hesap</span>') . '</td><td>' . pill($labels[$r['action']] ?? $r['action'], in_array($r['action'], ['revoke', 'expire'], true) ? 'neutral' : 'good') . ($r['days'] ? ' <small class="muted">' . (int)$r['days'] . ' gün</small>' : '') . '</td><td>' . h($r['until_at'] ? nbDate($r['until_at'], 'd.m.Y') : '—') . '</td><td>' . h($r['admin_name'] ?? 'Sistem') . '</td><td class="nowrap">' . h(nbAgo($r['created_at'])) . '</td>';
    }, 'Henüz premium işlemi yok.');
    cardEnd();
} else {
    $w = $v === 'expiring' ? 'is_premium=1 AND premium_until BETWEEN NOW() AND DATE_ADD(NOW(),INTERVAL 7 DAY)' : $prem;
    $rows = q("SELECT id,display_name,email,avatar_file,is_premium,premium_until,premium_since,last_seen_at FROM users WHERE $w ORDER BY premium_until IS NULL, premium_until ASC LIMIT 300")->fetchAll();
    card(nbNum(count($rows)) . ' kullanıcı');
    tableView(['Kullanıcı', 'Başlangıç', 'Bitiş', 'Son görülme', ''], $rows, function ($u) {
        $left = $u['premium_until'] ? strtotime((string)$u['premium_until']) - time() : null;
        echo '<td>' . userCell($u, (int)$u['id']) . '</td><td>' . h(nbDate($u['premium_since'], 'd.m.Y')) . '</td><td>' . ($left === null ? pill('Süresiz', 'good') : h(nbDate($u['premium_until'], 'd.m.Y')) . '<small class="block ' . ($left < 3 * 86400 ? 'neg' : 'muted') . '">' . h(nbRemaining($left)) . ' kaldı</small>') . '</td><td class="nowrap">' . h(nbAgo($u['last_seen_at'])) . '</td><td class="end"><a class="btn small ghost" href="/admin?p=player&amp;id=' . (int)$u['id'] . '">Aç</a></td>';
    }, $v === 'expiring' ? 'Önümüzdeki 7 günde biten üyelik yok.' : 'Henüz premium üye yok.');
    cardEnd();
}
