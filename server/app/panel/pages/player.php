<?php
if (!defined('ROOT')) { http_response_code(404); exit; }
$uid = (int)($_GET['id'] ?? 0);
$u = boxFindUser($uid);
if (!$u) { card(); echo emptyState('Kullanıcı bulunamadı', 'Numara yanlış olabilir ya da hesap silinmiş.') . '<p><a class="btn ghost" href="/admin?p=users">Kullanıcılara dön</a></p>'; cardEnd(); return; }
$isPrem = boxIsPremium($u);
$q = boxQuota($u);
$devices = q('SELECT device,created_at,last_used_at,expires_at FROM tokens WHERE user_id=? AND expires_at>NOW() ORDER BY COALESCE(last_used_at,created_at) DESC', [$uid])->fetchAll();
$dls = q('SELECT * FROM downloads WHERE user_id=? ORDER BY id DESC LIMIT 50', [$uid])->fetchAll();
$plog = q('SELECT p.*,a.username admin_name FROM premium_log p LEFT JOIN admins a ON a.id=p.admin_id WHERE p.user_id=? ORDER BY p.id DESC LIMIT 20', [$uid])->fetchAll();
$facts = [
    ['Üyelik', $isPrem ? 'Premium' : 'Ücretsiz'], ['Premium bitişi', $isPrem ? ($u['premium_until'] ? nbDate($u['premium_until']) : 'Süresiz') : '—'],
    ['Toplam indirme', nbNum((int)q('SELECT COUNT(*) FROM downloads WHERE user_id=?', [$uid])->fetchColumn())], ['Bugün', $q['downloads_used'] . ' indirme · ' . $q['searches_used'] . ' arama'],
    ['Kayıt', nbDate($u['created_at'], 'd.m.Y')], ['Son giriş', nbAgo($u['last_login_at'])], ['Son görülme', nbAgo($u['last_seen_at'])], ['Uygulama', $u['app_version'] ?: '—'],
];
$labels = ['grant' => 'Premium açıldı', 'extend' => 'Premium uzatıldı', 'revoke' => 'Premium kapatıldı', 'trial' => 'Deneme verildi', 'expire' => 'Süresi doldu'];
?>
<section class="dossier">
  <div class="dossier-id">
    <?=avatarHtml($u, 'xl')?>
    <div>
      <h2><?=h($u['display_name'])?> <span class="muted">#<?=$uid?></span></h2>
      <p class="pills"><?=statusPill($isPrem ? 'premium' : 'free')?><?=pill($u['email'], 'neutral')?><?php if ((int)$u['is_banned']): ?><?=pill('Askıda', 'bad')?><?php endif ?></p>
      <?php if ($u['ban_reason']): ?><p class="muted">Gerekçe: <?=h($u['ban_reason'])?></p><?php endif ?>
    </div>
  </div>
  <dl class="facts"><?php foreach ($facts as [$k, $v]): ?><div><dt><?=h($k)?></dt><dd><?=h($v)?></dd></div><?php endforeach ?></dl>
</section>

<div class="cols-2">
  <?php if (can('premium_grant')): card('Premium', $isPrem ? 'Şu an açık. Süre eklersen mevcut bitişin üstüne eklenir.' : 'Açınca arama ve indirme sekmesi uygulamada görünür.'); ?>
    <?php formStart('premium_grant', 'stack'); hidden('user_id', $uid); ?>
    <div class="chips">
      <?php foreach ([7 => '1 hafta', 30 => '1 ay', 90 => '3 ay', 365 => '1 yıl', 0 => 'Süresiz'] as $d => $l): ?>
      <label class="chip"><input type="radio" name="days" value="<?=$d?>"<?=$d === 30 ? ' checked' : ''?>><span><?=h($l)?></span></label>
      <?php endforeach ?>
    </div>
    <div class="row-actions"><?=button($isPrem ? 'Süre ekle' : 'Premium aç', 'primary', ['icon' => 'bolt'])?></div>
    <?php formEnd(); ?>
    <?php if ($isPrem): formStart('premium_revoke'); hidden('user_id', $uid); echo button('Premiumu kapat', 'danger ghost', ['confirm' => 'Premium hemen kapanacak. Emin misin?']); formEnd(); endif ?>
  <?php cardEnd(); endif ?>

  <?php card('Hesap'); ?>
    <?php if (can('user_rename')): formStart('user_rename', 'stack'); hidden('user_id', $uid); field('İsim', 'display_name', $u['display_name'], 'text', ['required' => true]); field('E-posta', 'email', $u['email'], 'email', ['required' => true]); echo '<div class="row-actions">' . button('Kaydet', 'ghost') . '</div>'; formEnd(); endif ?>
    <?php if (can('user_note')): formStart('user_note', 'stack'); hidden('user_id', $uid); area('Ekip notu', 'note', (string)$u['note'], ['hint' => 'Yalnızca panelde görünür.']); echo '<div class="row-actions">' . button('Notu kaydet', 'ghost') . '</div>'; formEnd(); endif ?>
  <?php cardEnd(); ?>
</div>

<div class="cols-2 wide-left">
  <?php card('İndirdikleri', 'Son 50');
  tableView(['Şarkı', 'Zaman'], $dls, function ($r) {
      echo '<td><a class="track" href="https://www.youtube.com/watch?v=' . h($r['video_id']) . '" target="_blank" rel="noopener noreferrer"><img src="https://i.ytimg.com/vi/' . h($r['video_id']) . '/default.jpg" alt="" loading="lazy"><b>' . h($r['title'] !== '' ? $r['title'] : $r['video_id']) . '</b></a></td><td class="nowrap">' . h(nbDate($r['created_at'])) . '</td>';
  }, 'Henüz indirme yok.');
  cardEnd(); ?>
  <div class="stack">
    <?php card('Cihazlar', count($devices) . ' açık oturum');
    tableView(['Cihaz', 'Son kullanım'], $devices, function ($d) { echo '<td>' . h(mb_strimwidth((string)($d['device'] ?: 'Bilinmeyen cihaz'), 0, 48, '…')) . '</td><td class="nowrap">' . h(nbAgo($d['last_used_at'] ?? $d['created_at'])) . '</td>'; }, 'Açık oturum yok.');
    if ($devices && can('user_logout_all')) { formStart('user_logout_all'); hidden('user_id', $uid); echo button('Bütün cihazlardan çıkar', 'ghost', ['confirm' => 'Kullanıcı tekrar giriş yapmak zorunda kalacak.']); formEnd(); }
    cardEnd(); ?>
    <?php card('Premium geçmişi');
    tableView(['İşlem', 'Kim', 'Zaman'], $plog, function ($p) use ($labels) { echo '<td>' . h($labels[$p['action']] ?? $p['action']) . ($p['days'] ? ' <small class="muted">' . (int)$p['days'] . ' gün</small>' : '') . '</td><td>' . h($p['admin_name'] ?? 'Sistem') . '</td><td class="nowrap">' . h(nbDate($p['created_at'])) . '</td>'; }, 'Kayıt yok.');
    cardEnd(); ?>
  </div>
</div>

<?php if (can('user_ban') || can('user_delete')): card('Tehlikeli bölge', '', 'danger-zone'); ?>
  <div class="cols-2">
    <div>
    <?php if ((int)$u['is_banned']): formStart('user_unban'); hidden('user_id', $uid); echo button('Hesabı yeniden aç', 'primary'); formEnd();
    elseif (can('user_ban')): formStart('user_ban', 'stack'); hidden('user_id', $uid); field('Askıya alma gerekçesi', 'reason', '', 'text', ['hint' => 'Kullanıcı giriş yapmaya çalışınca bunu görür.']); echo '<div class="row-actions">' . button('Askıya al', 'danger', ['confirm' => 'Hesap askıya alınacak ve bütün cihazlardan çıkarılacak.']) . '</div>'; formEnd(); endif ?>
    </div>
    <div>
    <?php if (can('user_delete')): formStart('user_delete', 'stack'); hidden('user_id', $uid); field('Onay için e-postayı yaz', 'confirm_email', '', 'text', ['required' => true, 'autocomplete' => 'off']); passwordConfirm(); echo '<div class="row-actions">' . button('Hesabı kalıcı sil', 'danger', ['confirm' => 'Bu geri alınamaz.']) . '</div>'; formEnd(); endif ?>
    </div>
  </div>
<?php cardEnd(); endif ?>
