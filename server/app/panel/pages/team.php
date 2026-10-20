<?php
if (!defined('ROOT')) { http_response_code(404); exit; }
$team = q("SELECT u.*,(SELECT MAX(last_seen) FROM admin_sessions s WHERE s.user_id=u.id) seen FROM admins u ORDER BY FIELD(role,'admin','support','viewer'),id")->fetchAll();
?>
<section class="role-cards">
  <?php foreach (NB_ROLES as $k => $v): ?><article><?=statusPill($k)?><p><?=h(NB_ROLE_HINTS[$k])?></p><small><?=count(array_filter($team, fn($t) => $t['role'] === $k && $t['status'] === 'active'))?> aktif hesap</small></article><?php endforeach ?>
</section>
<?php card('Ekip hesapları');
tableView(['Hesap', 'Rol', 'Güvenlik', 'Son görülme', ''], $team, function ($u) use ($admin) {
    $self = (int)$u['id'] === (int)$admin['id'];
    echo '<td><div class="who">' . avatarHtml($u) . '<span><b>' . h($u['username']) . ($self ? ' <em class="muted">(sen)</em>' : '') . '</b><small>' . h($u['email']) . '</small></span></div></td>';
    echo '<td>' . statusPill($u['role']) . ($u['status'] !== 'active' ? ' ' . pill('Kapalı', 'bad') : '') . '</td>';
    echo '<td>' . (!empty($u['totp_enabled_at']) ? pill('2FA açık', 'good') : pill('Yalnızca şifre', 'neutral')) . '<small class="block muted">son giriş ' . h(nbAgo($u['last_login_at'])) . '</small></td>';
    echo '<td class="nowrap">' . h(nbAgo($u['seen'] ?? $u['last_login_at'])) . '</td><td class="end">';
    if (!$self) {
        echo '<details class="pop"><summary class="btn small ghost">Yönet</summary><div class="pop-body">';
        formStart('team_update', 'stack'); hidden('id', (int)$u['id']); selectField('Rol', 'role', NB_ROLES, (string)$u['role']); selectField('Durum', 'status', ['active' => 'Aktif', 'suspended' => 'Kapalı (giriş yapamaz)'], (string)$u['status']); passwordConfirm(); echo button('Kaydet'); formEnd();
        echo '<hr>'; formStart('team_reset_password', 'stack'); hidden('id', (int)$u['id']); field('Yeni şifre', 'new_password', '', 'password', ['required' => true]); passwordConfirm(); echo button('Şifreyi değiştir', 'ghost'); formEnd();
        echo '<hr><div class="stack">';
        if (!empty($u['totp_enabled_at'])) { formStart('team_reset_2fa', 'stack'); hidden('id', (int)$u['id']); passwordConfirm(); echo button('İki adımlı girişi sıfırla', 'ghost', ['confirm' => 'Telefonunu kaybettiyse kullan. Sıfırlansın mı?']); formEnd(); }
        formStart('team_kick', 'stack'); hidden('id', (int)$u['id']); passwordConfirm(); echo button('Bütün oturumlarını kapat', 'ghost danger-text'); formEnd();
        echo '</div></div></details>';
    } else echo '<a class="btn small ghost" href="/admin?p=profile">Hesabım</a>';
    echo '</td>';
});
cardEnd(); ?>
<?php card('Yeni ekip hesabı', 'Şifre en az 12 karakter olmalı, harf ve rakam içermeli. Hesap sahibi ilk girişte şifresini değiştirsin.'); formStart('team_create', 'grid-fields');
field('Kullanıcı adı', 'username', '', 'text', ['required' => true, 'maxlength' => 32, 'autocomplete' => 'off']); field('E-posta', 'email', '', 'email', ['required' => true]);
field('Şifre', 'password', '', 'password', ['required' => true]); selectField('Rol', 'role', NB_ROLES, 'support', ['hint' => 'En az yetkiyle başla; gerekirse yükseltirsin.']);
passwordConfirm(); echo button('Hesabı oluştur'); formEnd(); cardEnd();
