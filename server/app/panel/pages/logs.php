<?php
if (!defined('ROOT')) { http_response_code(404); exit; }
$files = glob(nbPrivateDir('logs') . '/php-*.log') ?: []; rsort($files);
$pick = basename((string)($_GET['f'] ?? ($files ? basename($files[0]) : '')));
$path = nbPrivateDir('logs') . '/' . $pick;
$lines = [];
if ($pick !== '' && preg_match('/^php-\d{4}-\d{2}\.log$/', $pick) && is_file($path)) {
    
    $size = filesize($path); $fh = fopen($path, 'rb'); fseek($fh, max(0, $size - 262144)); $tail = (string)stream_get_contents($fh); fclose($fh);
    $entries = preg_split('/\n(?=\[\d{2}-\w{3}-\d{4} )/', trim($tail));
    $lines = array_slice(array_reverse($entries), 0, 150);
}
?>
<div class="toolbar">
  <div class="seg"><?php foreach (array_slice($files, 0, 6) as $f): $b = basename($f); ?><a class="<?=$b === $pick ? 'on' : ''?>" href="/admin?p=logs&amp;f=<?=h($b)?>"><?=h(substr($b, 4, 7))?><em><?=nbNum(filesize($f) / 1024)?> KB</em></a><?php endforeach ?></div>
</div>
<?php card('Son hatalar', 'En yeni üstte. Kullanıcılara hiçbir zaman ayrıntı gösterilmez; burada görünür.');
if (!$lines) echo emptyState('Kayıtlı hata yok', 'Sunucu sorunsuz çalışıyor ya da günlük henüz oluşmadı.');
else { echo '<ol class="log">'; foreach ($lines as $ln) { $first = strtok($ln, "\n"); $rest = trim(substr($ln, strlen((string)$first))); echo '<li><details><summary>' . h(mb_strimwidth((string)$first, 0, 260, '…')) . '</summary>' . ($rest !== '' ? '<pre>' . h(mb_substr($rest, 0, 4000)) . '</pre>' : '') . '</details></li>'; } echo '</ol>'; }
cardEnd();
