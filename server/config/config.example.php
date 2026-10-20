<?php
return [
    'app' => [
        'name' => 'NEON BREAK',
        'url' => 'https://neonbreak.aydworks.com.tr',
        'version' => '1.0.0',
        'debug' => false,
    ],
    'db' => [
        'host' => 'localhost',
        'port' => 3306,
        'name' => 'neonbreak',
        'user' => 'neonbreak',
        'pass' => 'CHANGE_ME',
        'charset' => 'utf8mb4',
    ],
    'security' => [
        'jwt_secret' => 'CHANGE_ME_TO_64_RANDOM_CHARS',
        'token_ttl' => 2592000,
        'cors_origins' => [],
    ],
];
