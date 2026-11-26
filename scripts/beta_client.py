"""Where the RS3 beta client keeps its files, shared by the scripts in this folder.

Windows: C:\\ProgramData\\Jagex\\RuneScape-BETA
Mac:     ~/Jagex/RuneScape-BETA (the live client's is ~/Jagex/RuneScape)
"""

import os
import shutil
import stat
import sys
from pathlib import Path

if sys.platform == "darwin":
    BETA_PATH = Path.home() / "Jagex" / "RuneScape-BETA"
else:
    BETA_PATH = Path(r"C:\ProgramData\Jagex\RuneScape-BETA")

DEV_PLUGINS_PATH = BETA_PATH / "dev_plugins"
PLUGINS_PATH = BETA_PATH / "plugins"


class ScriptError(Exception):
    """A problem to report in one line, without a traceback."""


def ensure_dev_plugins(dev_plugins: Path) -> None:
    """Make dev_plugins if it's missing, but only inside a client folder that exists.

    A missing client folder means the beta client hasn't run, or the path is wrong.
    """
    client = dev_plugins.parent
    if not client.is_dir():
        raise ScriptError(f"Beta client folder not found: {client} (has the beta client been run once?)")
    if not dev_plugins.is_dir():
        dev_plugins.mkdir()
        print(f"Created {dev_plugins}")


def remove_tree(path: Path) -> None:
    """Delete a folder, including read-only files (Windows marks git's objects read-only)."""

    def make_writable_and_retry(function, failed_path, _exc_info):
        os.chmod(failed_path, stat.S_IWRITE)
        function(failed_path)

    shutil.rmtree(path, onerror=make_writable_and_retry)


def count_files(path: Path) -> int:
    return sum(1 for item in path.rglob("*") if item.is_file())
