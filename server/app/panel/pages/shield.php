<?php
if (!defined('ROOT')) { http_response_code(404); exit; }
$tg = telegramConfigured(); $hasBackupPass = decryptSecret(site('backup_password')) !== ''; $zipOk = class_exists('ZipArchive') && defined('ZipArchive::EM_AES_256');
?>
<section class="kpis four">
  <?=kpi('Telegram', $tg ? 'Bağlı' : 'Bağlı değil', 'Uyarılar ve yedek buraya gider', $tg ? 'good' : 'warn')?>
  <?=kpi('Günlük yedek', site('backup_enabled', '0') === '1' ? 'Açık' : 'Kapalı', h(site('backup_last', 'Henüz yedek alınmadı')), site('backup_enabled', '0') === '1' ? '' : 'warn')?>
  <?=kpi('Yedek şifresi', $hasBackupPass ? 'AES-256' : 'Şifresiz', $zipOk ? 'Sunucu şifreli zip destekliyor' : 'Sunucuda php-zip yok', $hasBackupPass ? 'good' : 'warn')?>
  <?=kpi('Panel IP kısıtı', site('admin_ip_allowlist') !== '' ? 'Açık' : 'Kapalı', 'Şu anki IP: ' . h(clientIp()))?>
</section>
<div class="cols-2">
  <?php card('Telegram, yedek ve IP kısıtı', 'Bot belirtecini @BotFather\'dan, sohbet kimliğini @userinfobot\'tan al. Yedek her gece 04:00\'ten sonra gönderilir.'); formStart('security_save', 'stack'); echo '<div class="grid-fields">';
  field('Bot belirteci', 'telegram_bot_token', '', 'password', ['placeholder' => decryptSecret(site('telegram_bot_token')) !== '' ? 'Kayıtlı; değiştirmek için yaz' : '123456:ABC...', 'autocomplete' => 'off']);
  field('Sohbet kimliği', 'telegram_chat_id', site('telegram_chat_id'), 'text', ['mono' => true]);
  echo '</div>' . toggle('Yeni konumdan girişte ve hatalı denemelerde uyar', 'telegram_alerts', site('telegram_alerts', '1') === '1') . toggle('Her gün yedeği Telegram\'a gönder', 'backup_enabled', site('backup_enabled', '0') === '1');
  selectField('Yedek türü', 'backup_mode', ['db' => 'Yalnızca veritabanı (küçük, hızlı)', 'full' => 'Tam yedek: veritabanı + sunucudaki bütün dosyalar'], site('backup_mode', 'db'), ['hint' => 'Tam yedek ayar dosyasını ve yüklenen fotoğrafları da içerir; şifre zorunludur. 50 MB\'ı geçerse parça parça gönderilir.']);
  field('Yedek zip şifresi', 'backup_password', '', 'password', ['placeholder' => $hasBackupPass ? 'Kayıtlı; değiştirmek için yaz' : 'En az 10 karakter', 'hint' => 'Yedeği 7-Zip ya da WinRAR ile bu şifreyle açarsın. Kaybetme.']);
  echo toggle('Yedek şifresini kaldır', 'backup_password_clear', false);
  area('Panele girebilen IP adresleri', 'admin_ip_allowlist', site('admin_ip_allowlist'), ['rows' => 3, 'mono' => true, 'hint' => 'Boşsa kısıt yok. Her satıra bir IP; 85.105.* gibi önek de olur. Dışarıda kalırsan: php bin/unlock.php']);
  passwordConfirm(); echo button('Kaydet'); formEnd(); cardEnd(); ?>
  <?php card('Hemen dene'); echo '<div class="stack">'; formStart('telegram_test'); echo button('Telegram\'a test mesajı gönder', 'ghost', ['icon' => 'chat']); formEnd();
  formStart('backup_now', 'stack'); passwordConfirm(); echo button('Şimdi yedek al ve gönder (' . (site('backup_mode', 'db') === 'full' ? 'tam' : 'veritabanı') . ')', 'primary', ['icon' => 'download', 'confirm' => 'Yedek alınıp Telegram\'a gönderilsin mi?']); formEnd();
  formStart('backup_now', 'stack'); hidden('full', '1'); passwordConfirm(); echo button('Tam yedek al: veritabanı + bütün dosyalar', 'ghost', ['icon' => 'download', 'confirm' => 'Bütün sunucu dosyaları ve veritabanı şifreli zip olarak Telegram\'a gönderilsin mi? Birkaç dakika sürebilir.']); formEnd(); echo '</div>'; cardEnd(); ?>
</div>
<div class="cols-2">
  <?php card('Anlık uyarılar', 'Telegram botuna anında mesaj. Aynı türden dakikada en fazla 6 mesaj gider.'); formStart('tg_alerts_save', 'stack', ['autosave' => true]);
  echo toggle('Servis kesintisi', 'tg_alert_services', site('tg_alert_services', '1') === '1', 'VDS indirme servisi düşünce ve geri gelince.');
  echo toggle('Uzun premium verildi', 'tg_alert_premium', site('tg_alert_premium', '1') === '1', '1 yıl ya da süresiz premium açıldığında.');
  echo toggle('Uygulama içi satın alma', 'tg_alert_store', site('tg_alert_store', '1') === '1', 'Yeni satın alma, abonelik yenilenmesi, bitişi ve iade.');
  echo toggle('Yeni hata türü', 'tg_alert_errors', site('tg_alert_errors', '1') === '1', 'Sunucuda ilk kez görülen ya da yeniden başlayan hata.');
  if (!$tg) echo '<p class="notice warn">' . icon('alert') . '<span>Önce yukarıdan Telegram botunu bağla.</span></p>';
  formEnd(); cardEnd(); ?>
  <?php card('Yedekten geri yükle', 'Panelin aldığı .sql.gz ya da şifreli .zip yedeğini geri yükler. Önce şu anki durumun yedeği alınıp sunucuda saklanır.', 'danger-zone'); formStart('backup_restore', 'stack', ['files' => true]); ?>
    <p class="notice warn"><?=icon('alert')?><span>Veritabanının tamamı yedekteki hale döner: o andan sonraki hesaplar, premium değişiklikleri ve ayarlar kaybolur. Yalnızca büyük bir sorundan sonra kullan.</span></p>
    <label class="field"><span class="field-label">Yedek dosyası</span><input class="input" type="file" name="backup" accept=".gz,.zip,application/gzip,application/zip" required><span class="field-hint">Telegram'a gelen dosya. Zip şifresi paneldeki yedek şifresiyle aynı olmalı.</span></label>
    <?php field('Onay için GERİ YÜKLE yaz', 'confirm_text', '', 'text', ['required' => true, 'autocomplete' => 'off']); passwordConfirm(); echo button('Yedeği geri yükle', 'danger', ['icon' => 'upload', 'confirm' => 'Veritabanı bu yedeğe döndürülsün mü? Sonraki bütün değişiklikler kaybolur.']); formEnd(); cardEnd(); ?>
</div>
<?php $devices = q('SELECT d.*,u.username FROM admin_devices d JOIN admins u ON u.id=d.user_id ' . ($admin['role'] === 'admin' ? '' : 'WHERE d.user_id=' . (int)$admin['id'] . ' ') . 'ORDER BY d.last_seen_at DESC LIMIT 50')->fetchAll(); ?>
<div class="cols-2">
  <?php card('Ek korumalar', 'Panel girişi ve ekip hesapları için ek önlemler.'); formStart('guard_save', 'stack');
  echo toggle('Yeni cihazdan girişte Telegram onayı', 'login_approval', site('login_approval', '1') === '1', telegramConfigured() ? 'Şifre (ve kod) doğru olsa bile Telegram\'dan "Onayla" demeden giriş açılmaz. Onaylanan cihaz hatırlanır.' : 'Önce yukarıdan Telegram botunu bağla.');
  selectField('Kritik işlemlerde Telegram kodu', 'step_up_mode', ['new' => 'Yeni ya da şüpheli cihazda sor', 'always' => 'Her zaman sor', 'off' => 'Sorma'], stepUpMode(), ['hint' => 'Ekip hesabı oluşturma, hesap silme, servis anahtarları, yedek geri yükleme ve güvenlik ayarları gibi işlemlerde önce Telegram\'a 6 haneli kod gelir. Kod girilince 15 dakika tekrar sorulmaz. Cihaz, 3 günden yeniyse ya da IP değiştiyse şüpheli sayılır.']);
  echo toggle('İki adımlı giriş herkese zorunlu', 'staff_require_2fa', staffTwoFactorRequired(), 'Açmayan ekip üyesi girişte yalnızca Profil sayfasını görür, açana kadar işlem yapamaz.');
  echo '<div class="grid-fields">';
  field('Pasif ekip hesabı (gün)', 'staff_inactive_days', (string)configValue('staff_inactive_days', 90), 'number', ['min' => 0, 'hint' => 'Bu kadar gün girmeyen destek / izleyici hesabı askıya alınır. Yönetici hesapları hariç. 0 = kapalı.']);
  echo '</div>';
  passwordConfirm(); echo button('Kaydet'); formEnd(); cardEnd(); ?>
  <?php card('Onaylı cihazlar', 'Telegram ile onaylanmış tarayıcılar. Kaldırılan cihazdan bir sonraki girişte yeniden onay istenir.');
  tableView(['Cihaz', 'Hesap', 'Son kullanım', ['', 'actions']], $devices, function ($d) {
      echo '<td><b>' . h($d['label']) . '</b><small class="block muted">' . h((string)$d['last_ip']) . '</small></td><td>' . h($d['username']) . '</td><td class="nowrap">' . h(nbAgo($d['last_seen_at'] ?? $d['created_at'])) . '</td><td class="actions">';
      formStart('device_remove', 'inline'); hidden('id', (int)$d['id']); echo button('Kaldır', 'ghost small danger-text', ['confirm' => 'Bu cihaz kaldırılsın mı?']); formEnd();
      echo '</td>';
  }, 'Henüz onaylanmış cihaz yok.');
  cardEnd(); ?>
</div>
<?php card('Giriş geçmişi', 'Son 50 panel giriş denemesi');
tableView(['Sonuç', 'Hesap', 'IP', 'Tarayıcı', 'Tarih'], q('SELECT * FROM admin_logins ORDER BY id DESC LIMIT 50')->fetchAll(), function ($l) {
    echo '<td>' . ((int)$l['success'] ? pill('Başarılı', 'good') : pill('Hatalı', 'bad')) . '</td><td>' . h($l['login']) . '</td><td class="mono small">' . h($l['ip']) . '</td><td class="small muted wrap">' . h(mb_strimwidth($l['user_agent'], 0, 70, '…')) . '</td><td class="nowrap">' . h(nbDate($l['created_at'])) . '</td>';
}, 'Henüz giriş kaydı yok.');
cardEnd();
