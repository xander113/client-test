# Pot Webservice

Laravel owns accounts, discovery, publishing, versions, and game admission. A Luau game worker runs the authoritative simulation. PotRenderService validates binary projects and renders previews. PostgreSQL stores accounts, currency entries, releases, server leases, and credentials. The browser pages use Blade forms and plain CSS.

## Run the stack

Copy .env.example to .env. Set APP_KEY to base64: followed by the result of openssl rand -base64 32. Generate separate values for DB_PASSWORD, POT_CONTENT_TOKEN, and POT_WORKER_TOKEN with openssl rand -hex 32. Set POT_LEDGER_TOKEN only when an internal currency operator needs access.

~~~sh
docker compose up -d --build
docker compose ps
curl --fail http://127.0.0.1:8088/up
~~~

Compose runs migrations before PHP starts. It listens at http://127.0.0.1:8088 by default. Set APP_URL and POT_HTTP_PORT together to use a different port. The health URL checks Laravel startup. Matchmaking returns a temporary 503 while workers register.

1. Create an account on the website and open **Account**. Create a desktop key and copy it from the one-time display.
2. Launch Pot Studio 0.6 with the website URL as POT_API_ENDPOINT and the key as POT_ACCOUNT_TOKEN. Publish the open project. Its first published place becomes the game's start place.
3. Open **Creator**, select the game, and set it to **Public** when it is ready. A private game is playable by its owner through an authenticated Client. Add places to a game by uploading their .pot projects in Creator.
4. Open Pot Client 0.6 with the same endpoint. Use **Join online**. Launch a second Client with another account key, or with no key to join a public game as a guest.

On Windows, set the backend variables in PowerShell before launching the installed app.

~~~powershell
$env:POT_API_ENDPOINT = "http://127.0.0.1:8088"
$env:POT_ACCOUNT_TOKEN = "<desktop key>"
& "$env:LOCALAPPDATA\Pot\Pot Studio\Pot Studio.exe"
~~~

On a Mac with the app in Applications, launch its bundled executable from Terminal with the same environment variables.

~~~sh
POT_API_ENDPOINT=http://127.0.0.1:8088 \
POT_ACCOUNT_TOKEN='<desktop key>' \
'/Applications/Pot Studio.app/Contents/MacOS/love'
~~~

## Publishing and hosting

A game has an owner, a visibility policy, a start place, and any additional places. Each place has an immutable version history. Studio publishes using the account credential. The service calls the same Luau validator used by Pot, stores the canonical binary content by its SHA-256 digest, and updates the active version in a database transaction. Publishing an identical project reuses its version. Creators can restore an earlier version from Creator.

Client first requests a seat. The matchmaker reserves capacity in a healthy worker's server for the active release. If available instances are full, it assigns a new one. The same release is pinned for the life of each instance, so publishing a new version does not restart existing games or cause clients to render a different map from the server. The Client opens the returned same-origin WebSocket route and exchanges a 30-second, one-use ticket for an active connection. The worker maintains a lease through a private control endpoint. Dropped or revoked connections release their seats. Workers stop accepting new sessions when their heartbeat expires.

Account tokens are scoped to their owner and expire after 90 days. Browser passwords use Laravel's password hasher. Access keys and join tickets are stored as digests. Each player joins with the display name and avatar palette on their account. Currency is private and updated through a transactional ledger with idempotent operation IDs.

This arrangement follows Roblox's published concepts of games with start places, separate saved place versions, and matchmaking into live server instances. [Games and places](https://create.roblox.com/docs/production/publishing/publish-games-and-places) · [Server selection](https://create.roblox.com/docs/projects/teleport#teleport-to-specific-servers)

## Deployment

Point an HTTPS reverse proxy at the loopback gateway. Preserve the host and forward HTTPS and WebSocket upgrades for /v3/instances/*/socket. Set APP_URL to the public HTTPS origin, SESSION_SECURE_COOKIE=true, and POT_TRUSTED_PROXIES to the proxy address or CIDR. Keep the PHP, PostgreSQL, worker, renderer, and gateway's internal port 8081 on a private network. The public gateway rejects /v3/internal/*.

Back up both the PostgreSQL and content volumes. Restoring one without the other can leave published releases without their project files. Keep the application key in the deployment secret store. The production image uses the committed Composer lockfile and enables PHP OPcache.

Each worker can host multiple independent instances. POT_ROOM_SIZE defaults to 24 players per instance. POT_WORKER_LIMIT caps connections per worker. Add workers by giving each a unique name and credential in POT_GAME_NODES, starting a corresponding Luau worker with that identity, and mapping its exact WebSocket path at the gateway. Keep a worker name assigned to one running process at a time. Web replicas share PostgreSQL, the content directory, and the application key. The bundled maintenance service expires old admissions and removes idle server records.

~~~sh
lune run /srv/pot/main.luau hosted /srv/pot
~~~

The worker reads POT_WORKER_ID, POT_WORKER_TOKEN, POT_CONTROL_URL, POT_WORKER_HOST, POT_WORKER_PORT, and POT_WORKER_LIMIT. POT_CONTROL_URL is the private Laravel origin, including the gateway's internal port if using Compose. Configure a TLS edge, WebSocket connection limits, and a backup schedule before allowing public traffic. [Laravel deployment](https://laravel.com/docs/13.x/deployment)

## Binary API

All desktop and control messages use application/msgpack. JSON is unnecessary for the application protocol. The Composer manifest is PHP build metadata.

| Public route | Behavior |
| --- | --- |
| GET /v3/worlds | Browse public start places or the current account's private games. |
| GET /v3/worlds/{id} and /thumbnail and /spawns | Read current binary release, PNG preview, and spawn metadata. |
| PUT /v3/worlds/{id} | Publish an immutable version with an account bearer key. |
| DELETE /v3/worlds/{id} | Withdraw the active release. |
| GET /v3/published and /v3/published/{id} | Read places managed by the current account in Studio. |
| POST /v3/join | Reserve a seat. Send world and optional account bearer key. Returns the ticket, socket path, version digest, and pinned binary project. |
| GET /v3/instances/{worker}/socket | WebSocket. Send type=join, world, and ticket as the first binary frame. |
| GET /v3/account/me and PUT /v3/account/me/look | Read the current account and edit the four-color avatar palette. |

The protected worker routes accept heartbeat, redeem, and release operations at /v3/internal/workers/{worker}/{action}. The currency operator can submit a signed integer delta and unique operation ID at POST /v3/internal/accounts/{id}/currency using the ledger bearer key. A repeated operation returns the originally recorded result. Reusing an operation ID with a different delta or attempting an overdraw returns HTTP 409. Only the current account and trusted currency operator can read its balance.

## Test hosting

Run the integration suite against an isolated Compose stack with POT_ROOM_SIZE=2.

~~~sh
python -m pip install 'msgpack==1.2.1' 'websocket-client==1.9.0'
python tests/hosting.py http://127.0.0.1:8088
~~~

The suite creates test accounts and games. It checks the browser flows, ownership, publishing, multiple places, thumbnails, one-use tickets, multiplayer effects, reset, and release pinning while a game is live. Its concurrent join test admits 32 players across 16 two-seat instances. Set POT_WORKER_LIMIT to at least 32 for that test.
