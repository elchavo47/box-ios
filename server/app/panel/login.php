<?php
if (!defined('ROOT')) { http_response_code(404); exit; }

$siteName = 'BOX';
?><!doctype html>
<html lang="tr" data-theme="dark">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow">
<title>Giriş · Box Control Deck</title>
<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/assets/deck.css?v=<?=h(boxVersion())?>">
<?php if (!empty($waiting)): ?><meta http-equiv="refresh" content="3"><?php endif ?>
<script src="/assets/theme.js?v=<?=h(boxVersion())?>"></script>
</head>
<body class="auth">
<main class="auth-shell">
  <section class="auth-stage" aria-hidden="true">
    <div class="auth-brand"><?=brandMark('mark lg')?><span>Box<small>Control Deck</small></span></div>
    <div class="eq" aria-hidden="true">
      <?php foreach ([4, 7, 5, 9, 6, 8, 3, 7, 10, 6, 4, 8, 5, 9, 7, 4, 6, 8] as $i => $n): ?><span class="eq-col d<?=$i % 9?>"><?php for ($k = 0; $k < $n; $k++): ?><i></i><?php endfor ?></span><?php endforeach ?>
    </div>
    <div class="auth-copy">
      <h1>Box'ın bütün kolları burada.</h1>
      <p>Kullanıcılar, premium, uygulama ayarları ve servisler. Her işlem kayıt altında, her giriş izleniyor.</p>
    </div>
  </section>
  <section class="auth-panel">
    <?php if (!empty($waiting)): ?>
    <div class="auth-form">
      <h2>Telegram onayı bekleniyor</h2>
      <p class="muted">Bu cihazdan ilk kez giriş yapılıyor. Telegram'a gelen bağlantıyı açıp girişi onayla; bu sayfa kendiliğinden devam eder.</p>
      <div class="approve-wait" aria-hidden="true"><i></i><i></i><i></i></div>
      <p class="auth-fine"><?=icon('lock')?> Onay 10 dakika geçerli. Onaylanan cihaz hatırlanır.</p>
    </div>
    <form method="post" action="/admin" class="auth-alt" data-noajax><input type="hidden" name="csrf" value="<?=h(csrf())?>"><input type="hidden" name="action" value="login_cancel"><button class="link">Vazgeç</button></form>
    <?php elseif (!$pending): ?>
    <form method="post" action="/admin" class="auth-form" autocomplete="on" data-noajax>
      <h2>Giriş yap</h2>
      <p class="muted">Ekip hesabınla devam et.</p>
      <?php if ($error): ?><div class="notice bad" role="alert"><?=icon('alert')?><span><?=h($error)?></span></div><?php endif ?>
      <input type="hidden" name="csrf" value="<?=h(csrf())?>"><input type="hidden" name="action" value="login">
      <label class="field"><span class="field-label">Kullanıcı adı</span><input class="input" name="login" autocomplete="username" required autofocus maxlength="190"></label>
      <label class="field"><span class="field-label">Şifre</span><input class="input" name="password" type="password" autocomplete="current-password" required maxlength="200"></label>
      <?=toggle('Bu cihazda 30 gün açık kalsın', 'remember', false, 'Yalnızca kendi bilgisayarında aç.')?>
      <button class="btn primary block"><span>Giriş yap</span></button>
      <p class="auth-fine"><?=icon('lock')?> Bağlantı şifreli. 15 dakikada 10 hatalı denemeden sonra giriş kilitlenir ve Telegram'a uyarı gider.</p>
    </form>
    <?php else: ?>
    <form method="post" action="/admin" class="auth-form" autocomplete="off" data-noajax>
      <h2>Doğrulama kodu</h2>
      <p class="muted">Google Authenticator'daki 6 haneli kodu gir. Telefonun yanında değilse kurtarma kodlarından birini yazabilirsin.</p>
      <?php if ($error): ?><div class="notice bad" role="alert"><?=icon('alert')?><span><?=h($error)?></span></div><?php endif ?>
      <input type="hidden" name="csrf" value="<?=h(csrf())?>"><input type="hidden" name="action" value="login_2fa">
      <label class="field"><span class="field-label">Kod</span><input class="input code-input" name="code" inputmode="numeric" autocomplete="one-time-code" required autofocus maxlength="11" placeholder="123456"></label>
      <button class="btn primary block"><span>Doğrula</span></button>
    </form>
    <form method="post" action="/admin" class="auth-alt" data-noajax><input type="hidden" name="csrf" value="<?=h(csrf())?>"><input type="hidden" name="action" value="login_cancel"><button class="link">Başka hesapla giriş yap</button></form>
    <?php endif ?>
    <footer class="auth-foot">BOX · AYD Works</footer>
  </section>
</main>
</body>
</html>
