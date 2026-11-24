<?php

$nodes=[];
foreach (explode(',', (string) env('POT_GAME_NODES', '')) as $entry) {
    [$name, $secret] = array_pad(explode(':', trim($entry), 2), 2, '');
    if (preg_match('/\A[a-z][a-z0-9-]{0,38}\z/', $name) && preg_match('/\A[0-9a-f]{64}\z/', $secret)) {
        $nodes[$name]=$secret;
    }
}
return [
    'nodes' => $nodes,
    'room_size' => max(1, min(24, (int) env('POT_ROOM_SIZE', 24))),
    'content_url' => env('POT_CONTENT_URL', 'http://127.0.0.1:4812'),
    'content_token' => env('POT_CONTENT_TOKEN'),
    'ledger_token' => env('POT_LEDGER_TOKEN'),
    'max_project' => 1536 * 1024,
    'project_path' => env('POT_PROJECT_PATH', storage_path('app/private/pot')),
];
