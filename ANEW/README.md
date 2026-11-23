# Pot

Pot is an original desktop sandbox with a player, a world editor, and a thumbnail renderer. Pot Client and Pot Studio use a light theme with the Pot green `#09b734`.

| Component | Source | Purpose |
| --- | --- | --- |
| Pot Client | [renderer/client](renderer/client/) | Browse worlds, play solo, or join a shared session. |
| Pot Studio | [renderer/studio](renderer/studio/) | Edit primitive-based 3D worlds, save projects, open a playtest, and publish to the selected library. |
| World service | [services/worlds](services/worlds/) | Store published worlds and synchronize player presence and movement over WebSocket. |
| PotRenderService (PRS) | [services/render](services/render/) | Generate PNG world previews in a bounded pool of workers. |
| WEBSERVICE | `WEBSERVICE/` | Reserved empty directory for the future website. The install step creates it. |

## Run the desktop apps

Install Node.js 22.12 or later on Windows or macOS. From the repository checkout, open a terminal and run one of the app commands. The same commands work in PowerShell and Terminal.

```sh
cd ANEW
npm ci
npm run start:client
npm run start:studio
```

Use separate terminals to run both apps. The first install downloads Electron. After installation, the local workflows run without internet access or a registered domain. Both apps start private loopback world and render services. The three built-in worlds are available immediately. In the client, use **WASD** or the arrow keys to move, **Space** to jump, and mouse drag to look.

In Studio, create and arrange shapes, edit attributes in the Properties panel, and save as `.pot.json`. **Playtest** opens a Pot Client window with an isolated copy of the current project. **Publish** writes to the local library when the app is using loopback. The two apps share the local library under the operating system’s application data directory in `Pot/worlds`. Use the **Worlds** navigation button in an already open client to refresh the list.

## Test multiplayer without a domain

Start a shared world service to put two desktop instances in the same session. The local standalone service automatically starts a private PRS when no render endpoint is supplied.

```sh
npm run service:worlds
```

On Windows, set the endpoint in each app terminal.

```powershell
$env:POT_API_ENDPOINT = 'http://127.0.0.1:4831'
npm run start:client
```

On macOS, use the same endpoint in the environment.

```sh
POT_API_ENDPOINT=http://127.0.0.1:4831 npm run start:client
```

Start a second client against that address and select **Join online** in the same world. The traffic remains on the machine. Run the Studio command with the same endpoint and a publishing credential to publish into that shared service.

## Connect hosted services

Host the world service and PRS on persistent infrastructure when a website endpoint is available. The desktop backend reads `POT_API_ENDPOINT` at launch and expects the Pot API routes below, including WebSocket upgrades on the same base URL. Set the environment variable in the process launcher or desktop deployment environment. An unusable hosted catalog at startup leaves the desktop app connected to its local service. Endpoint settings and credentials stay in the backend.

| Process | Environment variables |
| --- | --- |
| Desktop | `POT_API_ENDPOINT` sets the world API base URL. `POT_API_READ_TOKEN` enables private worlds. `POT_API_WRITE_TOKEN` enables Studio publishing. |
| World service | `POT_WORLD_HOST` and `POT_WORLD_PORT` set the listener, defaulting to `127.0.0.1:4831`. `POT_WORLD_DATA_DIR` points to a persistent directory. `POT_WORLD_READ_TOKEN` protects browsing and sessions when set. `POT_WORLD_WRITE_TOKEN` enables publishing. |
| World service to PRS | `POT_RENDER_ENDPOINT` sets the optional separate PRS base URL. `POT_RENDER_TOKEN` supplies its bearer credential. |
| PRS | `POT_RENDER_HOST` and `POT_RENDER_PORT` set the private listener, defaulting to `127.0.0.1:4812`. `POT_RENDER_TOKEN` protects rendering and is required on a non-loopback listener. |

Run `npm run service:worlds` for the world service and `npm run service:render` to run PRS separately. Use HTTPS and WSS at the reverse proxy for non-loopback connections. Keep PRS private, configure request and connection limits at the proxy, and back up the world data directory. Hosted publishing requires a managed Studio credential. Grant it to trusted operators only. Each world service process holds its active rooms in memory.

| Protocol | Route | Purpose |
| --- | --- | --- |
| HTTP GET | `/healthz` | Service health. |
| HTTP GET | `/v1/worlds` | List published worlds. |
| HTTP GET | `/v1/worlds/{id}` | Read a world document. |
| HTTP PUT | `/v1/worlds/{id}` | Validate and persist a world document. |
| HTTP GET | `/v1/worlds/{id}/thumbnail` | Get a rendered PNG. |
| WebSocket | `/v1/session?world={id}` | Match peers in a world and exchange bounded position updates. |
| HTTP POST to PRS | `/v1/render` | Render a world document to PNG. |

The version 1 scene format supports three primitive geometries and a spawn position. Legacy project files, scripts, and network protocols require a separate migration.

## Test and package

```sh
npm test
npm run package:desktop
```

Run the packaging command on the target OS. Windows builds an installer for x64 and ARM64. macOS builds DMG and ZIP packages for Apple Silicon and Intel. Output is under `artifacts/client/` and `artifacts/studio/`. Use `npm run package:client` or `npm run package:studio` for one product. Use platform signing credentials and macOS notarization before distributing public releases.
