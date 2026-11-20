"""Print a text log saved in the RS3 beta client's PersistentDB.

PersistentDB is a SQLite file: RuneScape-BETA/plugins/PluginData.db, table DataStore
(PluginID, Key, Type, Value). We copy the file first so we never lock or modify the
game's copy.

Usage:
  python scripts/read_plugin_log.py                        # Evil Trees capture log
  python scripts/read_plugin_log.py --key <key>            # another saved text key
  python scripts/read_plugin_log.py --prefix <text>        # every key starting with <text>, one per line
  python scripts/read_plugin_log.py --db <path-to-PluginData.db>
"""

import argparse
import re
import shutil
import sqlite3
import tempfile
from pathlib import Path

DEFAULT_DB = Path(r"C:\ProgramData\Jagex\RuneScape-BETA\plugins\PluginData.db")


def main() -> None:
    args = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    args.add_argument("--db", type=Path, default=DEFAULT_DB, help="path to PluginData.db")
    args.add_argument("--plugin", default="Evil Trees", help="plugin name (PluginID); default: Evil Trees")
    args.add_argument("--key", default="captureLog", help="PersistentDB key (default: captureLog)")
    args.add_argument("--prefix", help="print every key that starts with this text (instead of --key)")
    options = args.parse_args()

    with tempfile.TemporaryDirectory() as tmp:
        copy = Path(tmp) / "PluginData.db"
        shutil.copy2(options.db, copy)
        # Copy the write-ahead log too, if the client keeps one; it may hold recent writes.
        for suffix in ("-wal", "-shm"):
            extra = options.db.with_name(options.db.name + suffix)
            if extra.exists():
                shutil.copy2(extra, copy.with_name(copy.name + suffix))

        connection = sqlite3.connect(copy)
        try:
            if options.prefix is not None:
                # substr, not LIKE: a prefix may contain % or _.
                query = "SELECT Key, Value FROM DataStore WHERE substr(Key, 1, ?) = ?"
                params = [len(options.prefix), options.prefix]
            else:
                query = "SELECT PluginID, Value FROM DataStore WHERE Key = ?"
                params = [options.key]
            if options.plugin is not None:
                query += " AND PluginID = ?"
                params.append(options.plugin)
            rows = connection.execute(query, params).fetchall()
        finally:
            connection.close()

    if options.prefix is not None:
        if not rows:
            print(f"No saved keys start with '{options.prefix}' (has the plugin run, and saved yet?)")
            return

        # Sort mark2 before mark10: split each key into text and number parts.
        def natural(row):
            return [int(part) if part.isdigit() else part for part in re.split(r"(\d+)", row[0])]

        for key, value in sorted(rows, key=natural):
            text = value.decode("utf-8", errors="replace") if isinstance(value, bytes) else str(value)
            print(f"{key}: " + text.replace("\x00", ""))
        return

    if not rows:
        print(f"No saved entry found for key '{options.key}' (has the plugin run, and saved yet?)")
        return
    for plugin_id, value in rows:
        text = value.decode("utf-8", errors="replace") if isinstance(value, bytes) else str(value)
        print(f"===== {plugin_id} =====")
        print(text.replace("\x00", ""))


if __name__ == "__main__":
    main()
