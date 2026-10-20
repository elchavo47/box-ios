<?php

if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
require dirname(__DIR__) . '/app/bootstrap.php';
$result = runCron(600);
echo date('Y-m-d H:i:s') . ' ' . json_encode($result, JSON_UNESCAPED_UNICODE) . PHP_EOL;
