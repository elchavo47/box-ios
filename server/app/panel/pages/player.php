<?php
if (!defined('ROOT')) { http_response_code(404); exit; }
$uid = (int)($_GET['id'] ?? 0);
$u = boxFindUser($uid);
if (!$u) { card(); echo emptyState('Kullanıcı bulunamadı', 'Numara yanlış olabilir ya da hesap silinmiş.') . '<p><a class="btn ghost" href="/admin?p=users">Kullanıcılara dön</a></p>'; cardEnd(); return; }
$isPrem = boxIsPremium($u);
$store = boxStoreEntitlement($u);
$purchases = boxStorePurchases($uid);
$u['avatar_url'] = boxAvatarUrl($u);
$q = boxQuota($u);
$devices = boxUserDevices($uid);
$latestApp = '';
foreach (q("SELECT app_version FROM tokens WHERE app_version IS NOT NULL AND last_used_at > DATE_SUB(NOW(), INTERVAL 14 DAY)")->fetchAll(PDO::FETCH_COLUMN) as $v) {
    $v = preg_replace('/\s.*$/', '', (string)$v);
    if ($v !== '' && ($latestApp === '' || boxVersionLess($latestApp, $v))) $latestApp = $v;
}
$dls = q('SELECT * FROM downloads WHERE user_id=? ORDER BY id DESC LIMIT 50', [$uid])->fetchAll();
$lib = boxLibSummary($uid);
$plog = q('SELECT p.*,a.username admin_name FROM premium_log p LEFT JOIN admins a ON a.id=p.admin_id WHERE p.user_id=? ORDER BY p.id DESC LIMIT 20', [$uid])->fetchAll();
$facts = [
    ['Üyelik', $isPrem ? 'Premium' : ($store ? 'Premium (App Store)' : 'Ücretsiz')], ['Premium bitişi', $isPrem ? ($u['premium_until'] ? nbDate($u['premium_until']) : 'Süresiz') : ($store ? ($store['expires_at'] ? nbDate($store['expires_at']) : 'Ömür boyu') : '—')],
    ['Toplam indirme', nbNum((int)q('SELECT COUNT(*) FROM downloads WHERE user_id=?', [$uid])->fetchColumn())], ['Bugün', $q['downloads_used'] . ' indirme · ' . $q['searches_used'] . ' arama'],
    ['Giriş yöntemi', !empty($u['apple_sub']) ? ((int)($u['has_password'] ?? 1) === 1 ? 'E-posta + Apple' : 'Apple') : 'E-posta'],
    ['Bildirim', ($pushN = (int)q('SELECT COUNT(*) FROM push_devices WHERE user_id=?', [$uid])->fetchColumn()) ? $pushN . ' cihaz' : 'Kapalı'],
    ['Kitaplık', count($lib['playlists']) . ' liste · ' . nbNum($lib['favorites']) . ' beğeni'],
    ['Kayıt', nbDate($u['created_at'], 'd.m.Y')], ['Son giriş', nbAgo($u['last_login_at'])], ['Son görülme', nbAgo($u['last_seen_at'])], ['Uygulama', $u['app_version'] ?: '—'],
];
$labels = ['grant' => 'Premium açıldı', 'extend' => 'Premium uzatıldı', 'revoke' => 'Premium kapatıldı', 'trial' => 'Deneme verildi', 'expire' => 'Süresi doldu'];
?>
<section class="dossier">
  <div class="dossier-id">
    <?=avatarHtml($u, 'xl')?>
    <div>
      <h2><?=h($u['display_name'])?> <span class="muted">#<?=$uid?></span></h2>
      <p class="pills"><?=statusPill($isPrem || $store ? 'premium' : 'free')?><?=pill($u['email'], 'neutral')?><?php if ((int)$u['is_banned']): ?><?=pill('Askıda', 'bad')?><?php endif ?></p>
      <?php if ($pushN && canSee($GLOBALS['NB_ADMIN'], 'notify')): ?><p><a class="btn small ghost" href="/admin?p=notify&amp;user=<?=$uid?>"><?=icon('bell')?><span>Bildirim gönder</span></a></p><?php endif ?>
      <?php if ($u['ban_reason']): ?><p class="muted">Gerekçe: <?=h($u['ban_reason'])?></p><?php endif ?>
    </div>
  </div>
  <dl class="facts"><?php foreach ($facts as [$k, $v]): ?><div><dt><?=h($k)?></dt><dd><?=h($v)?></dd></div><?php endforeach ?></dl>
</section>

<div class="cols-2">
  <?php if (can('premium_grant')): card('Premium', $isPrem ? 'Panelden açık. Süre eklersen mevcut bitişin üstüne eklenir.' : ($store ? (boxStoreUnlocks() === 'all' ? 'App Store\'dan satın aldı: ayara göre bütün özellikler açık. Aşağıdan tek tek kapatabilirsin.' : 'App Store\'dan satın aldı: tarayıcıdan indirme, ekolayzer ve kilitli klasör açık. YouTube özelliklerini aşağıdan istersen aç.') : 'Panelden açınca bütün özellikler açık gelir; aşağıdan tek tek kapatabilirsin.')); ?>
    <?php formStart('premium_grant', 'stack'); hidden('user_id', $uid); ?>
    <div class="segmented" role="radiogroup" aria-label="Süre">
      <?php foreach ([7 => '1 hafta', 30 => '1 ay', 90 => '3 ay', 365 => '1 yıl', 0 => 'Süresiz'] as $d => $l): ?>
      <label><input type="radio" name="days" value="<?=$d?>"<?=$d === 30 ? ' checked' : ''?>><span><?=h($l)?></span></label>
      <?php endforeach ?>
    </div>
    <div class="btn-row"><?=button($isPrem ? 'Süre ekle' : 'Premium aç', 'primary', ['icon' => 'bolt'])?></div>
    <?php formEnd(); ?>
    <?php if ($isPrem): formStart('premium_revoke'); hidden('user_id', $uid); echo button('Premiumu kapat', 'danger ghost', ['confirm' => 'Premium hemen kapanacak. Emin misin?']); formEnd(); endif ?>
    <?php $effective = boxHasPremium($u) ? boxFeatures($u) : array_values(array_diff(array_keys(BOX_PREMIUM_FEATURES), boxFeaturesOff($u)));
    $hints = ['search' => 'Arama sekmesi, ana sayfa önerileri, sanatçı ve albüm sayfaları', 'stream' => 'İndirmeden internetten çalma ve video', 'download' => 'Şarkıları kitaplığa indirme', 'radio' => 'Radyo ve sıra bitince benzerleriyle devam', 'playlist' => 'YouTube listesi bağlantısıyla içe aktarma', 'match' => '.boxlist içe aktarırken bulunamayanları arama', 'browser' => 'Tarayıcı sekmesinden dosya indirip kitaplığa ekleme' . (boxStoreUnlocks() === 'all' ? '' : ' (satın almayla gelir)'), 'eq' => '10 bantlı ekolayzer ve ses yükseltme (satın almayla gelir)', 'vault' => 'Face ID ile açılan kilitli klasör (satın almayla gelir)'];
    ?>
    <p class="ios-section-title">Premium özellikleri</p>
    <?php formStart('user_features', 'ios-list', ['autosave' => true]); hidden('user_id', $uid); ?>
      <?php foreach (BOX_PREMIUM_FEATURES as $k => $l): ?>
      <label class="switch ios-row"><span class="switch-text"><b><?=h($l)?></b><small><?=h($hints[$k] ?? '')?></small></span><input type="checkbox" role="switch" name="features[]" value="<?=h($k)?>"<?=in_array($k, $effective, true) ? ' checked' : ''?>><span class="switch-track" aria-hidden="true"></span></label>
      <?php endforeach ?>
    <?php formEnd(); ?>
    <p class="ios-footnote">Değişiklik anında kaydedilir; uygulama bir sonraki açılışta ya da yenilemede uygular.</p>
  <?php cardEnd(); endif ?>

  <?php card('Hesap'); ?>
    <?php if (can('user_rename')): formStart('user_rename', 'stack'); hidden('user_id', $uid); field('İsim', 'display_name', $u['display_name'], 'text', ['required' => true]); field('E-posta', 'email', $u['email'], 'email', ['required' => true]); echo '<div class="row-actions">' . button('Kaydet', 'ghost') . '</div>'; formEnd(); endif ?>
    <?php if (can('premium_grant')): formStart('user_quota', 'stack'); hidden('user_id', $uid); field('Günlük indirme hakkı', 'daily_downloads', $u['daily_downloads'] === null ? '' : (string)$u['daily_downloads'], 'number', ['min' => 0, 'placeholder' => 'Genel: ' . (int)configValue('premium_daily_downloads', 150), 'hint' => 'Boş bırakırsan genel ayar geçerli. 0 = sınırsız.']); echo '<div class="row-actions">' . button('Kaydet', 'ghost') . '</div>'; formEnd(); endif ?>
    <?php if (can('user_note')): formStart('user_note', 'stack'); hidden('user_id', $uid); area('Ekip notu', 'note', (string)$u['note'], ['hint' => 'Yalnızca panelde görünür.']); echo '<div class="row-actions">' . button('Notu kaydet', 'ghost') . '</div>'; formEnd(); endif ?>
  <?php cardEnd(); ?>
</div>

<?php if ($purchases): ?>
<?php card('App Store satın alımları', 'Uygulama içinden yapılan satın almalar. Yenileme, bitiş ve iadeler Apple\'dan otomatik gelir.'); ?>
<?php tableView(['Paket', 'Durum', 'Başlangıç', 'Bitiş', 'Ortam'], $purchases, function ($p) {
    $active = $p['revoked_at'] === null && ($p['expires_at'] === null || strtotime((string)$p['expires_at']) > time());
    $state = $p['revoked_at'] !== null ? pill('İade edildi', 'bad') : ($active ? pill('Aktif', 'good') : pill('Bitti', 'neutral'));
    echo '<td><b>' . h(boxStoreProductName((string)$p['product_id'])) . '</b><small class="muted block mono">' . h((string)$p['original_tx']) . '</small></td>';
    echo '<td>' . $state . '</td><td class="nowrap">' . h(nbDate((string)$p['purchased_at'], 'd.m.Y H:i')) . '</td>';
    echo '<td class="nowrap">' . h($p['expires_at'] ? nbDate((string)$p['expires_at'], 'd.m.Y H:i') : 'Ömür boyu') . '</td>';
    echo '<td>' . ($p['environment'] === 'sandbox' ? pill('Test', 'info') : pill('Gerçek', 'accent')) . '</td>';
}, ''); ?>
<?php cardEnd(); ?>
<?php endif ?>

<div class="cols-2 wide-left">
  <div class="stack">
  <?php card('İndirdikleri', 'Son 50');
  tableView(['Şarkı', 'Zaman'], $dls, function ($r) {
      echo '<td><a class="track" href="https://www.youtube.com/watch?v=' . h($r['video_id']) . '" target="_blank" rel="noopener noreferrer"><img src="https://i.ytimg.com/vi/' . h($r['video_id']) . '/default.jpg" alt="" loading="lazy"><b>' . h($r['title'] !== '' ? $r['title'] : $r['video_id']) . '</b></a></td><td class="nowrap">' . h(nbDate($r['created_at'])) . '</td>';
  }, 'Henüz indirme yok.');
  cardEnd(); ?>
  <?php card('Çalma listeleri', count($lib['playlists']) . ' liste · hesaba kayıtlı');
  tableView(['Liste', 'Şarkı', 'Son değişiklik'], $lib['playlists'], function ($p) {
      $cover = $p['cover'] ? '<img class="sq" src="' . h($p['cover']) . '" alt="" loading="lazy">' : '<span class="track-ph">' . icon('list') . '</span>';
      echo '<td><span class="track">' . $cover . '<b>' . h($p['name']) . '</b></span></td><td class="nowrap">' . nbNum($p['count']) . ($p['remote'] ? ' <small class="muted">' . nbNum($p['remote']) . ' internetten</small>' : '') . '</td><td class="nowrap">' . h($p['updated_at'] ? nbAgo(date('Y-m-d H:i:s', (int)floor($p['updated_at'] / 1000))) : '—') . '</td>';
  }, 'Hesaba kayıtlı liste yok. Uygulama güncellenince listeler otomatik yüklenir.');
  cardEnd(); ?>
  </div>
  <div class="stack">
    <?php card('Cihazlar', count($devices) . ' açık oturum');
    tableView(['Cihaz', 'Son kullanım', ''], $devices, function ($d) use ($uid, $latestApp) {
        $ver = $d['app'] ? preg_replace('/\s.*$/', '', (string)$d['app']) : '';
        $old = $d['legacy'] || ($ver !== '' && $latestApp !== '' && boxVersionLess($ver, $latestApp));
        $meta = array_filter([$d['os'], $d['app'] ? 'Box ' . $d['app'] : null]);
        echo '<td><span class="track"><span class="track-ph">' . icon('phone') . '</span><span><b>' . h($d['name']) . '</b>' . ($old ? ' ' . pill('Eski sürüm', 'warn') : '') . '<br><small class="muted">' . h($meta ? implode(' · ', $meta) : 'Sürüm bilgisi yok') . '</small></span></span></td>';
        echo '<td class="nowrap">' . h(nbAgo($d['last_used_at'])) . '</td><td class="nowrap">';
        if (can('user_logout_device')) { formStart('user_logout_device'); hidden('user_id', $uid); hidden('token_id', $d['id']); echo button('Çıkış yaptır', 'ghost small', ['confirm' => $d['name'] . ' cihazındaki oturum kapanacak.']); formEnd(); }
        echo '</td>';
    }, 'Açık oturum yok.');
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
