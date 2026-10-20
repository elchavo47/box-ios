<?php
if (!defined('ROOT')) { http_response_code(404); exit; }










function nbErrDb(): ?PDO {
    static $own = false, $mainDown = false;
    if (!$mainDown) {
        try { $main = db(); if (!$main->inTransaction()) return $main; }
        catch (Throwable $e) { $mainDown = true; return null; }
    }
    if ($own !== false) return $own;
    $own = null;
    $d = cfg('db');
    if (!is_array($d)) return null;
    try {
        $own = new PDO("mysql:host={$d['host']};port={$d['port']};dbname={$d['name']};charset={$d['charset']}", $d['user'], $d['pass'],
            [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC, PDO::ATTR_EMULATE_PREPARES => false, PDO::ATTR_TIMEOUT => 3]);
        $own->exec("SET time_zone='" . date('P') . "'");
    } catch (Throwable $e) { $own = null; }
    return $own;
}

function nbErrPath(string $file): string {
    return str_starts_with($file, ROOT . '/') ? substr($file, strlen(ROOT) + 1) : basename($file);
}


function nbErrNormalize(string $message): string {
    $m = preg_replace('/\'[^\']{0,200}\'|"[^"]{0,200}"/u', '?', $message) ?? $message;
    $m = preg_replace('/\b0x[0-9a-f]+\b|\b[0-9a-f]{12,}\b/i', 'H', $m) ?? $m;
    $m = preg_replace('/\d+/', 'N', $m) ?? $m;
    return mb_substr($m, 0, 300);
}

function nbErrLevel(int $no): string {
    if ($no & (E_WARNING | E_USER_WARNING | E_CORE_WARNING | E_COMPILE_WARNING)) return 'Warning';
    if ($no & (E_NOTICE | E_USER_NOTICE)) return 'Notice';
    if ($no & (E_DEPRECATED | E_USER_DEPRECATED)) return 'Deprecated';
    return 'Error';
}

function nbErrFrames(array $frames): string {
    $out = [];
    foreach (array_slice($frames, 0, 12) as $i => $f) {
        $where = isset($f['file']) ? nbErrPath((string)$f['file']) . ':' . (int)($f['line'] ?? 0) : '[iç]';
        $out[] = '#' . $i . ' ' . $where . ' ' . ($f['class'] ?? '') . ($f['type'] ?? '') . ($f['function'] ?? '') . '()';
    }
    return implode("\n", $out);
}


function nbErrRequest(): string {
    if (PHP_SAPI === 'cli') return 'Komut satırı (' . basename((string)($_SERVER['argv'][0] ?? 'php')) . ')';
    return mb_substr(strtoupper((string)($_SERVER['REQUEST_METHOD'] ?? 'GET')) . ' ' . (string)parse_url((string)($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_PATH), 0, 255);
}




function nbErrRecord(string $level, string $message, string $file, int $line, string $trace = '', bool $alertable = true): void {
    static $count = 0, $busy = false;
    if ($busy || ++$count > 8) return;
    $busy = true;
    try {
        $pdo = nbErrDb();
        if (!$pdo) return;
        $rel = nbErrPath($file);
        $sig = sha1($level . '|' . nbErrNormalize($message) . '|' . $rel . '|' . $line);
        $url = nbErrRequest();
        $msg = mb_substr($message, 0, 500);
        $trace = mb_substr($trace, 0, 6000);
        $st = $pdo->prepare('SELECT status FROM error_groups WHERE sig=?'); $st->execute([$sig]);
        $status = $st->fetchColumn();
        $kind = null;
        if ($status === false) {
            try {
                $pdo->prepare('INSERT INTO error_groups(sig,level,message,file,line,last_url,last_trace) VALUES(?,?,?,?,?,?,?)')->execute([$sig, $level, $msg, $rel, $line, $url, $trace]);
                $kind = 'new';
            } catch (PDOException $e) {
                if ((int)($e->errorInfo[1] ?? 0) !== 1062) throw $e;
                $status = 'open'; 
            }
        }
        if ($status !== false) {
            $next = $status === 'resolved' ? 'open' : (string)$status;
            $pdo->prepare('UPDATE error_groups SET occurrences=occurrences+1,last_seen=NOW(),last_url=?,last_trace=?,message=?,status=?,resolved_at=IF(?=\'open\',NULL,resolved_at) WHERE sig=?')->execute([$url, $trace, $msg, $next, $next, $sig]);
            if ($status === 'resolved') $kind = 'again';
        }
        $pdo->prepare('INSERT INTO error_daily(day,sig,n) VALUES(CURDATE(),?,1) ON DUPLICATE KEY UPDATE n=n+1')->execute([$sig]);
        if ($kind !== null && $alertable) nbErrAlert($pdo, $sig, $kind, $level, $msg, $rel, $line, $url);
    } catch (Throwable $e) {
        
    } finally {
        $busy = false;
    }
}


function nbErrAlert(PDO $pdo, string $sig, string $kind, string $level, string $msg, string $rel, int $line, string $url): void {
    if (!function_exists('staffAlert')) return;
    if ((int)$pdo->query('SELECT COUNT(*) FROM error_groups WHERE notified_at>DATE_SUB(NOW(),INTERVAL 1 HOUR)')->fetchColumn() >= 10) return;
    $pdo->prepare('UPDATE error_groups SET notified_at=NOW() WHERE sig=?')->execute([$sig]);
    staffAlert('errors', ($kind === 'again' ? "🐞 Çözüldü işaretlediğin hata yeniden başladı\n" : "🐞 Yeni hata türü\n")
        . $level . ': ' . mb_strimwidth($msg, 0, 400, '…') . "\nYer: {$rel}:{$line}\nİstek: {$url}\nPanel > Hatalar");
}


function nbReport(Throwable $e, string $context = ''): void {
    error_log(($context !== '' ? $context . ': ' : '') . $e);
    
    $file = $e->getFile(); $line = $e->getLine();
    if (str_ends_with($file, '/app/bootstrap.php')) {
        foreach ($e->getTrace() as $f) if (in_array($f['function'] ?? '', ['q', 'db'], true) && isset($f['file']) && !str_ends_with((string)$f['file'], '/app/bootstrap.php')) { $file = (string)$f['file']; $line = (int)($f['line'] ?? 0); break; }
    }
    nbErrRecord('Exception', ($context !== '' ? $context . ' · ' : '') . get_class($e) . ': ' . $e->getMessage(), $file, $line, $e->getTraceAsString());
}


function nbErrInstall(): void {
    set_error_handler(function (int $no, string $str, string $file = '', int $line = 0): bool {
        static $n = 0;
        if (!(error_reporting() & $no) || ++$n > 8) return false; 
        $level = nbErrLevel($no);
        nbErrRecord($level, $str, $file, $line, nbErrFrames(array_slice(debug_backtrace(DEBUG_BACKTRACE_IGNORE_ARGS, 14), 1)), !in_array($level, ['Notice', 'Deprecated'], true));
        return false;
    });
    register_shutdown_function(function (): void {
        $e = error_get_last();
        if ($e && in_array($e['type'], [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR], true)) nbErrRecord('Fatal', (string)$e['message'], (string)$e['file'], (int)$e['line']);
    });
}


function errorOpenCount(): int {
    try { return (int)q("SELECT COUNT(*) FROM error_groups WHERE status='open' AND last_seen>=DATE_SUB(NOW(),INTERVAL 7 DAY)")->fetchColumn(); }
    catch (Throwable $e) { return 0; }
}


function errorCleanup(): void {
    q('DELETE FROM error_daily WHERE day<DATE_SUB(CURDATE(),INTERVAL 30 DAY)');
    q("DELETE FROM error_groups WHERE status='resolved' AND last_seen<DATE_SUB(NOW(),INTERVAL 30 DAY)");
}

nbErrInstall();
