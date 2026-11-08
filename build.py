#!/usr/bin/env python3
"""Build the rehearsal display's song data from songs/<slug>/lead.md.

    python3 rehearsal/build.py            # parse every song with a lead.md -> app/songs.js
    python3 rehearsal/build.py --zip      # ...and package app/ as dist/OO-Rehearsal.zip
    python3 rehearsal/build.py --check    # parse + report only, write nothing
    python3 build.py --songs ~/band/songs # charts somewhere else

Songs are read from ../songs/<slug>/lead.md by default (this repo lives inside the
band repo as a submodule). Without real charts, the app falls back to
app/songs.example.js.

lead.md is the source of truth (see songs/README.md). This script never edits it.
It validates each section's bar count against the "— bars A-B" in its heading and
prints mismatches, which are usually chart typos worth fixing in lead.md.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_SONGS_DIR = HERE.parent / "songs"  # when this repo sits inside the band repo
APP_DIR = HERE / "app"
DIST_DIR = HERE / "dist"

SECTION_RE = re.compile(r"^##\s+(?P<name>.+?)\s*(?:[—–-]+\s*bars?\s+(?P<a>\d+)\s*[-–]\s*(?P<b>\d+))?\s*$")
TEMPO_RE = re.compile(r"(\d{2,3})\s*bpm", re.I)
KEY_RE = re.compile(r"bpm\s*/\s*([A-G][#b]?\s*(?:maj|min|m)?)", re.I)
NOTE_CELL_RE = re.compile(r"^_?\((?P<note>.*)\)_?$")  # "(2 bars)", "_(synth/pad)_"
EMPTY_CELLS = {"empty", "n.c.", "nc", "-", "%"}


def parse_bar(cell: str) -> list[dict]:
    """'A // E //' -> [{'c':'A','b':2},{'c':'E','b':2}]; 'F#m ////' -> one 4-beat chord."""
    cell = cell.strip()
    if cell.lower() in EMPTY_CELLS:
        return [{"c": "", "b": 4}]
    out: list[dict] = []
    for tok in cell.split():
        if set(tok) == {"/"}:
            if out:
                out[-1]["b"] += len(tok)
        else:
            out.append({"c": tok, "b": 0})
    for ch in out:
        if ch["b"] == 0:
            ch["b"] = 4 if len(out) == 1 else 1
    return out or [{"c": "", "b": 4}]


def parse_row(line: str) -> dict:
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    bars, notes = [], []
    for c in cells:
        if not c:
            continue
        m = NOTE_CELL_RE.match(c)
        if m:
            note = m.group("note").strip()
            if not re.fullmatch(r"\d+\s*bars?", note, re.I):  # "(2 bars)" is a reading aid, not a cue
                notes.append(note)
        else:
            bars.append(parse_bar(c))
    return {"bars": bars, "lyrics": [], "note": "; ".join(notes)}


def parse_lead(path: Path) -> dict:
    lines = path.read_text(encoding="utf-8").splitlines()
    title = path.parent.name.replace("-", " ").title()
    tempo = key = None
    sections: list[dict] = []
    cur = None
    last_row = None

    for raw in lines:
        line = raw.rstrip()
        s = line.strip()
        if not s:
            continue
        if s.startswith("# ") and not s.startswith("## "):
            title = s[2:].strip()
            continue
        if cur is None and TEMPO_RE.search(s) and not s.startswith("|"):
            tempo = int(TEMPO_RE.search(s).group(1))
            km = KEY_RE.search(s)
            key = km.group(1).replace(" ", "") if km else None
            continue
        if s.startswith("## "):
            m = SECTION_RE.match(s)
            name = m.group("name").strip() if m else s[3:].strip()
            cur = {
                "name": name,
                "from": int(m.group("a")) if m and m.group("a") else None,
                "to": int(m.group("b")) if m and m.group("b") else None,
                "rows": [],
                "notes": [],
            }
            sections.append(cur)
            last_row = None
            continue
        if cur is None:
            continue
        if s.startswith("|"):
            last_row = parse_row(s)
            cur["rows"].append(last_row)
            continue
        if set(s) <= {"-"}:  # '---' phrase separator
            last_row = None
            continue
        if last_row is not None:
            last_row["lyrics"].append(s)
        else:
            cur["notes"].append(s)

    meta = path.parent / "meta.md"
    meta_tempo = meta_key = None
    if meta.exists():
        mt = meta.read_text(encoding="utf-8")
        m = re.search(r"\*\*Tempo\*\*:\s*(\d+)", mt)
        meta_tempo = int(m.group(1)) if m else None
        m = re.search(r"\*\*Key\*\*:\s*([^\n]+)", mt)
        meta_key = m.group(1).strip() if m else None

    return {
        "slug": path.parent.name,
        "title": title,
        "bpm": tempo or meta_tempo or 120,
        "bpmSource": "lead.md" if tempo else ("meta.md" if meta_tempo else "default"),
        "metaBpm": meta_tempo,
        "key": meta_key or key or "",
        "sections": sections,
    }


def validate(song: dict) -> list[str]:
    problems = []
    if song["metaBpm"] and song["bpmSource"] == "lead.md" and song["metaBpm"] != song["bpm"]:
        problems.append(f"tempo: lead.md says {song['bpm']}, meta.md says {song['metaBpm']} (using lead.md)")
    expected_next = 1
    for sec in song["sections"]:
        n = sum(len(r["bars"]) for r in sec["rows"])
        if sec["from"] is not None:
            want = sec["to"] - sec["from"] + 1
            if n != want:
                problems.append(f"{sec['name']} (bars {sec['from']}-{sec['to']}): heading says {want} bars, chart has {n}")
            if sec["from"] != expected_next:
                problems.append(f"{sec['name']}: starts at bar {sec['from']}, previous section ended at {expected_next - 1}")
            expected_next = sec["to"] + 1
        if not sec["rows"]:
            problems.append(f"{sec['name']}: no chord rows")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zip", action="store_true", help="also package app/ into dist/OO-Rehearsal.zip")
    ap.add_argument("--check", action="store_true", help="parse + validate only; write nothing")
    ap.add_argument("--songs", type=Path, default=DEFAULT_SONGS_DIR,
                    help="folder of <slug>/lead.md charts (default: ../songs)")
    args = ap.parse_args()

    songs_dir = args.songs.expanduser().resolve()
    if not songs_dir.is_dir():
        print(f"no songs folder at {songs_dir}; pass --songs DIR", file=sys.stderr)
        return 1

    songs = []
    for lead in sorted(songs_dir.glob("*/lead.md")):
        song = parse_lead(lead)
        if not song["sections"]:
            print(f"skip  {song['slug']}: no sections")
            continue
        bars = sum(len(r["bars"]) for s in song["sections"] for r in s["rows"])
        probs = validate(song)
        flag = "WARN" if probs else "ok  "
        print(f"{flag}  {song['slug']:<22} {song['bpm']:>3} bpm  {len(song['sections']):>2} sections  {bars:>3} bars")
        for p in probs:
            print(f"        - {p}")
        song.pop("metaBpm")
        songs.append(song)

    if args.check:
        return 0

    out = APP_DIR / "songs.js"
    payload = json.dumps(songs, ensure_ascii=False, indent=1)
    out.write_text(
        "// GENERATED by rehearsal/build.py from songs/*/lead.md. Do not edit; edit lead.md and rebuild.\n"
        f"window.SONGS = {payload};\n",
        encoding="utf-8",
    )
    print(f"wrote {out.relative_to(HERE)}  ({len(songs)} songs)")

    if args.zip:
        DIST_DIR.mkdir(exist_ok=True)
        z = DIST_DIR / "OO-Rehearsal.zip"
        with zipfile.ZipFile(z, "w", zipfile.ZIP_DEFLATED) as zf:
            for f in sorted(APP_DIR.rglob("*")):
                if f.is_file() and f.name not in (".DS_Store", "songs.example.js"):
                    zf.write(f, Path("OO-Rehearsal") / f.relative_to(APP_DIR))
        print(f"wrote {z.relative_to(HERE)}  ({z.stat().st_size // 1024} KB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
