<?php
if (!defined('ROOT')) { http_response_code(404); exit; }

/*
 * Hesaba bağlı kitaplık: çalma listeleri, beğenilenler ve liste kapakları.
 * Uygulama yalnızca değişenleri gönderir (POST me/library); sunucu her öğe için
 * "en son değişen kazanır" kuralını uygular ve hesabın güncel kitaplığını döner.
 * Zaman damgaları milisaniye (istemci saati); silinenler "deleted" olarak tutulur ki
 * başka cihaz eski kopyayı geri yüklemesin.
 */

const BOX_LIB_MAX_PLAYLISTS = 500;
const BOX_LIB_MAX_ITEMS = 5000;
const BOX_LIB_MAX_FAVORITES = 10000;

function boxLibNow(): int { return (int)floor(microtime(true) * 1000); }

/** Zaman damgasını makul aralığa sıkıştır (gelecekteki saatler başka cihazları ezmesin). */
function boxLibStamp($value): int {
    $v = is_numeric($value) ? (int)$value : 0;
    return max(0, min($v, boxLibNow() + 5 * 60 * 1000));
}

function boxLibUuid($value): ?string {
    $v = is_string($value) ? strtoupper(trim($value)) : '';
    return preg_match('/^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/', $v) ? $v : null;
}

function boxLibText($value, int $max): string {
    return is_string($value) ? mb_substr(trim(preg_replace('/[\x00-\x1F\x7F]/u', '', $value) ?? ''), 0, $max) : '';
}

/** İnternet şarkısının bilgisi (uygulamanın SearchResult'ı); bilinmeyen alanlar atılır. */
function boxLibRemote($r): ?array {
    if (!is_array($r)) return null;
    $id = (string)($r['id'] ?? '');
    if (!preg_match(BOX_VIDEO_ID, $id)) return null;
    $out = [
        'id' => $id,
        'title' => boxLibText($r['title'] ?? '', 300),
        'channel' => boxLibText($r['channel'] ?? '', 300),
        'thumbnail' => null,
        'duration' => max(0, min(86400, (int)($r['duration'] ?? 0))),
    ];
    $thumb = (string)($r['thumbnail'] ?? '');
    if ($thumb !== '' && preg_match('#^https://[a-z0-9.-]+\.(ytimg|googleusercontent|ggpht)\.com/#i', $thumb) && strlen($thumb) <= 600) $out['thumbnail'] = $thumb;
    foreach (['artistId' => 80, 'albumId' => 80, 'album' => 300] as $key => $max) {
        $v = boxLibText($r[$key] ?? '', $max);
        if ($v !== '') $out[$key] = $v;
    }
    return $out;
}

function boxLibCoverDir(): string {
    $dir = nbPrivateDir('playlist-covers');
    if (!is_dir($dir)) @mkdir($dir, 0700, true);
    return $dir;
}

function boxLibCoverUrl(?string $file): ?string {
    if (!$file || !preg_match('/^[a-f0-9]{32}\.jpg$/', $file)) return null;
    return rtrim((string)cfg('app.url', ''), '/') . '/api/v1/pcover/' . $file;
}

function boxLibDeleteCover(?string $file): void {
    if ($file && preg_match('/^[a-f0-9]{32}\.jpg$/', $file)) @unlink(boxLibCoverDir() . '/' . $file);
}

/** Hesap silinirken: kapak dosyaları (satırlar FOREIGN KEY ile kendiliğinden silinir). */
function boxLibDeleteUserFiles(int $userId): void {
    try {
        foreach (q('SELECT cover_file FROM user_playlists WHERE user_id=? AND cover_file IS NOT NULL', [$userId])->fetchAll(PDO::FETCH_COLUMN) as $f) boxLibDeleteCover((string)$f);
    } catch (Throwable $e) {}
}

function boxLibPlaylistOut(array $row): array {
    $items = json_decode((string)$row['items'], true);
    return [
        'id' => (string)$row['pid'],
        'name' => (string)$row['name'],
        'paths' => is_array($items['paths'] ?? null) ? array_values($items['paths']) : [],
        'remote' => is_array($items['remote'] ?? null) ? array_values($items['remote']) : [],
        'source_id' => $row['source_id'] !== null ? (string)$row['source_id'] : null,
        'cover_url' => boxLibCoverUrl($row['cover_file']),
        'position' => (int)$row['position'],
        'created_at' => (int)$row['created_at'],
        'updated_at' => (int)$row['updated_at'],
        'deleted' => (int)$row['deleted'] === 1,
    ];
}

/** Hesabın kitaplığı (silinenler de: diğer cihazlar silsin diye son 180 gün). */
function boxLibState(int $userId): array {
    $cutoff = boxLibNow() - 180 * 86400 * 1000;
    $playlists = array_map('boxLibPlaylistOut', q('SELECT * FROM user_playlists WHERE user_id=? AND (deleted=0 OR updated_at>?) ORDER BY deleted, position, created_at', [$userId, $cutoff])->fetchAll());
    $favorites = [];
    foreach (q('SELECT item_key, meta, liked, updated_at FROM user_favorites WHERE user_id=? AND (liked=1 OR updated_at>?) ORDER BY updated_at DESC', [$userId, $cutoff])->fetchAll() as $f) {
        $meta = $f['meta'] !== null ? json_decode((string)$f['meta'], true) : null;
        $favorites[] = ['key' => (string)$f['item_key'], 'on' => (int)$f['liked'] === 1, 'at' => (int)$f['updated_at'], 'meta' => is_array($meta) ? $meta : null];
    }
    $orderAt = (int)(q('SELECT library_order_at FROM users WHERE id=?', [$userId])->fetchColumn() ?: 0);
    return ['playlists' => $playlists, 'favorites' => $favorites, 'order_at' => $orderAt, 'server_time' => boxLibNow()];
}

/** Uygulamadan gelen değişiklikleri uygular. Dönen değer: uygulanan değişiklik sayısı. */
function boxLibApply(int $userId, array $body): int {
    $applied = 0;
    $pdo = db();
    $pdo->beginTransaction();
    try {
        // Çalma listeleri
        $incoming = is_array($body['playlists'] ?? null) ? array_slice($body['playlists'], 0, BOX_LIB_MAX_PLAYLISTS) : [];
        $live = (int)q('SELECT COUNT(*) FROM user_playlists WHERE user_id=? AND deleted=0', [$userId])->fetchColumn();
        foreach ($incoming as $p) {
            if (!is_array($p) || !($pid = boxLibUuid($p['id'] ?? null))) continue;
            $at = boxLibStamp($p['updated_at'] ?? 0);
            $row = q('SELECT updated_at, deleted, cover_file FROM user_playlists WHERE user_id=? AND pid=? FOR UPDATE', [$userId, $pid])->fetch();
            if ($row && (int)$row['updated_at'] >= $at) continue;
            $deleted = !empty($p['deleted']);
            if ($deleted) {
                if (!$row) {
                    q('INSERT INTO user_playlists(user_id,pid,name,items,created_at,updated_at,deleted) VALUES(?,?,?,?,?,?,1)', [$userId, $pid, '', '{}', boxLibStamp($p['created_at'] ?? $at), $at]);
                } else {
                    boxLibDeleteCover($row['cover_file']);
                    q("UPDATE user_playlists SET deleted=1, name='', items='{}', cover_file=NULL, updated_at=? WHERE user_id=? AND pid=?", [$at, $userId, $pid]);
                    if ((int)$row['deleted'] === 0) $live--;
                }
                $applied++;
                continue;
            }
            if ((!$row || (int)$row['deleted'] === 1) && $live >= BOX_LIB_MAX_PLAYLISTS) continue;
            $paths = [];
            foreach (array_slice(is_array($p['paths'] ?? null) ? $p['paths'] : [], 0, BOX_LIB_MAX_ITEMS) as $path) {
                $path = boxLibText($path, 1000);
                if ($path !== '' && !str_contains($path, '..')) $paths[] = $path;
            }
            $remote = [];
            $seen = [];
            foreach (array_slice(is_array($p['remote'] ?? null) ? $p['remote'] : [], 0, BOX_LIB_MAX_ITEMS) as $r) {
                if (($item = boxLibRemote($r)) && !isset($seen[$item['id']])) { $seen[$item['id']] = true; $remote[] = $item; }
            }
            $name = boxLibText($p['name'] ?? '', 120);
            if ($name === '') $name = 'Liste';
            $source = boxLibText($p['source_id'] ?? '', 120);
            $items = json_encode(['paths' => array_values(array_unique($paths)), 'remote' => $remote], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
            if ($items === false || strlen($items) > 8 * 1024 * 1024) continue;
            if ($row) {
                q('UPDATE user_playlists SET name=?, items=?, source_id=?, deleted=0, updated_at=? WHERE user_id=? AND pid=?', [$name, $items, $source !== '' ? $source : null, $at, $userId, $pid]);
                if ((int)$row['deleted'] === 1) $live++;
            } else {
                $position = (int)q('SELECT COALESCE(MAX(position),0)+1 FROM user_playlists WHERE user_id=?', [$userId])->fetchColumn();
                q('INSERT INTO user_playlists(user_id,pid,name,items,source_id,position,created_at,updated_at,deleted) VALUES(?,?,?,?,?,?,?,?,0)', [$userId, $pid, $name, $items, $source !== '' ? $source : null, $position, boxLibStamp($p['created_at'] ?? $at), $at]);
                $live++;
            }
            $applied++;
        }

        // Liste sırası
        $order = $body['order'] ?? null;
        if (is_array($order) && is_array($order['ids'] ?? null)) {
            $at = boxLibStamp($order['at'] ?? 0);
            $current = (int)(q('SELECT library_order_at FROM users WHERE id=? FOR UPDATE', [$userId])->fetchColumn() ?: 0);
            if ($at > $current) {
                $position = 1;
                foreach (array_slice($order['ids'], 0, BOX_LIB_MAX_PLAYLISTS * 2) as $id) {
                    if ($pid = boxLibUuid($id)) q('UPDATE user_playlists SET position=? WHERE user_id=? AND pid=?', [$position++, $userId, $pid]);
                }
                q('UPDATE users SET library_order_at=? WHERE id=?', [$at, $userId]);
                $applied++;
            }
        }

        // Beğenilenler
        $favorites = is_array($body['favorites'] ?? null) ? array_slice($body['favorites'], 0, BOX_LIB_MAX_FAVORITES) : [];
        foreach ($favorites as $f) {
            if (!is_array($f)) continue;
            $key = boxLibText($f['key'] ?? '', 1000);
            if ($key === '' || str_contains($key, '..')) continue;
            if (str_starts_with($key, 'yt:') && !preg_match(BOX_VIDEO_ID, substr($key, 3))) continue;
            $at = boxLibStamp($f['at'] ?? 0);
            $hash = sha1($key);
            $stored = q('SELECT updated_at FROM user_favorites WHERE user_id=? AND key_hash=? FOR UPDATE', [$userId, $hash])->fetchColumn();
            if ($stored !== false && (int)$stored >= $at) continue;
            $meta = str_starts_with($key, 'yt:') ? boxLibRemote($f['meta'] ?? null) : null;
            $metaJson = $meta ? json_encode($meta, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) : null;
            q('INSERT INTO user_favorites(user_id,key_hash,item_key,meta,liked,updated_at) VALUES(?,?,?,?,?,?) ON DUPLICATE KEY UPDATE item_key=VALUES(item_key), meta=COALESCE(VALUES(meta),meta), liked=VALUES(liked), updated_at=VALUES(updated_at)',
                [$userId, $hash, $key, $metaJson, !empty($f['on']) ? 1 : 0, $at]);
            $applied++;
        }
        $pdo->commit();
    } catch (Throwable $e) {
        if ($pdo->inTransaction()) $pdo->rollBack();
        throw $e;
    }
    return $applied;
}

/** Liste kapağı yükleme / kaldırma. */
function boxLibSetCover(int $userId, string $pid, ?string $binary): ?string {
    $row = q('SELECT cover_file FROM user_playlists WHERE user_id=? AND pid=? AND deleted=0', [$userId, $pid])->fetch();
    if (!$row) throw new RuntimeException('Liste bulunamadı.');
    if ($binary === null) {
        boxLibDeleteCover($row['cover_file']);
        q('UPDATE user_playlists SET cover_file=NULL WHERE user_id=? AND pid=?', [$userId, $pid]);
        return null;
    }
    if (strlen($binary) < 100 || strlen($binary) > 1024 * 1024) throw new RuntimeException('Kapak en fazla 1 MB olmalı.');
    $info = @getimagesizefromstring($binary);
    if (($info['mime'] ?? '') !== 'image/jpeg' || ($info[0] ?? 0) < 32 || ($info[0] ?? 0) > 3000 || ($info[1] ?? 0) > 3000) throw new RuntimeException('Geçerli bir JPEG kapak gönder.');
    $name = bin2hex(random_bytes(16)) . '.jpg';
    if (@file_put_contents(boxLibCoverDir() . '/' . $name, $binary, LOCK_EX) === false) throw new RuntimeException('Kapak kaydedilemedi.');
    q('UPDATE user_playlists SET cover_file=? WHERE user_id=? AND pid=?', [$name, $userId, $pid]);
    boxLibDeleteCover($row['cover_file']);
    return boxLibCoverUrl($name);
}

/** Panel için özet. */
function boxLibSummary(int $userId): array {
    try {
        $rows = q('SELECT pid, name, items, updated_at, cover_file FROM user_playlists WHERE user_id=? AND deleted=0 ORDER BY position, created_at', [$userId])->fetchAll();
        $lists = [];
        foreach ($rows as $r) {
            $items = json_decode((string)$r['items'], true);
            $lists[] = ['name' => (string)$r['name'], 'count' => count($items['paths'] ?? []) + count($items['remote'] ?? []), 'remote' => count($items['remote'] ?? []), 'updated_at' => (int)$r['updated_at'], 'cover' => boxLibCoverUrl($r['cover_file'])];
        }
        $favorites = (int)q('SELECT COUNT(*) FROM user_favorites WHERE user_id=? AND liked=1', [$userId])->fetchColumn();
        return ['playlists' => $lists, 'favorites' => $favorites];
    } catch (Throwable $e) {
        return ['playlists' => [], 'favorites' => 0];
    }
}
