#!/bin/bash
# Reset MT5 window coordinates when they are saved off-screen (common on Mac after
# display changes). Users think MT5 "auto closed" but the window is invisible.
set -euo pipefail

python3 <<'PY'
import pathlib
import re

BASE = pathlib.Path.home() / "Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files"
LEFT, TOP, RIGHT, BOTTOM = 100, 100, 1500, 900


def off_screen(left: int, top: int, right: int, bottom: int) -> bool:
    return top < 0 or left < -200 or top > 1800 or left > 4000 or bottom < 0


def fix_ini(path: pathlib.Path) -> bool:
    raw = path.read_bytes()
    if not raw:
        return False
    try:
        text = raw.decode("utf-16-le")
    except UnicodeDecodeError:
        text = raw.decode("utf-8", errors="replace")

    m = re.search(
        r"\[Window\].*?Left=(\S+).*?Top=(\S+).*?Right=(\S+).*?Bottom=(\S+)",
        text,
        re.DOTALL,
    )
    if not m:
        return False

    left, top, right, bottom = map(int, m.groups())
    if not off_screen(left, top, right, bottom):
        return False

    def repl_window(section: re.Match) -> str:
        s = section.group(0)
        s = re.sub(r"Left=\S+", f"Left={LEFT}", s)
        s = re.sub(r"Top=\S+", f"Top={TOP}", s)
        s = re.sub(r"Right=\S+", f"Right={RIGHT}", s)
        s = re.sub(r"Bottom=\S+", f"Bottom={BOTTOM}", s)
        s = re.sub(r"LSave=\S+", f"LSave={LEFT}", s)
        s = re.sub(r"TSave=\S+", f"TSave={TOP}", s)
        s = re.sub(r"RSave=\S+", f"RSave={RIGHT}", s)
        s = re.sub(r"BSave=\S+", f"BSave={BOTTOM}", s)
        return s

    new_text = re.sub(r"\[Window\].*?(?=\[|\Z)", repl_window, text, count=1, flags=re.DOTALL)
    path.write_bytes(new_text.encode("utf-16-le"))
    print(f"Fixed: {path.parent.parent.name} (was Left={left} Top={top})")
    return True


fixed = 0
for d in sorted(BASE.iterdir()):
    ini = d / "config" / "terminal.ini"
    if ini.exists() and fix_ini(ini):
        fixed += 1

if fixed == 0:
    print("All MT5 window positions already on-screen.")
else:
    print(f"Reset {fixed} terminal(s). Open MT5 again — window should appear on screen.")
PY
