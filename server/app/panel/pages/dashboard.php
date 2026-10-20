<?php
if (!defined('ROOT')) { http_response_code(404); exit; }
$today = date('Y-m-d 00:00:00'); $yesterday = date('Y-m-d 00:00:00', strtotime('-1 day'));
$one = fn(string $sql, array $args = []): int => (int)q($sql, $args)->fetchColumn();
$premWhere = "is_premium=1 AND (premium_until IS NULL OR premium_until>NOW())";
$hd = [
    'total' => $one('SELECT COUNT(*) FROM users'),
    'active' => $one('SELECT COUNT(*) FROM users WHERE last_seen_at>=?', [$today]),
    'active_y' => $one('SELECT COUNT(*) FROM users WHERE last_seen_at>=? AND last_seen_at<?', [$yesterday, $today]),
    'new' => $one('SELECT COUNT(*) FROM users WHERE created_at>=?', [$today]),
    'new_y' => $one('SELECT COUNT(*) FROM users WHERE created_at>=? AND created_at<?', [$yesterday, $today]),
    'premium' => $one("SELECT COUNT(*) FROM users WHERE $premWhere"),
    'dl' => $one('SELECT COUNT(*) FROM downloads WHERE created_at>=?', [$today]),
    'dl_y' => $one('SELECT COUNT(*) FROM downloads WHERE created_at>=? AND created_at<?', [$yesterday, $today]),
    'search' => $one('SELECT COALESCE(SUM(n),0) FROM search_log WHERE day=CURDATE()'),
    'search_y' => $one('SELECT COALESCE(SUM(n),0) FROM search_log WHERE day=DATE_SUB(CURDATE(),INTERVAL 1 DAY)'),
    'expiring' => $one("SELECT COUNT(*) FROM users WHERE is_premium=1 AND premium_until BETWEEN NOW() AND DATE_ADD(NOW(),INTERVAL 3 DAY)"),
];
$vds = json_decode(site('vds_health'), true) ?: null;
$units = boxYoutubeUnitsToday();
$map = array_column(q('SELECT DATE(created_at) d,COUNT(*) c FROM downloads WHERE created_at>=DATE_SUB(CURDATE(),INTERVAL 13 DAY) GROUP BY DATE(created_at)')->fetchAll(), 'c', 'd');
$seen = array_column(q('SELECT DATE(last_seen_at) d,COUNT(*) c FROM users WHERE last_seen_at>=DATE_SUB(CURDATE(),INTERVAL 13 DAY) GROUP BY DATE(last_seen_at)')->fetchAll(), 'c', 'd');
$daily = []; $signups = array_column(q('SELECT DATE(created_at) d,COUNT(*) c FROM users WHERE created_at>=DATE_SUB(CURDATE(),INTERVAL 13 DAY) GROUP BY DATE(created_at)')->fetchAll(), 'c', 'd'); $sg = [];
for ($i = 13; $i >= 0; $i--) { $d = date('Y-m-d', strtotime("-$i days")); $daily[] = ['label' => date('d.m', strtotime($d)), 'value' => (int)($map[$d] ?? 0)]; $sg[] = ['label' => date('d.m', strtotime($d)), 'value' => (int)($signups[$d] ?? 0)]; }
$problems = array_values(array_filter($checks, fn($c) => in_array($c['state'], ['bad', 'warn'], true)));
usort($problems, fn($a, $b) => ($a['state'] === 'bad' ? 0 : 1) <=> ($b['state'] === 'bad' ? 0 : 1));
$hour = (int)date('G');
$greet = $hour < 6 ? 'İyi geceler' : ($hour < 12 ? 'Günaydın' : ($hour < 18 ? 'İyi günler' : 'İyi akşamlar'));
$errNew = canSee($admin, 'errors') ? $one("SELECT COUNT(*) FROM error_groups WHERE status='open' AND first_seen>=DATE_SUB(NOW(),INTERVAL 1 DAY)") : 0;
?>
<?php if (configBool('maintenance_mode')): ?>
<a class="alert-strip warn" href="/admin?p=app"><?=icon('alert')?><span><b>Bakım modu açık.</b> Uygulama şu an kullanıcılara bakım ekranı gösteriyor.</span><?=icon('arrow')?></a>
<?php endif ?>
<?php if ($vds && !$vds['ok']): ?>
<a class="alert-strip bad" href="/admin?p=services"><?=icon('server')?><span><b>VDS indirme servisine ulaşılamıyor.</b> <?=h($vds['error'])?> · <?=h(nbAgo($vds['at']))?></span><?=icon('arrow')?></a>
<?php endif ?>
<?php if ($errNew): ?>
<a class="alert-strip warn" href="/admin?p=errors"><?=icon('bug')?><span><b><?=nbNum($errNew)?> yeni hata türü</b> son 24 saatte görüldü.</span><?=icon('arrow')?></a>
<?php endif ?>

<section class="integrity <?=$summary['bad'] ? 'is-bad' : ($summary['warn'] ? 'is-warn' : 'is-ok')?>">
  <div class="integrity-copy">
    <p class="integrity-greet"><?=h($greet)?>, <?=h($admin['username'])?>.</p>
    <h2><?php if (!$checks): ?>Bugün Box'ta neler oluyor<?php elseif ($summary['bad']): ?><?=$summary['bad']?> sorun hemen bakılmalı<?php elseif ($summary['warn']): ?><?=$summary['warn']?> konu dikkatini bekliyor<?php else: ?>Her şey yolunda<?php endif ?></h2>
    <p><?=$checks ? count($checks) . ' kontrolden ' . $summary['ok'] . ' tanesi sorunsuz geçti.' : 'Aşağıdaki sayılar bugünün özeti.'?></p>
  </div>
  <?php if ($checks): ?>
  <div class="integrity-wall" role="img" aria-label="Kontroller">
    <?php foreach ($checks as $c): ?><a class="brick s-<?=h($c['state'])?>" href="/admin?p=status" title="<?=h($c['title'] . ': ' . $c['detail'])?>"></a><?php endforeach ?>
  </div>
  <?php endif ?>
  <?php if ($problems): ?>
  <ul class="issues">
    <?php foreach (array_slice($problems, 0, 5) as $c): ?>
    <li class="issue <?=h($c['state'])?>"><?=icon($c['state'] === 'bad' ? 'alert' : 'info')?><div><b><?=h($c['title'])?></b><span><?=h($c['detail'])?></span></div><?php if ($c['link'] !== '' && canSee($admin, $c['link'])): ?><a class="btn small ghost" href="/admin?p=<?=h($c['link'])?>">Aç</a><?php endif ?></li>
    <?php endforeach ?>
  </ul>
  <?php endif ?>
</section>

<section class="kpis">
  <?=kpi('Bugün açan', nbNum($hd['active']), trend($hd['active'], $hd['active_y']))?>
  <?=kpi('Yeni hesap', nbNum($hd['new']), trend($hd['new'], $hd['new_y']))?>
  <?=kpi('Premium üye', nbNum($hd['premium']), $hd['total'] ? nbNum($hd['total']) . ' hesabın %' . round($hd['premium'] / $hd['total'] * 100) . '\'i' : 'Henüz hesap yok', 'good')?>
  <?=kpi('İndirilen şarkı', nbNum($hd['dl']), trend($hd['dl'], $hd['dl_y']))?>
  <?=kpi('YouTube araması', nbNum($hd['search']), trend($hd['search'], $hd['search_y']))?>
  <?=kpi('YouTube kotası', nbNum($units) . ' / 10.000', $units > 8000 ? '<span class="trend down">Kota dolmak üzere</span>' : 'Bugün harcanan birim', $units > 8000 ? 'bad' : '')?>
</section>

<?php $quick = [['users', 'Kullanıcı bul', 'users'], ['bolt', 'Premium ver', 'premium'], ['music', 'İndirmeler', 'downloads'], ['phone', 'Uygulama ayarı', 'app'], ['server', 'Servisler', 'services'], ['shield', 'Güvenlik', 'status']];
$quick = array_values(array_filter($quick, fn($x) => canSee($admin, $x[2]))); ?>
<nav class="quick-actions" aria-label="Hızlı işlemler">
  <?php foreach ($quick as [$ic, $label, $page]): $n = $page === 'premium' ? $hd['expiring'] : 0; ?>
  <a href="/admin?p=<?=h($page)?>" class="quick<?=$n ? ' has' : ''?>"><?=icon($ic)?><span><?=h($label)?></span><?php if ($n): ?><em><?=$n?></em><?php endif ?></a>
  <?php endforeach ?>
</nav>

<div class="cols-2">
  <?php card('Günlük indirme', 'Son 14 gün'); echo barChart($daily, 'şarkı', true); cardEnd(); ?>
  <?php card('Yeni hesaplar', 'Son 14 gün · toplam ' . nbNum($hd['total']) . ' hesap'); echo barChart($sg, 'hesap'); cardEnd(); ?>
</div>

<div class="cols-2 wide-left">
  <?php
  $recent = q('SELECT d.*,u.display_name,u.email FROM downloads d JOIN users u ON u.id=d.user_id ORDER BY d.id DESC LIMIT 8')->fetchAll();
  card('Son indirilenler', '', '', canSee($admin, 'downloads') ? '<a class="btn small ghost" href="/admin?p=downloads">Tümü</a>' : '');
  tableView(['Şarkı', 'Kullanıcı', 'Zaman'], $recent, function ($r) {
      echo '<td><span class="track"><img src="https://i.ytimg.com/vi/' . h($r['video_id']) . '/default.jpg" alt="" loading="lazy"><b>' . h($r['title'] !== '' ? $r['title'] : $r['video_id']) . '</b></span></td><td>' . userCell($r, (int)$r['user_id']) . '</td><td class="nowrap">' . h(nbAgo($r['created_at'])) . '</td>';
  }, 'Henüz indirme yok.');
  cardEnd();
  ?>
  <?php card('Servis durumu'); ?>
  <ul class="queue">
    <li><a href="/admin?p=services" class="<?=$vds && !$vds['ok'] ? 'has' : ''?>"><?=icon('server')?><span>VDS indirme</span><b><?=$vds ? ($vds['ok'] ? $vds['ms'] . ' ms' : 'Kapalı') : '—'?></b></a></li>
    <li><a href="/admin?p=services"><?=icon('search')?><span>YouTube anahtarı</span><b><?=boxYoutubeKey() !== '' ? 'Tanımlı' : 'Yok'?></b></a></li>
    <li><a href="/admin?p=premium" class="<?=$hd['expiring'] ? 'has' : ''?>"><?=icon('bolt')?><span>3 gün içinde bitecek premium</span><b><?=nbNum($hd['expiring'])?></b></a></li>
    <li><a href="/admin?p=app"><?=icon('phone')?><span>Minimum uygulama sürümü</span><b><?=h((string)configValue('min_app_version', '1.0'))?></b></a></li>
  </ul>
  <?php $events = canSee($admin, 'status') ? q("SELECT * FROM security_events WHERE severity<>'info' ORDER BY id DESC LIMIT 4")->fetchAll() : [];
  if ($events): ?>
  <h3 class="sub-head">Son güvenlik olayları</h3>
  <ul class="events">
    <?php foreach ($events as $e): ?><li class="<?=h($e['severity'])?><?=$e['acknowledged_at'] ? ' done' : ''?>"><?=stateDot($e['severity'] === 'critical' ? 'bad' : 'warn')?><span><?=h($e['message'])?><small><?=h(nbAgo($e['created_at']))?></small></span></li><?php endforeach ?>
  </ul>
  <?php endif ?>
  <?php cardEnd(); ?>
</div>
