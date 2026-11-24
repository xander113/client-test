"""Run against an isolated Compose stack with POT_ROOM_SIZE=2."""
from contextlib import ExitStack
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from http.cookiejar import CookieJar
from secrets import token_hex
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import HTTPCookieProcessor, Request, build_opener
import argparse
import re
import time

import msgpack
import websocket


def binary(value):
    return msgpack.packb(value, use_bin_type=True)


class Platform:
    def __init__(self, url):
        self.url = url.rstrip("/")

    def call(self, path, method="GET", body=None, headers=None, browser=None, status=200):
        request = Request(self.url + path, data=body, method=method, headers=headers or {})
        agent = browser or build_opener()
        try:
            response = agent.open(request, timeout=8)
        except HTTPError as error:
            response = error
        with response:
            content = response.read()
            assert response.status == status, (method, path, response.status, content[:300])
            return content

    def api(self, path, method="GET", data=None, token=None, status=200):
        headers = {"Content-Type": "application/msgpack", "Accept": "application/msgpack"}
        if token:
            headers["Authorization"] = "Bearer " + token
        raw = self.call("/v3" + path, method, None if data is None else binary(data), headers, status=status)
        return msgpack.unpackb(raw, raw=False)

    def token(self, browser, page):
        html = self.call(page, browser=browser).decode()
        return re.search(r'name="_token" value="([^"]+)"', html)[1]

    def form(self, browser, page, action, **data):
        data["_token"] = self.token(browser, page)
        return self.call(action, "POST", urlencode(data).encode(),
                         {"Content-Type": "application/x-www-form-urlencoded"}, browser)

    def account(self, name):
        browser = build_opener(HTTPCookieProcessor(CookieJar()))
        password = token_hex(16)
        self.form(browser, "/register", "/register", name=name, email=token_hex(10) + "@example.com",
                  password=password, password_confirmation=password)
        result = self.form(browser, "/account", "/account/tokens", label="Hosting test").decode()
        key = re.search(r'value="([0-9a-f]{64})" readonly', result)[1]
        assert key.encode() not in self.call("/account", browser=browser), "Credential appeared more than once"
        return browser, key

    def admission(self, world, key=None):
        for _ in range(12):
            try:
                return self.api("/join", "POST", {"world": world}, key)
            except AssertionError as error:
                if error.args[0][2] != 503:
                    raise
                time.sleep(.5)
        raise AssertionError("The game worker never registered")

    def connect(self, grant, stack):
        socket = websocket.create_connection(self.url.replace("http", "ws", 1) + grant["socket"], timeout=5)
        stack.callback(socket.close, timeout=.15)
        socket.send_binary(binary({"type": "join", "world": grant["world"], "ticket": grant["ticket"]}))
        frame = socket.recv()
        return socket, msgpack.unpackb(frame, raw=False) if frame else None


def project(world, title, material="#2a9452"):
    def part(id, pos, size, color):
        return {"id": id, "name": id.capitalize(), "kind": "box", "position": pos, "size": size,
                "rotation": [0, 0, 0], "color": color, "solid": True}
    return {"schemaVersion": 5, "id": world, "name": title, "description": "A hosted Pot test world.",
            "spawn": {"x": 0, "y": 0, "z": 4}, "allowReset": True,
            "objects": [part("ground", [0, -.5, 0], [20, 1, 20], "#9ac2a2"),
                        part("switch", [1, .4, 3], [1, .8, 1], "#efaf43"),
                        part("gate", [0, 1, 1], [2, 2, .2], material)],
            "scripts": [{"id": "switch-script", "name": "Switch", "kind": "script", "parent": "switch",
                         "source": 'Pot.onPress(function() Pot.setVisible("gate", false) end)', "enabled": True}],
            "textures": []}


def state(socket, condition):
    for _ in range(40):
        event = msgpack.unpackb(socket.recv(), raw=False)
        if event.get("type") == "state" and condition(event):
            return event
    raise AssertionError("The expected multiplayer state did not arrive")


def concurrent_admission(api, world):
    def admit(_):
        grant = api.admission(world)
        with ExitStack() as cleanup:
            socket, welcome = api.connect(grant, cleanup)
            assert welcome and welcome["server"] == grant["server"], "A reserved seat was denied during concurrent joins"
            return grant, socket, cleanup.pop_all()

    with ThreadPoolExecutor(max_workers=8) as pool, ExitStack() as sessions:
        peers = []
        for grant, socket, cleanup in pool.map(admit, range(32)):
            sessions.enter_context(cleanup)
            peers.append((grant, socket))
        counts = Counter(grant["server"] for grant, _ in peers)
        assert len(counts) == 16 and set(counts.values()) == {2}, counts
        for _, socket in peers[::4]:
            state(socket, lambda event: len(event["players"]) == 2)
    print("32 simultaneous connections passed across 16 live instances.")


def run(base):
    api = Platform(base)
    suffix = token_hex(5)
    first_name, second_name = "Maple " + suffix, "Pine " + suffix
    author, first = api.account(first_name)
    rival, second = api.account(second_name)
    first_profile = api.api("/account/me", token=first)
    assert first_profile["displayName"] == first_name and first_profile["balance"] == 0
    assert api.api("/account/me", token=second)["id"] != first_profile["id"]
    api.api("/account/me", status=401)
    palette = {"skin": "#d1bd96", "shirt": "#2d43a4", "pants": "#353029", "visor": "#2f4941"}
    assert api.api("/account/me/look", "PUT", palette, second)["look"] == palette

    world = "host-" + suffix
    original = project(world, "Hosting test " + suffix)
    endpoint = "/worlds/" + world
    created = api.api(endpoint, "PUT", original, first)
    game = created["experience"]
    assert created["version"] == 1 and not created["public"]
    assert api.api(endpoint, "PUT", original, first)["version"] == 1
    api.api(endpoint, "PUT", original, second, status=404)
    api.api(endpoint, status=404)
    api.api("/join", "POST", {"world": world}, second, status=404)
    assert api.api("/published/" + world, token=first)["id"] == world

    creator = "/creator/" + game
    api.form(author, creator, creator + "/settings", visibility="public", start=world)
    assert world.encode() in api.call("/games/" + game)
    assert api.call("/v3" + endpoint + "/thumbnail").startswith(b"\x89PNG\r\n\x1a\n")

    annex = project("annex-" + suffix, "Annex " + suffix)
    boundary = token_hex(16)
    form = b""
    for name, value in (("_token", api.token(author, "/creator")), ("game", game)):
        form += f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode()
    form += (f'--{boundary}\r\nContent-Disposition: form-data; name="project"; filename="Annex.pot"\r\n'
             'Content-Type: application/octet-stream\r\n\r\n').encode()
    form += b"POT\0\1" + binary(annex) + (f"\r\n--{boundary}--\r\n").encode()
    view = api.call("/creator", "POST", form, {"Content-Type": "multipart/form-data; boundary=" + boundary}, author)
    assert annex["id"].encode() in view
    assert api.api("/worlds/" + annex["id"])["id"] == annex["id"]

    with ExitStack() as world_sockets:
        one = api.admission(world, first)
        a, a_welcome = api.connect(one, world_sockets)
        two = api.admission(world, second)
        b, b_welcome = api.connect(two, world_sockets)
        assert a_welcome["type"] == b_welcome["type"] == "welcome"
        assert a_welcome["server"] == b_welcome["server"]
        lobby = state(a, lambda event: len(event["players"]) == 2)
        player = next(p for p in lobby["players"] if p["name"] == second_name)
        assert player["look"] == palette and "balance" not in player
        _, denied = api.connect(one, world_sockets)
        assert denied is None, "A consumed ticket admitted a second socket"
        three = api.admission(world)
        _, overflow = api.connect(three, world_sockets)
        assert overflow["server"] != a_welcome["server"], "A full server failed to spill over"
        a.send_binary(binary({"type": "press", "part": "switch"}))
        state(b, lambda e: any(f["id"] == "gate" and not f["visible"] for f in e["effects"]))
        a.send_binary(binary({"type": "reset"}))
        for _ in range(20):
            event = msgpack.unpackb(a.recv(), raw=False)
            if event.get("type") == "resetResult":
                assert event["ok"]
                break
        else:
            raise AssertionError("Hosted reset did not return a result")

        newer = project(world, original["name"], "#3565a8")
        assert api.api(endpoint, "PUT", newer, first)["version"] == 2
        next_grant = api.admission(world)
        _, current = api.connect(next_grant, world_sockets)
        assert current["revision"] != a_welcome["revision"]
        assert msgpack.unpackb(next_grant["project"], raw=False)["objects"][-1]["color"] == "#3565a8"
        state(b, lambda e: any(f["id"] == "gate" and not f["visible"] for f in e["effects"]))

        html = api.call(creator, browser=author).decode()
        restore = re.search(re.escape(creator + "/" + world) + r"/[a-z0-9]{26}/restore", html)[0]
        api.form(author, creator, restore)
        assert api.api(endpoint)["objects"][-1]["color"] == original["objects"][-1]["color"]

    concurrent_admission(api, annex["id"])
    assert api.api(endpoint, "DELETE", token=first) is True
    api.api(endpoint, status=404)
    api.call("/v3/internal/workers/core/heartbeat", "POST", b"x", status=404)
    print("Passed browser accounts and keys, ownership, multi-place publishing and rollback, thumbnails,")
    print("one-use tickets, account appearances, shared scripts and reset, capacity overflow, and live version pinning.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url")
    run(parser.parse_args().url)
