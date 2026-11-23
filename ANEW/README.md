# Pot

Pot is a desktop sandbox with a playable client, a 3D place editor, and a headless thumbnail renderer. Pot Client and Pot Studio share a light desktop interface with Pot green `#09b734`.

| Component | Source | Purpose |
| --- | --- | --- |
| Pot Client | [renderer/client](renderer/client/) | Browse places, play solo, and join live sessions. |
| Pot Studio | [renderer/studio](renderer/studio/) | Build, save, playtest, and publish places. |
| Pot runtime | [native](native/) | Go project codec, desktop service, world storage, session simulation, and network replication. |
| PotRenderService | [native/internal/thumb](native/internal/thumb/) | Render the same place geometry to PNG through local or hosted PRS. |
| WEBSERVICE | `WEBSERVICE/` | Reserved empty directory for the future website. The install step creates it. |

## Run and test on Windows and macOS

Install Node.js 22.12 or later and Go 1.23 or later. Run from the repository checkout.

```sh
cd ANEW
npm ci
npm run start:studio
```

Use `npm run start:client` for Pot Client. The first install and build download dependencies. The applications then start local services on loopback and can operate without internet access or a domain. Both apps see the same library under the operating system’s application data directory in `Pot/worlds`. In an open client, select **Worlds** to refresh the catalog after publishing from Studio.

## Edit and playtest

| Action | Control |
| --- | --- |
| Select a part | Click it in the viewport or Outliner. Use **Find a part** to filter the Outliner. |
| Move, rotate, and scale | Select **Move**, **Rotate**, or **Scale**, then drag a colored axis or ring. Use **W**, **E**, or **R** to switch tools and **Q** to return to Select. |
| Control alignment | Use **World axes** or **Local axes** for Move and Rotate. Scale follows local axes. The **Snap** checkbox and adjacent increment menu control movement, size, and angle steps. |
| Enter an exact transform | Set **Position**, **Rotation**, and **Size** in Properties. Rotation uses degrees. |
| Navigate | Drag to orbit, middle-drag to pan, and scroll to zoom. Hold the right mouse button to look and use **WASD** to fly. Use **Q** and **E** to move down and up while looking. |
| Frame a part or switch views | Press **F** or use the frame button next to **Camera view**. Choose Perspective, Top, Front, or Right. |
| Cancel or undo | Press **Esc** during a drag. Each completed drag is one undo step. |
| Playtest | Press **F5** or click **Playtest**. Press **Esc** or **F5** to return to the same selection and editor view. |

In play, use **WASD** or the arrow keys to move, **Space** to jump, and mouse drag to look. Studio plays the working copy in its own viewport, including edits you have yet to save or publish.

Save projects as binary `.pot` files. Use **Open** to import a first-release `.pot.json` project and **Save** to write it as `.pot`. Existing local library files from the first release are readable and are written in binary when republished.

## Runtime and replication

Studio authors a typed place whose parts have stable IDs, shapes, transforms, and appearance. Publishing creates a validated snapshot for the world service. A session loads that snapshot into a live room, runs avatar motion and collisions at a fixed server tick, and broadcasts position snapshots. Clients send control inputs. The client predicts its own motion and interpolates other players between snapshots. Solo play and Studio playtest use the same movement rules locally. Solid geometry uses axis-aligned bounds calculated from the rotated part.

The Go runtime owns project files, endpoint selection, publishing, the session protocol, and PRS. Electron supplies native windows, file pickers, and a restricted bridge to that runtime. Saved files carry a Pot signature and format version. The bridge, HTTP world data, and session frames use MessagePack. Thumbnails use PNG.

The authoring and runtime split is inspired by Roblox’s public documentation. The formats and protocol are Pot’s own. [Roblox data model](https://create.roblox.com/docs/projects/data-model) · [Roblox client-server runtime](https://create.roblox.com/docs/projects/client-server)

Studio places transform handles and numeric fields near the model they edit. Both apps use the same focused controls, system typography, and reduced-motion settings. [Roblox part tools](https://create.roblox.com/docs/parts) · [NN/g usability heuristics](https://www.nngroup.com/articles/ten-usability-heuristics/) · [Frontend design research notes on common AI patterns](https://github.com/anthropics/skills/blob/main/skills/frontend-design/SKILL.md)

## Test multiplayer without a domain

Start a shared world service.

```sh
npm run service:worlds
```

Run this in each Windows app terminal.

```powershell
$env:POT_API_ENDPOINT = 'http://127.0.0.1:4831'
npm run start:client
```

On macOS, use the same endpoint.

```sh
POT_API_ENDPOINT=http://127.0.0.1:4831 npm run start:client
```

Open the same world in two clients and choose **Join online**. Use the Studio start command with the same endpoint and a publishing credential to publish to the shared service.

## Host the services

Set `POT_API_ENDPOINT` in the desktop process environment to connect the apps to your hosted Pot API. If the hosted catalog is unavailable at launch, Pot starts in local mode. Hosting an external website can use the same API contract. A reverse proxy can serve Pot under a URL prefix by stripping that prefix before forwarding to the service.

| Process | Environment |
| --- | --- |
| Desktop | `POT_API_ENDPOINT` sets the base URL. `POT_API_READ_TOKEN` and `POT_API_WRITE_TOKEN` supply access and publishing credentials. |
| World service | `POT_WORLD_HOST` and `POT_WORLD_PORT` default to `127.0.0.1:4831`. Set `POT_WORLD_DATA_DIR` for persistent worlds. `POT_WORLD_READ_TOKEN` restricts reads and sessions when set. `POT_WORLD_WRITE_TOKEN` enables publishing. `POT_WORLD_BROWSER_ORIGIN` allows a specific browser origin for WebSocket upgrades. |
| World service to PRS | Set `POT_RENDER_ENDPOINT` and `POT_RENDER_TOKEN` to use separate PRS. By default the world service starts its own private renderer. |
| Separate PRS | `POT_RENDER_HOST` and `POT_RENDER_PORT` default to `127.0.0.1:4812`. A non-loopback listener requires `POT_RENDER_TOKEN`. |

For a Go-only deployment, build from `ANEW/native` with `go build -buildvcs=false -o potd ./cmd/potd`, then run `potd worlds` or `potd render`. Serve HTTPS and WSS through your proxy outside loopback. Keep PRS private and back up the world directory. A world service maintains its active rooms in memory.

| Route | Operation |
| --- | --- |
| `GET /healthz` | Service status. |
| `GET /v2/worlds` | World catalog. |
| `GET /v2/worlds/{id}` | Validated place snapshot. |
| `PUT /v2/worlds/{id}` | Authenticated publishing. |
| `GET /v2/worlds/{id}/thumbnail` | PNG preview. |
| `GET /v2/session?world={id}` with WebSocket upgrade | Binary welcome, input, and server state frames. |
| `POST /v2/render` | Generate a PNG from a binary place document. |

Use `application/msgpack` for binary HTTP payloads. Pot 0.2 clients and services use the v2 API and should be deployed together.

## Package

```sh
npm test
npm run package:desktop
```

Run the packager on the target OS. Windows creates a setup program for x64 and ARM64. macOS creates DMG and ZIP packages for Apple Silicon and Intel. The packager compiles and includes the matching Go runtime in each app. Use the platform’s signing and notarization tools for public distribution.
