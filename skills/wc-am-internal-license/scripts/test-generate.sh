#!/usr/bin/env bash
# Scenario tests for generate.py on throwaway plugin folders (no network, no WordPress).
# Usage: bash test-generate.sh [path/to/generate.py]
# The generated files are syntax-checked with php -l when php is on PATH.
set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/generate.py}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }
# run ARGS...: the output in $OUT, the exit status in $RC.
run() { OUT="$(python3 -I "$SCRIPT" "$@" 2>&1)"; RC=$?; }
has() { if printf '%s\n' "$OUT" | grep -qF -- "$2"; then ok "$1"; else bad "$1 (no line: $2)"; printf '%s\n' "$OUT" | sed 's/^/         | /'; fi }
status() { if [ "$RC" -eq "$2" ]; then ok "$1"; else bad "$1 (exit $RC, expected $2)"; printf '%s\n' "$OUT" | sed 's/^/         | /'; fi }
contains() { if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1 (not in $2: $3)"; fi }
lacks() { if grep -qF -- "$3" "$2"; then bad "$1 (found in $2: $3)"; else ok "$1"; fi }

# plugin DIR MAIN CALL: a plugin folder whose main file creates the client with CALL.
plugin() {
	mkdir -p "$1"
	printf '<?php\n/**\n * Plugin Name: Fixture\n * Version: 1.0.0\n */\n\nadd_action(\n\t"init",\n\tfunction () {\n\t\t%s\n\t}\n);\n' "$3" >"$1/$2"
}

echo "generate.py"

# A plugin that passes null as the product ID (like jp4wc-pro) ---------------------------------

P="$W/my-plugin"
plugin "$P" my-plugin.php "new WC_AM_Client_2_12_2( __FILE__, null, 188, '1.0.0', 'plugin', 'https://shop.example.com/', 'My Plugin', 'my-plugin' );"

run --plugin-dir "$P" --out "$W/out/a.php"
status "null product ID without --product-id is refused" 2
has "the error asks for --product-id" "pass --product-id"

run --plugin-dir "$P" --product-id 188 --out "$W/out/a.php"
status "null product ID with --product-id writes the file" 0
has "the summary names the client" "client       : WC_AM_Client_2_12_2 in my-plugin.php"
contains "plugin file is folder/main file" "$W/out/a.php" "'plugin_file'           => 'my-plugin/my-plugin.php',"
contains "product ID is the one passed" "$W/out/a.php" "'product_id'            => 188,"
contains "the client gets no product ID" "$W/out/a.php" "'client_has_product_id' => false,"
contains "API URL comes from the call" "$W/out/a.php" "'api_url'               => 'https://shop.example.com/',"
contains "key constant comes from the API host" "$W/out/a.php" "'key_constant'          => 'SHOP_EXAMPLE_INTERNAL_API_KEY',"
contains "title comes from the call" "$W/out/a.php" "'title'                 => 'My Plugin',"
contains "the usage line names the constant" "$W/out/a.php" "define( 'SHOP_EXAMPLE_INTERNAL_API_KEY',"
contains "the class name carries the template version" "$W/out/a.php" "class AW_WC_AM_Internal_License_1_2_2 {"
contains "@package is the slug" "$W/out/a.php" "@package my-plugin"
lacks "no placeholder is left" "$W/out/a.php" "{{"
if command -v php >/dev/null 2>&1; then
	has "php -l passes" "php -l: ok"
else
	echo "  skip - php -l (no php)"
fi

run --plugin-dir "$P" --product-id 188 --out "$W/out/a.php" --check
status "--check on the same settings matches" 0
has "--check reports OK" "OK: $W/out/a.php matches"

printf '// edited\n' >>"$W/out/a.php"
run --plugin-dir "$P" --product-id 188 --out "$W/out/a.php" --check
status "--check on an edited file fails" 1
has "--check shows the diff" "-// edited"

run --plugin-dir "$P" --product-id 188 --out "$W/out/missing.php" --check
status "--check on a missing file fails" 1

run --plugin-dir "$P" --product-id 188 --out "$W/out/b.php" --slug other-folder --key-constant MY_KEY
status "--slug and --key-constant override the defaults" 0
contains "--slug changes the plugin file" "$W/out/b.php" "'plugin_file'           => 'other-folder/my-plugin.php',"
contains "--key-constant is used" "$W/out/b.php" "'key_constant'          => 'MY_KEY',"

run --plugin-dir "$P" --product-id 188 --out "$W/out/v.php" --verify-mock "$W/out/0-mock.php"
status "--verify-mock writes the mock as well" 0
has "the mock is reported" "WROTE MOCK: $W/out/0-mock.php"
contains "the mock answers for the API host" "$W/out/0-mock.php" "'shop.example.com' !== wp_parse_url( \$url, PHP_URL_HOST )"
contains "the mock defines the same constant" "$W/out/0-mock.php" "define( 'SHOP_EXAMPLE_INTERNAL_API_KEY', get_option( 'wcam_mock_alt_key' ) ? WCAM_MOCK_ALT_KEY : WCAM_MOCK_KEY );"
contains "the mu-plugin does nothing on multisite" "$W/out/a.php" "if ( is_multisite() || '' === \$this->api_key()"
contains "the mock's update names the plugin file" "$W/out/0-mock.php" "'plugin'         => 'my-plugin/my-plugin.php',"
contains "the mock's package carries the product ID" "$W/out/0-mock.php" "am_download_file=188&verify=1"
lacks "no placeholder is left in the mock" "$W/out/0-mock.php" "{{"
if command -v php >/dev/null 2>&1; then
	if php -l "$W/out/0-mock.php" >/dev/null 2>&1; then ok "the mock passes php -l"; else bad "the mock passes php -l"; fi
fi

run --plugin-dir "$P" --product-id 188 --out "$W/out/v.php" --check --key-file "$W/site/key.php"
status "--key-file writes the key file next to --check" 0
has "the key file is reported" "WROTE KEY FILE: $W/site/key.php"
contains "the key file defines the constant, left empty" "$W/site/key.php" "define( 'SHOP_EXAMPLE_INTERNAL_API_KEY', '' );"
contains "the key file does not redefine a constant from wp-config.php" "$W/site/key.php" "if ( ! defined( 'SHOP_EXAMPLE_INTERNAL_API_KEY' ) ) {"
contains "the key file names the mu-plugin it serves" "$W/site/key.php" "Defines SHOP_EXAMPLE_INTERNAL_API_KEY for v.php"
contains "the key file is a mu-plugin of its own" "$W/site/key.php" "Plugin Name: My Plugin internal license key"
contains "the key file names the store" "$W/site/key.php" "internal account on shop.example.com"
lacks "no placeholder is left in the key file" "$W/site/key.php" "{{"
if command -v php >/dev/null 2>&1; then
	if php -l "$W/site/key.php" >/dev/null 2>&1; then ok "the key file passes php -l"; else bad "the key file passes php -l"; fi
	# Load the key file as WordPress would, with a constant already defined (as in wp-config.php) or not.
	keyrun() { OUT="$(php -d display_errors=1 -d error_reporting=-1 -r 'define("ABSPATH", "/"); if ($argv[2] !== "") { define("SHOP_EXAMPLE_INTERNAL_API_KEY", $argv[2]); } include $argv[1]; var_export(SHOP_EXAMPLE_INTERNAL_API_KEY);' "$W/site/key.php" "$1" 2>&1)"; }
	keyrun ""
	if [ "$OUT" = "''" ]; then ok "the empty key file defines an empty key"; else bad "the empty key file defines an empty key (got: $OUT)"; fi
	keyrun "from-wp-config"
	if [ "$OUT" = "'from-wp-config'" ]; then ok "a constant from wp-config.php wins, with no warning"; else bad "a constant from wp-config.php wins, with no warning (got: $OUT)"; fi
fi

sed -i.bak "s/'SHOP_EXAMPLE_INTERNAL_API_KEY', ''/'SHOP_EXAMPLE_INTERNAL_API_KEY', 'pasted-key'/" "$W/site/key.php" && rm -f "$W/site/key.php.bak"
run --plugin-dir "$P" --product-id 188 --out "$W/out/v.php" --key-file "$W/site/key.php"
status "an existing key file is refused" 2
has "the error says why" "it may hold a key, so it is never overwritten"
contains "the pasted key is kept" "$W/site/key.php" "'pasted-key'"

run --plugin-dir "$P" --product-id 188 --out "$W/out/v.php" --key-file "$P/tools/key.php"
status "a key file inside --plugin-dir is refused" 2
has "the error names the repository" "is inside --plugin-dir"
if [ -e "$P/tools/key.php" ]; then bad "nothing is written inside --plugin-dir"; else ok "nothing is written inside --plugin-dir"; fi

run --plugin-dir "$P" --product-id 188 --out "$W/out/c.php" --key-constant my_key
status "a lower-case key constant is refused" 2

run --plugin-dir "$P" --product-id 0 --out "$W/out/c.php"
status "product ID 0 is refused" 2

# A plugin that passes its product ID ------------------------------------------------------------

P="$W/numbered"
plugin "$P" numbered.php 'new WC_AM_Client_2_11_0( __FILE__, 1234, null, "2.0.0", "plugin", "https://www.store.example.jp/", "Numbered", "numbered" );'

run --plugin-dir "$P" --out "$W/out/n.php"
status "an integer product ID needs no --product-id" 0
contains "the client gets the product ID" "$W/out/n.php" "'client_has_product_id' => true,"
contains "the product ID comes from the call" "$W/out/n.php" "'product_id'            => 1234,"
contains "www. is dropped from the key constant" "$W/out/n.php" "'key_constant'          => 'STORE_EXAMPLE_INTERNAL_API_KEY',"

run --plugin-dir "$P" --product-id 99 --out "$W/out/n.php"
status "a --product-id different from the call is refused" 2
has "the error names both IDs" "differs from the ID the plugin passes to the client (1234)"

# Custom menu ------------------------------------------------------------------------------------

P="$W/menu-slug"
plugin "$P" menu-slug.php "new WC_AM_Client_2_12_2( __FILE__, 7, null, '1.0.0', 'plugin', 'https://shop.example.com/', 'Menu', 'menu', array( 'menu_type' => 'add_submenu_page', 'parent_slug' => 'woocommerce', 'menu_slug' => 'menu-license' ) );"
run --plugin-dir "$P" --out "$W/out/m.php"
status "a custom menu with menu_slug is read" 0
contains "the settings page is the custom slug" "$W/out/m.php" "'settings_page'         => 'menu-license',"

P="$W/menu-noslug"
plugin "$P" menu-noslug.php "new WC_AM_Client_2_12_2( __FILE__, 7, null, '1.0.0', 'plugin', 'https://shop.example.com/', 'Menu', 'menu', \$menu );"
run --plugin-dir "$P" --out "$W/out/m2.php"
status "a custom menu without a readable menu_slug is refused" 2
has "the error asks for --settings-page" "pass --settings-page"
run --plugin-dir "$P" --out "$W/out/m2.php" --settings-page my-license
status "--settings-page fills it in" 0
contains "the settings page is the one passed" "$W/out/m2.php" "'settings_page'         => 'my-license',"

P="$W/menu-empty"
plugin "$P" menu-empty.php "new WC_AM_Client_2_12_2( __FILE__, 7, null, '1.0.0', 'plugin', 'https://shop.example.com/', 'Menu', 'menu', array(), false );"
run --plugin-dir "$P" --out "$W/out/m3.php"
status "an empty custom menu keeps the client default" 0
contains "the settings page is left to the client default" "$W/out/m3.php" "'settings_page'         => '',"

# Refused inputs ---------------------------------------------------------------------------------

P="$W/theme"
plugin "$P" theme.php "new WC_AM_Client_2_12_2( __FILE__, 7, null, '1.0.0', 'theme', 'https://shop.example.com/', 'Theme', 'theme' );"
run --plugin-dir "$P" --out "$W/out/t.php"
status "a theme is refused" 2

P="$W/http"
plugin "$P" http.php "new WC_AM_Client_2_12_2( __FILE__, 7, null, '1.0.0', 'plugin', 'http://shop.example.com/', 'Http', 'http' );"
run --plugin-dir "$P" --out "$W/out/h.php"
status "an http API URL is refused" 2

P="$W/const-url"
plugin "$P" const-url.php "new WC_AM_Client_2_12_2( __FILE__, 7, null, MY_VERSION, 'plugin', MY_API_URL, 'Const', 'const' );"
run --plugin-dir "$P" --out "$W/out/k.php"
status "an API URL that is not a literal is refused" 2
has "the error asks for --api-url" "pass --api-url"
run --plugin-dir "$P" --out "$W/out/k.php" --api-url https://shop.example.com/
status "--api-url fills it in" 0

P="$W/quote"
plugin "$P" quote.php "new WC_AM_Client_2_12_2( __FILE__, 7, null, '1.0.0', 'plugin', 'https://shop.example.com/', 'Bob\\'s Plugin', 'quote' );"
run --plugin-dir "$P" --out "$W/out/q.php"
status "a title with a quote is refused" 2
run --plugin-dir "$P" --out "$W/out/q.php" --title "Bobs Plugin"
status "--title replaces it" 0

P="$W/two-mains"
plugin "$P" one.php "new WC_AM_Client_2_12_2( __FILE__, 7, null, '1.0.0', 'plugin', 'https://shop.example.com/', 'Two', 'two' );"
plugin "$P" two.php "// nothing"
run --plugin-dir "$P" --out "$W/out/2.php"
status "two main files are refused" 2
has "the error asks for --main-file" "pass --main-file"
run --plugin-dir "$P" --main-file one.php --out "$W/out/2.php"
status "--main-file picks one" 0

P="$W/no-client"
plugin "$P" no-client.php "// nothing"
run --plugin-dir "$P" --product-id 1 --out "$W/out/x.php"
status "a plugin without the client is refused" 2

# Null product ID with the client created outside __FILE__ of the main file ----------------------

P="$W/null-sub"
plugin "$P" null-sub.php "require __DIR__ . '/includes/license.php';"
mkdir -p "$P/includes"
printf '<?php\nnew WC_AM_Client_2_12_2( __FILE__, null, 188, "1.0.0", "plugin", "https://shop.example.com/", "Sub", "sub" );\n' >"$P/includes/license.php"
run --plugin-dir "$P" --product-id 188 --out "$W/out/ns.php"
status "null product ID with the client in an included file is refused" 2
has "the error names the file" "creates the client with __FILE__ in includes/license.php"

P="$W/null-const"
plugin "$P" null-const.php "new WC_AM_Client_2_12_2( MY_MAIN_FILE, null, 188, '1.0.0', 'plugin', 'https://shop.example.com/', 'Const', 'const' );"
run --plugin-dir "$P" --product-id 188 --out "$W/out/nc.php"
status "null product ID with a constant instead of __FILE__ is refused" 2
has "the error names the argument" "creates the client with MY_MAIN_FILE in null-const.php"

# The client created in another file -------------------------------------------------------------

P="$W/elsewhere"
plugin "$P" elsewhere.php "require __DIR__ . '/includes/license.php';"
mkdir -p "$P/includes"
printf '<?php\nnew WC_AM_Client_2_12_2( MAIN_FILE, 55, null, "1.0.0", "plugin", "https://shop.example.com/", "Elsewhere", "elsewhere" );\n' >"$P/includes/license.php"
run --plugin-dir "$P" --out "$W/out/e.php"
status "the client call is found in an included file" 0
has "the summary names that file" "in includes/license.php"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
