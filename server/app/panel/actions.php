<?php
if (!defined('ROOT')) { http_response_code(404); exit; }

/*
 * Panel işlemleri. Her form "action" alanıyla buraya gelir; yetki actionAllowed() ile,
 * kritik işlemler stepUpRequired() ile (admin.php) denetlenir. Her işlem denetim günlüğüne yazılır.
 */

function panelAction(array $admin): string|array {
    $action = (string)($_POST['action'] ?? '');
    $isAdmin = $admin['role'] === 'admin';
    if (!actionAllowed((string)$admin['role'], $action)) throw new RuntimeException('Bu işlem için yetkiniz yok.');

    if ($action === 'logout') {
        logAdmin((int)$admin['id'], 'logout');
        q('DELETE FROM admin_sessions WHERE id=?', [hash('sha256', (string)session_id())]);
        panelDropSession();
        return 'Oturum kapatıldı.';
    }
    if ($action === 'migration_ack') {
        saveSite('migration_seen_' . (int)$admin['id'], (string)($_POST['id'] ?? ''));
        return ['message' => '', 'silent' => true];
    }
    if ($action === 'team_create') {
        requirePasswordConfirm($admin);
        $username = requiredText('username', 32); $email = strtolower(requiredText('email', 190)); $password = (string)($_POST['password'] ?? ''); $role = (string)($_POST['role'] ?? 'support');
        if (!preg_match('/^[\p{L}\p{N}_.-]{3,32}$/u', $username)) throw new RuntimeException('Kullanıcı adı 3-32 karakter olmalı; boşluk içeremez.');
        if (!filter_var($email, FILTER_VALIDATE_EMAIL) || !isset(NB_ROLES[$role])) throw new RuntimeException('E-posta ya da rol geçersiz.');
        if (!nbPasswordStrong($password)) throw new RuntimeException('Şifre en az 12 karakter olmalı, harf ve rakam içermeli; yaygın şifreler kabul edilmez.');
        if (q('SELECT 1 FROM admins WHERE username=? OR (email IS NOT NULL AND email=?)', [$username, $email])->fetchColumn()) throw new RuntimeException('Bu kullanıcı adı ya da e-posta zaten kullanılıyor.');
        q("INSERT INTO admins(username,email,password,role,status) VALUES(?,?,?,?,'active')", [$username,$email,password_hash($password,PASSWORD_DEFAULT),$role]);
        logAdmin((int)$admin['id'], 'team_create', ['target_id'=>(int)db()->lastInsertId(),'role'=>$role,'username'=>$username]);
        return NB_ROLES[$role] . ' hesabı oluşturuldu: ' . $username . '.';
    }
    if ($action === 'security_save') {
        if (!$isAdmin) throw new RuntimeException('Bu işlem için yönetici yetkisi gerekli.');
        requirePasswordConfirm($admin);
        $chat = trim((string)($_POST['telegram_chat_id'] ?? '')); $token = trim((string)($_POST['telegram_bot_token'] ?? ''));
        if ($chat !== '' && !preg_match('/^-?\\d{4,20}$/', $chat)) throw new RuntimeException('Telegram sohbet kimliği yalnızca rakamlardan oluşur (grup için başında - olabilir).');
        if ($token !== '' && !preg_match('/^\\d{6,12}:[A-Za-z0-9_-]{30,50}$/', $token)) throw new RuntimeException('Telegram bot belirteci biçimi geçersiz.');
        saveSite('telegram_chat_id', $chat);
        if ($token !== '') saveSite('telegram_bot_token', encryptSecret($token));
        saveSite('telegram_alerts', isset($_POST['telegram_alerts']) ? '1' : '0');
        saveSite('backup_enabled', isset($_POST['backup_enabled']) ? '1' : '0');
        $mode = ($_POST['backup_mode'] ?? 'db') === 'full' ? 'full' : 'db';
        if ($mode === 'full' && decryptSecret(site('backup_password')) === '' && (string)($_POST['backup_password'] ?? '') === '') throw new RuntimeException('Tam yedek için önce yedek şifresi belirle (ayar dosyası ve anahtarlar da yedeğe girer).');
        saveSite('backup_mode', $mode);
        $backupPassword = (string)($_POST['backup_password'] ?? '');
        if ($backupPassword !== '') { if (strlen($backupPassword) < 10) throw new RuntimeException('Yedek şifresi en az 10 karakter olmalı.'); saveSite('backup_password', encryptSecret($backupPassword)); }
        if (isset($_POST['backup_password_clear'])) saveSite('backup_password', '');
        $list = implode("\n", array_filter(array_map('trim', preg_split('/[\\s,]+/', (string)($_POST['admin_ip_allowlist'] ?? '')))));
        foreach (array_filter(explode("\n", $list)) as $entry) if (!preg_match('/^[0-9a-fA-F:.]{2,45}\\*?$/', $entry)) throw new RuntimeException('IP listesinde geçersiz satır: ' . $entry);
        if ($list !== '') {
            saveSite('admin_ip_allowlist', $list);
            if (!adminIpAllowed()) { saveSite('admin_ip_allowlist', ''); throw new RuntimeException('Listede kendi IP adresiniz (' . clientIp() . ') yok; kilitlenmemeniz için liste kaydedilmedi.'); }
        } else saveSite('admin_ip_allowlist', '');
        logAdmin((int)$admin['id'], 'security_save'); return 'Güvenlik ve yedek ayarları kaydedildi.';
    }
    if ($action === 'telegram_test') {
        if (!$isAdmin) throw new RuntimeException('Bu işlem için yönetici yetkisi gerekli.');
        [$ok, $error] = telegramSend('✅ Box paneli Telegram bağlantısı çalışıyor. ' . date('d.m.Y H:i'));
        if (!$ok) throw new RuntimeException($error);
        return 'Test mesajı Telegram\'a gönderildi.';
    }
    if ($action === 'backup_now') {
        if (!$isAdmin) throw new RuntimeException('Bu işlem için yönetici yetkisi gerekli.');
        requirePasswordConfirm($admin);
        $result = sendDatabaseBackup(isset($_POST['full']) ? true : null); logAdmin((int)$admin['id'], 'backup_now', ['mode' => isset($_POST['full']) ? 'full' : site('backup_mode', 'db')]); return $result;
    }
    if ($action === 'session_revoke') {
        $prefix = preg_replace('/[^a-f0-9]/', '', (string)($_POST['session'] ?? ''));
        if (strlen($prefix) < 12) throw new RuntimeException('Oturum bulunamadı.');
        q('DELETE FROM admin_sessions WHERE user_id=? AND id LIKE ?', [(int)$admin['id'], $prefix . '%']);
        logAdmin((int)$admin['id'], 'session_revoke'); return 'Oturum kapatıldı.';
    }
    if ($action === 'sessions_revoke') {
        q('DELETE FROM admin_sessions WHERE user_id=? AND id<>?', [(int)$admin['id'], hash('sha256', (string)session_id())]);
        logAdmin((int)$admin['id'], 'sessions_revoke'); return 'Bu tarayıcı dışındaki tüm oturumlar kapatıldı.';
    }
    if ($action === 'profile') {
        $old=(string)($_POST['current_password']??''); $new=(string)($_POST['password']??''); $again=(string)($_POST['password_again']??$new);
        if(!password_verify($old,$admin['password'])) throw new RuntimeException('Mevcut şifre yanlış.');
        if(!nbPasswordStrong($new)) throw new RuntimeException('Yeni şifre en az 12 karakter olmalı, harf ve rakam içermeli; yaygın şifreler kabul edilmez.');
        if(!hash_equals($new,$again)) throw new RuntimeException('Yeni şifreler birbirini tutmuyor.');
        if(password_verify($new,$admin['password'])) throw new RuntimeException('Yeni şifre eskisiyle aynı olamaz.');
        q('UPDATE admins SET password=? WHERE id=?',[password_hash($new,PASSWORD_DEFAULT),$admin['id']]);
        
        $fresh=q('SELECT * FROM admins WHERE id=?',[$admin['id']])->fetch(); $_SESSION['auth_hash']=panelSessionHash($fresh);
        q('DELETE FROM admin_sessions WHERE user_id=? AND id<>?', [(int)$admin['id'], hash('sha256', (string)session_id())]);
        logAdmin((int)$admin['id'],'password_change'); securityAlert("Panel şifresi değiştirildi: {$admin['username']}\nIP: ".clientIp());
        return 'Şifre değiştirildi. Diğer cihazlardaki oturumlar kapatıldı.';
    }
    if ($action === 'totp_begin') {
        if (!empty($admin['totp_enabled_at'])) throw new RuntimeException('İki adımlı giriş zaten açık.');
        $secret = totpNewSecret(); $_SESSION['totp_setup'] = ['secret' => $secret, 'at' => time()];
        return ['message' => 'Uygulamada kodu tarayın, ardından 6 haneli kodu girin.', 'data' => ['secret' => trim(chunk_split($secret, 4, ' ')), 'uri' => totpUri($secret, (string)$admin['username'])], 'silent' => true];
    }
    if ($action === 'totp_enable') {
        $setup = $_SESSION['totp_setup'] ?? null;
        if (!$setup || time() - (int)$setup['at'] > 900) throw new RuntimeException('Kurulum süresi doldu. Baştan başlayın.');
        requirePasswordConfirm($admin);
        $step = totpVerify((string)$setup['secret'], (string)($_POST['code'] ?? ''));
        if ($step === null) throw new RuntimeException('Kod doğru değil. Telefonunuzun saatinin otomatik olduğundan emin olup yeni kodu girin.');
        [$codes, $stored] = totpRecoveryCodes();
        q('UPDATE admins SET totp_secret=?,totp_enabled_at=NOW(),totp_recovery=?,totp_last_step=? WHERE id=?', [encryptSecret((string)$setup['secret']), $stored, $step, $admin['id']]);
        unset($_SESSION['totp_setup']);
        $fresh = q('SELECT * FROM admins WHERE id=?', [$admin['id']])->fetch(); $_SESSION['auth_hash'] = panelSessionHash($fresh);
        logAdmin((int)$admin['id'], 'totp_enable'); securityAlert("İki adımlı giriş açıldı: {$admin['username']}");
        return ['message' => 'İki adımlı giriş açıldı. Kurtarma kodlarını güvenli bir yere kaydedin.', 'data' => ['recovery' => $codes]];
    }
    if ($action === 'totp_regen') {
        if (empty($admin['totp_enabled_at'])) throw new RuntimeException('İki adımlı giriş kapalı.');
        requirePasswordConfirm($admin);
        [$codes, $stored] = totpRecoveryCodes();
        q('UPDATE admins SET totp_recovery=? WHERE id=?', [$stored, $admin['id']]);
        logAdmin((int)$admin['id'], 'totp_regen');
        return ['message' => 'Yeni kurtarma kodları üretildi; eskileri artık geçmez.', 'data' => ['recovery' => $codes]];
    }
    if ($action === 'totp_disable') {
        if (empty($admin['totp_enabled_at'])) throw new RuntimeException('İki adımlı giriş zaten kapalı.');
        requirePasswordConfirm($admin);
        $code = (string)($_POST['code'] ?? '');
        $step = totpVerify(decryptSecret((string)$admin['totp_secret']), $code, (int)$admin['totp_last_step']);
        if ($step === null && !totpUseRecovery($admin, $code)) throw new RuntimeException('Doğrulama kodu ya da kurtarma kodu yanlış.');
        q('UPDATE admins SET totp_secret=NULL,totp_enabled_at=NULL,totp_recovery=NULL,totp_last_step=0 WHERE id=?', [$admin['id']]);
        $fresh = q('SELECT * FROM admins WHERE id=?', [$admin['id']])->fetch(); $_SESSION['auth_hash'] = panelSessionHash($fresh);
        logAdmin((int)$admin['id'], 'totp_disable'); securityAlert("İki adımlı giriş KAPATILDI: {$admin['username']}\nIP: " . clientIp());
        return 'İki adımlı giriş kapatıldı.';
    }

    
    if (in_array($action, ['team_update', 'team_reset_password', 'team_reset_2fa', 'team_kick'], true)) {
        requirePasswordConfirm($admin);
        $id = (int)($_POST['id'] ?? 0);
        $target = q('SELECT * FROM admins WHERE id=?', [$id])->fetch();
        if (!$target) throw new RuntimeException('Ekip hesabı bulunamadı.');
        if ($id === (int)$admin['id']) throw new RuntimeException('Kendi hesabınızı buradan değiştiremezsiniz; Hesabım sayfasını kullanın.');
        if ($action === 'team_update') {
            $role = (string)($_POST['role'] ?? $target['role']); $status = (string)($_POST['status'] ?? $target['status']);
            if (!isset(NB_ROLES[$role]) || !in_array($status, ['active', 'suspended'], true)) throw new RuntimeException('Rol ya da durum geçersiz.');
            if ($target['role'] === 'admin' && ($role !== 'admin' || $status !== 'active') && (int)q("SELECT COUNT(*) FROM admins WHERE role='admin' AND status='active'")->fetchColumn() <= 1) throw new RuntimeException('Son aktif yöneticinin yetkisi alınamaz.');
            q('UPDATE admins SET role=?,status=? WHERE id=?', [$role, $status, $id]);
            if ($status !== 'active') q('DELETE FROM admin_sessions WHERE user_id=?', [$id]);
            logAdmin((int)$admin['id'], 'team_update', ['target_id' => $id, 'role' => $role, 'status' => $status]);
            securityAlert("Ekip yetkisi değişti: {$target['username']} → " . NB_ROLES[$role] . ($status !== 'active' ? ' (kapatıldı)' : '') . "\nYapan: {$admin['username']}");
            return $target['username'] . ' güncellendi.';
        }
        if ($action === 'team_reset_password') {
            $new = (string)($_POST['new_password'] ?? '');
            if (!nbPasswordStrong($new)) throw new RuntimeException('Yeni şifre en az 12 karakter olmalı, harf ve rakam içermeli.');
            q('UPDATE admins SET password=? WHERE id=?', [password_hash($new, PASSWORD_DEFAULT), $id]);
            q('DELETE FROM admin_sessions WHERE user_id=?', [$id]);
            logAdmin((int)$admin['id'], 'team_reset_password', ['target_id' => $id]);
            return $target['username'] . ' için yeni şifre ayarlandı; açık oturumları kapatıldı.';
        }
        if ($action === 'team_reset_2fa') {
            q('UPDATE admins SET totp_secret=NULL,totp_enabled_at=NULL,totp_recovery=NULL,totp_last_step=0 WHERE id=?', [$id]);
            q('DELETE FROM admin_sessions WHERE user_id=?', [$id]);
            logAdmin((int)$admin['id'], 'team_reset_2fa', ['target_id' => $id]);
            securityAlert("İki adımlı giriş sıfırlandı: {$target['username']}\nYapan: {$admin['username']}");
            return $target['username'] . ' için iki adımlı giriş kapatıldı.';
        }
        q('DELETE FROM admin_sessions WHERE user_id=?', [$id]);
        logAdmin((int)$admin['id'], 'team_kick', ['target_id' => $id]);
        return $target['username'] . ' için bütün oturumlar kapatıldı.';
    }
    if ($action === 'security_scan') {
        $r = runExposureScan();
        logAdmin((int)$admin['id'], 'security_scan', ['open' => count($r['open'])]);
        if ($r['error']) throw new RuntimeException($r['error']);
        return $r['open'] ? count($r['open']) . ' yol dışarıya açık! Ayrıntılar listede.' : 'Tarama tamam: gizli dosyaların hepsi dışarıya kapalı.';
    }
    if ($action === 'sec_ack') {
        $id = (int)($_POST['id'] ?? 0);
        if ($id > 0) q('UPDATE security_events SET acknowledged_at=NOW() WHERE id=?', [$id]);
        else q('UPDATE security_events SET acknowledged_at=NOW() WHERE acknowledged_at IS NULL');
        logAdmin((int)$admin['id'], 'sec_ack', ['id' => $id ?: 'all']);
        return $id ? 'Olay incelendi olarak işaretlendi.' : 'Bütün olaylar incelendi olarak işaretlendi.';
    }
    if ($action === 'tg_alerts_save') {
        foreach (['services', 'errors', 'premium'] as $kind) saveSite('tg_alert_' . $kind, isset($_POST['tg_alert_' . $kind]) ? '1' : '0');
        logAdmin((int)$admin['id'], 'tg_alerts_save');
        return 'Anlık uyarı ayarları kaydedildi.';
    }
    if ($action === 'backup_restore') {
        if (!$isAdmin) throw new RuntimeException('Bu işlem için yönetici yetkisi gerekli.');
        requirePasswordConfirm($admin);
        if (trim((string)($_POST['confirm_text'] ?? '')) !== 'GERİ YÜKLE') throw new RuntimeException('Onay için kutuya büyük harflerle GERİ YÜKLE yazın.');
        $file = $_FILES['backup'] ?? null;
        if (!$file || (int)($file['error'] ?? 1) !== UPLOAD_ERR_OK || !is_uploaded_file((string)$file['tmp_name'])) throw new RuntimeException('Yedek dosyası yüklenemedi (sunucunun dosya boyutu sınırını aşmış olabilir).');
        if ((int)$file['size'] > 200 * 1048576) throw new RuntimeException('Yedek dosyası 200 MB\'tan büyük olamaz.');
        @set_time_limit(600);
        logAdmin((int)$admin['id'], 'backup_restore_start', ['file' => mb_substr((string)$file['name'], 0, 100)]);
        $result = restoreDatabaseBackup((string)$file['tmp_name'], (string)$file['name']);
        try { ensureSchema(true); } catch (Throwable $e) { nbReport($e); }
        try { securityAlert('♻️ Veritabanı yedekten geri yüklendi: ' . $admin['username'] . "\nDosya: " . (string)$file['name'] . "\nÖnceki durumun yedeği sunucuda: " . $result['safety']); } catch (Throwable $e) {}
        return ['message' => 'Yedek geri yüklendi: ' . $result['tables'] . ' tablo, ' . $result['statements'] . ' komut. Önceki durumun yedeği sunucuda saklandı. Oturumun kapanmış olabilir; yeniden giriş yap.', 'data' => null];
    }
    if ($action === 'guard_save') {
        requirePasswordConfirm($admin);
        $req = isset($_POST['staff_require_2fa']);
        if ($req && empty($admin['totp_enabled_at'])) throw new RuntimeException('Önce kendi hesabında iki adımlı girişi aç (Profil sayfası), sonra herkes için zorunlu yap.');
        $days = max(0, min(3650, (int)($_POST['staff_inactive_days'] ?? 90)));
        saveSite('staff_inactive_days', (string)$days);
        saveSite('login_approval', isset($_POST['login_approval']) ? '1' : '0');
        $mode = (string)($_POST['step_up_mode'] ?? 'new'); if (in_array($mode, ['new', 'always', 'off'], true)) saveSite('step_up_mode', $mode);
        saveSite('staff_require_2fa', $req ? '1' : '0');
        logAdmin((int)$admin['id'], 'guard_save', ['inactive' => $days, 'approval' => isset($_POST['login_approval']), '2fa' => $req]);
        return 'Ek koruma ayarları kaydedildi.';
    }
    if ($action === 'device_remove') {
        $did = (int)($_POST['id'] ?? 0);
        $own = $admin['role'] === 'admin' ? q('DELETE FROM admin_devices WHERE id=?', [$did]) : q('DELETE FROM admin_devices WHERE id=? AND user_id=?', [$did, $admin['id']]);
        logAdmin((int)$admin['id'], 'device_remove', ['id' => $did]);
        return $own->rowCount() ? 'Cihaz kaldırıldı. O cihazdan bir sonraki girişte yeniden Telegram onayı istenir.' : 'Cihaz bulunamadı.';
    }
    if ($action === 'errors_resolve_all') {
        $n = q("UPDATE error_groups SET status='resolved',resolved_at=NOW() WHERE status='open'")->rowCount();
        logAdmin((int)$admin['id'], 'errors_resolve_all', ['count' => $n]);
        return $n . ' hata çözüldü işaretlendi.';
    }
    if ($action === 'errors_clear_resolved') {
        $sigs = q("SELECT sig FROM error_groups WHERE status='resolved'")->fetchAll(PDO::FETCH_COLUMN);
        if ($sigs) { $marks = implode(',', array_fill(0, count($sigs), '?')); q("DELETE FROM error_daily WHERE sig IN ($marks)", $sigs); q("DELETE FROM error_groups WHERE sig IN ($marks)", $sigs); }
        logAdmin((int)$admin['id'], 'errors_clear_resolved', ['count' => count($sigs)]);
        return count($sigs) . ' kayıt silindi.';
    }
    if ($action === 'error_test') {
        
        $sig = sha1('Test|' . microtime(true));
        q("INSERT INTO error_groups(sig,level,message,file,line,last_url,last_trace) VALUES(?,'Test',?,?,?,?,?)", [$sig, 'Panelden gönderilen deneme hatası (' . date('H:i:s') . '). Gerçek bir sorun yok; çözüldü işaretleyip silebilirsin.', 'app/panel/actions.php', __LINE__, 'POST /admin', '']);
        q('INSERT INTO error_daily(day,sig,n) VALUES(CURDATE(),?,1) ON DUPLICATE KEY UPDATE n=n+1', [$sig]);
        $sent = telegramConfigured() && site('tg_alert_errors', '1') === '1';
        if ($sent) { q('UPDATE error_groups SET notified_at=NOW() WHERE sig=?', [$sig]); staffAlert('errors', "🐞 Deneme hatası\nPanelden gönderildi; hata uyarıları Telegram'a ulaşıyor.\nPanel > Hatalar"); }
        logAdmin((int)$admin['id'], 'error_test');
        return $sent ? 'Deneme hatası oluşturuldu ve Telegram\'a gönderildi.' : 'Deneme hatası oluşturuldu. Telegram uyarısı kapalı olduğu için mesaj gitmedi.';
    }

    if (in_array($action, ['error_resolve', 'error_mute', 'error_delete'], true)) {
        $sig = (string)($_POST['sig'] ?? '');
        if (!preg_match('/^[a-f0-9]{40}$/', $sig)) throw new RuntimeException('Kayıt bulunamadı.');
        $row = q('SELECT status FROM error_groups WHERE sig=?', [$sig])->fetch();
        if (!$row) throw new RuntimeException('Kayıt bulunamadı.');
        if ($action === 'error_resolve') { q("UPDATE error_groups SET status='resolved',resolved_at=NOW() WHERE sig=?", [$sig]); $msg = 'Çözüldü işaretlendi. Tekrar olursa yeniden açılır ve haber gelir.'; }
        elseif ($action === 'error_mute') { $mute = $row['status'] !== 'muted'; q('UPDATE error_groups SET status=? WHERE sig=?', [$mute ? 'muted' : 'open', $sig]); $msg = $mute ? 'Sessize alındı: sayılmaya devam eder, Telegram\'a haber gitmez.' : 'Sesi açıldı.'; }
        else { q('DELETE FROM error_groups WHERE sig=?', [$sig]); q('DELETE FROM error_daily WHERE sig=?', [$sig]); $msg = 'Hata kaydı silindi.'; }
        logAdmin((int)$admin['id'], $action, ['sig' => substr($sig, 0, 10)]);
        return $msg;
    }

    /* ================= Box: kullanıcılar ve premium ================= */

    if (in_array($action, ['premium_grant', 'premium_revoke', 'user_ban', 'user_unban', 'user_note', 'user_rename', 'user_logout_all', 'user_delete', 'user_quota'], true)) {
        $uid = (int)($_POST['user_id'] ?? 0);
        $u = boxFindUser($uid);
        if (!$u) throw new RuntimeException('Kullanıcı bulunamadı.');
        $who = $u['display_name'] . ' (' . $u['email'] . ')';
        switch ($action) {
            case 'premium_grant':
                $days = (int)($_POST['days'] ?? 30);
                if ($days < 0 || $days > 3650) throw new RuntimeException('Süre 0 (süresiz) ile 3650 gün arasında olmalı.');
                $until = boxGrantPremium($uid, $days, (int)$admin['id'], boxIsPremium($u) ? 'extend' : 'grant');
                logAdmin((int)$admin['id'], 'premium_grant', ['user_id' => $uid, 'days' => $days, 'until' => $until]);
                if ($days >= 365 || $days === 0) staffAlert('premium', "⚡ Premium verildi: {$who}\nSüre: " . ($days ? "$days gün" : 'süresiz') . "\nYapan: {$admin['username']}");
                return $days ? "Premium " . (boxIsPremium($u) ? 'uzatıldı' : 'açıldı') . ': ' . nbDate($until, 'd.m.Y H:i') . ' tarihine kadar.' : 'Süresiz premium açıldı.';
            case 'premium_revoke':
                if (!boxIsPremium($u) && (int)$u['is_premium'] === 0) throw new RuntimeException('Bu kullanıcının premiumu zaten yok.');
                boxRevokePremium($uid, (int)$admin['id']);
                logAdmin((int)$admin['id'], 'premium_revoke', ['user_id' => $uid]);
                return 'Premium kapatıldı. Arama ve indirme sekmesi bir sonraki açılışta kaybolur.';
            case 'user_ban':
                $reason = mb_substr(trim((string)($_POST['reason'] ?? '')), 0, 255);
                q('UPDATE users SET is_banned=1, ban_reason=? WHERE id=?', [$reason !== '' ? $reason : null, $uid]);
                q('DELETE FROM tokens WHERE user_id=?', [$uid]);
                logAdmin((int)$admin['id'], 'user_ban', ['user_id' => $uid, 'reason' => $reason]);
                return 'Hesap askıya alındı ve bütün cihazlardan çıkarıldı.';
            case 'user_unban':
                q('UPDATE users SET is_banned=0, ban_reason=NULL WHERE id=?', [$uid]);
                logAdmin((int)$admin['id'], 'user_unban', ['user_id' => $uid]);
                return 'Hesap yeniden aktif.';
            case 'user_note':
                $note = mb_substr(trim((string)($_POST['note'] ?? '')), 0, 2000);
                q('UPDATE users SET note=? WHERE id=?', [$note !== '' ? $note : null, $uid]);
                logAdmin((int)$admin['id'], 'user_note', ['user_id' => $uid]);
                return 'Not kaydedildi.';
            case 'user_rename':
                $name = mb_substr(trim((string)($_POST['display_name'] ?? '')), 0, 60);
                $email = mb_strtolower(trim((string)($_POST['email'] ?? '')));
                if ($name === '' || !filter_var($email, FILTER_VALIDATE_EMAIL)) throw new RuntimeException('Geçerli bir isim ve e-posta gir.');
                $other = boxFindUserByEmail($email);
                if ($other && (int)$other['id'] !== $uid) throw new RuntimeException('Bu e-posta başka bir hesapta kullanılıyor.');
                q('UPDATE users SET display_name=?, email=? WHERE id=?', [$name, $email, $uid]);
                logAdmin((int)$admin['id'], 'user_rename', ['user_id' => $uid, 'email_changed' => $email !== $u['email']]);
                return 'Bilgiler güncellendi.';
            case 'user_quota':
                $raw = trim((string)($_POST['daily_downloads'] ?? ''));
                if ($raw !== '' && (!ctype_digit($raw) || (int)$raw > 100000)) throw new RuntimeException('Günlük hak 0 ile 100.000 arasında bir sayı olmalı (boş = genel ayar).');
                $value = $raw === '' ? null : (int)$raw;
                q('UPDATE users SET daily_downloads=? WHERE id=?', [$value, $uid]);
                logAdmin((int)$admin['id'], 'user_quota', ['user_id' => $uid, 'daily_downloads' => $value]);
                return $value === null ? 'Genel ayar kullanılacak (' . (int)configValue('premium_daily_downloads', 150) . ').' : ($value === 0 ? 'Bu kullanıcı için sınır kaldırıldı.' : "Günlük indirme hakkı $value olarak ayarlandı.");
            case 'user_logout_all':
                $n = q('DELETE FROM tokens WHERE user_id=?', [$uid])->rowCount();
                logAdmin((int)$admin['id'], 'user_logout_all', ['user_id' => $uid, 'count' => $n]);
                return $n . ' cihazdaki oturum kapatıldı.';
            case 'user_delete':
                requirePasswordConfirm($admin);
                if (mb_strtolower(trim((string)($_POST['confirm_email'] ?? ''))) !== mb_strtolower((string)$u['email'])) throw new RuntimeException('Onay için kullanıcının e-postasını aynen yaz.');
                q('DELETE FROM users WHERE id=?', [$uid]);
                logAdmin((int)$admin['id'], 'user_delete', ['user_id' => $uid, 'email' => $u['email']]);
                watchRefresh();
                return ['message' => 'Kullanıcı ve bütün verileri silindi.', 'redirect' => '/admin?p=users'];
        }
    }

    /* ================= Box: uygulama ayarları ================= */

    if ($action === 'app_save') {
        $section = (string)($_POST['section'] ?? '');
        $changed = [];
        $set = function (string $key, mixed $value) use (&$changed): void {
            if (configValue($key) !== $value) { saveConfigValue($key, $value); $changed[] = $key; }
        };
        if ($section === 'maintenance') {
            $on = isset($_POST['maintenance_mode']);
            $set('maintenance_mode', $on);
            $set('maintenance_message', mb_substr(trim((string)($_POST['maintenance_message'] ?? '')), 0, 300));
            if ($on && !configBool('maintenance_mode') !== false) {}
        } elseif ($section === 'version') {
            $min = trim((string)($_POST['min_app_version'] ?? '1.0'));
            if (!preg_match('/^\d+(\.\d+){0,2}$/', $min)) throw new RuntimeException('Sürüm 1.0 ya da 1.2.3 biçiminde olmalı.');
            $set('min_app_version', $min);
            $set('registration_open', isset($_POST['registration_open']));
        } elseif ($section === 'announcement') {
            $title = mb_substr(trim((string)($_POST['announcement_title'] ?? '')), 0, 80);
            $body = mb_substr(trim((string)($_POST['announcement_body'] ?? '')), 0, 600);
            $on = isset($_POST['announcement_on']);
            if ($on && ($title === '' || $body === '')) throw new RuntimeException('Duyuruyu açmak için başlık ve metin gerekli.');
            $set('announcement_title', $title); $set('announcement_body', $body); $set('announcement_on', $on);
        } elseif ($section === 'quota') {
            $set('premium_daily_downloads', max(0, min(10000, (int)($_POST['premium_daily_downloads'] ?? 150))));
            $set('premium_daily_searches', max(0, min(20000, (int)($_POST['premium_daily_searches'] ?? 400))));
            $set('new_user_premium_days', max(0, min(365, (int)($_POST['new_user_premium_days'] ?? 0))));
            $mail = trim((string)($_POST['support_email'] ?? ''));
            if ($mail !== '' && !filter_var($mail, FILTER_VALIDATE_EMAIL)) throw new RuntimeException('Destek e-postası geçerli değil.');
            $set('support_email', $mail);
        } else throw new RuntimeException('Bilinmeyen bölüm.');
        logAdmin((int)$admin['id'], 'app_save', ['section' => $section, 'changed' => $changed]);
        if ($section === 'maintenance' && in_array('maintenance_mode', $changed, true)) securityAlert((configBool('maintenance_mode') ? '🛠️ Bakım modu AÇILDI' : '✅ Bakım modu kapatıldı') . "\nYapan: {$admin['username']}");
        return $changed ? 'Kaydedildi. Uygulama bir sonraki istekte yeni ayarları kullanır.' : 'Değişiklik yok.';
    }

    /* ================= Box: servisler ================= */

    if ($action === 'services_save') {
        requirePasswordConfirm($admin);
        $changed = [];
        $yt = trim((string)($_POST['yt_api_key'] ?? ''));
        if ($yt !== '') { if (!preg_match('/^[A-Za-z0-9_-]{30,60}$/', $yt)) throw new RuntimeException('YouTube API anahtarı biçimi geçersiz.'); saveSecretSetting('yt_api_key', $yt); $changed[] = 'YouTube anahtarı'; }
        $key = trim((string)($_POST['vds_signing_key'] ?? ''));
        if ($key !== '') { if (strlen($key) < 16) throw new RuntimeException('VDS imza anahtarı çok kısa.'); saveSecretSetting('vds_signing_key', $key); $changed[] = 'VDS imza anahtarı'; }
        $url = rtrim(trim((string)($_POST['vds_url'] ?? '')), '/');
        if ($url !== '' && $url !== boxVdsUrl()) { if (!preg_match('#^https://[a-z0-9.-]+(:\d+)?$#i', $url)) throw new RuntimeException('VDS adresi https:// ile başlayan bir alan adı olmalı.'); saveSite('vds_url', $url); $changed[] = 'VDS adresi'; }
        foreach (['download_link_ttl' => [60, 3600], 'search_cache_seconds' => [60, 86400], 'token_ttl_days' => [1, 3650]] as $k => [$min, $max]) {
            if (!isset($_POST[$k])) continue;
            $v = (string)max($min, min($max, (int)$_POST[$k]));
            if ($v !== site($k)) { saveSite($k, $v); $changed[] = $k; }
        }
        logAdmin((int)$admin['id'], 'services_save', ['changed' => $changed]);
        return $changed ? 'Kaydedildi: ' . implode(', ', $changed) . '.' : 'Değişiklik yok.';
    }
    if ($action === 'services_check') {
        $h = boxVdsHealth();
        $prev = json_decode(site('vds_health'), true);
        $h['fails'] = $h['ok'] ? 0 : (int)($prev['fails'] ?? 0) + 1;
        saveSite('vds_health', json_encode($h, JSON_UNESCAPED_UNICODE));
        logAdmin((int)$admin['id'], 'services_check', ['ok' => $h['ok'], 'ms' => $h['ms']]);
        if (!$h['ok']) throw new RuntimeException('VDS\'ye ulaşılamadı: ' . $h['error']);
        return 'VDS çalışıyor (' . $h['ms'] . ' ms).';
    }
    if ($action === 'services_test_search') {
        try { $r = boxSearch('test'); } catch (RuntimeException $e) { throw new RuntimeException('Arama denemesi başarısız: ' . $e->getMessage()); }
        logAdmin((int)$admin['id'], 'services_test_search', ['results' => count($r)]);
        return 'YouTube araması çalışıyor: ' . count($r) . ' sonuç geldi.';
    }
    if ($action === 'cron_key_regen') {
        saveSite('cron_key', bin2hex(random_bytes(20)));
        logAdmin((int)$admin['id'], 'cron_key_regen');
        return 'Yeni cron adresi oluşturuldu; hosting panelindeki görevi güncelle.';
    }
    if ($action === 'cron_run') {
        $r = runCron();
        logAdmin((int)$admin['id'], 'cron_run', $r);
        return 'Görevler çalıştırıldı. Süresi dolan premium: ' . (int)$r['expired_premiums'] . '.';
    }


    throw new RuntimeException('Bilinmeyen işlem.');
}
