#!/usr/bin/env bash
# Scenario tests for compare.py on synthetic measure.js output (no browser, no network).
# Pixel tests need Pillow; they are skipped (and say so) without it.
# Usage: bash test-compare.sh [path/to/compare.py]
set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/compare.py}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }
run() { OUT="$(python3 -I "$SCRIPT" "$@" 2>&1)"; RC=$?; }
has() { if printf '%s\n' "$OUT" | grep -qF -- "$2"; then ok "$1"; else bad "$1 (no line: $2)"; printf '%s\n' "$OUT" | sed 's/^/         | /'; fi }
status() { if [ "$RC" -eq "$2" ]; then ok "$1"; else bad "$1 (exit $RC, expected $2)"; printf '%s\n' "$OUT" | sed 's/^/         | /'; fi }

# make NAME [python statements that edit `run` before it is written]
make() {
	python3 -I - "$W/$1.json" "${2:-}" <<'PY'
import json, sys
out, edit = sys.argv[1], sys.argv[2]
def page(fp="f1"):
    return {"url": "http://localhost:8881/?vdiff=x", "status": 200, "finalPath": "/", "error404": False,
            "title": "Top", "height": 3000, "broken": [], "fingerprint": {"imgs": fp, "css": "c1"},
            "imgs": [{"src": "hero.webp", "current": "hero.webp", "w": 1280, "h": 520, "x": 0, "y": 136, "loaded": True},
                     {"src": "card.webp", "current": "card.webp", "w": 540, "h": 338, "x": 80, "y": 900, "loaded": True}]}
run = {"label": out.split("/")[-1][:-5], "dpr": 1, "pages": {"top@1280": page(), "top@390": page()}}
exec(edit)
json.dump(run, open(out, "w"))
PY
}

echo "compare.py"

make before
make after "for p in run['pages'].values(): p['fingerprint']['imgs'] = 'f2'"
run "$W/before.json" "$W/after.json" --no-pixels
status "same layout, changed image attributes: no visual difference" 0
has "notes that attributes changed but the display did not" "image attributes or CSS changed, display did not"

make same
run "$W/before.json" "$W/same.json" --no-pixels
status "identical DOM on every page is inconclusive" 3
has "asks to check the swap and the page cache" "Check that the swap took effect"
run "$W/before.json" "$W/same.json" --no-pixels --allow-same-dom
status "--allow-same-dom accepts an identical DOM" 0

make taller "run['pages']['top@390']['height'] = 3120"
run "$W/before.json" "$W/taller.json" --no-pixels
status "a different document height is a difference" 1
has "reports the height" "document height 3000 -> 3120"

make wider "run['pages']['top@1280']['imgs'][1]['w'] = 541.0"
run "$W/before.json" "$W/wider.json" --no-pixels
status "an image wider than the tolerance is a difference" 1
has "names the image and the change" "image 1 (card.webp): w 540 -> 541.0"
make nudged "run['pages']['top@1280']['imgs'][1]['w'] = 540.3; run['pages']['top@1280']['fingerprint']['imgs'] = 'f2'"
run "$W/before.json" "$W/nudged.json" --no-pixels
status "a change within the tolerance is not a difference" 0

make fewer "run['pages']['top@1280']['imgs'].pop()"
run "$W/before.json" "$W/fewer.json" --no-pixels
status "a different image count is a difference" 1

make broken "run['pages']['top@1280']['broken'] = ['logo.png']; run['pages']['top@1280']['fingerprint']['imgs'] = 'f2'"
run "$W/broken.json" "$W/after.json" --no-pixels
status "images that did not load make the comparison invalid" 2
has "names the broken image" "logo.png"
run "$W/broken.json" "$W/after.json" --no-pixels --allow-broken
status "--allow-broken compares anyway" 0

make notfound "run['pages']['top@390']['status'] = 404"
run "$W/before.json" "$W/notfound.json" --no-pixels
status "an HTTP 404 makes the comparison invalid" 2
make tmpl404 "run['pages']['top@390']['error404'] = True"
run "$W/tmpl404.json" "$W/after.json" --no-pixels
status "WordPress's 404 template makes the comparison invalid even with HTTP 200" 2
has "explains the 404 template" "404 template"

make onlyone "del run['pages']['top@390']"
run "$W/before.json" "$W/onlyone.json" --no-pixels
status "pages measured in only one run make the comparison invalid" 2

make redirected "run['pages']['top@390']['finalPath'] = '/shop/'; run['pages']['top@390']['fingerprint']['imgs'] = 'f2'"
run "$W/before.json" "$W/redirected.json" --no-pixels
status "a page that ended on a different path in one run makes the comparison invalid" 2
has "names both paths" "top@390: the runs ended on different pages (/ -> /shop/"

# The synthetic runs have no screenshots: without --no-pixels nothing could check the pixels.
run "$W/before.json" "$W/after.json"
status "a missing screenshot makes the comparison invalid, not a pass" 2
has "suggests --no-pixels" "screenshot missing (None) — pass --no-pixels"

if python3 -I -c 'import PIL' 2>/dev/null; then
	python3 -I - "$W" <<'PY'
import sys
from PIL import Image
w = sys.argv[1]
a = Image.new("RGB", (1280, 3000), "white")
a.save(f"{w}/a.png")
a.save(f"{w}/a-copy.png")
b = a.copy()
for x in range(100, 300):
    for y in range(950, 1000):
        b.putpixel((x, y), (255, 0, 0))
b.save(f"{w}/b.png")
c = a.copy()
for x in range(500, 520):
    for y in range(2000, 2010):
        c.putpixel((x, y), (255, 255, 215))
c.save(f"{w}/c.png")
PY
	make pixA "for p in run['pages'].values(): p['screenshot'] = '$W/a.png'"
	make pixSame "for p in run['pages'].values(): p['screenshot'] = '$W/a-copy.png'; p['fingerprint']['imgs'] = 'f2'"
	make pixB "for p in run['pages'].values(): p['screenshot'] = '$W/b.png'; p['fingerprint']['imgs'] = 'f2'"
	run "$W/pixA.json" "$W/pixSame.json"
	status "byte-identical screenshots are no difference" 0
	run "$W/pixA.json" "$W/pixB.json"
	status "differing pixels are a difference" 1
	has "says where and which image overlaps" "pixels differ at rows 950-999, x 100-299 (image: card.webp)"
	make pixC "for p in run['pages'].values(): p['screenshot'] = '$W/c.png'; p['fingerprint']['imgs'] = 'f2'"
	run "$W/pixA.json" "$W/pixC.json"
	status "a colour change that barely changes brightness is still a difference" 1
	has "and says where" "pixels differ at rows 2000-2009, x 500-519"
	has "flags a small change with no image under it as possible text noise" "may be text-rendering noise"
else
	echo "  skip - pixel tests (Pillow not installed)"
fi

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
