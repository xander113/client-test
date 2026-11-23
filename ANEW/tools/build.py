#!/usr/bin/env python3
"""Build the native Lua/Luau Pot apps and platform developer installers."""
import argparse
from hashlib import sha256
from pathlib import Path
import os
import plistlib
import shutil
import stat
import subprocess
import sys
from tempfile import TemporaryDirectory
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = "0.4.0"
LOVE = "11.5"
LUNE = "0.11.1"
BASE_LOVE = f"https://github.com/love2d/love/releases/download/{LOVE}/"
BASE_LUNE = f"https://github.com/lune-org/lune/releases/download/v{LUNE}/"
DOWNLOADS = {
    f"love-{LOVE}-win64.zip": (BASE_LOVE, "ba6e56be2685e53c817749c4a5007f51137136fe5a3ab64920508babc2e74369"),
    f"love-{LOVE}-macos.zip": (BASE_LOVE, "6795bb3a1656af6a2fdfe741e150787b481886d3a280327a261a3fdded586913"),
    f"love-{LOVE}-x86_64.AppImage": (BASE_LOVE, "65a673406431eff7167a15a032bf7a2e4ba50108e091eb7b176465831f9b5e00"),
    f"lune-{LUNE}-windows-x86_64.zip": (BASE_LUNE, "83f1dc29d9e35c494907521f2ca6561f6c204fdf6f1b06525d2e9fdd1e6b4301"),
    f"lune-{LUNE}-macos-x86_64.zip": (BASE_LUNE, "d083047e08a40bd73dbb1ae8af929536497c0d57021c0ead0f9c8571f228a5fa"),
    f"lune-{LUNE}-macos-aarch64.zip": (BASE_LUNE, "0592c9b37c06f208f7d90e5d750e76101b9ba6191cd693ef34667f4f1f1063d4"),
    f"lune-{LUNE}-linux-x86_64.zip": (BASE_LUNE, "39859282ce677fce19e6eb45c37596a90a25c324c95b4e7e02d428b6cae294a1"),
    f"lune-{LUNE}-linux-aarch64.zip": (BASE_LUNE, "f8d7d63384fad5edfaf5423b0ff1a1dbca9c44ec43beaa35c234b20a584aea66"),
}
CACHE = Path(os.environ.get("POT_BUILD_CACHE", ROOT / ".build-cache"))


def download(name):
    base, expected = DOWNLOADS[name]
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / name
    if not path.is_file():
        temporary = path.with_suffix(path.suffix + ".part")
        try:
            request = urllib.request.Request(base + name, headers={"User-Agent": "Pot-build"})
            with urllib.request.urlopen(request, timeout=60) as response, temporary.open("wb") as out:
                shutil.copyfileobj(response, out)
            if sha256(temporary.read_bytes()).hexdigest() != expected:
                raise RuntimeError(f"Unexpected checksum for {name}")
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
    if sha256(path.read_bytes()).hexdigest() != expected:
        raise RuntimeError(f"Unexpected cached checksum for {name}")
    return path


def expand(archive, root):
    with zipfile.ZipFile(archive) as bundle:
        for item in bundle.infolist():
            name = Path(item.filename)
            if name.is_absolute() or ".." in name.parts or "\\" in item.filename:
                raise RuntimeError("Unexpected archive path")
            if "__MACOSX" in name.parts or name.name == ".DS_Store":
                continue
            path = root / name
            mode = item.external_attr >> 16
            if item.is_dir():
                path.mkdir(exist_ok=True, parents=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                if stat.S_ISLNK(mode):
                    path.symlink_to(bundle.read(item).decode("utf-8"))
                else:
                    path.write_bytes(bundle.read(item))
                    if mode & 0o111:
                        path.chmod(0o755)


def bundle_game(product, path):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as bundle:
        for file in sorted((ROOT / "game").iterdir()):
            bundle.write(file, file.name)
        for name in ("wire.lua", "geometry.lua", "hierarchy.lua"):
            bundle.write(ROOT / "luau" / name, name)
        bundle.write(ROOT / "build" / "icons" / f"{product}.png", "icon.png")
        bundle.writestr("product.lua", f'return "{product}"\n')


def runtime_files(target, directory):
    directory.mkdir(parents=True, exist_ok=True)
    shutil.copytree(ROOT / "luau", directory / "luau", dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns("tests*"))
    arches = {
        "windows": [("x86_64", "lune.exe")],
        "macos": [("x86_64", "lune-x64"), ("aarch64", "lune-arm64")],
        "linux": [("x86_64", "lune-x64")],
    }
    for arch, binary in arches[target]:
        archive = download(f"lune-{LUNE}-{target}-{arch}.zip")
        upstream = "lune.exe" if target == "windows" else "lune"
        with zipfile.ZipFile(archive) as z:
            entry = next(i for i in z.namelist() if Path(i).name == upstream)
            path = directory / binary
            data = z.read(entry)
            if not path.is_file() or path.read_bytes() != data:
                temporary = path.with_suffix(path.suffix + ".new")
                temporary.write_bytes(data)
                temporary.chmod(0o755)
                temporary.replace(path)


def zip_tree(root, archive, prefix=None):
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for path in sorted(root.rglob("*")):
            name = path.relative_to(root).as_posix()
            if prefix:
                name = prefix + "/" + name
            if path.is_symlink():
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
                z.writestr(info, os.readlink(path))
            elif path.is_dir():
                z.mkdir(name)
            else:
                z.write(path, name)


def windows(product, output, nsis):
    title = f"Pot {product.title()}"
    with TemporaryDirectory(dir=output, prefix=".win-") as temp:
        stage = Path(temp)
        expand(download(f"love-{LOVE}-win64.zip"), stage)
        source = next(stage.glob("*/love.exe"))
        payload = stage / "payload"
        payload.mkdir()
        for file in source.parent.iterdir():
            if file.is_file() and file.suffix.lower() != ".exe":
                shutil.copy2(file, payload / file.name)
        game = stage / "pot.love"
        bundle_game(product, game)
        with (payload / f"{title}.exe").open("wb") as f:
            for path in (source, game):
                with path.open("rb") as r:
                    shutil.copyfileobj(r, f)
        runtime_files("windows", payload)
        portable = output / f"{title}-{VERSION}-Windows-x64.zip"
        zip_tree(payload, portable)
        print(portable, flush=True)
        if nsis:
            installer = output / f"{title}-{VERSION}-Setup-x64.exe"
            # Only remove the files installed by Pot. The document library lives in AppData.
            files = [p.relative_to(payload) for p in payload.rglob("*") if p.is_file()]
            dirs = sorted((p.relative_to(payload) for p in payload.rglob("*") if p.is_dir()),
                          key=lambda p: len(p.parts), reverse=True)
            script = stage / "cleanup.nsh"
            commands = ['Delete "$INSTDIR\\' + str(p).replace("/", "\\") + '"' for p in files]
            commands += ['RMDir "$INSTDIR\\' + str(p).replace("/", "\\") + '"' for p in dirs]
            script.write_text("\n".join(commands) + "\n", encoding="utf-8")
            subprocess.run([nsis, f"-DTITLE={title}", f"-DKEY={product}", f"-DVERSION={VERSION}",
                            f"-DPAYLOAD={payload}", f"-DINSTALLER={installer}", f"-DCLEANUP={script}",
                            str(ROOT / "tools" / "windows.nsi")], check=True)
            print(installer, flush=True)


def macos(product, output, cross_signer):
    title = f"Pot {product.title()}"
    with TemporaryDirectory(dir=output, prefix=".mac-") as temp:
        stage = Path(temp)
        expand(download(f"love-{LOVE}-macos.zip"), stage)
        app = stage / f"{title}.app"
        (stage / "love.app").rename(app)
        resources = app / "Contents/Resources"
        resources.mkdir(exist_ok=True)
        bundle_game(product, resources / "pot.love")
        runtime_files("macos", resources)
        config = app / "Contents/Info.plist"
        data = plistlib.loads(config.read_bytes())
        data.update(CFBundleName=title, CFBundleDisplayName=title, CFBundleIdentifier=f"org.potproject.{product}",
                    CFBundleVersion=VERSION, CFBundleShortVersionString=VERSION,
                    NSHumanReadableCopyright="Pot")
        data.pop("CFBundleDocumentTypes", None)
        config.write_bytes(plistlib.dumps(data))
        # LÖVE 11.5 ships a FreeType framework with no identifier in its plist.
        freetype = app / "Contents/Frameworks/freetype.framework/Versions/A/Resources/Info.plist"
        framework_data = plistlib.loads(freetype.read_bytes())
        if "CFBundleIdentifier" not in framework_data:
            framework_data["CFBundleIdentifier"] = "org.freetype.freetype"
            freetype.write_bytes(plistlib.dumps(framework_data))
        if sys.platform == "darwin":
            identity = os.environ.get("POT_MAC_APP_IDENTITY", "-")
            subprocess.run(["codesign", "--force", "--deep", "--sign", identity, str(app)], check=True)
        else:
            subprocess.run([cross_signer, "sign", str(app)], check=True)
        portable = output / f"{title}-{VERSION}-macOS-universal.zip"
        zip_tree(app, portable, app.name)
        print(portable, flush=True)
        if sys.platform == "darwin":
            installer = output / f"{title}-{VERSION}-macOS-universal.pkg"
            command = ["pkgbuild", "--component", str(app), "--install-location", "/Applications",
                       "--identifier", f"org.potproject.{product}", "--version", VERSION]
            identity = os.environ.get("POT_MAC_INSTALLER_IDENTITY")
            if identity:
                command += ["--sign", identity]
            subprocess.run(command + [str(installer)], check=True)
            print(installer, flush=True)


def dev(product, output):
    directory = output / product
    directory.mkdir(parents=True, exist_ok=True)
    target = {"linux": "linux", "win32": "windows", "darwin": "macos"}[sys.platform]
    runtime_files(target, directory)
    game = directory / "pot.love"
    bundle_game(product, game)
    print(game, flush=True)
    return game


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=["dev", "windows", "macos", "all"])
    parser.add_argument("--product", choices=["client", "studio", "both"], default="both")
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts")
    parser.add_argument("--makensis", default=shutil.which("makensis"))
    parser.add_argument("--rcodesign", default=shutil.which("rcodesign"), help="Sign macOS app bundles on another OS")
    parser.add_argument("--love", type=Path, help="Run a dev bundle with this installed LÖVE 11.5")
    options = parser.parse_args()
    if options.target in ("macos", "all") and sys.platform != "darwin" and not options.rcodesign:
        parser.error("Install rcodesign or pass --rcodesign when building macOS app bundles on this OS.")
    options.output = options.output.resolve()
    options.output.mkdir(parents=True, exist_ok=True)
    (ROOT / "WEBSERVICE").mkdir(exist_ok=True)
    products = ["client", "studio"] if options.product == "both" else [options.product]
    for product in products:
        if options.target == "dev":
            game = dev(product, options.output)
            if options.love:
                env = dict(os.environ, POT_RESOURCES=str(game.parent))
                subprocess.run([str(options.love.resolve()), str(game)], env=env, check=True)
        else:
            if options.target in ("windows", "all"):
                windows(product, options.output, options.makensis)
            if options.target in ("macos", "all"):
                macos(product, options.output, options.rcodesign)


if __name__ == "__main__":
    main()
