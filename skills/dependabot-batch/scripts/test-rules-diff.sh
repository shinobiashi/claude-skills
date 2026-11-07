#!/usr/bin/env bash
# Scenario tests for rules-diff.py with stub tools in throwaway trees (no network, no real linters).
# The stubs answer from files in their tree, in the formats the real tools print. Each format
# was taken from a real run: ESLint 8 and 9, Stylelint 16, PHPCS 3, PHPStan 2, PHPUnit 9, Jest 30.
# Usage: bash test-rules-diff.sh [path/to/rules-diff.py]
set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/rules-diff.py}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; printf '%s\n' "${OUT:-}" | sed 's/^/         | /'; }
run() { OUT="$(python3 "$SCRIPT" "$@" 2>&1)"; RC=$?; }
has() { if printf '%s\n' "$OUT" | grep -qF -- "$2"; then ok "$1"; else bad "$1 (no line: $2)"; fi; }
hasnt() { if printf '%s\n' "$OUT" | grep -qF -- "$2"; then bad "$1 (unexpected line: $2)"; else ok "$1"; fi; }
status() { if [ "$RC" -eq "$2" ]; then ok "$1"; else bad "$1 (exit $RC, expected $2)"; fi; }

# A stub for tools with --print-config: answers from <tree>/stub/<tool>.json, or from
# <tree>/stub/<tool>-bundled.json when given --config, and fails when the file is missing.
stub_config_tool() { # stub_config_tool TREE TOOL
    mkdir -p "$1/node_modules/.bin"
    cat >"$1/node_modules/.bin/$2" <<EOF
#!/bin/sh
root="\$(cd "\$(dirname "\$0")/../.." && pwd)"
for arg in "\$@"; do
    if [ "\$arg" = "--config" ]; then
        cat "\$root/stub/$2-bundled.json" 2>/dev/null || exit 2
        exit 0
    fi
done
if [ -f "\$root/stub/$2.json" ]; then
    cat "\$root/stub/$2.json"
    exit 0
fi
echo "Could not find config" >&2
exit 2
EOF
    chmod +x "$1/node_modules/.bin/$2"
}

new_tree() { # new_tree NAME: files of each kind, a linter stub, dependencies not under git.
    local t="$W/$1"
    mkdir -p "$t/src" "$t/stub" "$t/vendor/lib" "$t/assets/build"
    printf '{"scripts":{"lint:js":"wp-scripts lint-js","lint:css":"wp-scripts lint-style"}}\n' >"$t/package.json"
    : >"$t/src/app.tsx"
    : >"$t/src/app.test.tsx"
    : >"$t/src/style.scss"
    : >"$t/webpack.config.js"
    : >"$t/.eslintrc.js"
    : >"$t/vendor/lib/skip.js"
    git -C "$t" init --quiet
    git -C "$t" add package.json src webpack.config.js .eslintrc.js
    stub_config_tool "$t" eslint
    stub_config_tool "$t" stylelint
    printf '%s' "$t"
}

fresh() { rm -rf "$W/base" "$W/head"; BASE="$(new_tree base)"; HEAD="$(new_tree head)"; }
eslint_rules() { # eslint_rules TREE JSON
    printf '{"rules":%s}\n' "$2" >"$1/stub/eslint.json"
}
ES() { run --base "$BASE" --head "$HEAD" --only eslint "$@"; }

echo "rules-diff.py"

echo "== eslint: rule states"
fresh
eslint_rules "$BASE" '{"a":"error","b":[2,{"x":1}],"c":"off"}'
eslint_rules "$HEAD" '{"a":[2],"b":["error",{"x":1}],"c":0}'
ES --sample src/app.tsx
status "the same rules in other spellings are no difference" 0
has "reads as the same" "[SAME] eslint: src/app.tsx"
has "counts the active rules" "active rules: base 2, head 2"

eslint_rules "$BASE" '{"keep":"error","gone":"error","off-now":"warn","removed-entry":[2]}'
eslint_rules "$HEAD" '{"keep":"error","off-now":"off","new":"error"}'
ES --sample src/app.tsx
status "a lost rule exits 1" 1
has "lists what was lost" "LOST (3): gone off-now removed-entry"
has "lists what was gained" "gained (1): new"

eslint_rules "$BASE" '{"a":"error"}'
eslint_rules "$HEAD" '{"a":"warn"}'
ES --sample src/app.tsx
status "error to warn exits 1" 1
has "reads as weakened" "WEAKENED error->warn (1): a"

eslint_rules "$BASE" '{"a":"warn"}'
eslint_rules "$HEAD" '{"a":"error"}'
ES --sample src/app.tsx
status "warn to error is not a loss" 0

eslint_rules "$BASE" '{"a":["error",{"x":1}]}'
eslint_rules "$HEAD" '{"a":["error",{"x":2}]}'
ES --sample src/app.tsx
status "changed options alone do not fail" 0
has "reads as changed" "[CHANGED] eslint"
has "names the rule" "OPTIONS changed (1): a"

# The text domain case: the rule survives, but the project's own option does not.
eslint_rules "$BASE" '{"@wordpress/i18n-text-domain":["error",{"allowedTextDomain":"my-plugin"}]}'
eslint_rules "$HEAD" '{"@wordpress/i18n-text-domain":["error"]}'
ES --sample src/app.tsx
status "a dropped option exits 1" 1
has "shows what was dropped" 'OPTIONS DROPPED: @wordpress/i18n-text-domain [{"allowedTextDomain": "my-plugin"}]'

echo "== eslint: where the config comes from"
fresh
eslint_rules "$BASE" '{"a":"error"}'
printf '{"rules":{"a":"error"}}\n' >"$HEAD/stub/eslint-bundled.json"
mkdir -p "$HEAD/node_modules/@wordpress/scripts/config"
: >"$HEAD/node_modules/@wordpress/scripts/config/eslint.config.cjs"
ES --sample src/app.tsx
status "falling back to the bundled config exits 1, even with equal rules" 1
has "says so" "CONFIG SOURCE: base uses project config, head uses wp-scripts' bundled eslint.config.cjs"
has "names the file nothing reads" "NOT READ: .eslintrc.js is still in the head tree"

# No project config on either side: a bundled file with another name is not the project losing its config.
fresh
rm "$BASE/.eslintrc.js" "$HEAD/.eslintrc.js"
for t in "$BASE" "$HEAD"; do
    printf '{"rules":{"a":"error"}}\n' >"$t/stub/eslint-bundled.json"
    mkdir -p "$t/node_modules/@wordpress/scripts/config"
done
: >"$BASE/node_modules/@wordpress/scripts/config/.eslintrc.js"
: >"$HEAD/node_modules/@wordpress/scripts/config/eslint.config.cjs"
ES --sample src/app.tsx
status "bundled on both sides under other names is no finding" 0
hasnt "no source change" "CONFIG SOURCE"
has "the names still show" "config: base uses wp-scripts' bundled .eslintrc.js, head uses wp-scripts' bundled eslint.config.cjs"

# Without wp-scripts in the lint command, the bundled config is not what runs.
fresh
eslint_rules "$BASE" '{"a":"error"}'
printf '{"rules":{"a":"error"}}\n' >"$HEAD/stub/eslint-bundled.json"
mkdir -p "$HEAD/node_modules/@wordpress/scripts/config"
: >"$HEAD/node_modules/@wordpress/scripts/config/eslint.config.cjs"
printf '{"scripts":{"lint:js":"eslint ."}}\n' >"$HEAD/package.json"
ES --sample src/app.tsx
status "no wp-scripts, no fallback: the probe failed" 1
has "reads as failed" "[FAILED] eslint: src/app.tsx"
has "says which side" "head: Could not find config"

fresh
eslint_rules "$BASE" '{"a":"error"}'
printf 'undefined\n' >"$HEAD/stub/eslint.json"
ES --sample src/app.tsx
status "a file that became ignored exits 1" 1
has "says it is ignored" "project config, file ignored"
has "the rules are lost" "LOST (1): a"

fresh
eslint_rules "$BASE" '{"a":"error"}'
printf 'not json' >"$HEAD/stub/eslint.json"
ES --sample src/app.tsx
status "garbage output is a failure, not a pass" 1
has "says so" "head: the output is not JSON"

fresh
rm "$BASE/node_modules/.bin/eslint" "$HEAD/node_modules/.bin/eslint"
ES --sample src/app.tsx
status "a tool package.json runs but nobody installed is a failure" 1
has "says what to do" "package.json runs it, but node_modules/.bin/eslint is missing"
has "and hints at the preparation" "hint: FAILED can also mean a CI preparation step was skipped"
printf '{"scripts":{"build":"webpack"}}\n' >"$BASE/package.json"
cp "$BASE/package.json" "$HEAD/package.json"
ES --sample src/app.tsx
status "a tool the project does not use is no finding" 0
has "reads as skipped" "[SKIPPED] eslint"
has "the summary lists it" "skipped=eslint"

echo "== samples"
fresh
eslint_rules "$BASE" '{"a":"error"}'
eslint_rules "$HEAD" '{"a":"error"}'
ES
has "picks a source file" "src/app.tsx"
has "picks a test file apart from it" "src/app.test.tsx"
hasnt "does not pick a dot file" ".eslintrc.js"
hasnt "does not pick a config file" "webpack.config.js"
hasnt "does not pick from vendor" "skip.js"
has "samples with the same answer print as one" "src/app.tsx, src/app.test.tsx"

echo "== stylelint"
fresh
printf '{"rules":{"a":["always"],"off-rule":null,"warned":["x",{"severity":"warning"}]}}\n' >"$BASE/stub/stylelint.json"
printf '{"rules":{"a":["always"],"off-rule":[null],"warned":["x",{"severity":"warning"}]}}\n' >"$HEAD/stub/stylelint.json"
run --base "$BASE" --head "$HEAD" --only stylelint
status "null and [null] are both off" 0
has "reads as the same" "[SAME] stylelint: src/style.scss"

printf '{"rules":{"a":["always"],"b":["x"]}}\n' >"$BASE/stub/stylelint.json"
printf '{"rules":{"a":null,"b":["x",{"severity":"warning"}]}}\n' >"$HEAD/stub/stylelint.json"
run --base "$BASE" --head "$HEAD" --only stylelint
status "turning a rule off exits 1" 1
has "lists it" "LOST (1): a"
has "a warning severity reads as weakened" "WEAKENED error->warn (1): b"

fresh
printf '{"rules":{"a":["always"]}}\n' >"$BASE/stub/stylelint-bundled.json"
cp "$BASE/stub/stylelint-bundled.json" "$HEAD/stub/stylelint-bundled.json"
for t in "$BASE" "$HEAD"; do
    mkdir -p "$t/node_modules/@wordpress/scripts/config"
    : >"$t/node_modules/@wordpress/scripts/config/.stylelintrc.json"
done
run --base "$BASE" --head "$HEAD" --only stylelint
status "the bundled config on both sides is no finding" 0
hasnt "no source change" "CONFIG SOURCE"

# A shared config can make every rule a warning without touching a single rule entry.
fresh
printf '{"rules":{"a":["always"],"b":["x",{"severity":"error"}]}}\n' >"$BASE/stub/stylelint.json"
printf '{"defaultSeverity":"warning","rules":{"a":["always"],"b":["x",{"severity":"error"}]}}\n' >"$HEAD/stub/stylelint.json"
run --base "$BASE" --head "$HEAD" --only stylelint
status "defaultSeverity warning exits 1" 1
has "the rules without a severity of their own read as weakened" "WEAKENED error->warn (1): a"

echo "== tsc"
fresh
stub_tsc() { # stub_tsc TREE JSON
    cat >"$1/node_modules/.bin/tsc" <<EOF
#!/bin/sh
cat <<'JSON'
$2
JSON
EOF
    chmod +x "$1/node_modules/.bin/tsc"
    : >"$1/tsconfig.json"
}
stub_tsc "$BASE" '{"compilerOptions":{"strict":true,"target":"es2020"},"files":["a.ts","b.ts"]}'
stub_tsc "$HEAD" '{"compilerOptions":{"strict":true,"target":"es2022"},"files":["a.ts","b.ts"]}'
run --base "$BASE" --head "$HEAD" --only tsc
status "a changed option does not fail by itself" 0
has "shows the change" "target: es2020 -> es2022"
stub_tsc "$HEAD" '{"compilerOptions":{"strict":false,"target":"es2020"},"files":["a.ts","b.ts"]}'
run --base "$BASE" --head "$HEAD" --only tsc
status "strict turned off exits 1" 1
has "reads as weakened, with the checks strict covered" "WEAKENED checks no longer on (10): strict noImplicitAny"
stub_tsc "$HEAD" '{"compilerOptions":{"strict":true,"noImplicitAny":false,"target":"es2020"},"files":["a.ts","b.ts"]}'
run --base "$BASE" --head "$HEAD" --only tsc
status "one check turned off under strict exits 1" 1
has "names it" "WEAKENED checks no longer on (1): noImplicitAny"
stub_tsc "$BASE" '{"compilerOptions":{"target":"es2020"},"files":["a.ts","b.ts"]}'
stub_tsc "$HEAD" '{"compilerOptions":{"strict":true,"target":"es2020"},"files":["a.ts","b.ts"]}'
run --base "$BASE" --head "$HEAD" --only tsc
status "strict turned on is no loss" 0
stub_tsc "$BASE" '{"compilerOptions":{"strict":true},"files":["a.ts","b.ts"]}'
stub_tsc "$HEAD" '{"compilerOptions":{"strict":true},"files":["a.ts"]}'
run --base "$BASE" --head "$HEAD" --only tsc
status "fewer files exits 1" 1
has "shows the count" "files: 2 -> 1"

echo "== jest"
fresh
stub_jest() { # stub_jest TREE EXIT LINES...
    local t="$1" rc="$2"
    shift 2
    {
        echo '#!/bin/sh'
        for line in "$@"; do echo "echo \"$t/$line\""; done
        echo "exit $rc"
    } >"$t/node_modules/.bin/jest"
    chmod +x "$t/node_modules/.bin/jest"
    : >"$t/jest.config.js"
}
stub_jest "$BASE" 0 src/a.test.ts src/b.test.ts
stub_jest "$HEAD" 0 src/a.test.ts src/b.test.ts
run --base "$BASE" --head "$HEAD" --only jest
status "the same tests in different roots are the same" 0
has "says these are files" "test files listed: base 2, head 2"
stub_jest "$HEAD" 0 src/a.test.ts
run --base "$BASE" --head "$HEAD" --only jest
status "a lost test exits 1" 1
has "names it" "LOST (1): src/b.test.ts"
stub_jest "$HEAD" 0
run --base "$BASE" --head "$HEAD" --only jest
status "no tests at all is a failure" 1
has "reads as failed" "[FAILED] jest"
rm "$HEAD/node_modules/.bin/jest"
run --base "$BASE" --head "$HEAD" --only jest
status "Jest gone from the head is a failure, not a skip" 1
has "says why" "not found"

fresh
run --base "$BASE" --head "$HEAD" --only jest
status "no Jest config is a skip" 0
has "says so" "no Jest config"

# Where else the config can be: a jest key in package.json, or wp-scripts' bundled config.
stub_jest_args() { # stub_jest_args TREE: lists one test and records the arguments it got
    cat >"$1/node_modules/.bin/jest" <<EOF
#!/bin/sh
printf '%s\n' "\$@" >"$1/jest-args"
echo "$1/src/a.test.ts"
EOF
    chmod +x "$1/node_modules/.bin/jest"
}
fresh
for t in "$BASE" "$HEAD"; do
    printf '{"scripts":{"test":"jest"},"jest":{"testMatch":["**/*.test.ts"]}}\n' >"$t/package.json"
    stub_jest_args "$t"
done
run --base "$BASE" --head "$HEAD" --only jest
status "a jest key in package.json is a config" 0
has "says where it came from" "[SAME] jest: jest (package.json)"
if [ ! -s "$HEAD/jest-args" ] || ! grep -q -- '--config' "$HEAD/jest-args"; then
    ok "and Jest is left to read the key itself"
else
    bad "and Jest is left to read the key itself"
fi

fresh
for t in "$BASE" "$HEAD"; do
    printf '{"scripts":{"test:unit":"wp-scripts test-unit-js"}}\n' >"$t/package.json"
    stub_jest_args "$t"
done
run --base "$BASE" --head "$HEAD" --only jest
status "wp-scripts with its bundled config missing is a failure, not a skip" 1
has "says what is missing" "jest-unit.config.js is missing"
if command -v node >/dev/null 2>&1; then
    for t in "$BASE" "$HEAD"; do
        mkdir -p "$t/node_modules/@wordpress/scripts/config"
        printf 'module.exports = { preset: "@wordpress/jest-preset-default" };\n' \
            >"$t/node_modules/@wordpress/scripts/config/jest-unit.config.js"
    done
    run --base "$BASE" --head "$HEAD" --only jest
    status "wp-scripts' bundled Jest config is used when the project has none" 0
    has "says so" "jest (wp-scripts' bundled jest-unit.config.js)"
    if grep -qF '{"preset":"@wordpress/jest-preset-default"}' "$HEAD/jest-args"; then
        ok "the config goes in as JSON, as wp-scripts passes it"
    else
        bad "the config goes in as JSON, as wp-scripts passes it"
    fi
else
    echo "  (node not found: the bundled Jest config cases are not run)"
fi

# A config the npm script hands over is what wp-scripts runs, not its bundled one.
fresh
for t in "$BASE" "$HEAD"; do
    printf '{"scripts":{"test:unit":"wp-scripts test-unit-js --config tests/js/jest.config.js"}}\n' >"$t/package.json"
    stub_jest_args "$t"
done
run --base "$BASE" --head "$HEAD" --only jest
status "the script's --config is compared" 0
has "and named" "jest (tests/js/jest.config.js)"
if grep -qx 'tests/js/jest.config.js' "$HEAD/jest-args"; then ok "and passed to Jest"; else bad "and passed to Jest"; fi

fresh
printf '{"scripts":{"test":"jest --ci"}}\n' >"$BASE/package.json"
run --base "$BASE" --head "$HEAD" --only jest
status "package.json runs Jest but no config is found: a failure" 1
has "says what to pass" "pass --jest-config"

echo "== playwright"
fresh
stub_playwright() { # stub_playwright TREE LINES...
    local t="$1"
    shift
    {
        echo '#!/bin/sh'
        echo 'echo "Listing tests:"'
        for line in "$@"; do echo "echo '  [chromium] › $line'"; done
        echo 'echo "Total: 2 tests in 1 file"'
    } >"$t/node_modules/.bin/playwright"
    chmod +x "$t/node_modules/.bin/playwright"
    : >"$t/playwright.config.ts"
}
stub_playwright "$BASE" "specs/a.spec.ts:10:5 › opens" "specs/a.spec.ts:20:5 › saves"
stub_playwright "$HEAD" "specs/a.spec.ts:12:5 › opens" "specs/a.spec.ts:22:5 › saves"
run --base "$BASE" --head "$HEAD" --only playwright
status "a moved test is the same test" 0
has "counts them" "tests listed: base 2, head 2"
hasnt "the total line is not a test" "Total"
stub_playwright "$HEAD" "specs/a.spec.ts:12:5 › opens"
run --base "$BASE" --head "$HEAD" --only playwright
status "a lost test exits 1" 1
has "names it" "specs/a.spec.ts › saves"
rm "$HEAD/node_modules/.bin/playwright"
run --base "$BASE" --head "$HEAD" --only playwright
status "Playwright gone from the head is a failure" 1
fresh
run --base "$BASE" --head "$HEAD" --only playwright
status "no Playwright config is a skip" 0
has "says so" "no Playwright config"

# wp-scripts test-playwright runs its bundled config when the project has none.
fresh
for t in "$BASE" "$HEAD"; do
    printf '{"scripts":{"test:e2e":"wp-scripts test-playwright"}}\n' >"$t/package.json"
done
run --base "$BASE" --head "$HEAD" --only playwright
status "wp-scripts' bundled Playwright config missing is a failure" 1
for t in "$BASE" "$HEAD"; do
    stub_playwright "$t" "specs/a.spec.ts:10:5 › opens"
    rm "$t/playwright.config.ts"
    printf 'printf "%%s\\n" "$@" >"%s/pw-args"\n' "$t" >>"$t/node_modules/.bin/playwright"
    mkdir -p "$t/node_modules/@wordpress/scripts/config"
    : >"$t/node_modules/@wordpress/scripts/config/playwright.config.js"
done
run --base "$BASE" --head "$HEAD" --only playwright
status "the bundled config lists the tests" 0
has "says which config" "playwright (wp-scripts' bundled playwright.config.js)"
if grep -qx 'node_modules/@wordpress/scripts/config/playwright.config.js' "$HEAD/pw-args"; then
    ok "and passes it as wp-scripts does"
else
    bad "and passes it as wp-scripts does"
fi
for t in "$BASE" "$HEAD"; do
    printf '{"scripts":{"test:e2e":"wp-scripts test-playwright --config tests/e2e/playwright.config.ts"}}\n' >"$t/package.json"
done
run --base "$BASE" --head "$HEAD" --only playwright
status "the script's --config is compared, not the bundled one" 0
has "and named" "playwright (tests/e2e/playwright.config.ts)"
if grep -qx 'tests/e2e/playwright.config.ts' "$HEAD/pw-args"; then ok "and passed to Playwright"; else bad "and passed to Playwright"; fi
run --base "$BASE" --head "$HEAD" --only playwright --playwright-config e2e/other.config.ts
has "--playwright-config wins" "playwright (e2e/other.config.ts)"
fresh
printf '{"scripts":{"test:e2e":"playwright test"}}\n' >"$BASE/package.json"
run --base "$BASE" --head "$HEAD" --only playwright
status "package.json runs Playwright but no config is found: a failure" 1
has "says what to pass" "pass --playwright-config"

echo "== phpcs"
fresh
run --base "$BASE" --head "$HEAD" --only phpcs
status "no PHPCS at all is a skip" 0
has "reads as skipped" "[SKIPPED] phpcs"
: >"$BASE/phpcs.xml.dist"
: >"$HEAD/phpcs.xml.dist"
run --base "$BASE" --head "$HEAD" --only phpcs
status "a PHPCS config with no phpcs is a skipped install, not a pass" 1
has "says so" "phpcs.xml.dist is here, but vendor/bin/phpcs is missing"
stub_phpcs() { # stub_phpcs TREE SNIFFS STANDARDS
    mkdir -p "$1/vendor/bin"
    cat >"$1/vendor/bin/phpcs" <<EOF
#!/bin/sh
if [ "\$1" = "-i" ]; then
    echo "The installed coding standards are $3"
    exit 0
fi
echo
echo "The Test standard contains 2 sniffs"
echo
echo "Generic (2 sniffs)"
echo "-------------------"
for s in $2; do echo "  \$s"; done
EOF
    chmod +x "$1/vendor/bin/phpcs"
}
stub_phpcs "$BASE" "Generic.A.B WordPress.Security.EscapeOutput" "PEAR, WordPress and WPCS"
stub_phpcs "$HEAD" "Generic.A.B WordPress.Security.EscapeOutput" "PEAR, WordPress and WPCS"
run --base "$BASE" --head "$HEAD" --only phpcs
status "the same sniffs" 0
has "counts them" "sniffs: base 2, head 2"
stub_phpcs "$HEAD" "Generic.A.B Woo.New.Sniff" "PEAR, WordPress and WPCS"
run --base "$BASE" --head "$HEAD" --only phpcs
status "a lost sniff exits 1" 1
has "names it" "LOST (1): WordPress.Security.EscapeOutput"
has "and what came in" "gained (1): Woo.New.Sniff"
stub_phpcs "$HEAD" "Generic.A.B WordPress.Security.EscapeOutput" "PEAR, WordPress"
run --base "$BASE" --head "$HEAD" --only phpcs
status "a lost standard exits 1" 1
has "names it" "LOST standards (1): WPCS"

echo "== phpstan"
fresh
mkdir -p "$BASE/vendor/bin"
printf '#!/bin/sh\n' >"$BASE/vendor/bin/phpstan"
chmod +x "$BASE/vendor/bin/phpstan"
run --base "$BASE" --head "$HEAD" --only phpstan
status "a tool only one tree has is a failure" 1
has "says so" "only one tree has it"
fresh
stub_phpstan() { # stub_phpstan TREE LEVEL RC
    mkdir -p "$1/vendor/bin"
    cat >"$1/vendor/bin/phpstan" <<EOF
#!/bin/sh
echo "Note: Using configuration file $1/phpstan.neon." >&2
[ "$3" -eq 0 ] || { echo "Scanned directory vendor-prefixed does not exist." >&2; exit $3; }
echo '{"level":$2,"paths":["$1/src"]}'
EOF
    chmod +x "$1/vendor/bin/phpstan"
}
stub_phpstan "$BASE" 6 0
stub_phpstan "$HEAD" 6 0
run --base "$BASE" --head "$HEAD" --only phpstan
status "paths under different roots are the same" 0
has "reads as the same" "level 6, same parameters"
stub_phpstan "$HEAD" 5 0
run --base "$BASE" --head "$HEAD" --only phpstan
status "a level change exits 1" 1
has "shows it" "level: 6 -> 5"
stub_phpstan "$HEAD" 6 1
run --base "$BASE" --head "$HEAD" --only phpstan
status "a probe failure exits 1" 1
has "skips the Note line for the real reason" "head: Scanned directory vendor-prefixed does not exist."

echo "== phpunit"
fresh
stub_phpunit() { # stub_phpunit TREE TESTS...
    local t="$1"
    shift
    mkdir -p "$t/vendor/bin"
    {
        echo '#!/bin/sh'
        echo 'echo "PHPUnit 9.6 by Sebastian Bergmann and contributors."'
        echo 'echo "Available test(s):"'
        for name in "$@"; do echo "echo ' - $name'"; done
    } >"$t/vendor/bin/phpunit"
    chmod +x "$t/vendor/bin/phpunit"
}
stub_phpunit "$BASE" "A::one" "A::two"
stub_phpunit "$HEAD" "A::one"
run --base "$BASE" --head "$HEAD" --only phpunit
status "a lost test exits 1" 1
has "names it" "LOST (1): - A::two"
hasnt "the banner is not a test" "Sebastian"

echo "== assets"
fresh
printf "<?php return array('dependencies' => array('react', 'wp-i18n'), 'version' => 'abc');\n" >"$BASE/assets/build/a.asset.php"
printf "<?php return ['dependencies' => ['wp-i18n', 'react'], 'version' => 'xyz'];\n" >"$HEAD/assets/build/a.asset.php"
run --base "$BASE" --head "$HEAD" --only assets
status "the same dependencies, another version hash and array syntax" 0
has "reads as the same" "1 entries, the same script dependencies"
printf "<?php return array('dependencies' => array('react', 'wp-url'), 'version' => 'xyz');\n" >"$HEAD/assets/build/a.asset.php"
printf "<?php return array('dependencies' => array('react'), 'version' => 'n');\n" >"$HEAD/assets/build/b.asset.php"
run --base "$BASE" --head "$HEAD" --only assets
status "a dependency change is for a person to read, not a failure" 0
has "shows the change" "a.asset.php: dependencies -['wp-i18n'] +['wp-url']"
has "shows a new entry" "b.asset.php: only in head"
rm "$BASE"/assets/build/*.php
run --base "$BASE" --head "$HEAD" --only assets
status "*.asset.php on one side only is a failure" 1
has "and says what to do" "only the head has *.asset.php: run the build in both trees"
rm "$HEAD"/assets/build/*.php
run --base "$BASE" --head "$HEAD" --only assets
status "no build output in a project that does not build is a skip" 0
printf '{"scripts":{"build":"wp-scripts build"}}\n' >"$BASE/package.json"
run --base "$BASE" --head "$HEAD" --only assets
status "no build output in a project that builds is a failure" 1
has "says what to do" "run the build in both trees, or pass --build-dir"

echo "== output"
fresh
python3 - "$BASE" "$HEAD" <<'PY'
import json, sys
rules = {f"rule-{i:03}": "error" for i in range(50)}
json.dump({"rules": rules}, open(f"{sys.argv[1]}/stub/eslint.json", "w"))
json.dump({"rules": {}}, open(f"{sys.argv[2]}/stub/eslint.json", "w"))
PY
ES --sample src/app.tsx
has "long lists are cut" "... and 10 more"
ES --sample src/app.tsx --full
hasnt "--full does not cut" "more"
run --base "$BASE" --head "$HEAD" --only eslint --sample src/app.tsx --json
if printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["eslint"][0]["data"]["lost"] else 1)'; then
    ok "--json is JSON and holds every name"
else
    bad "--json is JSON and holds every name"
fi

echo "== usage"
run --head "$HEAD"
status "--base is required" 2
run --base "$BASE" --head "$W/none"
status "a missing tree is an error" 2
has "names it" "no such directory"
run --base "$BASE" --head "$HEAD" --only nonsense
status "an unknown tool is an error" 2
run --help
status "--help exits 0" 0
has "--help shows the usage" "rules-diff.py --base DIR --head DIR"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
