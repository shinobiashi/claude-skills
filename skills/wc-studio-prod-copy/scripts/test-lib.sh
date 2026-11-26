#!/usr/bin/env bash
# Scenario tests for lib.php with plain php (no WordPress, no network).
# Usage: bash test-lib.sh [path/to/lib.php]
set -uo pipefail

LIB="${1:-$(cd "$(dirname "$0")" && pwd)/lib.php}"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }

# is NAME PHP_EXPRESSION EXPECTED_JSON: json_encode(EXPRESSION) equals EXPECTED_JSON.
is() {
	local got
	got="$(php -d display_errors=stderr -r "require '$LIB'; echo json_encode($2, JSON_UNESCAPED_UNICODE);" 2>&1)"
	if [ "$got" = "$3" ]; then ok "$1"; else bad "$1 (got $got, expected $3)"; fi
}

echo "lib.php"

# Local-only guard -------------------------------------------------------------------------------
is "localhost is local" "wcspc_is_local_host('localhost')" 'true'
is "127.0.0.1 is local" "wcspc_is_local_host('127.0.0.1')" 'true'
is "[::1] is local" "wcspc_is_local_host('[::1]')" 'true'
is "*.local is local" "wcspc_is_local_host('shop.local')" 'true'
is "*.test is local" "wcspc_is_local_host('shop.test')" 'true'
is "*.localhost is local" "wcspc_is_local_host('shop.localhost')" 'true'
is "a production host is not local" "wcspc_is_local_host('shop.example.com')" 'false'
is "bare 'test' is not local" "wcspc_is_local_host('test')" 'false'
is "a host ending in 'test' without a dot is not local" "wcspc_is_local_host('mytest')" 'false'
is "runs on Studio (local + localhost)" "wcspc_refusal_reason('local', 'http://localhost:8881')" 'null'
is "runs on development + .test" "wcspc_refusal_reason('development', 'http://shop.test')" 'null'
is "refuses production environment even on localhost" "is_string(wcspc_refusal_reason('production', 'http://localhost:8881'))" 'true'
is "refuses staging environment" "is_string(wcspc_refusal_reason('staging', 'http://localhost'))" 'true'
is "refuses a production host even when the environment says local" "is_string(wcspc_refusal_reason('local', 'https://shop.example.com'))" 'true'
is "refuses an empty home URL" "is_string(wcspc_refusal_reason('local', ''))" 'true'

# Kana keys --------------------------------------------------------------------------------------
is "jp4wc yomigana key" "wcspc_is_kana_key('_wc_billing/jp4wc/yomigana_first_name')" 'true'
is "furigana key" "wcspc_is_kana_key('billing_furigana')" 'true'
is "_kana suffix" "wcspc_is_kana_key('_cbjp_kana')" 'true'
is "kanagawa is not a kana key" "wcspc_is_kana_key('kanagawa_flag')" 'false'
is "banana is not a kana key" "wcspc_is_kana_key('banana')" 'false'

# JSON rewriting ---------------------------------------------------------------------------------
MAP="array('name' => '顧客', 'tel' => '000', 'noshi_text' => array('if_nonempty' => 'テスト'), 'card_name' => array('if_nonempty' => 'テスト'), 'missing' => 'Z')"
is "list of objects: mapped fields replaced, empty/null kept, others untouched, missing not added" \
	"wcspc_rewrite_fields(array(array('name' => 'A', 'tel' => '1', 'noshi_text' => '', 'card_name' => null, 'keep' => 'x'), array('name' => 'B', 'noshi_text' => 'N')), $MAP)" \
	'[{"name":"顧客","tel":"000","noshi_text":"","card_name":null,"keep":"x"},{"name":"顧客","noshi_text":"テスト"}]'
is "single object" "wcspc_rewrite_fields(array('name' => 'A'), $MAP)" '{"name":"顧客"}'
is "invalid JSON becomes []" "wcspc_rewrite_json('{oops', $MAP)" '"[]"'
is "JSON keeps Japanese unescaped" "wcspc_rewrite_json('[{\"name\":\"A\"}]', $MAP)" '"[{\"name\":\"顧客\"}]"'

# Address index, args, config --------------------------------------------------------------------
is "address index joins the fields with spaces" \
	"wcspc_address_index(array('first_name' => '顧客', 'last_name' => '7', 'state' => 'JP35', 'postcode' => '000-0000', 'country' => 'JP', 'email' => 'c@example.com'))" \
	'"顧客 7     JP35 000-0000 JP c@example.com "'
is "parse args: bare words, as WP-CLI eval-file needs" "wcspc_parse_args(array('dry-run', 'config=/x.json', 'oops'))" '{"config":"\/x.json","dry_run":true,"unknown":["oops"]}'
is "parse args: the -- forms work too" "wcspc_parse_args(array('--dry-run', '--config=/x.json'))" '{"config":"\/x.json","dry_run":true,"unknown":[]}'
is "parse args: other words are left to the script" "wcspc_parse_args(array('write-allow=/a.txt'))['unknown']" '["write-allow=\/a.txt"]'
is "merge: lists are appended without duplicates" \
	"wcspc_merge_config(array('a' => array('x', 'y')), array('a' => array('y', 'z')))" '{"a":["x","y","z"]}'
is "merge: maps are merged and the site wins" \
	"wcspc_merge_config(array('m' => array('k1' => '1', 'k2' => '2')), array('m' => array('k2' => 'B', 'k3' => 'C')))" '{"m":{"k1":"1","k2":"B","k3":"C"}}'
is "merge: new top-level keys are added" "wcspc_merge_config(array('a' => 1), array('b' => 2))" '{"a":1,"b":2}'
is "merge: an empty default map (json rules) accepts a site map" \
	"wcspc_merge_config(wcspc_default_config(), array('order_meta' => array('json' => array('_x' => array('name' => 'N')))))['order_meta']['json']" '{"_x":{"name":"N"}}'
is "merge keeps the built-in user meta rules" \
	"array_key_exists('_wc_email_verified_wp', wcspc_merge_config(wcspc_default_config(), array('user_meta' => array('per_user' => array('_x' => '@email'))))['user_meta']['per_user'])" 'true'

# Value resolution and identity ------------------------------------------------------------------
is "@address_1 resolves to the fake address" "wcspc_resolve('@address_1')" '"テスト町1-2-3"'
is "@id resolves to the user ID" "wcspc_resolve('@id', wcspc_customer_identity(7))" '"7"'
is "@email resolves to the anonymized email" "wcspc_resolve('@email', wcspc_customer_identity(7))" '"customer7@example.com"'
is "a literal stays" "wcspc_resolve('顧客')" '"顧客"'
is "an unknown token stays as written" "wcspc_resolve('@nope')" '"@nope"'
is "customer identity" "wcspc_customer_identity(7)" '{"id":7,"login":"customer7","email":"customer7@example.com","display_name":"顧客 7"}'
is "the default rules cover the verified-email meta that a first run once missed" \
	"wcspc_default_config()['user_meta']['per_user']['_wc_email_verified_wp']" '"@email"'

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
