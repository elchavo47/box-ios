<?php
if (!defined('ROOT')) { http_response_code(404); exit; }
 $base = rtrim((string)cfg('app.url'), '/'); ?>
<div class="cols-2">
  <?php card('Marka kimliği', 'E-postalarda ve sayfa başlıklarında kullanılır.'); formStart('site', 'stack');
  field('Site adı', 'site_name', site('site_name', 'NEON BREAK'), 'text', ['required' => true, 'maxlength' => 80]);
  field('Açıklama', 'site_description', site('site_description', 'Neon Break Control Deck'), 'text', ['required' => true, 'maxlength' => 255]);
  field('E-posta alt bilgisi', 'mail_footer', site('mail_footer', 'AYD Works · Neon Break'), 'text', ['required' => true, 'maxlength' => 255]);
  echo button('Kaydet'); formEnd(); cardEnd(); ?>
  <?php card('Sunucu'); ?>
  <ul class="kv">
    <li><span>Sürüm</span><b><?=h(neonBreakVersion())?></b></li>
    <li><span>Veritabanı şeması</span><b><?=h(site('schema_version', '?'))?></b></li>
    <li><span>PHP</span><b><?=h(PHP_VERSION)?></b></li>
    <li><span>Veritabanı</span><b><?=h((string)q('SELECT VERSION()')->fetchColumn())?></b></li>
    <li><span>API adresi</span><b class="mono"><?=h($base . '/api/v1')?></b></li>
    <li><span>Sağlık kontrolü</span><b class="mono"><?=h($base . '/health')?></b></li>
    <li><span>Saat dilimi</span><b><?=h(date_default_timezone_get())?> · <?=date('d.m.Y H:i')?></b></li>
  </ul>
  <?php cardEnd(); ?>
</div>
<?php card('Güncelleme nasıl yapılır', 'Yeni bir backend paketi geldiğinde.'); ?>
<ol class="steps">
  <li><b>Zip'i sitenin klasörüne çıkar, üzerine yaz.</b><span>config/config.php, yüklenen avatarlar ve yedekler pakette yok; dokunulmaz.</span></li>
  <li><b>Paneli aç.</b><span>Veritabanında eksik olan tablo, sütun ve ayarlar ilk açılışta otomatik oluşturulur. Ne yapıldığı bir pencerede gösterilir.</span></li>
  <li><b>Güvenlik durumuna bak.</b><span>"Şimdi tara" ile gizli dosyaların dışarıya kapalı olduğunu doğrula.</span></li>
</ol>
<?php cardEnd(); ?>
