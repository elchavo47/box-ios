<?php

/**
 * Box API
 * Tüm istekler: index.php?action=<işlem>
 * Yanıt: {"ok": true, ...} ya da {"ok": false, "error": "..."}
 */

declare(strict_types=1);

ob_start();
ini_set('display_errors', '0');
ini_set('log_errors', '1');

require __DIR__ . '/lib.php';

$action = isset($_GET['action']) && is_string($_GET['action']) ? $_GET['action'] : '';

try {
    switch ($action) {
        case 'register':
            require_method('POST');

            $email = strtolower(input_string('email', 190));
            $password = (string) (input_json()['password'] ?? '');
            $name = input_string('name', 60);

            if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
                throw new ApiError('Geçerli bir e-posta adresi gir.');
            }

            if (strlen($password) < 8 || strlen($password) > 200) {
                throw new ApiError('Şifre en az 8 karakter olmalı.');
            }

            if ($name === '') {
                $name = mb_substr(explode('@', $email)[0], 0, 60);
            }

            if (find_user_by_email($email) !== null) {
                throw new ApiError('Bu e-posta ile zaten bir hesap var.', 409);
            }

            db()->prepare(
                'INSERT INTO users (email, password_hash, display_name, last_login_at) VALUES (?, ?, ?, NOW())'
            )->execute([$email, password_hash($password, PASSWORD_DEFAULT), $name]);

            $user = find_user_by_id((int) db()->lastInsertId());

            json_out([
                'ok' => true,
                'token' => issue_token((int) $user['id']),
                'user' => user_public($user),
            ], 201);

        case 'login':
            require_method('POST');

            $ip = client_ip();
            $stmt = db()->prepare(
                'SELECT COUNT(*) FROM login_attempts WHERE ip = ? AND attempted_at > (NOW() - INTERVAL 15 MINUTE)'
            );
            $stmt->execute([$ip]);

            if ((int) $stmt->fetchColumn() >= 10) {
                throw new ApiError('Çok fazla deneme yaptın, 15 dakika sonra tekrar dene.', 429);
            }

            $email = strtolower(input_string('email', 190));
            $password = (string) (input_json()['password'] ?? '');
            $user = find_user_by_email($email);

            if ($user === null || !password_verify($password, (string) $user['password_hash'])) {
                db()->prepare('INSERT INTO login_attempts (ip) VALUES (?)')->execute([$ip]);
                throw new ApiError('E-posta veya şifre hatalı.', 401);
            }

            if ((int) $user['is_banned'] === 1) {
                throw new ApiError('Hesabın askıya alındı.', 403);
            }

            if (password_needs_rehash((string) $user['password_hash'], PASSWORD_DEFAULT)) {
                db()->prepare('UPDATE users SET password_hash = ? WHERE id = ?')
                    ->execute([password_hash($password, PASSWORD_DEFAULT), (int) $user['id']]);
            }

            db()->prepare('UPDATE users SET last_login_at = NOW() WHERE id = ?')->execute([(int) $user['id']]);
            db()->prepare('DELETE FROM login_attempts WHERE ip = ?')->execute([$ip]);

            json_out([
                'ok' => true,
                'token' => issue_token((int) $user['id']),
                'user' => user_public($user),
            ]);

        case 'me':
            $user = current_user();
            json_out(['ok' => true, 'user' => user_public($user)]);

        case 'update_profile':
            require_method('POST');
            $user = current_user();
            $name = input_string('name', 60);

            if ($name === '') {
                throw new ApiError('İsim boş olamaz.');
            }

            db()->prepare('UPDATE users SET display_name = ? WHERE id = ?')->execute([$name, (int) $user['id']]);
            json_out(['ok' => true, 'user' => user_public(find_user_by_id((int) $user['id']))]);

        case 'logout':
            require_method('POST');
            $token = bearer_token();

            if ($token !== null) {
                db()->prepare('DELETE FROM tokens WHERE token_hash = ?')->execute([hash('sha256', $token)]);
            }

            json_out(['ok' => true]);

        case 'delete_account':
            require_method('POST');
            $user = current_user();
            $password = (string) (input_json()['password'] ?? '');

            if (!password_verify($password, (string) $user['password_hash'])) {
                throw new ApiError('Şifre hatalı.', 401);
            }

            db()->prepare('DELETE FROM users WHERE id = ?')->execute([(int) $user['id']]);
            json_out(['ok' => true]);

        case 'search':
            $user = current_user();
            require_premium($user);

            $query = isset($_GET['q']) && is_string($_GET['q']) ? trim($_GET['q']) : '';
            if ($query === '' || mb_strlen($query) > 200) {
                throw new ApiError('Arama metni gerekli.');
            }

            $search = youtube_get('search', [
                'part' => 'snippet',
                'q' => $query,
                'type' => 'video',
                'maxResults' => 25,
                'safeSearch' => 'none',
                'regionCode' => 'TR',
            ]);

            $ids = [];
            foreach (($search['items'] ?? []) as $item) {
                $id = $item['id']['videoId'] ?? null;
                if (is_string($id) && preg_match('/^[A-Za-z0-9_-]{11}$/', $id)) {
                    $ids[] = $id;
                }
            }

            $durations = [];
            if ($ids !== []) {
                $details = youtube_get('videos', [
                    'part' => 'contentDetails',
                    'id' => implode(',', $ids),
                ]);

                foreach (($details['items'] ?? []) as $item) {
                    $durations[(string) $item['id']] = iso8601_seconds((string) ($item['contentDetails']['duration'] ?? ''));
                }
            }

            $results = [];
            foreach (($search['items'] ?? []) as $item) {
                $id = $item['id']['videoId'] ?? null;
                if (!is_string($id) || !in_array($id, $ids, true)) {
                    continue;
                }

                $snippet = $item['snippet'] ?? [];
                $thumbs = $snippet['thumbnails'] ?? [];

                $results[] = [
                    'id' => $id,
                    'title' => clean_text((string) ($snippet['title'] ?? '')),
                    'channel' => clean_text((string) ($snippet['channelTitle'] ?? '')),
                    'thumbnail' => $thumbs['high']['url'] ?? $thumbs['medium']['url'] ?? $thumbs['default']['url'] ?? null,
                    'duration' => $durations[$id] ?? 0,
                ];
            }

            json_out(['ok' => true, 'results' => $results]);

        case 'download_link':
            $user = current_user();
            require_premium($user);

            $videoId = isset($_GET['video_id']) && is_string($_GET['video_id']) ? $_GET['video_id'] : '';
            if (!preg_match('/^[A-Za-z0-9_-]{11}$/D', $videoId)) {
                throw new ApiError('Geçersiz video.');
            }

            if (VDS_SIGNING_KEY === '' || VDS_SIGNING_KEY === 'VDS_DEKI_YT_API_KEY_ILE_AYNI') {
                throw new ApiError('İndirme servisi yapılandırılmamış.', 500);
            }

            $title = isset($_GET['title']) && is_string($_GET['title']) ? mb_substr(trim($_GET['title']), 0, 255) : '';
            $expires = time() + (int) DOWNLOAD_LINK_TTL;
            $signature = hash_hmac('sha256', $videoId . ':' . $expires, VDS_SIGNING_KEY);

            db()->prepare('INSERT INTO downloads (user_id, video_id, title) VALUES (?, ?, ?)')
                ->execute([(int) $user['id'], $videoId, $title]);

            json_out([
                'ok' => true,
                'url' => rtrim(VDS_BASE_URL, '/') . '/get?' . http_build_query([
                    'v' => $videoId,
                    'exp' => $expires,
                    'sig' => $signature,
                ]),
                'expires_at' => $expires,
            ]);

        case 'ping':
            json_out(['ok' => true, 'service' => 'box', 'time' => time()]);

        default:
            throw new ApiError('Geçersiz işlem.', 404);
    }
} catch (ApiError $e) {
    json_out(['ok' => false, 'error' => $e->getMessage()], $e->status);
} catch (Throwable $e) {
    error_log('[Box API] ' . get_class($e) . ': ' . $e->getMessage() . ' @ ' . $e->getFile() . ':' . $e->getLine());
    json_out(['ok' => false, 'error' => 'Sunucu hatası, daha sonra tekrar dene.'], 500);
}
