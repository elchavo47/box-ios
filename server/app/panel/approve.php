<?php
if (!defined('ROOT')) { http_response_code(404); exit; }




header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
header('X-Robots-Tag: noindex, nofollow');
header('Referrer-Policy: no-referrer');
header("Content-Security-Policy: default-src 'none'; style-src 'self'; font-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'self'; frame-ancestors 'none'");
$tok = (string)($_GET['t'] ?? $_POST['t'] ?? '');
$state = preg_match('/^[A-Za-z0-9_-]{40,64}$/', $tok) ? loginApprovalState($tok) : null;
$user = $state ? q('SELECT username FROM admins WHERE id=?', [$state['user_id']])->fetchColumn() : null;
$done = '';
if (($_SERVER['REQUEST_METHOD'] ?? 'GET') === 'POST' && $state && $state['status'] === 'pending') {
    throttle('approve:' . clientIpHash(), 20, 600);
    $ok = ($_POST['decision'] ?? '') === 'approve';
    q("UPDATE admin_login_approvals SET status=?,decided_at=NOW() WHERE token_hash=? AND status='pending'", [$ok ? 'approved' : 'denied', hash('sha256', $tok)]);
    logAdmin((int)$state['user_id'], $ok ? 'login_approved' : 'login_denied', ['ip' => $state['ip']]);
    $done = $ok ? 'Giriş onaylandı. Bilgisayardaki panel birkaç saniye içinde açılır.' : 'Giriş reddedildi. Sen değilsen şifreni hemen değiştir.';
    $state = loginApprovalState($tok);
}
$h = fn($v) => htmlspecialchars((string)$v, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
?><!doctype html>
<html lang="tr" data-theme="dark"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow">
<title>Giriş onayı · Box</title><link rel="stylesheet" href="/assets/deck.css?v=<?=$h(boxVersion())?>"></head>
<body class="auth"><main class="auth-shell single"><section class="auth-panel"><div class="auth-form">
<?php if ($done !== ''): ?>
  <h2><?=$state && $state['status'] === 'approved' ? 'Onaylandı' : 'Reddedildi'?></h2><p class="muted"><?=$h($done)?></p>
<?php elseif (!$state || $state['status'] !== 'pending'): ?>
  <h2>Bağlantı geçersiz</h2><p class="muted">Bu onay isteğinin süresi dolmuş ya da daha önce yanıtlanmış.</p>
<?php else: ?>
  <h2>Panel girişi onayı</h2>
  <p class="muted"><b><?=$h($user)?></b> hesabıyla yeni bir cihazdan giriş yapılıyor.</p>
  <dl class="approve-meta"><dt>Cihaz</dt><dd><?=$h($state['label'])?></dd><dt>IP</dt><dd><?=$h($state['ip'])?></dd><dt>Zaman</dt><dd><?=$h(date('d.m.Y H:i', strtotime((string)$state['created_at'])))?></dd></dl>
  <form method="post" class="stack"><input type="hidden" name="t" value="<?=$h($tok)?>">
    <button class="btn primary block" name="decision" value="approve"><span>Evet, bu benim. Onayla</span></button>
    <button class="btn danger block" name="decision" value="deny"><span>Ben değilim. Reddet</span></button>
  </form>
  <p class="auth-fine">Onaylanan cihaz hatırlanır; bir daha onay istenmez. Cihazları Panel > Koruma ve yedek sayfasından kaldırabilirsin.</p>
<?php endif ?>
</div></section></main></body></html>
