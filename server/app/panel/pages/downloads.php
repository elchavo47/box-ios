<?php
if (!defined('ROOT')) { http_response_code(404); exit; }
$search = mb_substr(trim((string)($_GET['q'] ?? '')), 0, 80);
$where = '1=1'; $args = [];
if ($search !== '') { $like = '%' . addcslashes($search, '%_\\') . '%'; $where = '(d.title LIKE ? OR d.video_id=? OR u.email LIKE ?)'; $args = [$like, $search, $like]; }
$top = q('SELECT video_id,MAX(title) title,COUNT(*) c,COUNT(DISTINCT user_id) users FROM downloads WHERE created_at>=DATE_SUB(NOW(),INTERVAL 30 DAY) GROUP BY video_id ORDER BY c DESC LIMIT 10')->fetchAll();
$rows = q("SELECT d.*,u.display_name,u.email,u.avatar_file FROM downloads d JOIN users u ON u.id=d.user_id WHERE $where ORDER BY d.id DESC LIMIT 200", $args)->fetchAll();
$hours = array_fill(0, 24, 0);
foreach (q('SELECT HOUR(created_at) h,COUNT(*) c FROM downloads WHERE created_at>=DATE_SUB(NOW(),INTERVAL 7 DAY) GROUP BY HOUR(created_at)')->fetchAll() as $r) $hours[(int)$r['h']] = (int)$r['c'];
$hp = []; foreach ($hours as $h => $c) $hp[] = ['label' => sprintf('%02d', $h), 'value' => $c];
?>
<div class="cols-2">
  <?php card('En çok indirilen', 'Son 30 gün');
  $rank = 0;
  tableView([['#', 'num'], 'Şarkı', ['İndirme', 'num']], $top, function ($r) use (&$rank) {
      echo '<td class="num rank r' . (++$rank) . '">' . $rank . '</td><td><a class="track" href="https://www.youtube.com/watch?v=' . h($r['video_id']) . '" target="_blank" rel="noopener noreferrer"><img src="https://i.ytimg.com/vi/' . h($r['video_id']) . '/default.jpg" alt="" loading="lazy"><b>' . h($r['title'] ?: $r['video_id']) . '</b></a></td><td class="num strong">' . nbNum($r['c']) . '<small class="block muted">' . nbNum($r['users']) . ' kişi</small></td>';
  }, 'Henüz indirme yok.');
  cardEnd(); ?>
  <?php card('Günün saatlerine göre', 'Son 7 gün'); echo barChart($hp, 'indirme', true); cardEnd(); ?>
</div>
<form method="get" class="toolbar">
  <input type="hidden" name="p" value="downloads">
  <label class="search-field"><?=icon('search')?><input class="input" name="q" value="<?=h($search)?>" placeholder="Şarkı adı, video kimliği ya da e-posta" aria-label="İndirme ara"></label>
  <?=button('Ara', 'ghost')?>
</form>
<?php card('Son indirmeler', 'En fazla 200 kayıt');
tableView(['Şarkı', 'Kullanıcı', 'Zaman'], $rows, function ($r) {
    echo '<td><a class="track" href="https://www.youtube.com/watch?v=' . h($r['video_id']) . '" target="_blank" rel="noopener noreferrer"><img src="https://i.ytimg.com/vi/' . h($r['video_id']) . '/default.jpg" alt="" loading="lazy"><b>' . h($r['title'] !== '' ? $r['title'] : $r['video_id']) . '</b></a></td><td>' . userCell($r, (int)$r['user_id']) . '</td><td class="nowrap">' . h(nbDate($r['created_at'])) . '</td>';
}, $search !== '' ? 'Eşleşen indirme yok.' : 'Henüz indirme yok.');
cardEnd();
