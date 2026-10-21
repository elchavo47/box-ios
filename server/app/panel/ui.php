<?php
if (!defined('ROOT')) { http_response_code(404); exit; }





function icon(string $key, string $class = 'i'): string {
    static $p = [
        'grid' => 'M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z',
        'shield' => 'M12 3l7 3v5c0 5-3.5 8.5-7 10-3.5-1.5-7-5-7-10V6zM9 12l2 2 4-4',
        'users' => 'M16 20v-1.5a3.5 3.5 0 0 0-3.5-3.5h-5A3.5 3.5 0 0 0 4 18.5V20M10 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7M20 20v-1.5a3.5 3.5 0 0 0-2.5-3.35M15.5 4.2a3.5 3.5 0 0 1 0 6.6',
        'user' => 'M19 20v-1.5a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4V20M12 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7',
        'flag' => 'M5 21V4M5 4h11l-2 4 2 4H5',
        'chat' => 'M5 18l-1 3 4-2h9a3 3 0 0 0 3-3V7a3 3 0 0 0-3-3H7a3 3 0 0 0-3 3v9a3 3 0 0 0 1 2',
        'trophy' => 'M8 21h8M12 17v4M7 4h10v5a5 5 0 0 1-10 0zM7 6H4v1a3 3 0 0 0 3 3M17 6h3v1a3 3 0 0 1-3 3',
        'sliders' => 'M4 7h9M17 7h3M4 17h3M11 17h9M15 5v4M9 15v4',
        'bag' => 'M5 8h14l-1 12H6zM9 8V6a3 3 0 0 1 6 0v2',
        'megaphone' => 'M4 10v4h3l7 4V6L7 10zM18 9a4 4 0 0 1 0 6',
        'bell' => 'M6 16V11a6 6 0 1 1 12 0v5l2 2H4zM10 20a2 2 0 0 0 4 0',
        'coins' => 'M9 7a5 3 0 1 0 0.01 0M4 7v4c0 1.7 2.2 3 5 3s5-1.3 5-3V7M10 14v3c0 1.7 2.2 3 5 3s5-1.3 5-3v-4c0-1.7-2.2-3-5-3',
        'globe' => 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18M3 12h18M12 3c2.5 2.6 3.7 5.6 3.7 9s-1.2 6.4-3.7 9c-2.5-2.6-3.7-5.6-3.7-9S9.5 5.6 12 3',
        'mail' => 'M4 6h16v12H4zM4 7l8 6 8-6',
        'lock' => 'M6 11h12v9H6zM8.5 11V8a3.5 3.5 0 0 1 7 0v3M12 15v2',
        'team' => 'M9 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6M3 20v-1a4 4 0 0 1 4-4h4a4 4 0 0 1 4 4v1M16 11a3 3 0 1 0 0-6M18 15a4 4 0 0 1 3 4v1',
        'list' => 'M9 6h11M9 12h11M9 18h11M4.5 6h.01M4.5 12h.01M4.5 18h.01',
        'copy' => 'M9 9h11v11H9zM5 15H4V4h11v1',
        'terminal' => 'M4 5h16v14H4zM8 10l2.5 2L8 14M13 15h3',
        'gear' => 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6M19 12a7 7 0 0 0-.1-1.2l2-1.6-2-3.4-2.4 1a7 7 0 0 0-2-1.2L14 3h-4l-.5 2.6a7 7 0 0 0-2 1.2l-2.4-1-2 3.4 2 1.6A7 7 0 0 0 5 12c0 .4 0 .8.1 1.2l-2 1.6 2 3.4 2.4-1a7 7 0 0 0 2 1.2L10 21h4l.5-2.6a7 7 0 0 0 2-1.2l2.4 1 2-3.4-2-1.6c.1-.4.1-.8.1-1.2',
        'search' => 'M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14M20 20l-4-4',
        'menu' => 'M4 7h16M4 12h16M4 17h16',
        'logout' => 'M15 4h4v16h-4M10 8l-4 4 4 4M6 12h10',
        'sun' => 'M12 16a4 4 0 1 0 0-8 4 4 0 0 0 0 8M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4',
        'moon' => 'M20 14.5A8 8 0 0 1 9.5 4 8 8 0 1 0 20 14.5',
        'check' => 'M5 12.5l4.5 4.5L19 7.5',
        'x' => 'M6 6l12 12M18 6L6 18',
        'alert' => 'M12 4l9 16H3zM12 10v4M12 17h.01',
        'info' => 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18M12 11v5M12 8h.01',
        'arrow' => 'M9 6l6 6-6 6',
        'back' => 'M15 6l-6 6 6 6',
        'refresh' => 'M20 12a8 8 0 1 1-2.4-5.7M20 4v5h-5',
        'plus' => 'M12 5v14M5 12h14',
        'download' => 'M12 4v11M7 10l5 5 5-5M5 20h14',
        'key' => 'M14 10a4 4 0 1 0-1.2 2.8L20 20M17 17l2-2',
        'phone' => 'M8 3h8v18H8zM11 18h2',
        'clock' => 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18M12 7v5l3 2',
        'eye' => 'M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6',
        'spark' => 'M12 3v4M12 17v4M3 12h4M17 12h4M6 6l2.5 2.5M15.5 15.5L18 18M6 18l2.5-2.5M15.5 8.5L18 6',
        'chart' => 'M4 20h16M7 16v-5M12 16V6M17 16v-8',
        'image' => 'M4 5h16v14H4zM4 16l5-5 4 4 3-3 4 4M15.5 9.5h.01',
        'calendar' => 'M5 6h14v14H5zM5 10h14M9 4v4M15 4v4M9 14h2',
        'pulse' => 'M3 12h4l2-6 4 12 2-6h6',
        'wheel' => 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18M12 3v18M3 12h18M5.6 5.6l12.8 12.8M18.4 5.6L5.6 18.4',
        'upload' => 'M12 20V9M7 14l5-5 5 5M5 4h14',
        'undo' => 'M9 14L4 9l5-5M4 9h10.5a5.5 5.5 0 0 1 0 11H11',
        'bolt' => 'M13 3L5 13.5h6L10 21l8-10.5h-6z',
        'server' => 'M4 5h16v6H4zM4 13h16v6H4zM8 8h.01M8 16h.01',
        'music' => 'M9 18V6l11-2v12M9 18a3 3 0 1 1-6 0 3 3 0 0 1 6 0M20 16a3 3 0 1 1-6 0 3 3 0 0 1 6 0',
        'bug' => 'M9 7.5V6a3 3 0 0 1 6 0v1.5M8 9h8v5a4 4 0 0 1-8 0zM12 11v7M4 13h4M16 13h4M5 8.5l3 1.5M19 8.5l-3 1.5M5.5 19l3-2M18.5 19l-3-2',
    ];
    return '<svg class="' . h($class) . '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="' . ($p[$key] ?? $p['grid']) . '"/></svg>';
}


function brandMark(string $class = 'mark'): string {
    $size = str_contains($class, 'lg') ? ' lg' : '';
    return '<svg class="box-mark' . $size . '" viewBox="0 0 48 48" aria-hidden="true"><path class="t" d="M24 6 41 15 24 24 7 15Z"/><path class="l" d="M6 19 22 28v15L6 34Z"/><path class="r" d="M42 19 26 28v15l16-9Z"/></svg>';
}


function formStart(string $action, string $class = '', array $opts = []): void {
    $attrs = '';
    if (!empty($opts['autosave'])) $attrs .= ' data-autosave';
    if (!empty($opts['files'])) $attrs .= ' enctype="multipart/form-data"';
    if (!empty($opts['result'])) $attrs .= ' data-result="' . h($opts['result']) . '"';
    if (!empty($opts['fields'])) $attrs .= ' data-fields';
    echo '<form method="post" class="' . h($class) . '"' . $attrs . '><input type="hidden" name="csrf" value="' . h(csrf()) . '"><input type="hidden" name="action" value="' . h($action) . '">';
    if (!empty($opts['fields'])) echo '<input type="hidden" name="_fields" value="' . h(implode(',', $opts['fields'])) . '">';
}
function formEnd(): void { echo '</form>'; }
function hidden(string $name, $value): void { echo '<input type="hidden" name="' . h($name) . '" value="' . h($value) . '">'; }


function field(string $label, string $name, $value = '', string $type = 'text', array $o = []): void {
    $req = ($o['required'] ?? false) ? ' required' : '';
    $extra = '';
    foreach (['step', 'min', 'max', 'placeholder', 'autocomplete', 'maxlength', 'pattern', 'inputmode'] as $a) if (isset($o[$a])) $extra .= ' ' . $a . '="' . h($o[$a]) . '"';
    if ($type === 'password' && !isset($o['autocomplete'])) $extra .= ' autocomplete="new-password"';
    if (!empty($o['readonly'])) $extra .= ' readonly data-copy';
    echo '<label class="field' . (!empty($o['wide']) ? ' wide' : '') . '"><span class="field-label">' . h($label) . '</span><input class="input' . (!empty($o['mono']) ? ' mono' : '') . '" type="' . h($type) . '" name="' . h($name) . '" value="' . h($value) . '"' . $req . $extra . '>' . (!empty($o['hint']) ? '<span class="field-hint">' . h($o['hint']) . '</span>' : '') . '</label>';
}
function area(string $label, string $name, $value = '', array $o = []): void {
    echo '<label class="field' . (!empty($o['wide']) ? ' wide' : '') . '"><span class="field-label">' . h($label) . '</span><textarea class="input' . (!empty($o['mono']) ? ' mono' : '') . '" name="' . h($name) . '" rows="' . (int)($o['rows'] ?? 4) . '"' . (!empty($o['required']) ? ' required' : '') . (isset($o['maxlength']) ? ' maxlength="' . (int)$o['maxlength'] . '"' : '') . (isset($o['placeholder']) ? ' placeholder="' . h($o['placeholder']) . '"' : '') . '>' . h($value) . '</textarea>' . (!empty($o['hint']) ? '<span class="field-hint">' . h($o['hint']) . '</span>' : '') . '</label>';
}
function selectField(string $label, string $name, array $options, string $selected = '', array $o = []): void {
    echo '<label class="field' . (!empty($o['wide']) ? ' wide' : '') . '"><span class="field-label">' . h($label) . '</span><select class="input" name="' . h($name) . '">';
    foreach ($options as $k => $v) echo '<option value="' . h($k) . '"' . ((string)$k === $selected ? ' selected' : '') . '>' . h($v) . '</option>';
    echo '</select>' . (!empty($o['hint']) ? '<span class="field-hint">' . h($o['hint']) . '</span>' : '') . '</label>';
}

function toggle(string $label, string $name, bool $on, string $hint = '', string $confirm = ''): string {
    return '<label class="switch"><input type="checkbox" role="switch" name="' . h($name) . '"' . ($on ? ' checked' : '') . ($confirm !== '' ? ' data-confirm-on="' . h($confirm) . '"' : '') . '><span class="switch-track" aria-hidden="true"></span><span class="switch-text"><b>' . h($label) . '</b>' . ($hint !== '' ? '<small>' . h($hint) . '</small>' : '') . '</span></label>';
}
function passwordConfirm(string $label = 'Mevcut şifreniz'): void {
    field($label, 'confirm_password', '', 'password', ['required' => true, 'autocomplete' => 'current-password', 'hint' => 'Bu işlem için şifrenizi yeniden girmeniz gerekir.']);
}
function button(string $label, string $kind = 'primary', array $o = []): string {
    $attrs = '';
    if (!empty($o['confirm'])) $attrs .= ' data-confirm="' . h($o['confirm']) . '"';
    return '<button class="btn ' . h($kind) . '"' . $attrs . (!empty($o['type']) ? ' type="' . h($o['type']) . '"' : '') . '>' . (!empty($o['icon']) ? icon($o['icon']) : '') . '<span>' . h($label) . '</span></button>';
}


function card(string $title = '', string $sub = '', string $class = '', string $actions = ''): void {
    echo '<section class="card ' . h($class) . '">';
    if ($title !== '' || $actions !== '') echo '<header class="card-head"><div><h2>' . h($title) . '</h2>' . ($sub !== '' ? '<p>' . h($sub) . '</p>' : '') . '</div>' . ($actions !== '' ? '<div class="card-actions">' . $actions . '</div>' : '') . '</header>';
}
function cardEnd(): void { echo '</section>'; }

function pill(string $text, string $tone = 'neutral'): string { return '<span class="pill ' . h($tone) . '">' . h($text) . '</span>'; }
function statusPill(string $value): string {
    $map = ['active' => ['Aktif', 'good'], 'suspended' => ['Askıda', 'warn'], 'banned' => ['Banlı', 'bad'], 'deleted' => ['Silinmiş', 'neutral'], 'open' => ['Açık', 'warn'], 'answered' => ['Yanıtlandı', 'info'], 'closed' => ['Kapandı', 'neutral'], 'finished' => ['Tamamlandı', 'good'], 'rejected' => ['Reddedildi', 'bad'], 'sent' => ['Gönderildi', 'good'], 'failed' => ['Hata', 'bad'],
        'admin' => ['Yönetici', 'accent'], 'support' => ['Destek', 'info'], 'viewer' => ['İzleyici', 'neutral'], 'premium' => ['Premium', 'good'], 'free' => ['Ücretsiz', 'neutral']];
    [$t, $tone] = $map[$value] ?? [$value, 'neutral'];
    return pill($t, $tone);
}
function stateDot(string $state): string { return '<span class="dot ' . h($state) . '" aria-hidden="true"></span>'; }

function avatarHtml(array $u, string $size = ''): string {
    $name = (string)($u['username'] ?? $u['display_name'] ?? '?');
    // Uygulama kullanıcılarının fotoğrafı avatar_file sütununda durur.
    if (empty($u['avatar_url']) && !empty($u['avatar_file']) && function_exists('boxAvatarUrl')) $u['avatar_url'] = boxAvatarUrl($u);
    if (!empty($u['avatar_url']) && $size === 'xl') {
        // Profil sayfasında fotoğrafa dokununca büyür (NeonBreak'teki gibi).
        return '<button type="button" class="avatar xl zoomable" data-zoom-src="' . h($u['avatar_url']) . '" data-zoom-name="' . h($name) . '" aria-label="Profil fotoğrafını büyüt"><img src="' . h($u['avatar_url']) . '" alt=""></button>';
    }
    if (!empty($u['avatar_url'])) return '<span class="avatar ' . h($size) . '"><img src="' . h($u['avatar_url']) . '" alt="" loading="lazy"></span>';
    return '<span class="avatar ' . h($size) . '" data-hue="' . (crc32($name) % 6) . '">' . h(mb_strtoupper(mb_substr($name, 0, 1))) . '</span>';
}
function userCell(array $u, ?int $id = null, string $sub = ''): string {
    $id ??= (int)($u['user_id'] ?? $u['id'] ?? 0);
    return '<a class="who" href="/admin?p=player&amp;id=' . $id . '">' . avatarHtml($u) . '<span><b>' . h($u['display_name'] ?? $u['username'] ?? ('#' . $id)) . '</b><small>' . ($sub !== '' ? h($sub) : h($u['email'] ?? ('#' . $id))) . '</small></span></a>';
}


function tableView(array $headers, array $rows, callable $render, string $empty = 'Henüz kayıt yok.'): void {
    echo '<div class="table-wrap"><table class="table"><thead><tr>';
    foreach ($headers as $hd) { [$t, $c] = is_array($hd) ? $hd : [$hd, '']; echo '<th class="' . h($c) . '">' . h($t) . '</th>'; }
    echo '</tr></thead><tbody>';
    foreach ($rows as $row) { echo '<tr>'; $render($row); echo '</tr>'; }
    if (!$rows) echo '<tr class="empty-row"><td colspan="' . count($headers) . '"><div class="empty">' . h($empty) . '</div></td></tr>';
    echo '</tbody></table></div>';
}

function emptyState(string $title, string $text = ''): string { return '<div class="empty"><b>' . h($title) . '</b>' . ($text !== '' ? '<span>' . h($text) . '</span>' : '') . '</div>'; }

function kpi(string $label, string $value, string $foot = '', string $tone = ''): string {
    return '<article class="kpi ' . h($tone) . '"><span class="kpi-label">' . h($label) . '</span><strong class="kpi-value">' . h($value) . '</strong>' . ($foot !== '' ? '<span class="kpi-foot">' . $foot . '</span>' : '') . '</article>';
}
function trend(int $now, int $before): string {
    if ($before <= 0) return '<span class="trend flat">dün ' . $before . '</span>';
    $pct = (int)round(($now - $before) / $before * 100);
    return '<span class="trend ' . ($pct > 0 ? 'up' : ($pct < 0 ? 'down' : 'flat')) . '">' . ($pct > 0 ? '+' : '') . $pct . '% düne göre</span>';
}


function barChart(array $points, string $unit, bool $markMax = false): string {
    $n = count($points); if ($n === 0 || !array_sum(array_column($points, 'value'))) return emptyState('Henüz veri yok', 'Kullanıcılar uygulamayı kullandıkça burada görünecek.');
    $max = max(1, max(array_column($points, 'value'))); $w = 720; $hgt = 180; $gap = $n > 16 ? 6 : 10; $bw = ($w - $gap * ($n - 1)) / $n;
    $svg = '<svg viewBox="0 -14 ' . $w . ' ' . ($hgt + 40) . '" class="bars" role="img" aria-label="' . h($unit) . ' grafiği"><path class="grid" d="M0 ' . $hgt . 'H' . $w . 'M0 ' . round($hgt / 2) . 'H' . $w . '"/>';
    foreach ($points as $i => $pt) {
        $bh = $pt['value'] > 0 ? max(4, round($pt['value'] / $max * ($hgt - 20))) : 2; $x = round($i * ($bw + $gap), 1);
        $hot = $markMax && $pt['value'] === $max && $pt['value'] > 0;
        $svg .= '<rect class="bar' . ($hot ? ' hot' : '') . ($pt['value'] === 0 ? ' zero' : '') . '" x="' . $x . '" y="' . ($hgt - $bh) . '" width="' . round($bw, 1) . '" height="' . $bh . '" rx="3"><title>' . h($pt['label'] . ': ' . $pt['value'] . ' ' . $unit) . '</title></rect>';
        if ($pt['value'] > 0 && $n <= 21) $svg .= '<text class="bar-value" x="' . round($x + $bw / 2, 1) . '" y="' . ($hgt - $bh - 6) . '" text-anchor="middle">' . nbNum($pt['value']) . '</text>';
        if ($n <= 14 || $i % 2 === 0) $svg .= '<text class="bar-label" x="' . round($x + $bw / 2, 1) . '" y="' . ($hgt + 20) . '" text-anchor="middle">' . h($pt['label']) . '</text>';
    }
    return '<div class="chart">' . $svg . '</svg></div>';
}


function panelSearchIndex(array $admin): array {
    $all = [
        ['Kontrol merkezi', 'Bugün, dikkat gerektirenler', 'dashboard', '', 'ana sayfa özet istatistik sağlık bugün dashboard'],
        ['Güvenlik durumu', 'Bütün kontroller tek ekranda', 'status', '', 'güvenlik durum kontrol tarama açık dosya htaccess zincir'],
        ['Kullanıcı bul', 'İsim, e-posta ya da numara', 'users', '', 'kullanıcı üye hesap bul ara e-posta'],
        ['Premium ver', 'Kullanıcı dosyası > Premium', 'premium', '', 'premium ver aç uzat abonelik üyelik süre'],
        ['Süresi dolacak premiumlar', 'Önümüzdeki 7 gün', 'premium', 'Yakında bitecek', 'premium bitiyor süre dolacak yenile'],
        ['Kullanıcıyı askıya al', 'Kullanıcı dosyası > Hesap', 'users', '', 'ban askıya al engelle yasakla'],
        ['İndirme geçmişi', 'Kim ne indirdi', 'downloads', '', 'indirme şarkı m4a geçmiş log'],
        ['Bakım modu', 'Uygulamayı geçici kapat', 'app', 'Bakım modu', 'bakım kapat durdur maintenance'],
        ['Zorunlu güncelleme', 'Eski sürümleri kilitle', 'app', 'Minimum sürüm', 'güncelleme zorunlu minimum sürüm versiyon'],
        ['Duyuru yayınla', 'Uygulamada görünen duyuru', 'app', 'Duyuru', 'duyuru haber bilgilendirme mesaj'],
        ['Kotalar', 'Günlük indirme ve arama sınırı', 'app', 'Kotalar', 'kota limit sınır günlük indirme arama'],
        ['Kayıtları kapat', 'Yeni üyeliği durdur', 'app', 'Kayıt', 'kayıt üyelik kapat aç'],
        ['Bildirim gönder', 'Uygulamaya anlık bildirim', 'notify', 'Bildirim', 'bildirim push mesaj gönder duyur'],
        ['Apple ayarları', 'Apple ile giriş ve bildirim anahtarı', 'services', 'Apple', 'apple giriş p8 anahtar team key bildirim apns'],
        ['VDS ve YouTube', 'İndirme ve arama servisleri', 'services', '', 'vds yt-dlp youtube api anahtar imza servis sunucu kota'],
        ['API sağlığı', 'Yanıt süresi ve hata oranı', 'health', '', 'api sağlık hız yavaş hata 500 yanıt süresi'],
        ['Telegram ve yedek', 'Uyarılar ve günlük yedek', 'shield', 'Telegram', 'yedek backup telegram bot uyarı'],
        ['Panel IP kısıtı', 'Panele girebilen adresler', 'shield', 'Panel IP kısıtı', 'ip kısıt izin'],
        ['Açık oturumlar', 'Panele giriş yapılmış tarayıcılar', 'shield', 'Açık oturumlar', 'oturum cihaz çıkış tarayıcı'],
        ['Ekip üyesi ekle', 'Yönetici, destek, izleyici', 'team', '', 'ekip yönetici destek izleyici ekle yetki rol'],
        ['Denetim günlüğü', 'Kim ne yaptı', 'audit', '', 'denetim log kayıt kim ne yaptı audit'],
        ['Hatalar', 'Sunucu hataları, türlerine göre', 'errors', '', 'hata error bug exception fatal 500'],
        ['Sistem günlüğü', 'PHP hata günlüğünün ham hali', 'logs', '', 'hata error log günlük php ham'],
        ['Sürüm ve güncelleme', 'Zip ile güncelleme, cron komutu', 'settings', '', 'sürüm versiyon güncelleme zip cron sistem'],
        ['İki adımlı giriş', 'Hesabım > İki adımlı giriş', 'profile', '', '2fa iki adımlı authenticator güvenlik şifre'],
    ];
    $out = [];
    foreach ($all as [$title, $hint, $page, $find, $keywords]) if (canSee($admin, $page)) $out[] = ['t' => $title, 'h' => $hint, 'u' => '/admin?p=' . $page, 'f' => $find, 'k' => $keywords];
    return $out;
}
