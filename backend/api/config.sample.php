<?php
/*
 * Box backend ayarları.
 * Bu dosyayı aynı klasöre "config.php" adıyla kopyala ve değerleri doldur.
 * Dosya mutlaka ilk satırda <?php ile başlamalı, öncesinde boşluk olmamalı.
 */

declare(strict_types=1);

// MySQL
const DB_HOST = 'localhost';
const DB_NAME = 'box';
const DB_USER = 'VERITABANI_KULLANICISI';
const DB_PASS = 'VERITABANI_SIFRESI';

// Google YouTube Data API v3 anahtarı (arama için)
const YT_DATA_API_KEY = 'GOOGLE_API_ANAHTARI';

// VDS (yt-dlp) servisi: imzalı link burada üretilip uygulama doğrudan VDS'den indirir
const VDS_BASE_URL = 'https://yt2.aydworks.com.tr';
const VDS_SIGNING_KEY = 'VDS_DEKI_YT_API_KEY_ILE_AYNI';
const DOWNLOAD_LINK_TTL = 300; // saniye

// Oturum anahtarı geçerlilik süresi
const TOKEN_TTL_DAYS = 180;

// Arama önbelleği
const CACHE_DIR = __DIR__ . '/cache';
const CACHE_TIME = 3600;

// Admin paneli girişi (şifre en az 10 karakter)
const ADMIN_USERNAME = 'admin';
const ADMIN_PASSWORD = 'GUCLU_BIR_ADMIN_SIFRESI';
