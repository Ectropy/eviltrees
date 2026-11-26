"""Install the PrettyUI UI library into the RS3 beta client's dev_plugins folder.

Evil Trees draws its dashboard with PrettyUI (https://github.com/PrettyRS/prettyui),
a Plugin Hub library. A dev plugin's dependencies aren't downloaded by the client,
so this script fetches one tagged PrettyUI release with git and copies the files a
release contains (plugin.json, main.lua, src, resources, LICENSE) into
dev_plugins/prettyui. The deployed plugin.json points at that folder name
(see scripts/deploy_plugin.py).

Then enable it once in the game console:  pon prettyui
and reload Evil Trees:                     prl evil-trees

Usage:
  python3 scripts/install_prettyui.py                 # the pinned version
  python3 scripts/install_prettyui.py --tag v1.4.0    # another release
  python3 scripts/install_prettyui.py --hub           # the copy the Plugin Hub gave this client

--hub installs from the Hub's zip in plugins/6398181 (the plugin needs 1.3.0 or
later). Install PrettyUI from the Hub first. Use it to test Evil Trees against
what players will have.
"""

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

from beta_client import DEV_PLUGINS_PATH, PLUGINS_PATH, ScriptError, count_files, ensure_dev_plugins, remove_tree

DEFAULT_TAG = "v1.3.0"
# The client's plugins folder for PrettyUI (mod.io ID 6398181).
HUB_PATH = PLUGINS_PATH / "6398181"
RELEASE_FILES = ("plugin.json", "main.lua", "LICENSE", "src", "resources")
NEXT_STEP = "In the game console run:  pon prettyui   then   prl evil-trees"


def fresh_destination(dev_plugins: Path) -> Path:
    destination = dev_plugins / "prettyui"
    if destination.exists():
        remove_tree(destination)
    return destination


def install_from_hub(hub_path: Path, dev_plugins: Path) -> None:
    archive = hub_path / "6398181.zip"
    if not archive.is_file():
        raise ScriptError(f"Hub copy not found: {archive} (install PrettyUI from the Plugin Hub first)")
    destination = fresh_destination(dev_plugins)
    with zipfile.ZipFile(archive) as opened:
        opened.extractall(destination)
    # The version from its plugin.json, to show which one was installed.
    version = json.loads((destination / "plugin.json").read_text(encoding="utf-8-sig")).get("version")
    print(f"Installed the Hub's PrettyUI {version} ({count_files(destination)} files) to {destination}")
    print(NEXT_STEP)


def install_from_github(tag: str, dev_plugins: Path) -> None:
    temp = Path(tempfile.mkdtemp(prefix="prettyui-"))
    clone = temp / "prettyui"
    try:
        # (advice.detachedHead=false: a tag checkout is expected, so skip git's notice about it)
        result = subprocess.run(
            ["git", "-c", "advice.detachedHead=false", "clone", "--quiet", "--depth", "1",
             "--branch", tag, "https://github.com/PrettyRS/prettyui.git", str(clone)]
        )
        if result.returncode != 0:
            raise ScriptError(f"git clone failed for tag {tag}")
        missing = [item for item in RELEASE_FILES if not (clone / item).exists()]
        if missing:
            raise ScriptError(f"PrettyUI {tag} is missing {', '.join(missing)}")

        destination = fresh_destination(dev_plugins)
        destination.mkdir()
        for item in RELEASE_FILES:
            source = clone / item
            if source.is_dir():
                shutil.copytree(source, destination / item)
            else:
                shutil.copy2(source, destination / item)

        print(f"Installed PrettyUI {tag} ({count_files(destination)} files) to {destination}")
        print(NEXT_STEP)
    finally:
        remove_tree(temp)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tag", default=DEFAULT_TAG, help=f"the PrettyUI release (git tag) to install (default: {DEFAULT_TAG})")
    parser.add_argument("--hub", action="store_true", help="install the Hub's copy instead of a GitHub release")
    parser.add_argument("--hub-path", type=Path, default=HUB_PATH, help=f"where the Hub's copy is (default: {HUB_PATH})")
    parser.add_argument("--dev-plugins", type=Path, default=DEV_PLUGINS_PATH, help=f"the beta client's dev_plugins folder (default: {DEV_PLUGINS_PATH})")
    options = parser.parse_args()

    try:
        ensure_dev_plugins(options.dev_plugins)
        if options.hub:
            install_from_hub(options.hub_path, options.dev_plugins)
        else:
            install_from_github(options.tag, options.dev_plugins)
    except ScriptError as error:
        sys.exit(f"Error: {error}")


if __name__ == "__main__":
    main()
