<?php
if (!defined('ROOT')) { http_response_code(404); exit; }
$vds = json_decode(site('vds_health'), true) ?: null;
$units = boxYoutubeUnitsToday();
$hasYt = boxYoutubeKey() !== ''; $hasVds = boxVdsKey() !== '';
$cron = rtrim((string)cfg('app.url', ''), '/') . '/cron?key=' . site('cron_key');
?>
<section class="kpis">
  <?=kpi('VDS indirme', $vds ? ($vds['ok'] ? 'Çalışıyor' : 'Ulaşılamıyor') : 'Kontrol edilmedi', $vds ? h($vds['ok'] ? $vds['ms'] . ' ms · ' . nbAgo($vds['at']) : $vds['error']) : 'Aşağıdan kontrol et', $vds ? ($vds['ok'] ? 'good' : 'bad') : '')?>
  <?=kpi('YouTube anahtarı', $hasYt ? 'Tanımlı' : 'Eksik', $hasYt ? 'Şifreli saklanıyor' : 'Arama çalışmaz', $hasYt ? 'good' : 'bad')?>
  <?=kpi('Bugünkü kota', nbNum($units) . ' / 10.000', 'Bir arama yaklaşık 101 birim', $units > 8000 ? 'bad' : '')?>
</section>
<div class="cols-2">
  <?php card('Bağlantı ayarları', 'Anahtarlar şifreli saklanır ve bir daha gösterilmez. Boş bırakılan alan değişmez.');
  formStart('services_save', 'stack');
  field('VDS adresi', 'vds_url', boxVdsUrl(), 'url', ['hint' => 'Örnek: https://yt2.aydworks.com.tr']);
  field('VDS imza anahtarı', 'vds_signing_key', '', 'password', ['autocomplete' => 'off', 'placeholder' => $hasVds ? '•••••••• (tanımlı)' : 'Tanımlı değil', 'hint' => 'VDS\'deki /etc/yt-api.env içindeki YT_API_KEY ile aynı olmalı.']);
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
