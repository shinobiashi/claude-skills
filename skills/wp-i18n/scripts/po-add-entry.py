#!/usr/bin/env python3
"""Add one translatable string to a .pot and a .po by hand, rebuild the .mo,
and check that the .mo changed by exactly that string.

Inside a feature PR, `msgmerge --update` against a .pot that has not been
regenerated for a while drops long-obsolete entries and rewraps the whole .po,
so one new string becomes a diff of 1000+ lines. This script adds only the new
entry instead:

  * finds where the string is used (`git grep` in the PHP files, skipping
    vendor/, node_modules/, test/ and tests/ like `wp i18n make-pot`), unless
    --ref is given;
  * inserts the entry next to the entry with the nearest earlier reference in
    the same source file, in each file's own style: one `#:` line per
    reference and no wrapping for a WP-CLI .pot, gettext wrapping at 79
    columns (`msgcat`) for a .po that Poedit or msgmerge wrapped;
  * adds `#, php-format` when the string has a sprintf placeholder, as
    `wp i18n make-pot` does, and checks the translation's placeholders with
    `msgfmt --check-format`;
  * rebuilds the .mo with `msgfmt` and compares it with the old .mo entry by
    entry; any difference besides the new string means the old .mo was not
    built from this .po, and nothing is written.

Nothing is written unless every check passes. Exit codes: 0 done (or would be
done, with --dry-run); 1 refused or a check failed, nothing written; 2 usage or
setup error.

Requires python3 and GNU gettext (msgfmt, msgcat).
"""

import argparse
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

GETTEXT_CALLS = (
    "__", "_e", "_x", "_ex", "_n", "_nx", "_n_noop", "_nx_noop",
    "esc_html__", "esc_html_e", "esc_html_x",
    "esc_attr__", "esc_attr_e", "esc_attr_x",
)
CALL_RE = r"\b(?:" + "|".join(GETTEXT_CALLS) + r")\s*\(\s*"

# Port of WP-CLI i18n-command's SPRINTF_PLACEHOLDER_REGEX, which decides
# whether `wp i18n make-pot` writes `#, php-format`.
PLACEHOLDER_RE = re.compile(
    r"(?<!%)(%(?:[0-9]+\$)?[+-]?"
    r"(?:(?:0|'.)?-?[0-9]*(?:\.[0-9]+)?|(?:[ ])?-?[0-9]+(?:\.[0-9]+)?)"
    r"[bcdeEfFgGosuxX])"
)

EXCLUDED_DIRS = ("vendor", "node_modules", "test", "tests")

KEYWORD_RE = re.compile(r'^(msgctxt|msgid_plural|msgid|msgstr(?:\[(\d+)\])?)\s+(".*")\s*$')
STRING_RE = re.compile(r'^\s*(".*")\s*$')


class Refused(Exception):
    """A check failed; nothing is written (exit 1)."""


class SetupError(Exception):
    """Bad arguments or environment (exit 2)."""


# ---- PO strings ------------------------------------------------------------

def unquote(token):
    body = token[1:-1]
    out = []
    i = 0
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body):
            n = body[i + 1]
            out.append({"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}.get(n, "\\" + n))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def quote(text):
    return '"' + (
        text.replace("\\", "\\\\").replace('"', '\\"')
        .replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r")
    ) + '"'


# ---- PO files --------------------------------------------------------------

class Entry(object):
    def __init__(self, start, end):
        self.start = start          # index of the entry's first line
        self.end = end              # index just after its last line
        self.ctx = None
        self.msgid = None
        self.plural = None
        self.msgstrs = {}
        self.refs = []              # (path, line or None)
        self.obsolete = False
        self.width_wrapped = False  # a string split for width, not at "\n"


class PoFile(object):
    def __init__(self, path):
        self.path = path
        with open(path, encoding="utf-8", newline="") as fh:
            self.text = fh.read()
        self.newline = "\r\n" if "\r\n" in self.text else "\n"
        self.lines = self.text.splitlines(True)
        self.entries = []
        self.header = None
        self._parse()

    def _parse(self):
        start = None
        for i, line in enumerate(self.lines + [""]):
            if line.strip() == "":
                if start is not None:
                    self._parse_block(start, i)
                    start = None
            elif start is None:
                start = i

    def _parse_block(self, start, end):
        e = Entry(start, end)
        block = self.lines[start:end]
        if all(l.startswith("#") for l in block):
            if any(l.startswith("#~") for l in block):
                e.obsolete = True
                self.entries.append(e)
            return  # a comment-only block (e.g. the file's leading comments)
        current = None
        pieces = []

        def flush():
            if current is None:
                return
            value = "".join(unquote(p) for p in pieces)
            # `msgid ""` followed by pieces split only after "\n" is how every
            # tool writes a multi-line string; only a split elsewhere is wrapping.
            inner = [unquote(p) for p in pieces[:-1] if unquote(p) != ""]
            if any(not p.endswith("\n") for p in inner):
                e.width_wrapped = True
            kw, index = current
            if kw == "msgctxt":
                e.ctx = value
            elif kw == "msgid":
                e.msgid = value
            elif kw == "msgid_plural":
                e.plural = value
            else:
                e.msgstrs[index] = value

        for line in block:
            s = line.rstrip("\r\n")
            if s.startswith("#:"):
                for token in s[2:].split():
                    path, sep, num = token.rpartition(":")
                    if sep and num.isdigit():
                        e.refs.append((path, int(num)))
                    else:
                        e.refs.append((token, None))
                continue
            if s.startswith("#"):
                continue
            m = KEYWORD_RE.match(s)
            if m:
                flush()
                kw = m.group(1)
                current = ("msgstr", int(m.group(2) or 0)) if kw.startswith("msgstr") else (kw, None)
                pieces = [m.group(3)]
                continue
            m = STRING_RE.match(s)
            if m and current is not None:
                pieces.append(m.group(1))
                continue
            raise SetupError("%s:%d: cannot parse this line: %s" % (self.path, start + block.index(line) + 1, s))
        flush()
        if e.msgid == "" and e.ctx is None and self.header is None:
            self.header = e
            return
        self.entries.append(e)

    def live_entries(self):
        return [e for e in self.entries if not e.obsolete]

    def find(self, msgid, ctx):
        for e in self.live_entries():
            if e.msgid == msgid and e.ctx == ctx:
                return e
        return None

    def header_value(self, name):
        if self.header is None:
            return None
        for line in self.header.msgstrs.get(0, "").split("\n"):
            key, sep, value = line.partition(":")
            if sep and key.strip().lower() == name.lower():
                return value.strip()
        return None

    def nplurals(self):
        m = re.search(r"nplurals\s*=\s*(\d+)", self.header_value("Plural-Forms") or "")
        return int(m.group(1)) if m else 2

    def charset(self):
        m = re.search(r"charset\s*=\s*([\w-]+)", self.header_value("Content-Type") or "")
        return m.group(1).upper() if m else None

    def is_width_wrapped(self):
        return any(e.width_wrapped for e in self.live_entries())

    def position_for(self, refs, after_msgid):
        """Return (line index to insert at, the neighbouring entry or None, 'after'/'before'/'end')."""
        live = self.live_entries()
        if after_msgid is not None:
            for e in live:
                if e.msgid == after_msgid:
                    return e.end, e, "after"
            raise SetupError("--after: %s has no entry %s" % (self.path, quote(after_msgid)))
        if refs:
            path, line = refs[0]
            best = None
            best_line = None
            first_later = None
            for e in live:
                for rpath, rline in e.refs:
                    if rpath != path:
                        continue
                    if rline is not None and line is not None and rline > line:
                        if first_later is None:
                            first_later = e
                        continue
                    key = rline if rline is not None else -1
                    if best is None or key >= best_line:
                        best, best_line = e, key
            if best is not None:
                return best.end, best, "after"
            if first_later is not None:
                return first_later.start, first_later, "before"
        obsolete = [e for e in self.entries if e.obsolete]
        if obsolete:
            return obsolete[0].start, obsolete[0], "before"
        return len(self.lines), None, "end"

    def with_block(self, block_lines, index, how):
        nl = self.newline
        block = [l.rstrip("\n") + nl for l in block_lines]
        lines = list(self.lines)
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += nl
        if how == "before":
            new = lines[:index] + block + [nl] + lines[index:]
        elif index > 0 and lines[index - 1].strip() == "":
            new = lines[:index] + block + lines[index:]
        else:
            new = lines[:index] + [nl] + block + lines[index:]
        return "".join(new)


# ---- the entry -------------------------------------------------------------

def entry_lines(args, refs, msgstrs, flag):
    out = []
    if args.comment:
        out += ["#. " + c for c in args.comment.split("\n")]
    for path, line in refs:
        out.append("#: %s" % path if line is None else "#: %s:%d" % (path, line))
    if flag:
        out.append("#, php-format")
    if args.context is not None:
        out.append("msgctxt " + quote(args.context))
    out.append("msgid " + quote(args.msgid))
    if args.msgid_plural is not None:
        out.append("msgid_plural " + quote(args.msgid_plural))
        for i, s in enumerate(msgstrs):
            out.append("msgstr[%d] %s" % (i, quote(s)))
    else:
        out.append("msgstr " + quote(msgstrs[0]))
    return out


def mini_po(block_lines, extra_header=""):
    return (
        'msgid ""\nmsgstr ""\n"Content-Type: text/plain; charset=UTF-8\\n"\n'
        + extra_header + "\n" + "\n".join(block_lines) + "\n"
    )


def gettext_wrap(block_lines, tmp):
    """Rewrap the entry the way msgmerge/Poedit do (79 columns)."""
    src = os.path.join(tmp, "wrap-in.po")
    dst = os.path.join(tmp, "wrap-out.po")
    with open(src, "w", encoding="utf-8") as fh:
        fh.write(mini_po(block_lines))
    run(["msgcat", "--width=79", "-o", dst, src], "msgcat could not wrap the new entry")
    with open(dst, encoding="utf-8") as fh:
        blocks = fh.read().strip("\n").split("\n\n")
    return blocks[-1].split("\n")


def mo_key(args):
    key = args.msgid
    if args.context is not None:
        key = args.context + "\x04" + key
    if args.msgid_plural is not None:
        key += "\x00" + args.msgid_plural
    return key.encode("utf-8")


def read_mo(path):
    with open(path, "rb") as fh:
        data = fh.read()
    if len(data) < 20:
        raise SetupError("%s is not a .mo file" % path)
    magic = struct.unpack("<I", data[:4])[0]
    order = "<" if magic == 0x950412DE else ">" if magic == 0xDE120495 else None
    if order is None:
        raise SetupError("%s is not a .mo file" % path)
    _, count, orig, trans = struct.unpack(order + "4I", data[4:20])
    out = {}
    for i in range(count):
        olen, ooff = struct.unpack(order + "2I", data[orig + 8 * i:orig + 8 * i + 8])
        tlen, toff = struct.unpack(order + "2I", data[trans + 8 * i:trans + 8 * i + 8])
        out[data[ooff:ooff + olen]] = data[toff:toff + tlen]
    return out


def short(key):
    text = key.decode("utf-8", "replace").replace("\x04", " | ").replace("\x00", " / ")
    return text if len(text) <= 70 else text[:67] + "..."


# ---- references ------------------------------------------------------------

def php_literals(text):
    single = "'" + text.replace("\\", "\\\\").replace("'", "\\'") + "'"
    double = '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$") + '"'
    return [single, double]


def find_refs(root, msgid):
    hits = []
    loose = []
    for literal in php_literals(msgid):
        proc = subprocess.run(
            # --untracked: the string is often in a file not added yet.
            ["git", "-C", root, "grep", "--untracked", "-n", "-F", "-e", literal, "--", "*.php"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
        )
        if proc.returncode not in (0, 1):
            raise SetupError("git grep failed in %s: %s (pass --ref)" % (root, proc.stderr.strip()))
        for row in proc.stdout.splitlines():
            path, _, rest = row.partition(":")
            num, _, code = rest.partition(":")
            if any(part in EXCLUDED_DIRS for part in path.split("/")[:-1]):
                continue
            line = int(num)
            if re.search(CALL_RE + re.escape(literal), code):
                hits.append((path, line))
                continue
            # `__(` alone on an earlier line: WP-CLI reports the call's line.
            call_line = call_line_above(os.path.join(root, path), line, literal)
            if call_line is not None:
                hits.append((path, call_line))
            else:
                loose.append("%s:%d" % (path, line))
    return sorted(set(hits)), loose


def call_line_above(path, line, literal):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().split("\n")
    except OSError:
        return None
    if not lines[line - 1].lstrip().startswith(literal):
        return None
    for back in range(line - 1, max(0, line - 4), -1):
        above = lines[back - 1]
        if re.search(CALL_RE + r"$", above.rstrip()):
            return back
        if above.strip():
            return None
    return None


def parse_ref(text):
    path, sep, num = text.rpartition(":")
    if sep and num.isdigit():
        return (path, int(num))
    return (text, None)


# ---- helpers -----------------------------------------------------------------

def run(cmd, what):
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    if proc.returncode != 0:
        raise Refused("%s:\n%s" % (what, proc.stderr.strip()))
    return proc.stdout


def describe(e, how, path):
    if e is None:
        return "at the end of %s" % path
    if e.obsolete:
        return "before the obsolete (#~) entries (line %d)" % (e.start + 1)
    return "%s %s (line %d)" % (how, quote(short(e.msgid.encode("utf-8"))), e.start + 1)


def main(argv):
    p = argparse.ArgumentParser(
        description="Add one string to a .pot and a .po by hand, rebuild the .mo, and check the .mo diff.",
    )
    p.add_argument("--msgid", required=True, help="the source string, as PHP passes it (unescaped)")
    p.add_argument("--msgid-plural", help="plural source string (_n / _nx)")
    p.add_argument("--context", help="msgctxt (_x / _nx)")
    p.add_argument("--comment", help='translator comment, e.g. "translators: %%s: order number"')
    p.add_argument("--ref", action="append", default=[], metavar="PATH:LINE",
                   help="source reference; repeatable (default: git grep the PHP files)")
    p.add_argument("--source-root", help="directory references are relative to (default: the git top level)")
    p.add_argument("--pot", help="template to add the entry to (left alone if it already has the entry)")
    p.add_argument("--po", help="translation to add the entry to (must not have it yet)")
    p.add_argument("--msgstr", action="append", default=[],
                   help="the translation; with --msgid-plural, once per plural form")
    p.add_argument("--mo", help="compiled file to rebuild (default: the .po with .mo)")
    p.add_argument("--no-mo", action="store_true", help="do not rebuild the .mo")
    p.add_argument("--after", metavar="MSGID", help="insert after this existing msgid instead of by reference")
    p.add_argument("--accept-mo-drift", action="store_true",
                   help="write the rebuilt .mo even when it differs from the old one by more than the new entry")
    p.add_argument("--dry-run", action="store_true", help="print what would change; write nothing")
    args = p.parse_args(argv)

    if not args.pot and not args.po:
        raise SetupError("give --pot, --po or both")
    if args.po and not args.msgstr:
        raise SetupError("--po needs --msgstr")
    if not args.po and args.msgstr:
        raise SetupError("--msgstr needs --po")
    if any(s == "" for s in args.msgstr):
        raise SetupError("--msgstr must not be empty (msgfmt leaves untranslated entries out of the .mo)")
    if args.msgid == "":
        raise SetupError("--msgid must not be empty")
    for tool in ["msgfmt"] + (["msgcat"] if args.po else []):
        if shutil.which(tool) is None:
            raise SetupError("%s not found (install GNU gettext, e.g. brew install gettext)" % tool)

    # References.
    if args.ref:
        refs = [parse_ref(r) for r in args.ref]
    else:
        root = args.source_root
        if root is None:
            proc = subprocess.run(["git", "rev-parse", "--show-toplevel"], stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, universal_newlines=True)
            if proc.returncode != 0:
                raise SetupError("not in a git repository; pass --ref or --source-root")
            root = proc.stdout.strip()
        refs, loose = find_refs(root, args.msgid)
        for where in loose:
            print("note: %s has the string, but not as the first argument of a gettext call; not used" % where)
        if not refs:
            raise SetupError("could not find %s in a gettext call in the PHP files under %s; pass --ref PATH:LINE"
                             % (quote(args.msgid), root))
    flag = bool(PLACEHOLDER_RE.search(args.msgid) or
                (args.msgid_plural is not None and PLACEHOLDER_RE.search(args.msgid_plural)))

    tmp = tempfile.mkdtemp(prefix="po-add-entry-")
    try:
        writes = []   # (path, text or None, source file for binary copy or None)
        report = []

        # .pot
        if args.pot:
            pot = PoFile(args.pot)
            if pot.charset() not in (None, "UTF-8"):
                raise SetupError("%s is not UTF-8" % args.pot)
            if pot.find(args.msgid, args.context) is not None:
                report.append("pot: %s already has this entry; left alone" % args.pot)
            else:
                n = 2 if args.msgid_plural is not None else 1
                lines = entry_lines(args, refs, [""] * n, flag)
                if pot.is_width_wrapped():
                    lines = gettext_wrap(lines, tmp)
                index, near, how = pot.position_for(refs, args.after)
                text = pot.with_block(lines, index, how)
                check_syntax(text, tmp, os.path.basename(args.pot))
                writes.append((args.pot, text, None))
                report.append("pot: added to %s %s" % (args.pot, describe(near, how, args.pot)))
                report.append("\n".join("     | " + l for l in lines))

        # .po and .mo
        if args.po:
            po = PoFile(args.po)
            if po.charset() not in (None, "UTF-8"):
                raise SetupError("%s is not UTF-8" % args.po)
            existing = po.find(args.msgid, args.context)
            if existing is not None:
                raise Refused("%s already has this entry (msgstr %s); edit it by hand"
                              % (args.po, quote(existing.msgstrs.get(0, ""))))
            if args.msgid_plural is not None and len(args.msgstr) != po.nplurals():
                raise SetupError("%s has nplurals=%d; give --msgstr %d times"
                                 % (args.po, po.nplurals(), po.nplurals()))
            if args.msgid_plural is None and len(args.msgstr) != 1:
                raise SetupError("give --msgstr once (or use --msgid-plural)")
            lines = entry_lines(args, refs, args.msgstr, flag)
            if po.is_width_wrapped():
                lines = gettext_wrap(lines, tmp)
            # Check the translation's placeholders against the source on the
            # entry alone, so an old problem elsewhere in the file can't block it.
            check_format(lines, po, tmp)
            index, near, how = po.position_for(refs, args.after)
            text = po.with_block(lines, index, how)
            new_po = os.path.join(tmp, "new.po")
            with open(new_po, "w", encoding="utf-8", newline="") as fh:
                fh.write(text)
            writes.append((args.po, text, None))
            report.append("po:  added to %s %s" % (args.po, describe(near, how, args.po)))
            report.append("\n".join("     | " + l for l in lines))

            if not args.no_mo:
                mo = args.mo or re.sub(r"\.po$", "", args.po) + ".mo"
                new_mo = os.path.join(tmp, "new.mo")
                run(["msgfmt", "-o", new_mo, new_po], "msgfmt could not compile %s with the new entry" % args.po)
                after = read_mo(new_mo)
                expected_key = mo_key(args)
                expected_value = "\x00".join(args.msgstr).encode("utf-8")
                if after.get(expected_key) != expected_value:
                    raise Refused("the rebuilt .mo does not have the new entry as expected")
                if os.path.exists(mo):
                    before = read_mo(mo)
                    drift = mo_drift(before, after, expected_key)
                    if drift and not args.accept_mo_drift:
                        raise Refused(
                            "the rebuilt %s differs from the old one by more than the new entry, so the old "
                            ".mo was not built from this .po:\n%s\nNothing was written. Rebuild the .mo from "
                            "the .po in its own commit first, or pass --accept-mo-drift to include those "
                            "changes." % (mo, "\n".join(drift))
                        )
                    if drift:
                        report.append("mo:  rebuilt %s; it also changes %d other entries (--accept-mo-drift):\n%s"
                                      % (mo, len(drift), "\n".join(drift)))
                    else:
                        report.append("mo:  rebuilt %s; it differs from the old one by exactly the new entry" % mo)
                else:
                    report.append("mo:  created %s (there was no .mo to compare with)" % mo)
                writes.append((mo, None, new_mo))
                l10n = re.sub(r"\.po$", "", args.po) + ".l10n.php"
                if os.path.exists(l10n):
                    report.append("note: WordPress 6.5+ loads %s instead of the .mo; regenerate it with "
                                  "`wp i18n make-php %s`" % (l10n, os.path.dirname(args.po) or "."))

        print("references: " + " ".join("%s:%s" % (p_, l) if l is not None else p_ for p_, l in refs))
        if flag:
            print("flag: php-format (the string has a sprintf placeholder)")
        for line in report:
            print(line)
        if args.dry_run:
            print("dry run: nothing written")
            return 0
        for path, text, source in writes:
            if text is not None:
                with open(path, "w", encoding="utf-8", newline="") as fh:
                    fh.write(text)
            else:
                shutil.copyfile(source, path)
        print("written: " + " ".join(w[0] for w in writes))
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def mo_drift(before, after, expected_key):
    out = []
    for key in sorted(set(before) | set(after)):
        if key == expected_key and key not in before:
            continue
        if key not in after:
            out.append("  removed: " + short(key))
        elif key not in before:
            out.append("  added:   " + short(key))
        elif before[key] != after[key]:
            out.append("  changed: " + short(key) if key else "  changed: (header)")
    return out


def check_syntax(text, tmp, name):
    path = os.path.join(tmp, name)
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)
    run(["msgfmt", "-o", os.devnull, path], "msgfmt rejected %s with the new entry" % name)


def check_format(lines, po, tmp):
    plural = po.header_value("Plural-Forms")
    extra = '"Plural-Forms: %s\\n"\n' % plural if plural else ""
    path = os.path.join(tmp, "entry.po")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(mini_po(lines, extra))
    run(["msgfmt", "--check-format", "-o", os.devnull, path],
        "msgfmt --check-format rejected the translation (its placeholders must match the source)")


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Refused as exc:
        print("refused: %s" % exc, file=sys.stderr)
        sys.exit(1)
    except SetupError as exc:
        print("error: %s" % exc, file=sys.stderr)
        sys.exit(2)
