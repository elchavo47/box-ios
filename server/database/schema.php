<?php
if (!defined('ROOT')) { http_response_code(404); exit; }

/*
 * Box veritabanı şeması (sıfır kurulum).
 * Mevcut kurulumlarda eksik tablo ve sütunları app/setup.php içindeki ensureSchema() tamamlar;
 * bu dosyadaki tablolar oradan da "yoksa oluştur" olarak kullanılır.
 */

return <<<'SQL'
CREATE TABLE users (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  email VARCHAR(190) NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  display_name VARCHAR(60) NOT NULL,
  is_premium TINYINT(1) NOT NULL DEFAULT 0,
  premium_until DATETIME NULL DEFAULT NULL,
  premium_since DATETIME NULL DEFAULT NULL,
  is_banned TINYINT(1) NOT NULL DEFAULT 0,
  ban_reason VARCHAR(255) NULL DEFAULT NULL,
  note TEXT NULL,
  app_version VARCHAR(20) NULL DEFAULT NULL,
  daily_downloads INT UNSIGNED NULL DEFAULT NULL,
  avatar_file VARCHAR(64) NULL DEFAULT NULL,
  has_password TINYINT(1) NOT NULL DEFAULT 1,
  apple_sub VARCHAR(120) NULL DEFAULT NULL,
  apple_refresh TEXT NULL,
  expiry_notified_for DATETIME NULL DEFAULT NULL,
  library_order_at BIGINT UNSIGNED NOT NULL DEFAULT 0,
  lang VARCHAR(8) NULL DEFAULT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_login_at DATETIME NULL DEFAULT NULL,
  last_seen_at DATETIME NULL DEFAULT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_users_email (email),
  UNIQUE KEY uq_users_apple (apple_sub),
  KEY idx_users_premium (is_premium, premium_until),
  KEY idx_users_seen (last_seen_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE tokens (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id INT UNSIGNED NOT NULL,
  token_hash CHAR(64) NOT NULL,
  device VARCHAR(120) NULL DEFAULT NULL,
  device_id VARCHAR(64) NULL DEFAULT NULL,
  model VARCHAR(40) NULL DEFAULT NULL,
  os VARCHAR(30) NULL DEFAULT NULL,
  app_version VARCHAR(20) NULL DEFAULT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_used_at DATETIME NULL DEFAULT NULL,
  expires_at DATETIME NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_tokens_hash (token_hash),
  KEY idx_tokens_user (user_id),
  KEY idx_tokens_device (user_id, device_id),
  CONSTRAINT fk_tokens_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE login_attempts (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  ip VARCHAR(45) NOT NULL,
  attempted_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_attempts_ip_time (ip, attempted_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE downloads (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id INT UNSIGNED NOT NULL,
  video_id CHAR(11) NOT NULL,
  title VARCHAR(255) NOT NULL DEFAULT '',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_downloads_user (user_id, created_at),
  KEY idx_downloads_time (created_at),
  CONSTRAINT fk_downloads_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE push_devices (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id INT UNSIGNED NOT NULL,
  token VARCHAR(200) NOT NULL,
  environment VARCHAR(12) NOT NULL DEFAULT 'production',
  app_version VARCHAR(20) NULL DEFAULT NULL,
  device_id VARCHAR(64) NULL DEFAULT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen_at DATETIME NULL DEFAULT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_push_token (token),
  KEY idx_push_user (user_id),
  CONSTRAINT fk_push_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE notifications (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id INT UNSIGNED NULL DEFAULT NULL,
  target VARCHAR(40) NOT NULL,
  title VARCHAR(120) NOT NULL,
  body VARCHAR(400) NOT NULL,
  title_en VARCHAR(120) NULL DEFAULT NULL,
  body_en VARCHAR(400) NULL DEFAULT NULL,
  open_to VARCHAR(20) NULL DEFAULT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_notif_user (user_id, id),
  KEY idx_notif_target (target, id),
  CONSTRAINT fk_notif_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE user_playlists (
  user_id INT UNSIGNED NOT NULL,
  pid CHAR(36) NOT NULL,
  name VARCHAR(120) NOT NULL DEFAULT '',
  items MEDIUMTEXT NOT NULL,
  source_id VARCHAR(120) NULL DEFAULT NULL,
  cover_file VARCHAR(64) NULL DEFAULT NULL,
  position INT NOT NULL DEFAULT 0,
  created_at BIGINT UNSIGNED NOT NULL DEFAULT 0,
  updated_at BIGINT UNSIGNED NOT NULL DEFAULT 0,
  deleted TINYINT(1) NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, pid),
  KEY idx_upl_user (user_id, deleted, position),
  CONSTRAINT fk_upl_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE user_favorites (
  user_id INT UNSIGNED NOT NULL,
  key_hash CHAR(40) NOT NULL,
  item_key TEXT NOT NULL,
  meta TEXT NULL,
  liked TINYINT(1) NOT NULL DEFAULT 1,
  updated_at BIGINT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, key_hash),
  KEY idx_ufav_user (user_id, liked, updated_at),
  CONSTRAINT fk_ufav_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE push_log (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  admin_id INT UNSIGNED NULL DEFAULT NULL,
  target VARCHAR(40) NOT NULL,
  title VARCHAR(120) NOT NULL,
  body VARCHAR(400) NOT NULL,
  sent INT UNSIGNED NOT NULL DEFAULT 0,
  failed INT UNSIGNED NOT NULL DEFAULT 0,
  error VARCHAR(120) NULL DEFAULT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE search_terms (
  day DATE NOT NULL,
  term VARCHAR(120) NOT NULL,
  n INT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (day, term),
  KEY idx_search_terms_term (term)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE search_log (
  day DATE NOT NULL,
  user_id INT UNSIGNED NOT NULL,
  n INT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (day, user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE premium_log (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id INT UNSIGNED NOT NULL,
  admin_id INT UNSIGNED NULL DEFAULT NULL,
  action VARCHAR(20) NOT NULL,
  days INT UNSIGNED NOT NULL DEFAULT 0,
  until_at DATETIME NULL DEFAULT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_premium_log_user (user_id, id),
  KEY idx_premium_log_time (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE admins (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT,
  username VARCHAR(60) NOT NULL,
  email VARCHAR(190) NULL DEFAULT NULL,
  password VARCHAR(255) NOT NULL,
  role VARCHAR(20) NOT NULL DEFAULT 'admin',
  status VARCHAR(20) NOT NULL DEFAULT 'active',
  totp_secret VARCHAR(255) NULL DEFAULT NULL,
  totp_last_step BIGINT NOT NULL DEFAULT 0,
  totp_recovery TEXT NULL,
  totp_enabled_at DATETIME NULL DEFAULT NULL,
  avatar_url VARCHAR(255) NULL DEFAULT NULL,
  last_login_at DATETIME NULL DEFAULT NULL,
  last_login_ip VARCHAR(45) NULL DEFAULT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_admins_username (username)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE app_config (
  config_key VARCHAR(80) NOT NULL,
  config_value TEXT NOT NULL,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (config_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE site_settings (
  setting_key VARCHAR(80) NOT NULL,
  setting_value TEXT NOT NULL,
  PRIMARY KEY (setting_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE admin_audit_log (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  admin_id INT UNSIGNED NULL DEFAULT NULL,
  action VARCHAR(80) NOT NULL,
  details TEXT NULL,
  ip VARCHAR(45) NULL DEFAULT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  prev_hash CHAR(64) NULL DEFAULT NULL,
  row_hash CHAR(64) NULL DEFAULT NULL,
  PRIMARY KEY (id),
  KEY idx_audit_admin (admin_id, id),
  KEY idx_audit_time (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE admin_logins (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id INT UNSIGNED NULL DEFAULT NULL,
  login VARCHAR(120) NOT NULL DEFAULT '',
  ip VARCHAR(45) NOT NULL,
  user_agent VARCHAR(255) NOT NULL DEFAULT '',
  success TINYINT(1) NOT NULL DEFAULT 0,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_admin_logins_ip (ip, created_at),
  KEY idx_admin_logins_user (user_id, created_at),
  KEY idx_admin_logins_login (login, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE admin_sessions (
  id CHAR(64) NOT NULL,
  data MEDIUMBLOB NOT NULL,
  user_id INT UNSIGNED NULL DEFAULT NULL,
  ip VARCHAR(45) NULL DEFAULT NULL,
  user_agent VARCHAR(255) NULL DEFAULT NULL,
  remember TINYINT(1) NOT NULL DEFAULT 0,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_admin_sessions_user (user_id, last_seen),
  KEY idx_admin_sessions_seen (last_seen)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE admin_devices (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id INT UNSIGNED NOT NULL,
  token_hash CHAR(64) NOT NULL,
  label VARCHAR(120) NOT NULL DEFAULT '',
  last_ip VARCHAR(45) NULL DEFAULT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen_at DATETIME NULL DEFAULT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_devices_token (token_hash),
  KEY idx_devices_user (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE admin_login_approvals (
  token_hash CHAR(64) NOT NULL,
  user_id INT UNSIGNED NOT NULL,
  ip VARCHAR(45) NULL DEFAULT NULL,
  label VARCHAR(120) NOT NULL DEFAULT '',
  remember TINYINT(1) NOT NULL DEFAULT 0,
  status VARCHAR(10) NOT NULL DEFAULT 'pending',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  decided_at DATETIME NULL DEFAULT NULL,
  PRIMARY KEY (token_hash)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE rate_limits (
  bucket CHAR(64) NOT NULL,
  window_start INT UNSIGNED NOT NULL,
  hits INT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (bucket),
  KEY idx_rate_window (window_start)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE security_events (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  severity ENUM('info','warn','critical') NOT NULL DEFAULT 'info',
  kind VARCHAR(40) NOT NULL,
  message VARCHAR(500) NOT NULL,
  user_id INT UNSIGNED NULL DEFAULT NULL,
  fingerprint CHAR(40) NULL DEFAULT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  acknowledged_at DATETIME NULL DEFAULT NULL,
  PRIMARY KEY (id),
  KEY idx_secev_created (created_at),
  KEY idx_secev_fp (fingerprint, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE api_metrics (
  bucket DATETIME NOT NULL,
  requests INT UNSIGNED NOT NULL DEFAULT 0,
  client_errors INT UNSIGNED NOT NULL DEFAULT 0,
  server_errors INT UNSIGNED NOT NULL DEFAULT 0,
  total_ms BIGINT UNSIGNED NOT NULL DEFAULT 0,
  max_ms INT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (bucket)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE error_groups (
  sig CHAR(40) NOT NULL,
  level VARCHAR(16) NOT NULL,
  message VARCHAR(500) NOT NULL,
  file VARCHAR(255) NOT NULL DEFAULT '',
  line INT UNSIGNED NOT NULL DEFAULT 0,
  occurrences INT UNSIGNED NOT NULL DEFAULT 1,
  first_seen DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_url VARCHAR(255) NOT NULL DEFAULT '',
  last_trace TEXT NULL,
  status VARCHAR(10) NOT NULL DEFAULT 'open',
  resolved_at DATETIME NULL DEFAULT NULL,
  notified_at DATETIME NULL DEFAULT NULL,
  PRIMARY KEY (sig),
  KEY idx_err_status (status, last_seen)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE error_daily (
  day DATE NOT NULL,
  sig CHAR(40) NOT NULL,
  n INT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (day, sig)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
SQL;
