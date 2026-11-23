# Pot 0.3

Pot Client and Pot Studio are native desktop apps. Lua runs the LÖVE windows, tools, and 3D viewport. Luau runs the world model, movement, scripts, publishing, and PotRenderService in a separate Lune runtime. Projects use binary `.pot` files. The desktop apps communicate with the runtime using length-prefixed MessagePack over authenticated loopback.

| Directory | Contents |
| --- | --- |
| `game/` | Lua source for the apps, viewport, and original six-part block avatars. |
| `luau/` | Project codec, scripting, multiplayer, publishing, and thumbnail rendering. |
| `tools/` | Developer build and installer source. |
| `Installers/` | Windows x64 Setup executables and macOS Universal app archives for this edition. |
| `WEBSERVICE/` | Empty directory reserved for the future website. |

## Try the scripted world

Install with the Windows Setup executable or extract the macOS Universal archive. Both include the runtime. Start **Terrace Park** in Client or **Terrace Workshop** in Studio. Press **E** near the gold switch to open the green gate. Step on the blue plate to light it up. Local testing needs no domain.

In Studio, use **Q** Select, **W** Move, **E** Rotate, **R** Scale, **F** Frame, and **F5** Playtest. Use the visible axis and snap controls or enter transforms in Properties. Press **Esc** to cancel a drag or return from playtest. Use **WASD**, mouse drag, **Space**, and **E** to move, look, jump, and interact in play.

## Pot scripting

Select a part, then choose **Add script** or **Edit script** in Properties. Start with the Press or Touch example. **Check script** validates the source and **Apply** attaches it to the part. **Playtest** runs the working copy in the viewport. A binary `.pot` file retains scripts and part IDs. Studio opens both earlier `.pot` and first-release `.pot.json` projects.

```lua
Pot.onPress(function(player)
    Pot.pulse("self", 1, "#ffda6a")
    Pot.setColor("self", "#09b734")
end)

Pot.onTouch(function(player: string)
    Pot.pulse("self", 2, "#91e4ff")
end)
```

Pot accepts a bounded Lua/Luau subset with event callbacks, typed locals, literals, arithmetic, and `if` blocks. Callbacks receive a player's session ID. Use `"self"` for the attached part or copy a target part's ID in Properties. Press requires a nearby player. Touch fires when contact begins. Scripts run in the authoritative simulation. The compiler limits scripts to the Pot API and rejects loops, imports, and unrestricted native access.

| API | Purpose |
| --- | --- |
| `Pot.setColor(part, "#rrggbb")` | Change a part's color during play. |
| `Pot.setVisible(part, bool)`, `Pot.setSolid(part, bool)` | Control drawing and collision. Turn both off to open a door. |
| `Pot.pulse(part, seconds, "#rrggbb")` | Animate a temporary glow. |
| `Pot.flag(name)`, `Pot.setFlag(name, bool)` | Read or write a room-scoped flag. |
| `Pot.isSolid(part)` | Read collision state. |
| `Pot.after(seconds, function() … end)` | Run a delayed action. |

## Publish and manage worlds

**Publish** writes the current place to the local library by default. **Published** lets you open a published copy, republish changes, or unpublish. Select **Worlds** in Client to refresh the catalog. The OS application data directory holds local places in `Pot/worlds`.

Set `POT_API_ENDPOINT` in the desktop launch environment when hosting is ready. If the v3 catalog is unavailable at startup, the app uses the local library.

| Process | Settings |
| --- | --- |
| Desktop | `POT_API_ENDPOINT` sets the base URL and requires HTTPS outside loopback. `POT_API_READ_TOKEN` and `POT_API_WRITE_TOKEN` supply credentials. |
| World service | `POT_WORLD_HOST`, `POT_WORLD_PORT`, and `POT_WORLD_DATA_DIR` set binding and persistence. Binding defaults to `127.0.0.1:4831`. `POT_WORLD_READ_TOKEN` and `POT_WORLD_WRITE_TOKEN` control access. |
| PotRenderService | `POT_RENDER_ENDPOINT` optionally connects the world service to a separate renderer. `POT_RENDER_HOST` and `POT_RENDER_PORT` default to `127.0.0.1:4812`. `POT_RENDER_TOKEN` is required for a non-loopback binding. |

Run `lune run luau/main.luau worlds /absolute/path/to/ANEW/luau` to start a world service. Run with `render` in place of `worlds` for separate PRS. To test multiplayer on one machine, point both clients at `http://127.0.0.1:4831`. Use a TLS reverse proxy for hosting, forward the session WebSocket upgrade, cap uploads there, and keep PRS privately reachable.

| Binary v3 route | Operation |
| --- | --- |
| `GET /v3/worlds`, `GET /v3/worlds/{id}` | Catalog and place snapshot. |
| `GET /v3/published`, `GET /v3/published/{id}` | Studio management with publishing credentials. |
| `PUT /v3/worlds/{id}`, `DELETE /v3/worlds/{id}` | Publish and unpublish. |
| `GET /v3/worlds/{id}/thumbnail` | Perspective map PNG. |
| `GET /v3/session` via WebSocket | Binary join, input, press, and authoritative snapshots. The first frame supplies the world ID and access credential. |
| `POST /v3/render` | Generate a map PNG from a binary place. |

## Build and test

Use Python 3.10 or later. The packager verifies the checksums of pinned LÖVE 11.5 and Lune 0.11.1 releases. Install NSIS 3 for Windows Setup executables. The macOS build emits a Universal archive and creates a `.pkg` when run with native macOS tools. Set `POT_MAC_APP_IDENTITY` and `POT_MAC_INSTALLER_IDENTITY` for release signing.

```sh
python tools/build.py windows
python tools/build.py macos
python tools/build.py dev --product studio --love /path/to/love
lune run luau/tests.luau /absolute/path/to/ANEW/luau /path/to/empty/scratch 4851
```

The third-party runtimes are included in developer packages. [LÖVE source](https://github.com/love2d/love/tree/11.5) · [Lune source and license](https://github.com/lune-org/lune/tree/v0.11.1)
