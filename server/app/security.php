<?php
if (!defined('ROOT')) { http_response_code(404); exit; }




function isHttps(): bool {
    return (($_SERVER['HTTPS'] ?? '') !== '' && ($_SERVER['HTTPS'] ?? '') !== 'off')
        || strtolower((string)($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '')) === 'https'
        || (int)($_SERVER['SERVER_PORT'] ?? 0) === 443;
}

function clientIp(): string {
    return substr((string)($_SERVER['REMOTE_ADDR'] ?? '0.0.0.0'), 0, 45);
}

function userAgentHash(): string {
    return hash('sha256', (string)($_SERVER['HTTP_USER_AGENT'] ?? ''));
}


function adminIpAllowed(): bool {
    if (cfg('security.disable_ip_allowlist', false)) return true;
    $list = array_filter(array_map('trim', preg_split('/[\s,]+/', site('admin_ip_allowlist'))));
    if (!$list) return true;
    $ip = clientIp();
    foreach ($list as $entry) {
        if ($entry === $ip) return true;
        if (str_ends_with($entry, '*') && str_starts_with($ip, rtrim($entry, '*'))) return true; 
    }
    return false;
}



function telegramConfigured(): bool {
    return site('telegram_chat_id') !== '' && decryptSecret(site('telegram_bot_token')) !== '';
}


function telegramRequest(string $method, array $fields, int $timeout = 20): array {
    $token = decryptSecret(site('telegram_bot_token'));
    if ($token === '' || !function_exists('curl_init')) return [false, 'Telegram botu ayarlı değil.'];
    $ch = curl_init("https://api.telegram.org/bot$token/$method");
    curl_setopt_array($ch, [CURLOPT_POST => true, CURLOPT_POSTFIELDS => $fields, CURLOPT_RETURNTRANSFER => true, CURLOPT_CONNECTTIMEOUT => 8, CURLOPT_TIMEOUT => $timeout]);
    $response = curl_exec($ch);
    $error = curl_error($ch);
    curl_close($ch);
    if ($response === false) return [false, 'Telegram\'a ulaşılamadı: ' . $error];
    $data = json_decode((string)$response, true);
    if (!is_array($data) || empty($data['ok'])) return [false, 'Telegram: ' . (string)($data['description'] ?? 'bilinmeyen hata')];
    return [true, ''];
}

function telegramSend(string $text): array {
    return telegramRequest('sendMessage', ['chat_id' => site('telegram_chat_id'), 'text' => mb_substr($text, 0, 3900), 'disable_web_page_preview' => 'true']);
}

function telegramSendDocument(string $path, string $caption): array {
    return telegramRequest('sendDocument', ['chat_id' => site('telegram_chat_id'), 'caption' => mb_substr($caption, 0, 900), 'document' => new CURLFile($path, 'application/octet-stream', basename($path))], 600);
}


function securityAlert(string $text): void {
    if (site('telegram_alerts', '1') !== '1' || !telegramConfigured()) return;
    try { telegramSend("🔐 Box paneli\n" . $text); } catch (Throwable $e) { error_log((string)$e); }
}


function recordAdminLogin(?array $user, string $login, bool $success): void {
    $ip = clientIp();
    $agent = mb_substr((string)($_SERVER['HTTP_USER_AGENT'] ?? ''), 0, 250);
    try {
        if ($success && $user) {
            $known = (int)q('SELECT COUNT(*) FROM admin_logins WHERE user_id=? AND ip=? AND success=1 AND created_at>DATE_SUB(NOW(),INTERVAL 60 DAY)', [$user['id'], $ip])->fetchColumn();
            q('INSERT INTO admin_logins(user_id,login,ip,user_agent,success) VALUES(?,?,?,?,1)', [$user['id'], mb_substr($login, 0, 120), $ip, $agent]);
            if (!$known) securityAlert("Yeni konumdan giriş: {$user['username']}\nIP: $ip\nTarayıcı: $agent\nSaat: " . date('d.m.Y H:i'));
        } else {
            q('INSERT INTO admin_logins(user_id,login,ip,user_agent,success) VALUES(?,?,?,?,0)', [$user['id'] ?? null, mb_substr($login, 0, 120), $ip, $agent]);
            $recent = (int)q('SELECT COUNT(*) FROM admin_logins WHERE ip=? AND success=0 AND created_at>DATE_SUB(NOW(),INTERVAL 15 MINUTE)', [$ip])->fetchColumn();
            if ($recent === 5) securityAlert("Art arda 5 hatalı giriş denemesi\nIP: $ip\nDenenen: " . mb_substr($login, 0, 60) . "\nSaat: " . date('d.m.Y H:i'));
        }
        if (random_int(1, 50) === 1) q('DELETE FROM admin_logins WHERE created_at<DATE_SUB(NOW(),INTERVAL 180 DAY)');
    } catch (Throwable $e) { nbReport($e); }
}


function requirePasswordConfirm(array $admin): void {
    if (!password_verify((string)($_POST['confirm_password'] ?? ''), (string)$admin['password'])) throw new RuntimeException('Bu işlem için mevcut şifrenizi doğru girmeniz gerekiyor.');
}








function createDatabaseBackup(): array {
    $dir = nbPrivateDir('backups');
    if (!is_dir($dir) || !is_writable($dir)) throw new RuntimeException('Yedek klasörü oluşturulamadı.');
    $name = 'box-' . date('Ymd-His') . '-' . bin2hex(random_bytes(3));
    $sqlPath = "$dir/$name.sql.gz";
    [$tables, $totalRows] = dumpDatabaseTo($sqlPath);
    return finishDatabaseBackup($dir, $name, $sqlPath, $tables, $totalRows);
}


function dumpDatabaseTo(string $sqlPath): array {
    @set_time_limit(0);
    $gz = gzopen($sqlPath, 'wb6');
    if (!$gz) throw new RuntimeException('Yedek dosyası yazılamadı.');
    gzwrite($gz, "-- Box yedeği " . date('c') . "\nSET NAMES utf8mb4;\nSET FOREIGN_KEY_CHECKS=0;\n\n");
    $skipData = ['rate_limits', 'admin_sessions', 'api_metrics'];
    $tables = q('SHOW TABLES')->fetchAll(PDO::FETCH_COLUMN);
    $totalRows = 0;
    foreach ($tables as $table) {
        if (!preg_match('/^[A-Za-z0-9_]+$/', (string)$table)) continue;
        $create = q("SHOW CREATE TABLE `$table`")->fetch(PDO::FETCH_NUM)[1];
        gzwrite($gz, "DROP TABLE IF EXISTS `$table`;\n$create;\n\n");
        if (in_array($table, $skipData, true)) continue;
        $offset = 0; $page = 1000;
        do {
            $rows = q("SELECT * FROM `$table` LIMIT $page OFFSET $offset")->fetchAll(PDO::FETCH_ASSOC);
            foreach (array_chunk($rows, 200) as $chunk) {
                $values = [];
                foreach ($chunk as $row) {
                    $cells = [];
                    foreach ($row as $value) $cells[] = $value === null ? 'NULL' : (is_int($value) || is_float($value) ? (string)$value : db()->quote((string)$value));
                    $values[] = '(' . implode(',', $cells) . ')';
                }
                gzwrite($gz, "INSERT INTO `$table` (`" . implode('`,`', array_keys($chunk[0])) . "`) VALUES\n" . implode(",\n", $values) . ";\n");
            }
            $totalRows += count($rows);
            $offset += $page;
        } while (count($rows) === $page);
        gzwrite($gz, "\n");
    }
    gzwrite($gz, "SET FOREIGN_KEY_CHECKS=1;\n");
    gzclose($gz);
    return [$tables, $totalRows];
}

function finishDatabaseBackup(string $dir, string $name, string $sqlPath, array $tables, int $totalRows): array {
    $path = $sqlPath; $encrypted = false;
    $password = decryptSecret(site('backup_password'));
    if ($password !== '') {
        if (!class_exists('ZipArchive') || !defined('ZipArchive::EM_AES_256')) { @unlink($sqlPath); throw new RuntimeException('Sunucuda şifreli zip desteği (php-zip) yok. Yedek şifresini kaldırın ya da php-zip eklentisini açtırın.'); }
        $zipPath = "$dir/$name.zip";
        $zip = new ZipArchive();
        if ($zip->open($zipPath, ZipArchive::CREATE | ZipArchive::OVERWRITE) !== true) { @unlink($sqlPath); throw new RuntimeException('Zip oluşturulamadı.'); }
        $zip->addFile($sqlPath, "$name.sql.gz");
        $zip->setEncryptionName("$name.sql.gz", ZipArchive::EM_AES_256, $password);
        $zip->close();
        @unlink($sqlPath);
        $path = $zipPath; $encrypted = true;
    }
    return ['path' => $path, 'size' => (int)filesize($path), 'encrypted' => $encrypted, 'tables' => count($tables), 'rows' => $totalRows];
}






function createFullBackup(): array {
    @set_time_limit(0);
    @ini_set('memory_limit', '512M');
    if (!class_exists('ZipArchive') || !defined('ZipArchive::EM_AES_256')) throw new RuntimeException('Sunucuda şifreli zip desteği (php-zip) yok; tam yedek alınamaz.');
    $password = decryptSecret(site('backup_password'));
    if ($password === '') throw new RuntimeException('Tam yedek ayar dosyasını ve anahtarları da içerdiği için yedek şifresi zorunlu. Önce panelde yedek şifresi belirle.');
    $dir = nbPrivateDir('backups');
    if (!is_dir($dir) || !is_writable($dir)) throw new RuntimeException('Yedek klasörü oluşturulamadı.');
    $name = 'box-full-' . date('Ymd-His') . '-' . bin2hex(random_bytes(3));
    $sqlPath = "$dir/$name.sql.gz";
    [$tables, $rows] = dumpDatabaseTo($sqlPath);
    $zipPath = "$dir/$name.zip";
    $zip = new ZipArchive();
    if ($zip->open($zipPath, ZipArchive::CREATE | ZipArchive::OVERWRITE) !== true) { @unlink($sqlPath); throw new RuntimeException('Zip oluşturulamadı.'); }
    $zip->addFile($sqlPath, "$name.sql.gz");
    
    $backupDir = realpath($dir) ?: $dir;
    $roots = [['site', realpath(ROOT) ?: ROOT]];
    $private = realpath(nbPrivateDir()) ?: '';
    if ($private !== '' && !str_starts_with($private, $roots[0][1] . DIRECTORY_SEPARATOR)) $roots[] = ['private', $private];
    $files = 0;
    foreach ($roots as [$prefix, $base]) {
        $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($base, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::LEAVES_ONLY);
        foreach ($it as $file) {
            if (!$file->isFile() || !$file->isReadable()) continue;
            $real = $file->getRealPath() ?: $file->getPathname();
            if (str_starts_with($real, $backupDir . DIRECTORY_SEPARATOR)) continue;
            if (preg_match('#/(\.git|node_modules|cache)/#', $real)) continue;
            $zip->addFile($real, $prefix . '/' . ltrim(substr($real, strlen($base)), '/\\'));
            $files++;
        }
    }
    $zip->addFromString('GERI_YUKLEME.txt', "Box tam yedeği - " . date('d.m.Y H:i') . "\n\n"
        . "$name.sql.gz : veritabanı. Panel > Erişim ve yedek > Yedekten geri yükle ile ya da phpMyAdmin'den içe aktarılır.\n"
        . "site/ : sunucudaki dosyaların tamamı (ayarlar, yüklenen fotoğraflar). Hosting'de site klasörüne olduğu gibi kopyalanır.\n"
        . (count($roots) > 1 ? "private/ : site klasörünün dışındaki gizli klasör (box-private). Site klasörünün yanına kopyalanır.\n" : '')
        . "\nParçalı geldiyse (.zip.001, .zip.002 ...) hepsini aynı klasöre indir, 7-Zip ile .001 dosyasını aç.\n");
    for ($i = 0; $i < $zip->numFiles; $i++) $zip->setEncryptionIndex($i, ZipArchive::EM_AES_256, $password);
    if (!$zip->close()) { @unlink($sqlPath); @unlink($zipPath); throw new RuntimeException('Zip yazılamadı (disk dolu olabilir).'); }
    @unlink($sqlPath);
    return ['path' => $zipPath, 'size' => (int)filesize($zipPath), 'encrypted' => true, 'tables' => count($tables), 'rows' => $rows, 'files' => $files];
}


function splitBackupFile(string $path, int $partBytes): array {
    $in = fopen($path, 'rb'); if (!$in) throw new RuntimeException('Yedek okunamadı.');
    $parts = []; $n = 0;
    while (!feof($in)) {
        $partPath = $path . '.' . str_pad((string)(++$n), 3, '0', STR_PAD_LEFT);
        $out = fopen($partPath, 'wb'); $written = 0;
        while ($written < $partBytes && !feof($in)) { $chunk = fread($in, min(1048576, $partBytes - $written)); if ($chunk === false || $chunk === '') break; fwrite($out, $chunk); $written += strlen($chunk); }
        fclose($out);
        if ($written === 0) { @unlink($partPath); break; }
        $parts[] = $partPath;
    }
    fclose($in);
    return $parts;
}


function sendDatabaseBackup(?bool $full = null): string {
    if (!telegramConfigured()) throw new RuntimeException('Önce Telegram bot belirtecini ve sohbet kimliğini girin.');
    $full ??= site('backup_mode', 'db') === 'full';
    $backup = $full ? createFullBackup() : createDatabaseBackup();
    $sizeMb = round($backup['size'] / 1048576, 2);
    $caption = ($full ? "Box TAM yedeği (veritabanı + dosyalar)" : "Box yedeği") . "\n" . date('d.m.Y H:i') . "\n{$backup['tables']} tablo • " . number_format($backup['rows'], 0, ',', '.') . " satır" . ($full ? ' • ' . number_format($backup['files'], 0, ',', '.') . ' dosya' : '') . " • $sizeMb MB" . ($backup['encrypted'] ? "\n🔒 AES-256 şifreli (7-Zip / WinRAR ile açılır)" : "\n⚠️ Şifresiz");
    $limit = 49 * 1048576;
    if ($backup['size'] > $limit) {
        
        $parts = splitBackupFile($backup['path'], 45 * 1048576);
        $total = count($parts); $sent = 0;
        foreach ($parts as $i => $part) {
            [$ok, $error] = telegramSendDocument($part, ($i === 0 ? $caption . "\n" : '') . "📦 Parça " . ($i + 1) . "/$total" . ($i === 0 ? "\nHepsini aynı klasöre indir, 7-Zip ile .001 dosyasını aç." : ''));
            @unlink($part);
            if (!$ok) { foreach (array_slice($parts, $i + 1) as $rest) @unlink($rest); throw new RuntimeException("Parça " . ($i + 1) . "/$total gönderilemedi: $error"); }
            $sent++;
        }
        $result = "Yedek $total parça halinde gönderildi ($sizeMb MB" . ($backup['encrypted'] ? ', şifreli' : ', şifresiz') . ').';
    } else {
        [$ok, $error] = telegramSendDocument($backup['path'], $caption);
        if (!$ok) throw new RuntimeException($error);
        $result = ($full ? 'Tam yedek' : 'Yedek') . " gönderildi ($sizeMb MB" . ($backup['encrypted'] ? ', şifreli' : ', şifresiz') . ').';
    }
    
    @unlink($backup['path']);
    $files = glob(nbPrivateDir('backups') . '/box-*') ?: [];
    rsort($files);
    foreach (array_slice($files, 2) as $old) @unlink($old);
    saveSite('backup_last', date('Y-m-d H:i:s') . ' • ' . $result);
    return $result;
}


function runDailyBackup(): void {
    if (site('backup_enabled', '0') !== '1' || (int)date('G') < 4 || site('backup_done') === date('Y-m-d')) return;
    saveSite('backup_done', date('Y-m-d'));
    try { sendDatabaseBackup(); }
    catch (Throwable $e) { saveSite('backup_last', date('Y-m-d H:i:s') . ' • HATA: ' . $e->getMessage()); error_log('Yedek: ' . $e->getMessage()); try { telegramSend('⚠️ Box günlük yedeği alınamadı: ' . $e->getMessage()); } catch (Throwable $ignored) {} }
}


function runCron(int $limit = 400): array {
    saveSite('cron_last_run', date('Y-m-d H:i:s'));
    saveSite('cron_real_run', date('Y-m-d H:i:s'));
    $expired = boxExpirePremiums();
    runDailyBackup();
    runSecurityCron();
    return ['expired_premiums' => $expired];
}

/** Hatalar ve önemli olaylar için Telegram uyarısı (Koruma ve yedek > Anlık uyarılar). */
function staffAlert(string $kind, string $text): void {
    if (site('tg_alert_' . $kind, '1') !== '1' || !telegramConfigured()) return;
    try { telegramSend("📦 Box\n" . $text); } catch (Throwable $e) { error_log((string)$e); }
}

/** Panelin aldığı .sql.gz ya da şifreli .zip yedeğini geri yükler; önce mevcut durumun yedeğini alır. */
function restoreDatabaseBackup(string $uploadPath, string $originalName): array {
    $lower = strtolower($originalName);
    $tmpDir = nbPrivateDir('backups');
    $sqlGz = $uploadPath;
    $cleanup = [];
    if (str_ends_with($lower, '.zip')) {
        if (!class_exists('ZipArchive')) throw new RuntimeException('Sunucuda zip desteği yok.');
        $zip = new ZipArchive();
        if ($zip->open($uploadPath) !== true) throw new RuntimeException('Zip dosyası açılamadı.');
        $password = decryptSecret(site('backup_password'));
        if ($password !== '') $zip->setPassword($password);
        $entry = null;
        for ($i = 0; $i < $zip->numFiles; $i++) { $n = (string)$zip->getNameIndex($i); if (preg_match('/^box-[\w-]+\.sql\.gz$/', $n)) { $entry = $n; break; } }
        if ($entry === null) { $zip->close(); throw new RuntimeException('Zip içinde Box yedeği bulunamadı.'); }
        $data = $zip->getFromName($entry);
        $zip->close();
        if ($data === false) throw new RuntimeException('Zip açılamadı. Yedek şifresi panelde kayıtlı şifreyle aynı olmalı.');
        $sqlGz = $tmpDir . '/restore-' . bin2hex(random_bytes(4)) . '.sql.gz';
        file_put_contents($sqlGz, $data);
        $cleanup[] = $sqlGz;
    } elseif (!str_ends_with($lower, '.sql.gz') && !str_ends_with($lower, '.gz')) {
        throw new RuntimeException('Yalnızca panelin aldığı .sql.gz ya da .zip yedekleri yüklenebilir.');
    }
    $gz = gzopen($sqlGz, 'rb');
    if (!$gz) throw new RuntimeException('Yedek dosyası okunamadı.');
    $head = (string)gzread($gz, 64);
    if (!str_starts_with($head, '-- Box yedeği')) { gzclose($gz); foreach ($cleanup as $f) @unlink($f); throw new RuntimeException('Bu dosya Box panel yedeği değil.'); }
    gzrewind($gz);

    
    $safety = createDatabaseBackup();

    $count = 0; $tables = 0; $buf = ''; $inStr = false; $esc = false;
    $exec = function (string $sql) use (&$count, &$tables) {
        $sql = trim($sql);
        if ($sql === '' || str_starts_with($sql, '--')) {
            $lines = array_filter(explode("\n", $sql), fn($l) => !str_starts_with(trim($l), '--') && trim($l) !== '');
            $sql = trim(implode("\n", $lines));
            if ($sql === '') return;
        }
        db()->exec($sql);
        $count++;
        if (stripos($sql, 'CREATE TABLE') === 0) $tables++;
    };
    try {
        while (!gzeof($gz)) {
            $chunk = (string)gzread($gz, 1 << 16);
            $len = strlen($chunk);
            for ($i = 0; $i < $len; $i++) {
                $c = $chunk[$i];
                $buf .= $c;
                if ($inStr) {
                    if ($esc) { $esc = false; continue; }
                    if ($c === '\\') { $esc = true; continue; }
                    if ($c === "'") $inStr = false;
                    continue;
                }
                if ($c === "'") { $inStr = true; continue; }
                if ($c === ';') { $exec(substr($buf, 0, -1)); $buf = ''; }
            }
        }
        if (trim($buf) !== '') $exec($buf);
    } finally {
        gzclose($gz);
        foreach ($cleanup as $f) @unlink($f);
        try { db()->exec('SET FOREIGN_KEY_CHECKS=1'); } catch (Throwable $e) {}
    }
    return ['statements' => $count, 'tables' => $tables, 'safety' => basename($safety['path'])];
}
