"""Copy the plugin in this repo's plugin/ folder into the RS3 beta client's dev_plugins folder.

Replaces the plugin's folder in dev_plugins with a fresh copy, so files deleted here
don't linger there. Only that one plugin folder is touched.
After deploying, reload in the game console with:  prl <plugin-name>
(or, if it was turned off by a world hop:  pon <plugin-name>)

PrettyUI: plugin/plugin.json names the Plugin Hub's PrettyUI by its ID
("prettyui": 6398181), as a release must. A dev plugin can't use a Hub ID
(beta, 2026-11-18: prettyui came through empty), so the deployed copy is changed
to the dev folder ("prettyui": "prettyui"), which scripts/install_prettyui.py
fills. --hub-dependency keeps the Hub ID.

Usage:
  python3 scripts/deploy_plugin.py             # plugin/ as dev_plugins/evil-trees
  python3 scripts/deploy_plugin.py --probe     # research/probe (local, not in git) as evil-trees-probe
  python3 scripts/deploy_plugin.py --lab       # research/gridlab as evil-trees-grid-lab
  python3 scripts/deploy_plugin.py --sprites   # research/spritelab as evil-trees-sprite-lab
  python3 scripts/deploy_plugin.py --effects   # research/effectslab as evil-trees-effects-lab
"""

import argparse
import re
import shutil
import sys
from pathlib import Path

from beta_client import DEV_PLUGINS_PATH, ScriptError, count_files, ensure_dev_plugins, remove_tree

REPO = Path(__file__).resolve().parent.parent

# Each choice: (folder in this repo, folder name in dev_plugins, which is also the name pon/prl use).
PLUGINS = {
    "plugin": ("plugin", "evil-trees"),
    "probe": ("research/probe", "evil-trees-probe"),
    "lab": ("research/gridlab", "evil-trees-grid-lab"),
    "sprites": ("research/spritelab", "evil-trees-sprite-lab"),
    "effects": ("research/effectslab", "evil-trees-effects-lab"),
}

HUB_ID = re.compile(r'"prettyui":\s*6398181')


def deploy(choice: str, dev_plugins: Path, hub_dependency: bool) -> None:
    relative, name = PLUGINS[choice]
    source = REPO / relative
    if not source.is_dir():
        raise ScriptError(f"Plugin folder not found: {relative}")
    for required in ("main.lua", "plugin.json"):
        if not (source / required).is_file():
            raise ScriptError(f"{relative} is missing {required}")
    ensure_dev_plugins(dev_plugins)

    destination = dev_plugins / name
    if destination.exists():
        remove_tree(destination)
    shutil.copytree(source, destination)

    # The real plugin: point the deployed copy's PrettyUI dependency at the dev
    # folder (see the description at the top).
    if choice == "plugin" and not hub_dependency:
        manifest = destination / "plugin.json"
        # newline="": keep the file's line endings as they are.
        with open(manifest, encoding="utf-8", newline="") as file:
            text = file.read()
        if HUB_ID.search(text):
            with open(manifest, "w", encoding="utf-8", newline="") as file:
                file.write(HUB_ID.sub('"prettyui": "prettyui"', text))
            print("PrettyUI dependency: dev folder dev_plugins/prettyui (plugin/plugin.json keeps the Hub ID)")
        else:
            print("Warning: plugin.json has no '\"prettyui\": 6398181' to change; deployed as is", file=sys.stderr)

    print(f"Deployed {relative} ({count_files(destination)} files) to {destination}")
    print(f"In the game console run:  prl {name}   (or pon {name} if it's off)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    which = parser.add_mutually_exclusive_group()
    which.add_argument("--probe", dest="choice", action="store_const", const="probe", help="deploy the research probe")
    which.add_argument("--lab", dest="choice", action="store_const", const="lab", help="deploy the grid lab (UI experiments)")
    which.add_argument("--sprites", dest="choice", action="store_const", const="sprites", help="deploy the sprite lab (icon candidates)")
    which.add_argument("--effects", dest="choice", action="store_const", const="effects", help="deploy the effects lab (lightning and sparks)")
    parser.set_defaults(choice="plugin")
    parser.add_argument("--hub-dependency", action="store_true", help="keep plugin.json's Hub ID for PrettyUI instead of the dev folder")
    parser.add_argument("--dev-plugins", type=Path, default=DEV_PLUGINS_PATH, help=f"the beta client's dev_plugins folder (default: {DEV_PLUGINS_PATH})")
    options = parser.parse_args()

    try:
        deploy(options.choice, options.dev_plugins, options.hub_dependency)
    except ScriptError as error:
        sys.exit(f"Error: {error}")


if __name__ == "__main__":
    main()
