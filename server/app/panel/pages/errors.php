<?php
if (!defined('ROOT')) { http_response_code(404); exit; }

$view = (string)($_GET['v'] ?? 'open'); if (!in_array($view, ['open', 'resolved', 'muted', 'all'], true)) $view = 'open';
$one = fn(string $sql) => (int)q($sql)->fetchColumn();
$openN = $one("SELECT COUNT(*) FROM error_groups WHERE status='open'");
$newN = $one('SELECT COUNT(*) FROM error_groups WHERE first_seen>=DATE_SUB(NOW(),INTERVAL 1 DAY)');
$today = $one('SELECT COALESCE(SUM(n),0) FROM error_daily WHERE day=CURDATE()');
$week = $one('SELECT COALESCE(SUM(n),0) FROM error_daily WHERE day>=DATE_SUB(CURDATE(),INTERVAL 6 DAY)');
$counts = array_column(q('SELECT status,COUNT(*) c FROM error_groups GROUP BY status')->fetchAll(), 'c', 'status');
$where = $view === 'all' ? '' : 'WHERE g.status=' . db()->quote($view);
$rows = q("SELECT g.*,(SELECT COALESCE(SUM(d.n),0) FROM error_daily d WHERE d.sig=g.sig AND d.day=CURDATE()) today,(SELECT COALESCE(SUM(d.n),0) FROM error_daily d WHERE d.sig=g.sig AND d.day>=DATE_SUB(CURDATE(),INTERVAL 6 DAY)) week FROM error_groups g $where ORDER BY g.status='open' DESC, g.last_seen DESC LIMIT 200")->fetchAll();
$levelTone = ['Fatal' => 'bad', 'Exception' => 'bad', 'Error' => 'bad', 'Warning' => 'warn', 'Notice' => 'neutral', 'Deprecated' => 'neutral', 'Test' => 'info'];
$levelName = ['Fatal' => 'Ölümcül', 'Exception' => 'İstisna', 'Error' => 'Hata', 'Warning' => 'Uyarı', 'Notice' => 'Not', 'Deprecated' => 'Eski kullanım', 'Test' => 'Deneme'];
$tg = function_exists('telegramConfigured') && telegramConfigured() && site('tg_alert_errors', '1') === '1';
?>
<section class="kpis four">
  <?=kpi('Açık hata türü', nbNum($openN), 'Çözüldü işaretlenmemiş', $openN ? 'warn' : 'good')?>
  <?=kpi('Yeni tür (24 sa)', nbNum($newN), 'İlk kez görülen', $newN ? 'bad' : '')?>
  <?=kpi('Bugün', nbNum($today), 'Toplam hata sayısı')?>
  <?=kpi('Son 7 gün', nbNum($week), $tg ? 'Yeni türde Telegram\'a haber gelir' : 'Telegram uyarısı kapalı', $tg ? '' : 'warn')?>
</section>
<div class="toolbar">
  <div class="seg" role="group" aria-label="Durum"><?php foreach (['open' => 'Açık', 'resolved' => 'Çözüldü', 'muted' => 'Sessiz', 'all' => 'Tümü'] as $k => $v): ?><a class="<?=$view === $k ? 'on' : ''?>" href="/admin?p=errors&amp;v=<?=$k?>"><?=h($v)?><?php if ($k !== 'all'): ?><em><?=nbNum($counts[$k] ?? 0)?></em><?php endif ?></a><?php endforeach ?></div>
  <div class="row-actions">
    <?php if ($view === 'open' && $openN): formStart('errors_resolve_all', 'inline'); echo button('Hepsini çözüldü işaretle', 'ghost small', ['icon' => 'check', 'confirm' => 'Açık bütün hatalar çözüldü işaretlensin mi? Tekrar olursa yeniden açılır ve haber gelir.']); formEnd(); endif ?>
    <?php if ($view === 'resolved' && ($counts['resolved'] ?? 0)): formStart('errors_clear_resolved', 'inline'); echo button('Çözülenleri temizle', 'ghost small danger-text', ['confirm' => 'Çözüldü işaretli bütün kayıtlar silinsin mi?']); formEnd(); endif ?>
    <?php formStart('error_test', 'inline'); echo button('Deneme hatası gönder', 'ghost small', ['icon' => 'bell']); formEnd(); ?>
    <a class="btn ghost small" href="/admin?p=logs"><?=icon('terminal')?><span>Ham günlük</span></a>
  </div>
</div>
<?php if (!$tg): ?><p class="notice warn"><?=icon('alert')?><span>Yeni hata türlerinde Telegram uyarısı kapalı. Koruma ve yedek &gt; Anlık uyarılar &gt; "Yeni hata türü" ile aç<?=function_exists('telegramConfigured') && !telegramConfigured() ? ' (önce Telegram botunu bağla)' : ''?>.</span></p><?php endif ?>
<?php card(['open' => 'Açık hatalar', 'resolved' => 'Çözüldü işaretlenenler', 'muted' => 'Sessize alınanlar', 'all' => 'Bütün hatalar'][$view], 'Aynı hata tek satırda toplanır. Ayrıntı için hatanın metnine dokun. Çözüldü dediğin hata yeniden olursa kendiliğinden açılır ve Telegram\'a haber gelir.');
tableView(['Hata', ['Kaç kez', 'num'], 'İlk / son', ['', 'actions']], $rows, function ($g) use ($levelTone, $levelName) {
    echo '<td class="wrap err-cell">' . pill($levelName[$g['level']] ?? $g['level'], $levelTone[$g['level']] ?? 'neutral') . ($g['status'] === 'muted' ? ' ' . pill('Sessiz', 'neutral') : '') . ($g['status'] === 'resolved' ? ' ' . pill('Çözüldü', 'good') : '')
        . '<details><summary>' . h(mb_strimwidth((string)$g['message'], 0, 220, '…')) . '</summary>'
        . '<dl class="err-meta"><dt>Yer</dt><dd class="mono">' . h($g['file'] . ':' . $g['line']) . '</dd><dt>Son istek</dt><dd class="mono">' . h($g['last_url']) . '</dd></dl>'
        . (mb_strlen((string)$g['message']) > 220 ? '<pre>' . h($g['message']) . '</pre>' : '') . ($g['last_trace'] ? '<pre>' . h($g['last_trace']) . '</pre>' : '') . '</details>'
        . '<small class="block muted mono">' . h($g['file'] . ':' . $g['line']) . '</small></td>';
    echo '<td class="num"><b>' . nbNum($g['occurrences']) . '</b><small class="block muted">bugün ' . nbNum($g['today']) . ' · 7 gün ' . nbNum($g['week']) . '</small></td>';
    echo '<td class="nowrap">' . h(nbAgo($g['first_seen'])) . '<small class="block muted">son: ' . h(nbAgo($g['last_seen'])) . '</small></td><td class="actions">';
    if ($g['status'] !== 'resolved') { formStart('error_resolve', 'inline'); hidden('sig', $g['sig']); echo button('Çözüldü', 'primary small', ['icon' => 'check']); formEnd(); }
    formStart('error_mute', 'inline'); hidden('sig', $g['sig']); echo button($g['status'] === 'muted' ? 'Sesi aç' : 'Sessize al', 'ghost small'); formEnd();
    formStart('error_delete', 'inline'); hidden('sig', $g['sig']); echo button('Sil', 'ghost small danger-text', ['confirm' => 'Bu hata kaydı silinsin mi? Tekrar olursa yeni tür olarak gelir.']); formEnd();
    echo '</td>';
}, ['open' => 'Açık hata yok. Sunucu sorunsuz çalışıyor.', 'resolved' => 'Çözüldü işaretli kayıt yok.', 'muted' => 'Sessize alınan hata yok.', 'all' => 'Henüz hiç hata kaydedilmedi.'][$view]);
cardEnd();
