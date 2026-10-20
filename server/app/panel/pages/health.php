<?php
if (!defined('ROOT')) { http_response_code(404); exit; }

$hours = (int)($_GET['h'] ?? 24); if (!in_array($hours, [6, 24, 168], true)) $hours = 24;
$step = $hours <= 6 ? 15 : ($hours <= 24 ? 60 : 360); 
$rows = q("SELECT FLOOR(UNIX_TIMESTAMP(bucket)/(?*60)) k, MIN(bucket) t, SUM(requests) r, SUM(client_errors) c, SUM(server_errors) s, SUM(total_ms) ms, MAX(max_ms) mx FROM api_metrics WHERE bucket>=DATE_SUB(NOW(),INTERVAL ? HOUR) GROUP BY k ORDER BY k", [$step, $hours])->fetchAll();
$tot = q("SELECT COALESCE(SUM(requests),0) r, COALESCE(SUM(client_errors),0) c, COALESCE(SUM(server_errors),0) s, COALESCE(SUM(total_ms),0) ms, COALESCE(MAX(max_ms),0) mx FROM api_metrics WHERE bucket>=DATE_SUB(NOW(),INTERVAL ? HOUR)", [$hours])->fetch();
$last = q("SELECT COALESCE(SUM(requests),0) r, COALESCE(SUM(server_errors),0) s, COALESCE(SUM(total_ms),0) ms FROM api_metrics WHERE bucket>=DATE_SUB(NOW(),INTERVAL 15 MINUTE)")->fetch();
$avg = $tot['r'] ? $tot['ms'] / $tot['r'] : 0; $lastAvg = $last['r'] ? $last['ms'] / $last['r'] : 0;
$errRate = $tot['r'] ? $tot['s'] / $tot['r'] * 100 : 0;
$label = fn(string $t) => $hours > 24 ? date('d.m H', strtotime($t)) : date('H:i', strtotime($t));
$reqChart = []; $msChart = []; $errChart = [];
foreach ($rows as $r) {
    $reqChart[] = ['label' => $label($r['t']), 'value' => (int)$r['r']];
    $msChart[] = ['label' => $label($r['t']), 'value' => $r['r'] ? (int)round($r['ms'] / $r['r']) : 0];
    $errChart[] = ['label' => $label($r['t']), 'value' => (int)$r['s']];
}
$state = $errRate >= 2 || $lastAvg >= 1500 ? ['Sorun var', 'bad'] : ($errRate >= 0.5 || $lastAvg >= 700 ? ['Yavaş', 'warn'] : ['Sağlıklı', 'good']);
?>
<div class="seg" role="group" aria-label="Zaman aralığı">
  <?php foreach ([6 => 'Son 6 saat', 24 => 'Son 24 saat', 168 => 'Son 7 gün'] as $k => $v): ?><a class="<?=$hours === $k ? 'on' : ''?>" href="/admin?p=health&amp;h=<?=$k?>"><?=h($v)?></a><?php endforeach ?>
</div>
<section class="kpis">
  <?=kpi('Durum', $state[0], 'Son 15 dk ort. ' . nbNum($lastAvg) . ' ms', $state[1])?>
  <?=kpi('İstek', nbNum($tot['r']), 'Dakikada ort. ' . nbNum($tot['r'] / max(1, $hours * 60), 1))?>
  <?=kpi('Ortalama yanıt', nbNum($avg) . ' ms', 'En yavaş ' . nbNum($tot['mx']) . ' ms')?>
  <?=kpi('Sunucu hatası (5xx)', nbNum($tot['s']), '%' . nbNum($errRate, 2) . ' oran', $tot['s'] ? 'warn' : 'good')?>
  <?=kpi('İstemci hatası (4xx)', nbNum($tot['c']), 'Oturum, sınır, geçersiz istek')?>
</section>
<?php if (!$rows): ?>
<p class="notice info"><?=icon('info')?><span>Henüz ölçüm yok. Kullanıcılar uygulamayı kullandıkça burada görünecek.</span></p>
<?php endif ?>
<div class="cols-2">
  <?php card('İstek sayısı'); echo barChart($reqChart, 'istek'); cardEnd(); ?>
  <?php card('Ortalama yanıt süresi', 'Milisaniye; 300 ms altı iyi'); echo barChart($msChart, 'ms', true); cardEnd(); ?>
</div>
<?php if ($tot['s']): card('Sunucu hataları', 'Ayrıntı Sistem günlüğünde'); echo barChart($errChart, 'hata', true); cardEnd(); endif; ?>
