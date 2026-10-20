<?php
if (!defined('ROOT')) { http_response_code(404); exit; }
$has2fa = !empty($admin['totp_enabled_at']);
$recoveryLeft = count(json_decode((string)($admin['totp_recovery'] ?? '[]'), true) ?: []);
$sessions = q('SELECT id,ip,user_agent,remember,created_at,last_seen FROM admin_sessions WHERE user_id=? ORDER BY last_seen DESC LIMIT 20', [(int)$admin['id']])->fetchAll();
$current = hash('sha256', (string)session_id());
$browser = function (string $ua): string {
    $b = str_contains($ua, 'Edg/') ? 'Edge' : (str_contains($ua, 'Chrome/') ? 'Chrome' : (str_contains($ua, 'Firefox/') ? 'Firefox' : (str_contains($ua, 'Safari/') ? 'Safari' : 'Tarayıcı')));
    $os = str_contains($ua, 'iPhone') ? 'iPhone' : (str_contains($ua, 'iPad') ? 'iPad' : (str_contains($ua, 'Android') ? 'Android' : (str_contains($ua, 'Windows') ? 'Windows' : (str_contains($ua, 'Mac OS') ? 'Mac' : (str_contains($ua, 'Linux') ? 'Linux' : '')))));
    return trim($b . ($os ? ' · ' . $os : ''));
};
?>
<section class="dossier slim">
  <div class="dossier-id"><?=avatarHtml($admin, 'xl')?><div><h2><?=h($admin['username'])?></h2><p class="pills"><?=statusPill($admin['role'])?><?=$has2fa ? pill('İki adımlı giriş açık', 'good') : pill('Yalnızca şifre', 'neutral')?></p><p class="muted"><?=h($admin['email'])?> · son giriş <?=h(nbAgo($admin['last_login_at']))?></p></div></div>
</section>
<div class="cols-2">
  <?php card('İki adımlı giriş', 'İsteğe bağlı. Açarsan girişte şifreden sonra telefonundaki 6 haneli kod sorulur; şifren çalınsa bile kimse giremez.', 'totp-card'); ?>
  <?php if ($has2fa): ?>
    <p class="callout ok"><?=icon('lock')?><span><?=h(nbDate($admin['totp_enabled_at'], 'd.m.Y'))?> tarihinden beri açık. <?=$recoveryLeft?> kurtarma kodun kaldı.</span></p>
    <details class="disclosure inline"><summary>Yeni kurtarma kodları üret</summary><div class="disclosure-body"><?php formStart('totp_regen', 'stack', ['result' => 'recovery']); passwordConfirm(); echo button('Kodları üret', 'ghost'); formEnd(); ?></div></details>
    <details class="disclosure inline"><summary>İki adımlı girişi kapat</summary><div class="disclosure-body"><?php formStart('totp_disable', 'stack'); field('Uygulamadaki kod ya da kurtarma kodu', 'code', '', 'text', ['required' => true, 'inputmode' => 'numeric', 'autocomplete' => 'one-time-code']); passwordConfirm(); echo button('Kapat', 'danger', ['confirm' => 'İki adımlı giriş kapatılsın mı?']); formEnd(); ?></div></details>
  <?php else: ?>
    <ol class="steps compact">
      <li><b>Telefonuna Google Authenticator'ı kur.</b><span>Microsoft Authenticator ya da 1Password da olur.</span></li>
      <li><b>Kurulumu başlat, çıkan kareyi tara.</b><span>Tarayamıyorsan altındaki anahtarı elle yaz.</span></li>
      <li><b>Uygulamadaki kodu gir.</b><span>Sonra sana verilen kurtarma kodlarını sakla.</span></li>
    </ol>
    <?php formStart('totp_begin', 'stack', ['result' => 'totp']); echo button('Kurulumu başlat', 'primary', ['icon' => 'phone']); formEnd(); ?>
    <div class="totp-setup" id="totp-setup" hidden>
      <div class="qr"><img id="totp-qr" alt="Google Authenticator için kare kod"></div>
      <p class="muted">Elle giriş anahtarı</p><code class="secret" id="totp-secret"></code>
      <?php formStart('totp_enable', 'stack', ['result' => 'recovery']); field('Uygulamadaki 6 haneli kod', 'code', '', 'text', ['required' => true, 'inputmode' => 'numeric', 'autocomplete' => 'one-time-code', 'maxlength' => 6]); passwordConfirm(); echo button('Doğrula ve aç'); formEnd(); ?>
    </div>
  <?php endif ?>
  <div class="recovery" id="recovery" hidden><p class="callout warn"><?=icon('key')?><span>Kurtarma kodların aşağıda. Her biri bir kez kullanılır. Şimdi bir yere kaydet; bu ekranı kapatınca bir daha gösterilmez.</span></p><ol class="codes" id="recovery-codes"></ol><button type="button" class="btn ghost" data-copy-target="recovery-codes"><?=icon('download')?><span>Kodları kopyala</span></button></div>
  <?php cardEnd(); ?>

  <?php card('Şifre değiştir', 'En az 12 karakter, harf ve rakam. Değiştirince diğer cihazlardaki oturumların kapanır.'); formStart('profile', 'stack');
  field('Mevcut şifre', 'current_password', '', 'password', ['required' => true, 'autocomplete' => 'current-password']);
  field('Yeni şifre', 'password', '', 'password', ['required' => true]); field('Yeni şifre (tekrar)', 'password_again', '', 'password', ['required' => true]);
  echo button('Şifreyi değiştir'); formEnd(); cardEnd(); ?>
</div>
<?php card('Açık oturumların', 'Hesabına giriş yapılmış tarayıcılar. "30 gün açık kalsın" oturumları 30 gün, diğerleri 2 saat hareketsizlikte kapanır.', '', count($sessions) > 1 ? (function () { ob_start(); formStart('sessions_revoke'); echo button('Diğerlerini kapat', 'ghost small', ['confirm' => 'Bu tarayıcı dışındaki bütün oturumlar kapatılsın mı?']); formEnd(); return ob_get_clean(); })() : '');
tableView(['Cihaz', 'IP', 'Son hareket', ''], $sessions, function ($s) use ($current, $browser) {
    echo '<td><b>' . h($browser((string)$s['user_agent'])) . '</b>' . ((int)$s['remember'] ? '<small class="block muted">30 gün açık</small>' : '') . '</td><td class="mono small">' . h($s['ip'] ?? '—') . '</td><td class="nowrap">' . h(nbAgo($s['last_seen'])) . '</td><td class="end">';
    if ($s['id'] === $current) echo pill('Bu tarayıcı', 'good');
    else { formStart('session_revoke'); hidden('session', substr($s['id'], 0, 24)); echo button('Kapat', 'ghost small'); formEnd(); }
    echo '</td>';
});
cardEnd();
