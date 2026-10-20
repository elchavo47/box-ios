<?php
if (!defined('ROOT')) { http_response_code(404); exit; }
$vds = json_decode(site('vds_health'), true) ?: null;
$units = boxYoutubeUnitsToday();
$hasYt = boxYoutubeKey() !== ''; $hasVds = boxVdsKey() !== '';
$musicOk = json_decode(site('music_last_ok'), true) ?: null;
$musicErr = json_decode(site('music_last_error'), true) ?: null;
$musicCalls = (int)site('music_calls_' . date('Y-m-d'), '0');
$cron = rtrim((string)cfg('app.url', ''), '/') . '/cron?key=' . site('cron_key');
?>
<section class="kpis">
  <?=kpi('VDS indirme', $vds ? ($vds['ok'] ? 'Çalışıyor' : 'Ulaşılamıyor') : 'Kontrol edilmedi', $vds ? h($vds['ok'] ? $vds['ms'] . ' ms · ' . nbAgo($vds['at']) : $vds['error']) : 'Aşağıdan kontrol et', $vds ? ($vds['ok'] ? 'good' : 'bad') : '')?>
  <?php if (boxMusicEnabled()): $musicFresh = $musicErr && (!$musicOk || strtotime($musicErr['at']) > strtotime($musicOk['at'])); ?>
  <?=kpi('Arama: YouTube Music', $musicFresh ? 'Hata' : ($musicOk ? 'Çalışıyor' : 'Henüz arama yok'), $musicFresh ? h($musicErr['reason'] . ' · ' . nbAgo($musicErr['at']) . ' (yedek: YouTube API)') : ($musicOk ? (int)$musicOk['ms'] . ' ms · ' . nbAgo($musicOk['at']) . ' · bugün ' . nbNum($musicCalls) . ' istek' : 'Kota yok, VDS üzerinden'), $musicFresh ? 'bad' : ($musicOk ? 'good' : ''))?>
  <?=kpi('Yedek: YouTube API', nbNum($units) . ' / 10.000', $hasYt ? 'YouTube Music çalışmazsa devreye girer' : 'Anahtar yok, yedek kapalı', $units > 8000 ? 'bad' : '')?>
  <?php else: ?>
  <?=kpi('YouTube anahtarı', $hasYt ? 'Tanımlı' : 'Eksik', $hasYt ? 'Şifreli saklanıyor' : 'Arama çalışmaz', $hasYt ? 'good' : 'bad')?>
  <?=kpi('Bugünkü kota', nbNum($units) . ' / 10.000', 'Bir arama yaklaşık 101 birim', $units > 8000 ? 'bad' : '')?>
  <?php endif ?>
</section>
<?php
$series = json_decode(site('vds_series'), true) ?: [];
$recent = array_slice($series, -24);
$sum = fn(string $k, string $f) => array_sum(array_map(fn($p) => (int)($p[$k][$f] ?? 0), $recent));
$musicN = $sum('music', 'n'); $musicErr = $sum('music', 'err'); $resN = $sum('resolve', 'n'); $resErr = $sum('resolve', 'err');
$avg = function (string $k) use ($recent): int { $n = 0; $t = 0; foreach ($recent as $p) { $c = (int)($p[$k]['n'] ?? 0); $n += $c; $t += $c * (int)($p[$k]['avg_ms'] ?? 0); } return $n ? (int)round($t / $n) : 0; };
$lastPoint = $series ? end($series) : null;
$hourLabel = fn($p) => substr((string)$p['at'], 11, 2);
?>
<?php card('VDS takibi', 'Saatlik ölçüm (zamanlanmış görevle). Son 24 saat.'); ?>
<section class="kpis">
  <?=kpi('Durum', $lastPoint ? ($lastPoint['ok'] ? 'Çalışıyor' : 'Ulaşılamıyor') : 'Henüz ölçüm yok', $lastPoint ? 'Son ölçüm ' . h(nbAgo($lastPoint['at'] . ':00')) . (isset($lastPoint['uptime']) ? ' · ' . h(nbRemaining((int)$lastPoint['uptime'])) . ' süredir açık' : '') : 'Bir saat içinde ilk ölçüm gelir', $lastPoint ? ($lastPoint['ok'] ? 'good' : 'bad') : '')?>
  <?=kpi('YouTube Music', nbNum($musicN) . ' istek', ($musicN ? '%' . round($musicErr / max(1, $musicN) * 100) . ' hata · ort. ' . $avg('music') . ' ms' : 'Son 24 saatte istek yok') . ($lastPoint && isset($lastPoint['music_ready']) && !$lastPoint['music_ready'] ? ' · kütüphane kurulu değil' : ''), $musicN && $musicErr / max(1, $musicN) > 0.3 ? 'bad' : ($musicN ? 'good' : ''))?>
  <?=kpi('Şarkı hazırlama (yt-dlp)', nbNum($resN) . ' şarkı', $resN ? '%' . round($resErr / max(1, $resN) * 100) . ' hata · ort. ' . nbNum($avg('resolve')) . ' ms' : 'Son 24 saatte yok', $resN && $resErr / max(1, $resN) > 0.2 ? 'bad' : ($resN ? 'good' : ''))?>
</section>
<div class="cols-2">
  <div><p class="muted">YouTube Music istekleri (saat)</p><?=barChart(array_map(fn($p) => ['label' => $hourLabel($p), 'value' => (int)($p['music']['n'] ?? 0)], $recent), 'istek')?></div>
  <div><p class="muted">Hatalar (YouTube Music + yt-dlp)</p><?=barChart(array_map(fn($p) => ['label' => $hourLabel($p), 'value' => (int)($p['music']['err'] ?? 0) + (int)($p['resolve']['err'] ?? 0)], $recent), 'hata', true)?></div>
</div>
<div class="cols-2">
  <div><p class="muted">VDS yanıt süresi (ms)</p><?=barChart(array_map(fn($p) => ['label' => $hourLabel($p), 'value' => (int)$p['ms']], $recent), 'ms')?></div>
  <div><p class="muted">Şarkı hazırlama süresi (ort. ms)</p><?=barChart(array_map(fn($p) => ['label' => $hourLabel($p), 'value' => (int)($p['resolve']['avg_ms'] ?? 0)], $recent), 'ms')?></div>
</div>
<?php $vdsInfo = json_decode(site('vds_info'), true) ?: null; if ($vdsInfo): $le = $vdsInfo['last_error'] ?? null; ?>
<p class="muted">
  <?= $vdsInfo['ytmusicapi'] ? 'ytmusicapi ' . h($vdsInfo['ytmusicapi']) : 'ytmusicapi sürümü bilinmiyor (yt_stream.py eski)' ?>
  <?php if (is_array($le) && !empty($le['at']) && time() - (int)$le['at'] < 86400): ?>
   · Son YouTube Music hatası: <code><?=h(($le['where'] ?? '') . ' ' . ($le['type'] ?? ''))?></code><?= !empty($le['query']) ? ' "' . h($le['query']) . '"' : '' ?> · <?=h(nbAgo(date('Y-m-d H:i:s', (int)$le['at'])))?> <small>(diğer dille tekrar denendi)</small>
  <?php endif ?>
</p>
<?php endif ?>
<p class="muted">Sorun olunca Telegram'a haber gelir: VDS'ye iki ölçüm üst üste ulaşılamazsa, YouTube Music isteklerinin %30'undan fazlası hata verirse ve kütüphane eksikse.</p>
<?php cardEnd(); ?>

<div class="cols-2">
  <?php card('Bağlantı ayarları', 'Anahtarlar şifreli saklanır ve bir daha gösterilmez. Boş bırakılan alan değişmez.');
  formStart('services_save', 'stack');
  field('VDS adresi', 'vds_url', boxVdsUrl(), 'url', ['hint' => 'Örnek: https://yt2.aydworks.com.tr']);
  field('VDS imza anahtarı', 'vds_signing_key', '', 'password', ['autocomplete' => 'off', 'placeholder' => $hasVds ? '•••••••• (tanımlı)' : 'Tanımlı değil', 'hint' => 'VDS\'deki /etc/yt-api.env içindeki YT_API_KEY ile aynı olmalı.']);
  selectField('Arama kaynağı', 'search_source', ['music' => 'YouTube Music (VDS, kota yok) — önerilen', 'api' => 'YouTube Data API (günde ~99 arama)'], site('search_source', 'music'), ['hint' => 'YouTube Music seçiliyken bir sorun olursa arama kendiliğinden YouTube API ile yapılır.']);
  field('YouTube Data API anahtarı', 'yt_api_key', '', 'password', ['autocomplete' => 'off', 'placeholder' => $hasYt ? '•••••••• (tanımlı)' : 'Tanımlı değil']);
  echo '<div class="grid-3">';
  field('İndirme bağlantısı (sn)', 'download_link_ttl', site('download_link_ttl', '300'), 'number', ['min' => 60]);
  field('Arama önbelleği (sn)', 'search_cache_seconds', site('search_cache_seconds', '21600'), 'number', ['min' => 60]);
  field('Oturum süresi (gün)', 'token_ttl_days', site('token_ttl_days', '180'), 'number', ['min' => 1]);
  echo '</div>';
  passwordConfirm();
  echo '<div class="row-actions">' . button('Kaydet') . '</div>';
  formEnd(); cardEnd(); ?>
  <div class="stack">
    <?php card('Dene', 'Ayarların gerçekten çalıştığını buradan doğrula.'); ?>
    <div class="row-actions">
      <?php formStart('services_check'); echo button('VDS\'yi kontrol et', 'ghost', ['icon' => 'server']); formEnd(); ?>
      <?php formStart('services_test_search'); echo button('Deneme araması', 'ghost', ['icon' => 'search']); formEnd(); ?>
    </div>
    <?php cardEnd(); ?>
    <?php card('Apple (giriş ve bildirim)', 'Apple Developer > Keys bölümünden oluşturduğun anahtar. Apple ile giriş anahtarsız da çalışır; anahtar bildirim göndermek ve hesap silinince Apple bağlantısını iptal etmek için gerekir.');
    $apple = boxAppleConfig();
    echo '<p class="pills">' . (boxAppleConfigured() ? pill('Tanımlı', 'good') : pill('Eksik', 'bad')) . (boxPushSupported() ? pill('Sunucu HTTP/2 destekliyor', 'good') : pill('Sunucuda HTTP/2 yok, bildirim gönderilemez', 'bad')) . pill(nbNum((int)q('SELECT COUNT(*) FROM push_devices')->fetchColumn()) . ' cihaz bildirime açık', 'neutral') . '</p>';
    if ($edit = can('apple_save')) {
        formStart('apple_save', 'stack');
        echo '<div class="grid-2">';
        field('Team ID', 'apple_team_id', $apple['team'], 'text', ['placeholder' => '10 karakter', 'maxlength' => 10, 'mono' => true, 'hint' => 'developer.apple.com sağ üstte, hesap adının altında.']);
        field('Key ID', 'apple_key_id', $apple['key'], 'text', ['placeholder' => '10 karakter', 'maxlength' => 10, 'mono' => true, 'hint' => 'İndirdiğin AuthKey_XXXXXXXXXX.p8 dosyasının adındaki kod.']);
        echo '</div>';
        area('.p8 anahtarı', 'apple_p8', '', ['rows' => 5, 'mono' => true, 'placeholder' => $apple['p8'] !== '' ? '•••••••• (tanımlı, değiştirmek için yenisini yapıştır)' : "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----", 'hint' => 'Dosyayı Not Defteri ile aç, tamamını yapıştır. Şifreli saklanır ve bir daha gösterilmez.']);
        passwordConfirm();
        echo '<div class="row-actions">' . button('Kaydet') . '</div>';
        formEnd();
        formStart('apple_test'); echo '<div class="row-actions">' . button('Bağlantıyı dene', 'ghost', ['icon' => 'bell']) . '</div>'; formEnd();
    }
    cardEnd(); ?>
    <?php card('Zamanlanmış görevler', 'Hosting panelinde (cPanel > Cron) saatte bir çalışacak şekilde ekle. Eklemezsen panel açıldıkça çalışır.'); ?>
    <pre class="code" data-copy><?=h('curl -s "' . $cron . '" > /dev/null')?></pre>
    <p class="muted">Son çalışma: <?=h(nbAgo(site('cron_last_run') ?: null))?></p>
    <div class="row-actions">
      <?php formStart('cron_run'); echo button('Şimdi çalıştır', 'ghost'); formEnd(); ?>
      <?php formStart('cron_key_regen'); echo button('Adresi yenile', 'ghost', ['confirm' => 'Eski cron adresi çalışmayı bırakacak.']); formEnd(); ?>
    </div>
    <?php cardEnd(); ?>
  </div>
</div>
