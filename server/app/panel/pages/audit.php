<?php
if (!defined('ROOT')) { http_response_code(404); exit; }
$who = (int)($_GET['u'] ?? 0); $act = mb_substr(trim((string)($_GET['a'] ?? '')), 0, 60);
$where = []; $args = [];
if ($who) { $where[] = 'l.admin_id=?'; $args[] = $who; }
if ($act !== '') { $where[] = 'l.action LIKE ?'; $args[] = '%' . addcslashes($act, '%_\\') . '%'; }
$rows = q('SELECT l.*,u.username FROM admin_audit_log l LEFT JOIN admins u ON u.id=l.admin_id' . ($where ? ' WHERE ' . implode(' AND ', $where) : '') . ' ORDER BY l.id DESC LIMIT 200', $args)->fetchAll();
$verify = json_decode(site('audit_verify'), true) ?: ['ok' => true, 'checked' => 0, 'at' => null];
$staff = array_column(q('SELECT id,username FROM admins ORDER BY username')->fetchAll(), 'username', 'id');
$names = ['login' => 'Giriş', 'logout' => 'Çıkış', 'install' => 'Kurulum', 'premium_grant' => 'Premium verildi', 'premium_revoke' => 'Premium kapatıldı', 'user_ban' => 'Hesap askıya alındı', 'user_unban' => 'Hesap açıldı', 'user_note' => 'Kullanıcı notu', 'user_rename' => 'Kullanıcı bilgisi', 'user_logout_all' => 'Cihazlardan çıkarıldı', 'user_delete' => 'Hesap silindi', 'app_save' => 'Uygulama ayarı', 'services_save' => 'Servis ayarı', 'services_check' => 'VDS kontrolü', 'services_test_search' => 'Deneme araması', 'cron_key_regen' => 'Cron adresi yenilendi', 'cron_run' => 'Görevler çalıştırıldı', 'team_create' => 'Ekip hesabı', 'team_update' => 'Ekip yetkisi', 'team_reset_password' => 'Ekip şifresi', 'team_reset_2fa' => 'Ekip 2FA sıfırlandı', 'team_kick' => 'Ekip oturumları kapatıldı', 'security_save' => 'Güvenlik ayarı', 'backup_now' => 'Elle yedek', 'backup_restore' => 'Yedek geri yüklendi', 'password_change' => 'Şifre değişti', 'totp_enable' => '2FA açıldı', 'totp_disable' => '2FA kapatıldı', 'totp_regen' => 'Kurtarma kodları', 'security_scan' => 'Erişim taraması', 'audit_export' => 'Günlük dışa aktarıldı'];
?>
<section class="audit-head">
  <p class="callout <?=$verify['ok'] ? 'ok' : 'bad'?>"><?=icon($verify['ok'] ? 'lock' : 'alert')?><span><?=$verify['ok'] ? 'Zincir sağlam: ' . nbNum($verify['checked']) . ' kayıt doğrulandı, hiçbiri silinmemiş ya da değiştirilmemiş.' : 'Zincir #' . (int)$verify['broken_at'] . ' numaralı kayıtta kırık. Bu kayıttan itibaren günlük veritabanında değiştirilmiş.'?><?=$verify['at'] ? ' Son doğrulama ' . h(nbAgo($verify['at'])) . '.' : ''?></span></p>
  <?php if ($admin['role'] === 'admin'): ?><a class="btn ghost" href="/admin?p=audit&amp;export=audit" data-download><?=icon('download')?><span>CSV indir</span></a><?php endif ?>
</section>
<form method="get" class="toolbar">
  <input type="hidden" name="p" value="audit">
  <?php selectField('Yetkili', 'u', ['0' => 'Herkes'] + $staff, (string)$who); ?>
  <label class="search-field"><?=icon('search')?><input class="input" name="a" value="<?=h($act)?>" placeholder="İşlem adı, örn. premium" aria-label="İşlem ara"></label>
  <?=button('Filtrele', 'ghost')?>
</form>
<?php card('Kayıtlar', 'Son 200');
tableView(['Zaman', 'Yetkili', 'İşlem', 'Ayrıntı', 'IP', ''], $rows, function ($l) use ($names) {
    $d = json_decode((string)$l['details'], true); $parts = [];
    if (is_array($d)) foreach ($d as $k => $v) $parts[] = $k . ': ' . (is_scalar($v) ? (string)$v : json_encode($v, JSON_UNESCAPED_UNICODE));
    $target = is_array($d) && !empty($d['user_id']) && in_array($l['action'], ['premium_grant', 'premium_revoke', 'user_ban', 'user_unban', 'user_note', 'user_rename', 'user_logout_all'], true) ? ' <a href="/admin?p=player&amp;id=' . (int)$d['user_id'] . '">kullanıcı</a>' : '';
    echo '<td class="nowrap">' . h(nbDate($l['created_at'], 'd.m.Y H:i:s')) . '</td><td>' . h($l['username'] ?? 'sistem') . '</td><td><b>' . h($names[$l['action']] ?? $l['action']) . '</b></td><td class="wrap small">' . h(implode(' · ', $parts)) . $target . '</td><td class="mono small">' . h($l['ip'] ?? '') . '</td><td>' . ($l['row_hash'] ? '<span class="chain" title="Zincirli kayıt">' . icon('lock') . '</span>' : '') . '</td>';
}, 'Bu filtreyle kayıt yok.');
cardEnd();
