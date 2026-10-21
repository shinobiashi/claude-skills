#!/usr/bin/env python3
"""Generate the internal-license mu-plugin for a plugin that bundles the WooCommerce API Manager client.

Reads the plugin's `new WC_AM_Client_X_Y_Z( ... )` call, fills templates/internal-license.php and writes the
mu-plugin. Values that cannot be read from the call (or that you want to override) come from the options.

Usage:
  generate.py --plugin-dir DIR [--product-id N] [--out FILE] [--check] [overrides...]

Overrides: --slug, --main-file, --title, --api-url, --key-constant, --settings-page, --package.
--verify-mock FILE also writes a temporary mu-plugin that answers for the store on a development site.

Exit status: 0 written (or --check matched), 1 --check found a difference, 2 bad input.
"""

import argparse
import difflib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import urlparse

TEMPLATE_VERSION = "1.0.0"
HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE = os.path.join(HERE, "..", "templates", "internal-license.php")
MOCK_TEMPLATE = os.path.join(HERE, "..", "templates", "verify-mock.php")

# Constructor arguments of WC_AM_Client 2.x, in order.
ARG_NAMES = [
    "file",
    "product_id",
    "product_parent_id",
    "software_version",
    "plugin_or_theme",
    "api_url",
    "software_title",
    "text_domain",
    "custom_menu",
    "inactive_notice",
]


class InputError(Exception):
    pass


def find_main_file(plugin_dir, main_file):
    if main_file:
        path = os.path.join(plugin_dir, main_file)
        if not os.path.isfile(path):
            raise InputError(f"--main-file {main_file} does not exist in {plugin_dir}")
        return main_file
    found = []
    for name in sorted(os.listdir(plugin_dir)):
        if not name.endswith(".php"):
            continue
        with open(os.path.join(plugin_dir, name), encoding="utf-8", errors="replace") as fh:
            head = fh.read(8192)
        if re.search(r"^[ \t/*#@]*Plugin Name:", head, re.M):
            found.append(name)
    if len(found) != 1:
        raise InputError(
            "could not pick the main plugin file (found: %s); pass --main-file" % (", ".join(found) or "none")
        )
    return found[0]


def find_client_call(plugin_dir, main_file):
    """Return (path, argument source list) of the first `new WC_AM_Client_...(` call."""
    candidates = [os.path.join(plugin_dir, main_file)]
    for root, dirs, files in os.walk(plugin_dir):
        dirs[:] = [d for d in dirs if d not in ("vendor", "node_modules", ".git", "tests", "build", "dist")]
        for name in sorted(files):
            path = os.path.join(root, name)
            if name.endswith(".php") and path not in candidates:
                candidates.append(path)
    pattern = re.compile(r"new\s+(WC_AM_Client_\d+_\d+_\d+)\s*\(")
    for path in candidates:
        with open(path, encoding="utf-8", errors="replace") as fh:
            source = fh.read()
        match = pattern.search(source)
        if match:
            return path, match.group(1), split_args(source, match.end())
    raise InputError("no `new WC_AM_Client_X_Y_Z(` call found in the plugin")


def split_args(source, start):
    """Split the call's arguments at top-level commas, starting just after its opening parenthesis."""
    args, current, depth, quote, i = [], [], 0, None, start
    while i < len(source):
        ch = source[i]
        if quote:
            current.append(ch)
            if ch == "\\" and i + 1 < len(source):
                current.append(source[i + 1])
                i += 2
                continue
            if ch == quote:
                quote = None
        elif ch in ("'", '"'):
            quote = ch
            current.append(ch)
        elif ch in "([{":
            depth += 1
            current.append(ch)
        elif ch in ")]}":
            if depth == 0:
                tail = "".join(current).strip()
                if tail:
                    args.append(tail)
                return args
            depth -= 1
            current.append(ch)
        elif ch == "," and depth == 0:
            args.append("".join(current).strip())
            current = []
        else:
            current.append(ch)
        i += 1
    raise InputError("the WC_AM_Client call is not closed")


def php_string(arg):
    """Return the value of a plain single- or double-quoted PHP string literal, or None."""
    if arg is None:
        return None
    match = re.fullmatch(r"'((?:[^'\\]|\\.)*)'", arg, re.S)
    if match:
        return re.sub(r"\\([\\'])", r"\1", match.group(1))
    match = re.fullmatch(r'"([^"\\$]*)"', arg)
    if match:
        return match.group(1)
    return None


def default_key_constant(api_url):
    host = urlparse(api_url).hostname or ""
    host = re.sub(r"^www\.", "", host)
    labels = host.split(".")
    base = ".".join(labels[:-1]) if len(labels) > 1 else host
    name = re.sub(r"[^A-Za-z0-9]+", "_", base).strip("_").upper()
    if not name or name[0].isdigit():
        name = "WC_AM_" + name
    return name + "_INTERNAL_API_KEY"


def require(value, pattern, what):
    if not isinstance(value, str) or not re.fullmatch(pattern, value):
        raise InputError(f"{what} {value!r} is not allowed (must match {pattern})")
    return value


def build(opts):
    plugin_dir = os.path.abspath(os.path.expanduser(opts.plugin_dir))
    if not os.path.isdir(plugin_dir):
        raise InputError(f"--plugin-dir {opts.plugin_dir} is not a directory")

    main_file = find_main_file(plugin_dir, opts.main_file)
    path, client_class, raw = find_client_call(plugin_dir, main_file)
    call = dict(zip(ARG_NAMES, raw))

    if php_string(call.get("plugin_or_theme")) != "plugin":
        raise InputError(f"{client_class} in {path} is not created for a plugin; themes are not supported")

    raw_id = (call.get("product_id") or "").strip()
    if raw_id.lower() == "null" or raw_id in ("''", '""', "0", ""):
        client_has_product_id = False
        # Without a product ID the client names its options after the folder of the file it is given, which is
        # the plugin folder only for __FILE__ of the main file.
        file_arg = (call.get("file") or "").strip()
        if file_arg != "__FILE__" or os.path.abspath(path) != os.path.join(plugin_dir, main_file):
            raise InputError(
                f"the plugin passes no product ID and creates the client with {file_arg or '(nothing)'} in "
                f"{os.path.relpath(path, plugin_dir)}; the client then names its options after that file's folder, "
                f"which is supported only for __FILE__ in the main file {main_file}"
            )
        if opts.product_id is None:
            raise InputError("the plugin passes no product ID to the client; pass --product-id (the API Manager product ID)")
        product_id = opts.product_id
    elif re.fullmatch(r"\d+", raw_id):
        client_has_product_id = True
        product_id = int(raw_id)
        if opts.product_id is not None and opts.product_id != product_id:
            raise InputError(f"--product-id {opts.product_id} differs from the ID the plugin passes to the client ({product_id})")
    else:
        raise InputError(f"unsupported product ID argument {raw_id!r} (only null or an integer literal)")
    if product_id <= 0:
        raise InputError("--product-id must be a positive integer")

    api_url = opts.api_url or php_string(call.get("api_url"))
    if not api_url:
        raise InputError(f"the API URL argument {call.get('api_url')!r} is not a string literal; pass --api-url")
    require(api_url, r"https://[A-Za-z0-9.-]+(:\d+)?(/[A-Za-z0-9._~/-]*)?", "API URL")

    title = opts.title or php_string(call.get("software_title"))
    if not title:
        raise InputError(f"the title argument {call.get('software_title')!r} is not a string literal; pass --title")
    require(title, r"[A-Za-z0-9 ._()&+-]{1,80}", "title")

    settings_page = opts.settings_page
    custom_menu = (call.get("custom_menu") or "").strip()
    if settings_page is None and custom_menu and re.sub(r"\s", "", custom_menu) not in ("array()", "[]"):
        match = re.search(r"['\"]menu_slug['\"]\s*=>\s*('[^']*'|\"[^\"$]*\")", custom_menu)
        if not match:
            raise InputError("the plugin passes a custom menu to the client; pass --settings-page with its menu slug")
        settings_page = php_string(match.group(1))
    settings_page = require(settings_page or "", r"[a-z0-9_-]{0,100}", "settings page slug")

    slug = require(opts.slug or os.path.basename(plugin_dir), r"[a-z0-9._-]+", "plugin slug")
    plugin_file = f"{slug}/{main_file}"
    require(plugin_file, r"[a-z0-9._-]+/[A-Za-z0-9._-]+\.php", "plugin file")

    key_constant = require(opts.key_constant or default_key_constant(api_url), r"[A-Z][A-Z0-9_]{2,100}", "key constant")
    package = require(opts.package or slug, r"[A-Za-z0-9._-]+", "package")

    values = {
        "TITLE": title,
        "API_HOST": urlparse(api_url).hostname,
        "API_URL": api_url,
        "TEMPLATE_VERSION": TEMPLATE_VERSION,
        "CLASS_VERSION": TEMPLATE_VERSION.replace(".", "_"),
        "KEY_CONSTANT": key_constant,
        "PACKAGE": package,
        "PLUGIN_FILE": plugin_file,
        "PRODUCT_ID": str(product_id),
        "CLIENT_HAS_PRODUCT_ID": "true" if client_has_product_id else "false",
        "SETTINGS_PAGE": settings_page,
        "SLUG": slug,
    }

    summary = [
        f"client       : {client_class} in {os.path.relpath(path, plugin_dir)}",
        f"plugin file  : {plugin_file}",
        f"product ID   : {product_id} ({'passed to the client' if client_has_product_id else 'supplied through wc_am_product_id_* because the plugin passes null'})",
        f"API URL      : {api_url}",
        f"key constant : {key_constant}",
        f"settings page: {settings_page or '(client default)'}",
    ]
    return values, slug, summary


def fill(template, values):
    with open(template, encoding="utf-8") as fh:
        text = fh.read()
    for name, value in values.items():
        text = text.replace("{{" + name + "}}", value)
    left = re.findall(r"\{\{[A-Z_]+\}\}", text)
    if left:
        raise InputError(
            f"placeholders left unfilled in {os.path.basename(template)}: " + ", ".join(sorted(set(left)))
        )
    return text


def php_lint(text):
    php = shutil.which("php")
    if not php:
        return "php not found; syntax not checked"
    with tempfile.NamedTemporaryFile("w", suffix=".php", delete=False, encoding="utf-8") as fh:
        fh.write(text)
        tmp = fh.name
    try:
        result = subprocess.run([php, "-l", tmp], capture_output=True, text=True)
    finally:
        os.unlink(tmp)
    if result.returncode != 0:
        raise InputError("generated file does not pass php -l:\n" + result.stdout + result.stderr)
    return "php -l: ok"


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--plugin-dir", required=True, help="plugin repository (its folder name is the slug unless --slug)")
    parser.add_argument("--product-id", type=int, help="API Manager product ID (required when the plugin passes null)")
    parser.add_argument("--out", help="output file (default: <slug>-internal-license.php in the current directory)")
    parser.add_argument("--check", action="store_true", help="compare with --out instead of writing; exit 1 on a difference")
    parser.add_argument("--slug", help="installed folder name of the plugin")
    parser.add_argument("--main-file", help="main plugin file name inside --plugin-dir")
    parser.add_argument("--title", help="product name (default: the client's software title)")
    parser.add_argument("--api-url", help="API Manager store URL (default: the client's API URL)")
    parser.add_argument("--key-constant", help="wp-config.php constant name (default: from the API host)")
    parser.add_argument("--settings-page", help="menu slug of the client's settings page when the plugin passes a custom menu")
    parser.add_argument("--package", help="@package tag (default: the slug)")
    parser.add_argument(
        "--verify-mock",
        metavar="FILE",
        help="also write the verification mock (a temporary mu-plugin answering for the store) to FILE",
    )
    opts = parser.parse_args(argv)

    try:
        values, slug, summary = build(opts)
        text = fill(TEMPLATE, values)
        lint = php_lint(text)
        mock = fill(MOCK_TEMPLATE, values) if opts.verify_mock else None
        if mock is not None:
            php_lint(mock)
    except InputError as err:
        print(f"ERROR: {err}", file=sys.stderr)
        return 2

    out = opts.out or f"{slug}-internal-license.php"
    print("\n".join(summary))
    print(lint)

    if mock is not None:
        os.makedirs(os.path.dirname(os.path.abspath(opts.verify_mock)), exist_ok=True)
        with open(opts.verify_mock, "w", encoding="utf-8") as fh:
            fh.write(mock)
        print(f"WROTE MOCK: {opts.verify_mock}")

    if opts.check:
        try:
            with open(out, encoding="utf-8") as fh:
                current = fh.read()
        except FileNotFoundError:
            print(f"DIFF: {out} does not exist")
            return 1
        if current == text:
            print(f"OK: {out} matches the template {TEMPLATE_VERSION}")
            return 0
        sys.stdout.writelines(difflib.unified_diff(current.splitlines(True), text.splitlines(True), out, "generated"))
        print(f"DIFF: {out} differs from the template {TEMPLATE_VERSION}")
        return 1

    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(text)
    print(f"WROTE: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
