<?php
if (!defined('ROOT')) { http_response_code(404); exit; }
$devices = (int)q('SELECT COUNT(*) FROM push_devices')->fetchColumn();
$users = (int)q('SELECT COUNT(DISTINCT user_id) FROM push_devices')->fetchColumn();
$premUsers = (int)q('SELECT COUNT(DISTINCT d.user_id) FROM push_devices d JOIN users u ON u.id=d.user_id WHERE u.is_premium=1 AND (u.premium_until IS NULL OR u.premium_until>NOW())')->fetchColumn();
$log = q('SELECT p.*,a.username admin_name FROM push_log p LEFT JOIN admins a ON a.id=p.admin_id ORDER BY p.id DESC LIMIT 50')->fetchAll();
$prefill = isset($_GET['user']) ? (string)(int)$_GET['user'] : '';
$ready = boxAppleConfigured() && boxPushSupported();
$targets = ['all' => 'Herkes', 'premium' => 'Premium üyeler', 'free' => 'Ücretsiz üyeler', 'user' => 'Tek kullanıcı'];
?>
<section class="kpis">
  <?=kpi('Bildirime açık cihaz', nbNum($devices), nbNum($users) . ' kullanıcı')?>
  <?=kpi('Premium', nbNum($premUsers), 'bildirime açık premium üye')?>
  <?=kpi('Durum', $ready ? 'Hazır' : 'Ayar eksik', $ready ? 'Apple anahtarı tanımlı' : 'Servisler > Apple bölümünü doldur', $ready ? 'good' : 'bad')?>
</section>
<div class="cols-2">
  <?php card('Bildirim gönder', 'Kullanıcının telefonuna anında düşer. Uygulama kapalı olsa bile görünür.');
  formStart('push_send', 'stack');
  selectField('Kime', 'target', $targets, $prefill !== '' ? 'user' : 'all');
  field('Kullanıcı (yalnızca "Tek kullanıcı" seçiliyse)', 'user', $prefill, 'text', ['placeholder' => 'Numara ya da e-posta']);
  field('Başlık', 'title', '', 'text', ['required' => true, 'maxlength' => 120, 'placeholder' => 'Örnek: Yeni sürüm hazır']);
  area('Metin', 'body', '', ['required' => true, 'maxlength' => 400, 'rows' => 3, 'placeholder' => 'Örnek: TestFlight\'tan güncelle, yeni özellikler seni bekliyor.']);
  echo '<details class="stack"><summary class="muted">İngilizce metin (isteğe bağlı)</summary>';
  field('Title (English)', 'title_en', '', 'text', ['maxlength' => 120, 'placeholder' => 'Example: New version is ready', 'hint' => 'Uygulamayı Türkçe dışında bir dilde kullananlara bu gider. Boş bırakırsan herkese Türkçe metin gider.']);
  area('Text (English)', 'body_en', '', ['maxlength' => 400, 'rows' => 3, 'placeholder' => 'Example: Update from TestFlight, new features are waiting for you.']);
  echo '</details>';
  echo '<div class="row-actions">' . button('Gönder', 'primary', ['icon' => 'bell', 'confirm' => 'Bildirim seçtiğin herkese hemen gönderilecek.']) . '</div>';
  formEnd(); cardEnd(); ?>

  <?php card('Otomatik bildirimler', 'Box bunları kendiliğinden gönderir.');
  formStart('push_auto_save', 'stack');
  echo toggle('Premium açılınca / uzatılınca', 'push_auto_premium', site('push_auto_premium', '1') === '1', 'Panelden premium verdiğinde kullanıcıya haber verir.');
  echo toggle('Premium bitmeden 3 gün önce', 'push_auto_expiring', site('push_auto_expiring', '1') === '1', 'Her üyelik dönemi için bir kez hatırlatır (zamanlanmış görevle çalışır).');
  echo toggle('Premium süresi dolunca', 'push_auto_expired', site('push_auto_expired', '1') === '1', '"Premium üyeliğin sona erdi"');
  echo toggle('Panelden premium kapatılınca', 'push_auto_revoke', site('push_auto_revoke', '1') === '1', '"Premium üyeliğin kapatıldı"');
  echo toggle('Hesap askıya alınınca / açılınca', 'push_auto_ban', site('push_auto_ban', '1') === '1', 'Gerekçe yazdıysan bildirimde görünür.');
  echo '<div class="row-actions">' . button('Kaydet', 'ghost') . '</div>';
  formEnd(); cardEnd(); ?>
</div>
<?php card('Gönderilenler', 'Son 50');
$names = ['all' => 'Herkes', 'premium' => 'Premium', 'free' => 'Ücretsiz'];
tableView(['Bildirim', 'Kime', 'Sonuç', 'Gönderen', 'Zaman'], $log, function ($r) use ($names) {
    $target = $names[$r['target']] ?? (str_starts_with((string)$r['target'], 'user:') ? '<a href="/admin?p=player&amp;id=' . (int)substr((string)$r['target'], 5) . '">#' . (int)substr((string)$r['target'], 5) . '</a>' : h($r['target']));
    if (isset($names[$r['target']])) $target = h($target);
    echo '<td><b>' . h($r['title']) . '</b><small class="block muted">' . h(mb_strimwidth((string)$r['body'], 0, 90, '…')) . '</small></td><td>' . $target . '</td><td>' . pill((int)$r['sent'] . ' gönderildi', (int)$r['sent'] ? 'good' : 'bad') . ((int)$r['failed'] ? ' <small class="muted">' . (int)$r['failed'] . ' başarısız' . ($r['error'] ? ' · ' . h($r['error']) : '') . '</small>' : '') . '</td><td>' . h($r['admin_name'] ?? 'Sistem') . '</td><td class="nowrap">' . h(nbAgo($r['created_at'])) . '</td>';
}, 'Henüz bildirim gönderilmedi.');
cardEnd();
