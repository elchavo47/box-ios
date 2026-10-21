<?php
if (!defined('ROOT')) { http_response_code(404); exit; }
$edit = can('app_save');
$dis = $edit ? [] : ['disabled' => true];
?>
<div class="cols-2">
  <?php card('Bakım modu', 'Açıkken uygulama giriş ve indirme yerine bu mesajı gösterir. Çalan şarkılar ve dosyalar etkilenmez.');
  formStart('app_save', 'stack'); hidden('section', 'maintenance');
  echo toggle('Bakım modu', 'maintenance_mode', configBool('maintenance_mode'), 'Bütün kullanıcıları etkiler', 'Bakım modu bütün kullanıcılar için açılacak.');
  area('Kullanıcıya gösterilecek mesaj', 'maintenance_message', (string)configValue('maintenance_message', ''), $dis + ['maxlength' => 300]);
  if ($edit) echo '<div class="row-actions">' . button('Kaydet') . '</div>';
  formEnd(); cardEnd(); ?>

  <?php card('Sürüm ve kayıt', 'Minimum sürümün altındaki uygulamalar güncelleme ekranı görür.');
  formStart('app_save', 'stack'); hidden('section', 'version');
  field('Minimum uygulama sürümü', 'min_app_version', (string)configValue('min_app_version', '1.0'), 'text', $dis + ['hint' => 'Örnek: 1.2 ya da 2.0.1']);
  echo toggle('Yeni kayıtlar açık', 'registration_open', configBool('registration_open', true), 'Kapalıyken yalnızca mevcut hesaplar giriş yapar');
  if ($edit) echo '<div class="row-actions">' . button('Kaydet') . '</div>';
  formEnd(); cardEnd(); ?>
</div>
<div class="cols-2">
  <?php card('Duyuru', 'Açılışta bir kez gösterilir. Metni değiştirince herkese yeniden gösterilir.');
  formStart('app_save', 'stack'); hidden('section', 'announcement');
  echo toggle('Duyuru yayında', 'announcement_on', configBool('announcement_on'));
  field('Başlık', 'announcement_title', (string)configValue('announcement_title', ''), 'text', $dis + ['maxlength' => 80]);
  area('Metin', 'announcement_body', (string)configValue('announcement_body', ''), $dis + ['maxlength' => 600]);
  $aud = (string)configValue('announcement_audience', 'users');
  echo '<div class="field"><span class="field-label">Kime gösterilsin</span><div class="segmented" role="radiogroup" aria-label="Kime gösterilsin">';
  foreach (['all' => 'Herkese', 'users' => 'Hesabı olanlara', 'premium' => 'Sadece premium'] as $k => $l) {
      echo '<label><input type="radio" name="announcement_audience" value="' . h($k) . '"' . ($aud === $k ? ' checked' : '') . ($dis ? ' disabled' : '') . '><span>' . h($l) . '</span></label>';
  }
  echo '</div><span class="field-hint">"Herkese" seçilirse hesap açmamış, uygulamayı yeni yüklemiş kişiler de görür.</span></div>';
  if ($edit) echo '<div class="row-actions">' . button('Kaydet') . '</div>';
  formEnd(); cardEnd(); ?>

  <?php card('Premium kotaları', '0 yazarsan sınır kalkar.');
  formStart('app_save', 'stack'); hidden('section', 'quota');
  echo '<div class="grid-2">';
  field('Günlük indirme', 'premium_daily_downloads', (string)configValue('premium_daily_downloads', 150), 'number', $dis + ['min' => 0]);
  field('Günlük arama', 'premium_daily_searches', (string)configValue('premium_daily_searches', 400), 'number', $dis + ['min' => 0]);
  echo '</div>';
  field('Yeni hesaplara deneme (gün)', 'new_user_premium_days', (string)configValue('new_user_premium_days', 0), 'number', $dis + ['min' => 0, 'hint' => '0 ise yeni hesaplar ücretsiz başlar.']);
  field('Destek e-postası', 'support_email', (string)configValue('support_email', ''), 'email', $dis);
  if ($edit) echo '<div class="row-actions">' . button('Kaydet') . '</div>';
  formEnd(); cardEnd(); ?>
</div>
<div class="cols-2">
  <?php card('Tarayıcı kısayolları', 'YouTube, YouTube Music ve Google uygulamada zaten var. Buraya eklediklerin onların yanında görünür.');
  formStart('app_save', 'stack'); hidden('section', 'browser');
  $lines = implode("\n", array_map(fn($i) => $i['title'] . ' | ' . $i['url'], boxBrowserShortcuts()));
  area('Kısayollar', 'browser_shortcuts', $lines, $dis + ['placeholder' => "Örnek | https://example.com\nexample.org", 'hint' => 'Her satıra bir kısayol. "Ad | adres" yazabilir ya da yalnızca adresi yapıştırabilirsin; ad kendiliğinden konur. En fazla 12.']);
  if ($edit) echo '<div class="row-actions">' . button('Kaydet') . '</div>';
  formEnd(); cardEnd(); ?>
</div>
