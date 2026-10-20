<?php
if (!defined('ROOT')) { http_response_code(404); exit; }
$byGroup = [];
foreach ($checks as $c) $byGroup[$c['group']][] = $c;
$scan = json_decode(site('exposure_scan'), true);
$labels = ['ok' => 'Sorunsuz', 'warn' => 'Dikkat', 'bad' => 'Sorun', 'info' => 'Bilgi'];
?>
<section class="status-strip">
  <?php foreach (['bad', 'warn', 'ok', 'info'] as $st): ?>
  <div class="tally <?=$st?>"><strong><?=$summary[$st]?></strong><span><?=$labels[$st]?></span></div>
  <?php endforeach ?>
  <div class="status-strip-actions">
    <?php if (can('security_scan')): formStart('security_scan'); echo button('Şimdi tara', 'primary', ['icon' => 'search']); formEnd(); endif; ?>
  </div>
</section>

<div class="check-groups">
<?php foreach ($byGroup as $group => $items): ?>
  <?php card($group); ?>
  <ul class="checks">
    <?php foreach ($items as $c): ?>
    <li class="check <?=h($c['state'])?>">
      <span class="check-state"><?=icon($c['state'] === 'ok' ? 'check' : ($c['state'] === 'info' ? 'info' : 'alert'))?></span>
      <div class="check-body"><b><?=h($c['title'])?></b><span><?=h($c['detail'])?></span><?php if ($c['fix'] !== '' && $c['state'] !== 'ok'): ?><small class="fix"><?=h($c['fix'])?></small><?php endif ?></div>
      <?php if ($c['link'] !== '' && $c['link'] !== 'status' && canSee($admin, $c['link'])): ?><a class="btn small ghost" href="/admin?p=<?=h($c['link'])?>">Aç</a><?php endif ?>
    </li>
    <?php endforeach ?>
  </ul>
  <?php cardEnd(); ?>
<?php endforeach ?>
</div>

<div>
  <?php card('Dışarıdan erişim taraması', ($scan ? 'Son tarama ' . nbAgo($scan['at']) . '. Her gece otomatik tekrarlanır. ' : '') . 'Site kendi adresine istek atar ve dönen içeriğin gerçekten o dosya olup olmadığına bakar; güvenlik duvarı sayfaları açık sayılmaz.'); ?>
  <ul class="scan-list">
    <?php if (!empty($scan['checked'])): foreach ($scan['checked'] as $c): ?>
    <li class="<?=$c['open'] ? 'bad' : 'ok'?>" title="<?=h($c['note'])?>"><?=icon($c['open'] ? 'alert' : 'lock')?><code><?=h(rawurldecode($c['path']))?></code><span><?=h($c['label'])?></span><em><?=$c['open'] ? 'Açık' : 'Kapalı'?></em></li>
    <?php endforeach; else: foreach (exposureTargets() as $path => [$label]): ?>
    <li class="idle"><?=icon('clock')?><code><?=h(rawurldecode($path))?></code><span><?=h($label)?></span><em>Taranmadı</em></li>
    <?php endforeach; endif ?>
  </ul>
  <?php cardEnd(); ?>

</div>

<?php
$events = q('SELECT e.*,u.display_name username FROM security_events e LEFT JOIN users u ON u.id=e.user_id ORDER BY e.id DESC LIMIT 60')->fetchAll();
$unacked = count(array_filter($events, fn($e) => !$e['acknowledged_at'] && $e['severity'] !== 'info'));
card('Güvenlik olayları', 'Servis kesintileri, kota, bütünlük ve erişim taramasının bulguları. Kritik ve uyarı olayları Telegram\'a da gider.', '', $unacked && can('sec_ack') ? (function () { ob_start(); formStart('sec_ack'); hidden('id', 0); echo button('Hepsini incelendi say', 'ghost small'); formEnd(); return ob_get_clean(); })() : '');
tableView(['Önem', 'Olay', 'Zaman', ''], $events, function ($e) {
    $tone = ['critical' => 'bad', 'warn' => 'warn', 'info' => 'info'][$e['severity']] ?? 'neutral';
    echo '<td>' . pill(['critical' => 'Kritik', 'warn' => 'Uyarı', 'info' => 'Bilgi'][$e['severity']] ?? $e['severity'], $tone) . '</td><td class="wrap">' . h($e['message']) . ($e['user_id'] ? ' <a href="/admin?p=player&amp;id=' . (int)$e['user_id'] . '">Kullanıcıyı aç</a>' : '') . '</td><td class="nowrap">' . h(nbDate($e['created_at'])) . '</td><td class="end">';
    if ($e['acknowledged_at']) echo '<span class="muted small">İncelendi</span>';
    elseif ($e['severity'] !== 'info' && can('sec_ack')) { formStart('sec_ack'); hidden('id', (int)$e['id']); echo button('İncelendi', 'ghost small'); formEnd(); }
    echo '</td>';
}, 'Henüz güvenlik olayı yok. Bu iyi bir şey.');
cardEnd();
