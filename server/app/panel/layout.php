<?php
if (!defined('ROOT')) { http_response_code(404); exit; }

$meta = $pages[$page];
$checks = in_array($admin['role'], ['admin', 'viewer'], true) ? securityChecks() : [];
$summary = checkSummary($checks);
$alertCount = $summary['bad'] + $summary['warn'];
$descriptions = [
    'dashboard' => 'Bugün Box\'ta neler oluyor, neyin dikkat beklediği.',
    'status' => 'Sunucudan servislere, yedekten panele kadar bütün güvenlik kontrolleri.',
    'users' => 'Kullanıcıları bul, dosyalarını aç, hesaplarını ve premiumlarını yönet.',
    'player' => 'Hesap bilgileri, premium geçmişi, indirmeler ve açık oturumlar.',
    'premium' => 'Premium üyeler, yakında bitecekler ve son premium hareketleri.',
    'downloads' => 'Premium kullanıcıların indirdiği şarkılar ve günlük kullanım.',
    'stats' => 'Aktif kullanıcılar, indirme ve arama eğilimleri, en çok arananlar.',
    'app' => 'Uygulamanın uzaktan ayarları: bakım modu, duyuru, zorunlu güncelleme ve kotalar. Değişiklikler uygulamaya anında yansır.',
    'services' => 'VDS indirme servisi ve YouTube arama anahtarı: durum, kota ve ayarlar.',
    'notify' => 'Uygulamaya bildirim gönder: herkese, premium üyelere ya da tek kişiye. Otomatik bildirimler de buradan açılıp kapanır.',
    'health' => 'Uygulama API isteklerinin yanıt süresi ve hata oranı.',
    'shield' => 'Telegram uyarıları, şifreli günlük yedek, IP kısıtı, oturumlar ve giriş geçmişi.',
    'team' => 'Ekip hesapları ve yetkileri.',
    'audit' => 'Panelde kim, ne zaman, ne yaptı. Kayıtlar zincirlidir; silinen ya da değiştirilen kayıt fark edilir.',
    'logs' => 'Sunucunun PHP hata günlüğü (ham hali). Gruplanmış hali Hatalar sayfasında.',
    'errors' => 'Sunucuda oluşan hatalar türlerine göre gruplanır. Yeni bir tür çıkınca Telegram\'a haber gelir.',
    'settings' => 'Sürüm, zip ile güncelleme, zamanlanmış görev ve sunucu bilgisi.',
    'profile' => 'Şifren, iki adımlı giriş ve açık oturumların.',
];

$migration = null;
if ($admin['role'] === 'admin') {
    $rep = json_decode(site('migration_report'), true);
    if (is_array($rep) && ($rep['id'] ?? '') !== site('migration_seen_' . (int)$admin['id'])) $migration = $rep;
}
$groups = [];
foreach ($pages as $key => [$ic, $label, $group, $roles]) if ($group !== null && in_array($admin['role'], $roles, true)) $groups[$group][$key] = [$ic, $label];
$badgeCounts = [
    'status' => $summary['bad'],
    'errors' => canSee($admin, 'errors') ? errorOpenCount() : 0,
    'premium' => (int)q('SELECT COUNT(*) FROM users WHERE is_premium=1 AND premium_until IS NOT NULL AND premium_until>NOW() AND premium_until<DATE_ADD(NOW(),INTERVAL 3 DAY)')->fetchColumn(),
];
$appVer = h(boxVersion());
?><!doctype html>
<html lang="tr" data-theme="dark">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow">
<title><?=h($meta[1])?> · Box Control Deck</title>
<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">
<link rel="manifest" href="/admin/manifest.json">
<link rel="apple-touch-icon" href="/assets/panel-touch.png">
<meta name="theme-color" content="#0B0F0D"><meta name="apple-mobile-web-app-capable" content="yes"><meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent"><meta name="apple-mobile-web-app-title" content="Box Panel">
<link rel="stylesheet" href="/assets/deck.css?v=<?=$appVer?>">
<script src="/assets/theme.js?v=<?=$appVer?>"></script>
</head>
<body class="deck">
<a class="skip" href="#main">İçeriğe geç</a>
<aside class="rail" id="rail" aria-label="Ana menü">
  <a class="rail-brand" href="/admin"><?=brandMark()?><span>Box<small>Control Deck</small></span></a>
  <nav class="rail-nav">
    <?php foreach ($groups as $group => $items): ?>
    <div class="rail-group"><p><?=h($group)?></p>
      <?php foreach ($items as $key => [$ic, $label]): $active = $key === $page || ($key === 'users' && $page === 'player'); $n = $badgeCounts[$key] ?? 0; ?>
      <a href="/admin?p=<?=h($key)?>" class="<?=$active ? 'on' : ''?>"<?=$active ? ' aria-current="page"' : ''?>><?=icon($ic)?><span><?=h($label)?></span><?php if ($n > 0): ?><em class="<?=$key === 'status' ? 'bad' : ''?>"><?=$n > 99 ? '99+' : $n?></em><?php endif ?></a>
      <?php endforeach ?>
    </div>
    <?php endforeach ?>
  </nav>
  <div class="rail-foot">
    <a class="me" href="/admin?p=profile"><?=avatarHtml($admin)?><span><b><?=h($admin['username'])?></b><small><?=h(NB_ROLES[$admin['role']] ?? $admin['role'])?><?=!empty($admin['totp_enabled_at']) ? ' · 2FA' : ''?></small></span></a>
    <?php formStart('logout', 'logout'); ?><button class="icon-btn" title="Çıkış yap" aria-label="Çıkış yap"><?=icon('logout')?></button><?php formEnd(); ?>
  </div>
</aside>
<button class="scrim" aria-label="Menüyü kapat" tabindex="-1"></button>
<div class="frame">
  <header class="bar">
    <button class="icon-btn menu-btn" aria-label="Menüyü aç" aria-controls="rail"><?=icon('menu')?></button>
    <button type="button" class="search-trigger" id="search-trigger" data-index="<?=h(json_encode(panelSearchIndex($admin), JSON_UNESCAPED_UNICODE))?>"><?=icon('search')?><span>Kullanıcı, ayar ya da işlem ara</span><kbd>Ctrl K</kbd></button>
    <div class="bar-right">
      <?php if ($checks): ?>
      <a class="health-chip <?=$summary['bad'] ? 'bad' : ($summary['warn'] ? 'warn' : 'ok')?>" href="/admin?p=status"><?=stateDot($summary['bad'] ? 'bad' : ($summary['warn'] ? 'warn' : 'ok'))?><span class="chip-long"><?=$alertCount ? $alertCount . ' konu dikkat bekliyor' : 'Sistem sağlıklı'?></span><span class="chip-short"><?=$alertCount ? $alertCount . ' konu' : 'Sağlıklı'?></span></a>
      <?php endif ?>
      <button type="button" class="icon-btn theme-btn" aria-label="Temayı değiştir" title="Temayı değiştir"><?=icon('moon', 'i t-dark')?><?=icon('sun', 'i t-light')?></button>
    </div>
  </header>
  <main class="page" id="main" tabindex="-1">
    <div class="page-head">
      <div>
        <?php if ($page === 'player'): ?><a class="crumb" href="/admin?p=users"><?=icon('back')?> Kullanıcılar</a><?php endif ?>
        <h1><?=h($meta[1])?></h1>
        <p><?=h($descriptions[$page] ?? '')?></p>
      </div>
      <div class="page-actions" id="page-actions"></div>
    </div>
    <?php if ($flash && $flash['text'] !== ''): ?><div class="flash" data-flash="<?=h($flash['type'])?>" hidden><?=h($flash['text'])?></div><?php endif ?>
    <?php if ($admin['role'] === 'viewer'): ?><div class="notice info"><?=icon('eye')?><span>İzleyici hesabıyla giriş yaptın: her şeyi görebilirsin, değişiklik yapamazsın.</span></div><?php endif ?>
    <?php require ROOT . '/app/panel/pages/' . $page . '.php'; ?>
    <footer class="page-foot"><span>Box Control Deck <?=$appVer?></span><span>AYD Works · <?=date('Y')?></span></footer>
  </main>
</div>
<?php if ($migration): $items = (array)($migration['items'] ?? []); ?>
<dialog class="modal migration" id="migration-modal" data-open-on-load>
  <div class="modal-body">
    <div class="migration-hero"><?=brandMark('mark lg')?><div><h2>Güncelleme tamamlandı</h2><p><?=h($migration['from_app'])?> → <b><?=h($migration['to_app'])?></b> · <?=h(nbDate($migration['at']))?></p></div></div>
    <?php if ($items): ?>
    <p>Veritabanında eksik olan <?=count($items)?> şey otomatik oluşturuldu. Mevcut verilere ve ayarlarına dokunulmadı.</p>
    <ul class="migration-list">
      <?php foreach (array_slice($items, 0, 40) as $it): ?><li><?=icon('check')?><span><?=h($it['what'])?></span><code><?=h($it['name'])?></code></li><?php endforeach ?>
      <?php if (count($items) > 40): ?><li class="more">ve <?=count($items) - 40?> değişiklik daha</li><?php endif ?>
    </ul>
    <?php else: ?>
    <p>Veritabanı zaten günceldi; oluşturulması gereken bir şey çıkmadı.</p>
    <?php endif ?>
    <p class="muted">Şema sürümü <?=(int)$migration['from_schema']?> → <?=(int)$migration['to_schema']?> · <?=(int)$migration['ms']?> ms sürdü.</p>
  </div>
  <?php formStart('migration_ack', 'modal-foot'); hidden('id', $migration['id']); ?><a class="btn ghost" href="/admin?p=status">Güvenlik durumunu aç</a><button class="btn primary" autofocus><span>Tamam</span></button><?php formEnd(); ?>
</dialog>
<?php endif ?>
<?php

$tabs = array_values(array_filter([['dashboard', 'grid', 'Özet'], ['users', 'users', 'Kullanıcılar'], ['premium', 'bolt', 'Premium'], [canSee($admin, 'app') ? 'app' : 'downloads', canSee($admin, 'app') ? 'sliders' : 'download', canSee($admin, 'app') ? 'Uygulama' : 'İndirme']], fn($t) => canSee($admin, $t[0])));
?>
<nav class="tabbar" aria-label="Hızlı menü">
  <?php foreach ($tabs as [$key, $ic, $label]): $active = $key === $page || ($key === 'users' && $page === 'player'); $n = $badgeCounts[$key] ?? 0; ?>
  <a href="/admin?p=<?=h($key)?>" class="<?=$active ? 'on' : ''?>"<?=$active ? ' aria-current="page"' : ''?>><?=icon($ic)?><span><?=h($label)?></span><?php if ($n > 0): ?><em><?=$n > 99 ? '99+' : $n?></em><?php endif ?></a>
  <?php endforeach ?>
  <button type="button" class="menu-btn tab-menu" aria-controls="rail"><?=icon('menu')?><span>Menü</span></button>
</nav>
<div class="toasts" id="toasts" aria-live="polite"></div>
<div class="loadbar" id="loadbar"></div>
<script src="/admin/static/qrcode.js?v=<?=$appVer?>"></script>
<script src="/admin/static/deck.js?v=<?=$appVer?>"></script>
</body>
</html>
