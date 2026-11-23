# Pot 0.4

Pot Client and Pot Studio are native desktop apps. Lua runs the LÖVE windows, tools, and 3D viewport. Luau runs the world model, movement, scripts, publishing, and PotRenderService in a separate Lune runtime. Projects use binary `.pot` files. The desktop apps communicate with the runtime using length-prefixed MessagePack over authenticated loopback.

| Directory | Contents |
| --- | --- |
| `game/` | Lua source for the apps, viewport, and original six-part block avatars. |
| `luau/` | Project codec, scripting, multiplayer, publishing, and thumbnail rendering. |
| `tools/` | Developer build and installer source. |
| `Installers/` | Windows x64 Setup executables and macOS Universal app archives for this edition. |
| `WEBSERVICE/` | Empty directory reserved for the future website. |

## Try the scripted world

Run the Windows Setup executable or extract the macOS Universal archive and move the app to Applications. Both include the runtime. If macOS asks you to approve an ad hoc signed developer build, use **Open Anyway** in **System Settings → Privacy & Security**. Start **Terrace Park** in Client or **Terrace Workshop** in Studio. Press **E** near the gold switch to open the green gate. Step on the blue plate to light it up. Local testing needs no domain.

In Studio, use **Q** Select, **W** Move, **E** Rotate, **R** Scale, **F** Frame, and **F5** Playtest. Use the axis and snap controls or enter transforms in Properties. Press **Esc** to cancel a drag or return from playtest. Use **WASD**, mouse drag, **Space**, and **E** to move, look, jump, and interact in play.

## Play together

Use **Join local** in two copies of Pot Client on the same computer and select the same world. The first Client hosts a loopback session for the others while its runtime is open. Use **Join online** when your administrator has configured a hosted endpoint.

Press **Esc** in play to open the world menu. **Players** shows the live roster and the viewport shows other avatars with name tags. **Settings** saves your volume and render resolution on this device. Use **Reset character** to return to a spawn point or **Leave world** to return to the library. Both actions ask for confirmation. Worlds allow reset by default.

## Explorer and spawn points

Select **Workspace**, a part, or a script in Explorer and use **+ Add**. Parts and Spawn Points can be nested under parts. A **Script** or **Local Script** can be nested under either script type, under a part, or directly in Workspace. Drag Explorer rows onto a new parent or choose **Move to…** in Properties. Nesting groups objects in Explorer. Part transforms use world coordinates.

Add a **Spawn Point**, move or rotate it, and optionally choose **Make default** in its properties. Without a preferred point, enabled spawn points are used in order. The Workspace fallback position is used in worlds without an enabled point. Choose **Workspace** and set **Character reset** to **Disabled** to block manual resets for everyone in that world. **F6** tests reset in Studio when the world allows it.

## Pot scripting

Add a script in Explorer or choose **Add Script** in a part's properties. Start with the Press, Touch, or Spawn example. **Check script** validates the source and **Apply** saves it in the working project. **Playtest** runs the working copy in the viewport. Binary `.pot` files retain the hierarchy, spawn configuration, and scripts. Studio opens earlier `.pot` and first-release `.pot.json` projects.

```lua
Pot.onPress(function(player)
    Pot.pulse("self", 1, "#ffda6a")
    Pot.setColor("self", "#09b734")
end)

Pot.onTouch(function(player: string)
    Pot.pulse("self", 2, "#91e4ff")
end)
```

Pot accepts a bounded Lua/Luau subset with event callbacks, typed locals, literals, arithmetic, and `if` blocks. Callbacks receive a player's session ID. Use `"self"` for the nearest part ancestor or copy a target part's ID in Properties. Press requires a nearby player. Touch fires when contact begins. **Scripts** run in the authoritative simulation and replicate their effects. **Local Scripts** run for the local player and can change local visuals, flags, and timers. Collision and player placement are server actions.

| API | Purpose |
| --- | --- |
| `Pot.setColor(part, "#rrggbb")` | Change a part's color during play. |
| `Pot.setVisible(part, bool)`, `Pot.setSolid(part, bool)` | Control drawing and collision. Turn both off to open a door. |
| `Pot.pulse(part, seconds, "#rrggbb")` | Animate a temporary glow. |
| `Pot.flag(name)`, `Pot.setFlag(name, bool)` | Read or write a room-scoped flag. |
| `Pot.isSolid(part)` | Read collision state. |
| `Pot.after(seconds, function() … end)` | Run a delayed action. |
| `Pot.onSpawn(function(player) … end)` | Run a callback when a player joins, resets, or returns after falling out of the world. |
| `Pot.spawn(player, spawnPointId)` | Move a player to an enabled Spawn Point from a Script. The move preserves the session and does not fire `onSpawn` again. |

For a teleporter, place a Script under a part and paste an enabled Spawn Point's ID into the call.

```lua
Pot.onPress(function(player)
    Pot.spawn(player, "terrace-entry")
end)
```

## Publish and manage worlds

**Publish** writes the current place to the local library by default. **Published** lets you open a published copy, republish changes, or unpublish. Select **Worlds** in Client to refresh the catalog. The OS application data directory holds local places in `Pot/worlds`.

Set `POT_API_ENDPOINT` in the desktop launch environment when hosting is ready. If the v3 catalog is unavailable at startup, the app uses the local library.

| Process | Settings |
| --- | --- |
| Desktop | `POT_API_ENDPOINT` sets the base URL and requires HTTPS outside loopback. `POT_API_READ_TOKEN` and `POT_API_WRITE_TOKEN` supply credentials. `POT_LOCAL_SESSION_PORT` overrides the loopback port `4832`. |
| World service | `POT_WORLD_HOST`, `POT_WORLD_PORT`, and `POT_WORLD_DATA_DIR` set binding and persistence. Binding defaults to `127.0.0.1:4831`. `POT_WORLD_READ_TOKEN` and `POT_WORLD_WRITE_TOKEN` control access. |
| PotRenderService | `POT_RENDER_ENDPOINT` optionally connects the world service to a separate renderer. `POT_RENDER_HOST` and `POT_RENDER_PORT` default to `127.0.0.1:4812`. `POT_RENDER_TOKEN` is required for a non-loopback binding. |

Run `lune run luau/main.luau worlds /absolute/path/to/ANEW/luau` to start a world service. Run with `render` in place of `worlds` for separate PRS. To test multiplayer on one machine, point both clients at `http://127.0.0.1:4831`. Use a TLS reverse proxy for hosting, forward the session WebSocket upgrade, cap uploads there, and keep PRS privately reachable.

| Binary v3 route | Operation |
| --- | --- |
| `GET /v3/worlds`, `GET /v3/worlds/{id}` | Catalog and place snapshot. |
| `GET /v3/published`, `GET /v3/published/{id}` | Studio management with publishing credentials. |
| `PUT /v3/worlds/{id}`, `DELETE /v3/worlds/{id}` | Publish and unpublish. |
| `GET /v3/worlds/{id}/thumbnail` | Perspective map PNG. |
| `GET /v3/worlds/{id}/spawns` | Read-authorized MessagePack spawn metadata and world reset policy. |
| `GET /v3/session` via WebSocket | Binary join, input, press, reset, and authoritative snapshots. The first frame supplies the world ID and access credential. `welcome.allowReset` advertises the policy. A `reset` packet can reset the authenticated player's avatar and returns `resetResult`. |
| `POST /v3/render` | Generate a map PNG from a binary place. |

## Build and test

Use Python 3.10 or later. The packager verifies the checksums of pinned LÖVE 11.5 and Lune 0.11.1 releases. Install NSIS 3 for Windows Setup executables. The macOS build emits an ad hoc signed Universal app archive and creates a `.pkg` when run with native macOS tools. Install `rcodesign` to build the macOS archive on another OS. Set `POT_MAC_APP_IDENTITY` and `POT_MAC_INSTALLER_IDENTITY` on Mac for release signing. [rcodesign releases](https://github.com/indygreg/apple-platform-rs/releases)

```sh
python tools/build.py windows
python tools/build.py macos
python tools/build.py dev --product studio --love /path/to/love
lune run luau/tests.luau /absolute/path/to/ANEW/luau /path/to/empty/scratch 4851
```

The third-party runtimes are included in developer packages. [LÖVE source](https://github.com/love2d/love/tree/11.5) · [Lune source and license](https://github.com/lune-org/lune/tree/v0.11.1)
