#!/usr/bin/env python3
"""Compare two measure.js runs (before / after).

Usage:
  compare.py BEFORE.json AFTER.json [--tolerance 0.5] [--allow-broken] [--allow-same-dom] [--no-pixels]

Checks, in order:
  1. Preconditions on both runs (exit 2 when broken): the same pages were measured (the same
     keys, each with the same requested path and query apart from the vdiff cache buster), each
     page ended on the same path in both runs (a redirect in one run means two different pages),
     every page answered HTTP < 400, none is WordPress's 404 template, every image loaded (a
     page whose images 404 is already broken, and comparing two broken pages says nothing;
     --allow-broken to compare anyway), and every screenshot exists unless --no-pixels (a
     missing one would leave a CSS change unchecked).
  2. Layout: document height, image count, and each image's src and box (beyond --tolerance px).
  3. Pixels: the full-page screenshots, byte for byte, then (with Pillow) the rows that differ
     and the images that overlap them.
  4. Whether anything changed at all: when the layout and pixels are the same AND the <img>
     attributes and CSS fingerprints are identical on every page, the change may not have been
     applied (the swap did not take effect, or a page cache served the same HTML). That is
     exit 3 unless --allow-same-dom says the change is not expected to touch the DOM.

Exit: 0 no visual difference; 1 differences; 2 preconditions failed; 3 inconclusive (same DOM).
"""

import argparse
import json
import os
import sys
from urllib.parse import parse_qsl, urlencode, urlsplit


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def requested(page):
    """The requested path and query, without measure.js's vdiff cache buster (it differs per run).

    The query matters: /?p=12 and /?p=13 both end on the path /.
    """
    parts = urlsplit(page.get("url", ""))
    query = urlencode(sorted((k, v) for k, v in parse_qsl(parts.query, keep_blank_values=True) if k != "vdiff"))
    return parts.path + (f"?{query}" if query else "")


def preconditions(run, label, allow_broken):
    problems = []
    for key, page in sorted(run["pages"].items()):
        status = page.get("status")
        if status is None or status >= 400:
            problems.append(f"{label} {key}: HTTP {status} ({page.get('url', '')})")
        if page.get("error404"):
            problems.append(f"{label} {key}: WordPress served its 404 template (title: {page.get('title', '')})")
        broken = page.get("broken") or []
        if broken and not allow_broken:
            problems.append(f"{label} {key}: {len(broken)} image(s) did not load, e.g. {', '.join(broken[:3])}")
    return problems


def bands(channel_max, threshold=24, gap=3):
    """Row ranges where the per-pixel largest channel difference is above threshold."""
    gray = channel_max.point(lambda v: 255 if v > threshold else 0)
    width, height = gray.size
    rows = []
    for y in range(height):
        if gray.crop((0, y, width, y + 1)).getbbox():
            rows.append(y)
    out = []
    for y in rows:
        if out and y - out[-1][1] <= gap:
            out[-1][1] = y
        else:
            out.append([y, y])
    result = []
    for start, end in out:
        box = gray.crop((0, start, width, end + 1)).getbbox()
        result.append((start, end, box[0] if box else 0, box[2] if box else width))
    return result


def compare_pixels(before, after, imgs, dpr):
    a_path, b_path = before.get("screenshot"), after.get("screenshot")
    if not (a_path and b_path and os.path.exists(a_path) and os.path.exists(b_path)):
        return None, ["screenshot missing; pixels not compared"]
    with open(a_path, "rb") as fa, open(b_path, "rb") as fb:
        if fa.read() == fb.read():
            return True, []
    try:
        from PIL import Image, ImageChops  # noqa: PLC0415
    except ImportError:
        return False, ["screenshots differ (install Pillow to see where)"]
    a, b = Image.open(a_path).convert("RGB"), Image.open(b_path).convert("RGB")
    if a.size != b.size:
        return False, [f"screenshot sizes differ: {a.size} -> {b.size}"]
    diff = ImageChops.difference(a, b)
    if not diff.getbbox():
        return True, []
    # The largest of the R/G/B differences: a converted-to-gray difference hides colour changes
    # that barely change brightness (a resized photo differed by up to 49 in one channel and
    # stayed under the threshold in gray, so the change went unreported).
    red, green, blue = diff.split()
    channel_max = ImageChops.lighter(ImageChops.lighter(red, green), blue)
    notes = []
    found = bands(channel_max)
    if not found:
        x0, y0, x1, y1 = channel_max.getbbox()
        found = [(y0, y1 - 1, x0, x1)]
    for start, end, x0, x1 in found[:12]:
        y0, y1 = start / dpr, end / dpr
        hits = [
            i["current"] or i["src"]
            for i in imgs
            if i["y"] <= y1 and i["y"] + i["h"] >= y0 and i["x"] <= x1 / dpr and i["x"] + i["w"] >= x0 / dpr
        ]
        where = f"rows {int(y0)}-{int(y1)}, x {int(x0 / dpr)}-{int((x1 - 1) / dpr)}"
        if hits:
            hint = f" (image: {', '.join(hits[:3])})"
        elif end - start <= 12:
            # Japanese text rendered with web-font subsets can differ by a few pixels between
            # runs of the same page (seen on two runs of the same commit).
            hint = " (no image here, small: may be text-rendering noise — measure the same state twice to check)"
        else:
            hint = ""
        notes.append(f"pixels differ at {where}{hint}")
    return False, notes


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("before")
    ap.add_argument("after")
    ap.add_argument("--tolerance", type=float, default=0.5)
    ap.add_argument("--allow-broken", action="store_true")
    ap.add_argument("--allow-same-dom", action="store_true")
    ap.add_argument("--no-pixels", action="store_true")
    args = ap.parse_args(argv)

    before, after = load(args.before), load(args.after)
    problems = []
    missing = sorted(set(before["pages"]) ^ set(after["pages"]))
    if missing:
        problems.append(f"pages measured in only one run: {', '.join(missing)}")
    for key in sorted(set(before["pages"]) & set(after["pages"])):
        req_b, req_a = requested(before["pages"][key]), requested(after["pages"][key])
        if req_b != req_a:
            problems.append(f"{key}: the runs measured different URLs ({req_b} -> {req_a})")
        path_b, path_a = before["pages"][key].get("finalPath"), after["pages"][key].get("finalPath")
        if path_b != path_a:
            problems.append(f"{key}: the runs ended on different pages ({path_b} -> {path_a}; a redirect in one of them)")
    problems += preconditions(before, before.get("label", "before"), args.allow_broken)
    problems += preconditions(after, after.get("label", "after"), args.allow_broken)
    if not args.no_pixels:
        for run in (before, after):
            for key, page in sorted(run["pages"].items()):
                shot = page.get("screenshot")
                if not (shot and os.path.exists(shot)):
                    problems.append(
                        f"{run.get('label')} {key}: screenshot missing ({shot}) — pass --no-pixels to compare the layout only"
                    )
    if problems:
        print("## Cannot compare (exit 2)")
        for p in problems:
            print(f"- {p}")
        return 2

    differences = 0
    same_dom = True
    print(f"## {before.get('label')} -> {after.get('label')}")
    for key in sorted(before["pages"]):
        b, a = before["pages"][key], after["pages"][key]
        notes = []
        if b["height"] != a["height"]:
            notes.append(f"document height {b['height']} -> {a['height']}")
        if len(b["imgs"]) != len(a["imgs"]):
            notes.append(f"image count {len(b['imgs'])} -> {len(a['imgs'])}")
        else:
            for n, (i, j) in enumerate(zip(b["imgs"], a["imgs"])):
                if i["src"] != j["src"]:
                    notes.append(f"image {n}: src {i['src']} -> {j['src']}")
                    continue
                moved = [f for f in ("w", "h", "x", "y") if abs(i[f] - j[f]) > args.tolerance]
                if moved:
                    detail = ", ".join(f"{f} {i[f]} -> {j[f]}" for f in moved)
                    notes.append(f"image {n} ({i['src']}): {detail}")
        pixel_same = None
        if not args.no_pixels:
            pixel_same, pixel_notes = compare_pixels(b, a, a["imgs"], float(after.get("dpr", 1)))
            if not pixel_same:
                notes += pixel_notes
        fp_b, fp_a = b.get("fingerprint", {}), a.get("fingerprint", {})
        dom_changed = fp_b != fp_a
        if dom_changed:
            same_dom = False
        if notes:
            differences += 1
            print(f"- **{key}**: {len(notes)} difference(s)")
            for n in notes:
                print(f"  - {n}")
        else:
            extra = " (image attributes or CSS changed, display did not)" if dom_changed else ""
            pix = "" if pixel_same else " (pixels not compared)" if pixel_same is None else ""
            print(f"- {key}: no difference{extra}{pix}")
    if differences:
        print(f"\n{differences} page/width combination(s) differ (exit 1)")
        return 1
    if same_dom and not args.allow_same_dom:
        print(
            "\nInconclusive (exit 3): the <img> attributes and the CSS are identical in both runs on every page. "
            "Check that the swap took effect and that no page cache served the same HTML, "
            "or pass --allow-same-dom when the change is not expected to touch the DOM."
        )
        return 3
    print("\nNo visual difference (exit 0)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
