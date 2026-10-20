<?php
if (!defined('ROOT')) { http_response_code(404); exit; }

/*
 * Herkese açık sayfalar: tanıtım (landing) ve özel hata sayfaları.
 * API isteklerinde hata sayfası yerine JSON döner.
 */

function webH($v): string { return htmlspecialchars((string)$v, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }

function webMark(string $class = 'mark'): string {
    return '<svg class="' . webH($class) . '" viewBox="8 8 32 32" aria-hidden="true"><path fill="#3EE39A" d="M24 9 38 16.5 24 24 10 16.5Z"/><path fill="#21A86C" d="M9 20 22 27.2v12.3L9 32.3Z"/><path fill="#147A4D" d="M39 20 26 27.2v12.3l13-7.2Z"/></svg>';
}

function webHeaders(int $status): void {
    if (headers_sent()) return;
    http_response_code($status);
    header('Content-Type: text/html; charset=utf-8');
    header('X-Frame-Options: DENY');
    header('X-Content-Type-Options: nosniff');
    header('Referrer-Policy: same-origin');
    header("Content-Security-Policy: default-src 'none'; style-src 'self'; font-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'");
}

function webLayout(string $title, string $body, string $bodyClass = '', string $description = ''): string {
    $v = function_exists('boxVersion') ? boxVersion() : '2';
    return '<!doctype html><html lang="tr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">'
        . '<title>' . webH($title) . '</title>'
        . ($description !== '' ? '<meta name="description" content="' . webH($description) . '">' : '')
        . '<meta name="theme-color" content="#030304"><meta name="color-scheme" content="dark">'
        . '<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml"><link rel="apple-touch-icon" href="/assets/panel-touch.png">'
        . '<link rel="stylesheet" href="/assets/web.css?v=' . webH($v) . '"></head><body class="' . webH($bodyClass) . '">' . $body . '</body></html>';
}

/** Tanıtım sayfası (kök adres). */
function webLanding(): never {
    webHeaders(200);
    header('Cache-Control: public, max-age=300');
    $features = [
        ['M4 6h16M4 12h16M4 18h10', 'Dosya yöneticisi', 'Klasörler, taşıma, yeniden adlandırma. Finder\'dan sürükle, Dosyalar uygulamasından aç, her şey Box\'ta.'],
        ['M9 18V6l11-2v12M9 18a3 3 0 1 1-6 0 3 3 0 0 1 6 0M20 16a3 3 0 1 1-6 0 3 3 0 0 1 6 0', 'Gerçek bir oynatıcı', 'Sıra, karıştırma, tekrar, çalma hızı, AirPlay, kilit ekranı kontrolleri ve kaldığın yerden devam.'],
        ['M20 14.5A8 8 0 0 1 9.5 4 8 8 0 1 0 20 14.5Z', 'Uyku zamanlayıcısı', 'Süreyi seç ya da "şarkı bitince" de. Son saniyelerde ses yavaşça kısılır, uyandırmaz.'],
        ['M13 2 4 14h7l-1 8 9-12h-7z', 'Premium ile ara ve indir', 'Şarkıyı bul, tek dokunuşla indir. Kapak ve bilgileriyle kitaplığa girer, internetsiz çalar.'],
        ['M12 3 4 6v6c0 5 3.4 8.3 8 9 4.6-.7 8-4 8-9V6z', 'Önce gizlilik', 'Müziğin telefonunda kalır. Hesap yalnızca premium ayrıcalıkları için; reklam ve takip yok.'],
        ['M3 12h4l3-8 4 16 3-8h4', 'Hafif ve hızlı', 'Yerel, akıcı arayüz. Binlerce şarkıda bile anında açılan kitaplık.'],
    ];
    ob_start(); ?>
<header class="nav">
  <a class="brand" href="/"><?=webMark()?><span>Box</span></a>
  <nav><a href="#ozellikler">Özellikler</a><a href="#nasil">Nasıl başlarım</a><a class="pill" href="/admin">Yönetim</a></nav>
</header>
<main>
  <section class="hero">
    <div class="hero-copy">
      <p class="eyebrow">iPhone için müzik oynatıcı ve dosya yöneticisi</p>
      <h1>Müziğin,<br>tek bir <em>kutuda</em>.</h1>
      <p class="lead">Box; telefonundaki şarkıları düzenler, güzelce çalar ve premium ile yenilerini bulup indirmeni sağlar. Sade, hızlı, reklamsız.</p>
      <div class="cta">
        <a class="btn primary" href="#nasil">Davet iste</a>
        <a class="btn ghost" href="#ozellikler">Neler yapıyor?</a>
      </div>
      <p class="fine">Şu an kapalı beta: TestFlight daveti ile.</p>
    </div>
    <div class="phone" aria-hidden="true">
      <div class="screen">
        <div class="ph-top"><span>Şimdi çalıyor</span></div>
        <div class="ph-art"><?=webMark('ph-mark')?></div>
        <div class="ph-title"><b>Gece Yolu</b><span>Box Sessions</span></div>
        <div class="ph-bar"><i></i></div>
        <div class="ph-time"><span>1:24</span><span>-2:11</span></div>
        <div class="ph-ctrl"><span class="s"></span><span class="p"></span><span class="play"></span><span class="n"></span><span class="s"></span></div>
        <div class="ph-sleep"><span>☾</span> 28:14</div>
      </div>
    </div>
  </section>

  <section class="features" id="ozellikler">
    <h2>Bir müzik uygulamasında olması gereken her şey</h2>
    <div class="grid">
      <?php foreach ($features as [$path, $title, $text]): ?>
      <article><svg viewBox="0 0 24 24" aria-hidden="true"><path d="<?=webH($path)?>"/></svg><h3><?=webH($title)?></h3><p><?=webH($text)?></p></article>
      <?php endforeach ?>
    </div>
  </section>

  <section class="steps" id="nasil">
    <h2>Nasıl başlarım?</h2>
    <ol>
      <li><b>Davet al.</b><span>Box şu an kapalı beta. Davet için AYD Works ile iletişime geç.</span></li>
      <li><b>TestFlight'tan kur.</b><span>Gelen bağlantıyla Box'u iPhone'una yükle.</span></li>
      <li><b>Müziğini ekle.</b><span>Dosyalar uygulamasından, bilgisayardan ya da premium ile doğrudan arayarak.</span></li>
    </ol>
  </section>
</main>
<footer class="foot">
  <span class="brand small"><?=webMark()?><span>Box</span></span>
  <span>© <?=date('Y')?> AYD Works · <a href="https://aydworks.com.tr">aydworks.com.tr</a></span>
</footer>
<?php
    echo webLayout('Box · Müziğin, tek bir kutuda', (string)ob_get_clean(), 'landing', 'Box: iPhone için reklamsız müzik oynatıcı ve dosya yöneticisi. Uyku zamanlayıcısı, sıra, AirPlay ve premium ile arama.');
    exit;
}

/** Özel hata sayfası; API yollarında JSON döner. */
function webError(int $code, string $message = ''): never {
    $map = [
        400 => ['Geçersiz istek', 'Bu isteği anlayamadık. Bağlantı eksik ya da bozuk olabilir.'],
        401 => ['Giriş gerekli', 'Bu sayfayı görmek için önce giriş yapman gerekiyor.'],
        403 => ['Erişim yok', 'Bu sayfaya erişim izni yok. Dosyalar ve iç klasörler dışarıya kapalıdır.'],
        404 => ['Sayfa bulunamadı', 'Aradığın sayfa taşınmış ya da hiç var olmamış olabilir.'],
        405 => ['Bu yöntem desteklenmiyor', 'Bu adres bu tür isteği kabul etmiyor.'],
        419 => ['Oturum süresi doldu', 'Güvenlik doğrulaması başarısız oldu. Sayfayı yenileyip tekrar dene.'],
        429 => ['Biraz yavaş', 'Kısa sürede çok fazla istek geldi. Birkaç dakika sonra tekrar dene.'],
        500 => ['Bir şeyler ters gitti', 'Sunucuda beklenmeyen bir hata oluştu. Ekip bilgilendirildi.'],
        502 => ['Servise ulaşılamadı', 'Arka plandaki bir servis yanıt vermedi. Biraz sonra tekrar dene.'],
        503 => ['Kısa bir bakımdayız', 'Box şu an bakımda. Birazdan geri döneceğiz.'],
    ];
    $status = $code === 419 ? 403 : $code;
    [$title, $text] = $map[$code] ?? ['Hata', 'İstek tamamlanamadı.'];
    if ($message !== '') $text = $message;

    $path = function_exists('routePath') ? routePath() : (string)parse_url((string)($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_PATH);
    $wantsJson = str_starts_with($path, '/api/') || str_starts_with($path, '/box-api') || str_contains((string)($_SERVER['HTTP_ACCEPT'] ?? ''), 'application/json') || ($_SERVER['HTTP_X_REQUESTED_WITH'] ?? '') === 'nb-ajax';
    if ($wantsJson) {
        if (!headers_sent()) {
            http_response_code($status);
            header('Content-Type: application/json; charset=utf-8');
            header('Cache-Control: no-store');
        }
        echo json_encode(['ok' => false, 'error' => $text, 'message' => $text, 'status' => $status], JSON_UNESCAPED_UNICODE);
        exit;
    }

    if (headers_sent()) {
        echo '<p style="font:15px system-ui;color:#c33;padding:16px">' . webH($title . ': ' . $text) . '</p>';
        exit;
    }
    webHeaders($status);
    header('Cache-Control: no-store');
    $back = str_starts_with($path, '/admin') ? ['/admin', 'Panele dön'] : ['/', 'Ana sayfaya dön'];
    $body = '<main class="err"><a class="brand" href="/">' . webMark() . '<span>Box</span></a>'
        . '<div class="err-code" aria-hidden="true">' . webH((string)$code) . '</div>'
        . '<h1>' . webH($title) . '</h1><p>' . webH($text) . '</p>'
        . '<div class="cta"><a class="btn primary" href="' . webH($back[0]) . '">' . webH($back[1]) . '</a>'
        . ($code === 401 ? '<a class="btn ghost" href="/admin">Giriş yap</a>' : '')
        . '</div><small>Hata kodu ' . webH((string)$code) . (isset($_SERVER['UNIQUE_ID']) ? ' · ' . webH(substr((string)$_SERVER['UNIQUE_ID'], 0, 12)) : '') . '</small></main>';
    echo webLayout($title . ' · Box', $body, 'error-page');
    exit;
}
