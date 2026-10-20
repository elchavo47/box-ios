<?php
if (!defined('ROOT')) { http_response_code(404); exit; }
$one = fn(string $sql, array $args = []): int => (int)q($sql, $args)->fetchColumn();
$days = 30;
$series = function (string $sql) use ($days): array {
    $map = array_column(q($sql)->fetchAll(), 'c', 'd');
    $out = [];
    for ($i = $days - 1; $i >= 0; $i--) { $d = date('Y-m-d', strtotime("-$i days")); $out[] = ['label' => date('d.m', strtotime($d)), 'value' => (int)($map[$d] ?? 0)]; }
    return $out;
};
$active = $series("SELECT DATE(last_seen_at) d,COUNT(*) c FROM users WHERE last_seen_at>=DATE_SUB(CURDATE(),INTERVAL $days DAY) GROUP BY DATE(last_seen_at)");
$dl = $series("SELECT DATE(created_at) d,COUNT(*) c FROM downloads WHERE created_at>=DATE_SUB(CURDATE(),INTERVAL $days DAY) GROUP BY DATE(created_at)");
$search = $series("SELECT day d,SUM(n) c FROM search_log WHERE day>=DATE_SUB(CURDATE(),INTERVAL $days DAY) GROUP BY day");
$k = [
    'wau' => $one('SELECT COUNT(*) FROM users WHERE last_seen_at>=DATE_SUB(NOW(),INTERVAL 7 DAY)'),
    'mau' => $one('SELECT COUNT(*) FROM users WHERE last_seen_at>=DATE_SUB(NOW(),INTERVAL 30 DAY)'),
    'dl30' => $one('SELECT COUNT(*) FROM downloads WHERE created_at>=DATE_SUB(NOW(),INTERVAL 30 DAY)'),
    'se30' => $one('SELECT COALESCE(SUM(n),0) FROM search_log WHERE day>=DATE_SUB(CURDATE(),INTERVAL 30 DAY)'),
];
$terms = q('SELECT term,SUM(n) c FROM search_terms WHERE day>=DATE_SUB(CURDATE(),INTERVAL 30 DAY) GROUP BY term ORDER BY c DESC LIMIT 15')->fetchAll();
$topUsers = q('SELECT u.id,u.display_name,u.email,u.avatar_file,COUNT(*) c FROM downloads d JOIN users u ON u.id=d.user_id WHERE d.created_at>=DATE_SUB(NOW(),INTERVAL 30 DAY) GROUP BY u.id ORDER BY c DESC LIMIT 10')->fetchAll();
$versions = q("SELECT COALESCE(NULLIF(app_version,''),'?') v,COUNT(*) c FROM users WHERE last_seen_at>=DATE_SUB(NOW(),INTERVAL 30 DAY) GROUP BY v ORDER BY c DESC LIMIT 8")->fetchAll();
?>
<section class="kpis">
  <?=kpi('Haftalık aktif', nbNum($k['wau']), 'Son 7 gün')?>
  <?=kpi('Aylık aktif', nbNum($k['mau']), 'Son 30 gün')?>
  <?=kpi('İndirme (30 gün)', nbNum($k['dl30']), 'Günde ort. ' . nbNum($k['dl30'] / 30, 1))?>
  <?=kpi('Arama (30 gün)', nbNum($k['se30']), 'Günde ort. ' . nbNum($k['se30'] / 30, 1))?>
</section>
<div class="cols-2">
  <?php card('Günlük aktif kullanıcı', 'Son 30 gün'); echo barChart($active, 'kullanıcı'); cardEnd(); ?>
  <?php card('Günlük indirme', 'Son 30 gün'); echo barChart($dl, 'indirme', true); cardEnd(); ?>
</div>
<div class="cols-2">
  <?php card('En çok aranan', 'Son 30 gün');
  $rank = 0;
  tableView([['#', 'num'], 'Arama', ['Sayı', 'num']], $terms, function ($r) use (&$rank) {
      echo '<td class="num rank r' . (++$rank) . '">' . $rank . '</td><td>' . h($r['term']) . '</td><td class="num strong">' . nbNum($r['c']) . '</td>';
  }, 'Henüz arama kaydı yok (2.6 backend ile birlikte toplanmaya başlar).');
  cardEnd(); ?>
  <?php card('Günlük arama', 'Son 30 gün'); echo barChart($search, 'arama'); cardEnd(); ?>
</div>
<div class="cols-2">
  <?php card('En çok indirenler', 'Son 30 gün');
  tableView(['Kullanıcı', ['İndirme', 'num']], $topUsers, function ($u) {
      echo '<td>' . userCell($u, (int)$u['id']) . '</td><td class="num strong">' . nbNum($u['c']) . '</td>';
  }, 'Henüz indirme yok.');
  cardEnd(); ?>
  <?php card('Uygulama sürümleri', 'Son 30 günde görülen');
  tableView(['Sürüm', ['Kullanıcı', 'num']], $versions, function ($v) {
      echo '<td>' . h($v['v']) . '</td><td class="num strong">' . nbNum($v['c']) . '</td>';
  }, 'Veri yok.');
  cardEnd(); ?>
</div>
