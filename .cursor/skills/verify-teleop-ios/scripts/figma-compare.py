#!/usr/bin/env python3
"""Pair each Figma frame with its simulator screenshot by screen id and score the pixel diff.

Usage:
  figma-compare.py --figma DIR --shots DIR --out DIR [--threshold 0.10] [--only S1,P5]

--figma : files named <SCREEN_ID>.png (P1..P7, T1..T3, S1, S2, S3a, S3b, S3m, S4, S5, S5a, S6, S7)
--shots : simulator screenshots; the screen id is taken from the name, e.g. 06-S1-connect.png
Output  : <out>/<SCREEN_ID>-side-by-side.png (figma | sim | diff heatmap) and <out>/report.json, report.md
Score   : fraction of pixels whose max channel delta > 32 after resizing the shot to the frame size.
Exit 0 when every paired page is under the threshold, 1 otherwise, 2 when nothing could be paired.
"""
import argparse, json, re, sys
from pathlib import Path
import numpy as np
from PIL import Image

IDS = ["P1","P2","P3","P4","P5","P6","P7","T1","T2","T3","S1","S2","S3a","S3b","S3m","S4","S5","S5a","S6","S7"]
CANON = {i.lower(): i for i in IDS}

def screen_id(name):
    for tok in re.split(r"[-_ .]", Path(name).stem):
        if tok.lower() in CANON:
            return CANON[tok.lower()]
    return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--figma", required=True); ap.add_argument("--shots", required=True)
    ap.add_argument("--out", required=True); ap.add_argument("--threshold", type=float, default=0.10)
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    only = {s.strip() for s in a.only.split(",") if s.strip()}
    shots = {}
    for p in sorted(Path(a.shots).rglob("*.png")):
        sid = screen_id(p.name)
        if sid and sid not in shots:  # first (lowest-numbered) shot per screen wins
            shots[sid] = p
    rows = []
    for sid in IDS:
        if only and sid not in only: continue
        f = Path(a.figma) / f"{sid}.png"; s = shots.get(sid)
        if not f.exists() or s is None:
            rows.append({"screen": sid, "status": "MISSING", "figma": str(f) if f.exists() else None, "shot": str(s) if s else None}); continue
        fi = Image.open(f).convert("RGB"); si = Image.open(s).convert("RGB").resize(fi.size, Image.LANCZOS)
        d = np.abs(np.asarray(fi, np.int16) - np.asarray(si, np.int16)).max(axis=2)
        score = float((d > 32).mean())
        heat = Image.fromarray(np.where(d > 32, 255, d * 4).clip(0, 255).astype(np.uint8)).convert("RGB")
        w, h = fi.size; sbs = Image.new("RGB", (w * 3 + 20, h), "white")
        for i, im in enumerate((fi, si, heat)): sbs.paste(im, (i * (w + 10), 0))
        img = out / f"{sid}-side-by-side.png"; sbs.save(img)
        rows.append({"screen": sid, "status": "PASS" if score <= a.threshold else "FAIL", "score": round(score, 4),
                     "figma": str(f), "shot": str(s), "image": str(img)})
    (out / "report.json").write_text(json.dumps({"threshold": a.threshold, "pages": rows}, indent=2))
    md = ["| screen | status | diff score | image |", "|---|---|---|---|"]
    md += [f"| {r['screen']} | {r['status']} | {r.get('score','')} | {Path(r['image']).name if 'image' in r else ''} |" for r in rows]
    (out / "report.md").write_text("\n".join(md) + "\n"); print("\n".join(md))
    paired = [r for r in rows if r["status"] != "MISSING"]
    if not paired: return 2
    return 0 if all(r["status"] == "PASS" for r in paired) else 1

if __name__ == "__main__":
    sys.exit(main())
