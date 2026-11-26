#!/usr/bin/env bash
# Scenario tests for assets/local-prod-copy-safety.php with stubbed WordPress functions
# (plain php, no WordPress, no network). Each scenario runs in its own php process because
# the plugin defines constants.
# Usage: bash test-safety-plugin.sh [path/to/local-prod-copy-safety.php]
set -uo pipefail

PLUGIN="${1:-$(cd "$(dirname "$0")/.." && pwd)/assets/local-prod-copy-safety.php}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }

cat >"$W/stubs.php" <<'PHP'
<?php
define( 'ABSPATH', '/tmp/' );
$GLOBALS['hooks'] = array();
function add_filter( $hook, $cb, $prio = 10, $args = 1 ) { $GLOBALS['hooks'][ $hook ] = $cb; return true; }
function add_action( $hook, $cb, $prio = 10, $args = 1 ) { $GLOBALS['hooks'][ $hook ] = $cb; return true; }
function wp_get_environment_type() { return $GLOBALS['env']; }
function home_url() { return $GLOBALS['home']; }
class WP_Error { public $code; public function __construct( $code = '', $msg = '' ) { $this->code = $code; } }
PHP

# scenario NAME PRELUDE CODE EXPECTED: run PRELUDE (globals/constants), load the plugin, then
# echo CODE's value; the output must equal EXPECTED.
scenario() {
	local got
	got="$(php -d display_errors=stderr -d error_reporting=E_ALL -r "require '$W/stubs.php'; $2 require '$PLUGIN'; echo $3;" 2>&1)"
	if [ "$got" = "$4" ]; then ok "$1"; else bad "$1 (got: $got | expected: $4)"; fi
}
LOCAL="\$GLOBALS['env'] = 'local'; \$GLOBALS['home'] = 'http://localhost:8881';"
HOOKS="implode(',', array_keys(\$GLOBALS['hooks']))"

echo "local-prod-copy-safety.php"

scenario "does nothing on production" "\$GLOBALS['env'] = 'production'; \$GLOBALS['home'] = 'https://shop.example.com';" \
	"'[' . $HOOKS . '] cron=' . var_export(defined('DISABLE_WP_CRON'), true)" "[] cron=false"
scenario "does nothing on a production host even if the environment says local" "\$GLOBALS['env'] = 'local'; \$GLOBALS['home'] = 'https://shop.example.com';" \
	"'[' . $HOOKS . ']'" "[]"
scenario "does nothing on localhost when the environment is production" "\$GLOBALS['env'] = 'production'; \$GLOBALS['home'] = 'http://localhost:8881';" \
	"'[' . $HOOKS . ']'" "[]"
scenario "registers the protections on a local copy" "$LOCAL" "$HOOKS" \
	"pre_get_ready_cron_jobs,action_scheduler_allow_async_request_runner,option_active_plugins,site_option_active_sitewide_plugins,pre_http_request,admin_notices"
scenario "turns off WP-Cron spawning" "$LOCAL" "var_export(DISABLE_WP_CRON, true)" "true"
scenario "cron jobs are emptied even for direct wp-cron.php requests" "$LOCAL" "\$GLOBALS['hooks']['pre_get_ready_cron_jobs']" "__return_empty_array"
scenario "keeps a DISABLE_WP_CRON already set in wp-config without a warning" "$LOCAL define('DISABLE_WP_CRON', false);" \
	"var_export(DISABLE_WP_CRON, true) . ' ' . (isset(\$GLOBALS['hooks']['pre_get_ready_cron_jobs']) ? 'jobs-blocked' : 'jobs-open')" "false jobs-blocked"

PLUGINS="array('wp-mail-smtp/wp_mail_smtp.php', 'woocommerce/woocommerce.php', 'post-smtp/postman-smtp.php', 'updraftplus/updraftplus.php', 'fluent-smtp/fluent-smtp.php')"
scenario "unloads mail plugins and keeps the rest" "$LOCAL" "implode(',', lpcs_filter_active_plugins($PLUGINS))" \
	"woocommerce/woocommerce.php,updraftplus/updraftplus.php"
scenario "unloads the plugins named in LOCAL_PROD_COPY_UNLOAD_PLUGINS too" "$LOCAL define('LOCAL_PROD_COPY_UNLOAD_PLUGINS', 'updraftplus, cart-bridge-jp');" \
	"implode(',', lpcs_filter_active_plugins($PLUGINS))" "woocommerce/woocommerce.php"
scenario "network-active mail plugins are unloaded" "$LOCAL" \
	"implode(',', array_keys(lpcs_filter_sitewide_plugins(array('wp-mail-smtp/wp_mail_smtp.php' => 1, 'woocommerce/woocommerce.php' => 1))))" "woocommerce/woocommerce.php"

scenario "blocks HTTP to an external service" "$LOCAL" "get_class(lpcs_block_http(false, array(), 'https://api.payments.example/v1/charges'))" "WP_Error"
scenario "allows HTTP to the site itself" "$LOCAL" "var_export(lpcs_block_http(false, array(), 'http://localhost:8881/wp-cron.php'), true)" "false"
scenario "allows HTTP to wordpress.org" "$LOCAL" "var_export(lpcs_block_http(false, array(), 'https://downloads.wordpress.org/plugin/x.zip'), true)" "false"
scenario "allows hosts in LOCAL_PROD_COPY_HTTP_ALLOW (wildcard)" "$LOCAL define('LOCAL_PROD_COPY_HTTP_ALLOW', '*.example.net');" \
	"var_export(lpcs_block_http(false, array(), 'https://api.example.net/x'), true)" "false"
scenario "a wildcard does not allow a look-alike host" "$LOCAL define('LOCAL_PROD_COPY_HTTP_ALLOW', '*.example.net');" \
	"get_class(lpcs_block_http(false, array(), 'https://example.net.evil.example/x'))" "WP_Error"
scenario "a wildcard does not match a longer name that only ends the same" "$LOCAL define('LOCAL_PROD_COPY_HTTP_ALLOW', '*.example.net');" \
	"get_class(lpcs_block_http(false, array(), 'https://notexample.net/x'))" "WP_Error"
scenario "an earlier short-circuit value is passed through" "$LOCAL" "lpcs_block_http(array('ok'), array(), 'https://api.payments.example/')[0]" "ok"
scenario "LOCAL_PROD_COPY_ALLOW_HTTP stops the blocking" "$LOCAL define('LOCAL_PROD_COPY_ALLOW_HTTP', true);" \
	"var_export(isset(\$GLOBALS['hooks']['pre_http_request']), true)" "false"
scenario "mail is left to Studio by default" "$LOCAL" "var_export(isset(\$GLOBALS['hooks']['pre_wp_mail']), true)" "false"
scenario "LOCAL_PROD_COPY_BLOCK_MAIL drops all mail" "$LOCAL define('LOCAL_PROD_COPY_BLOCK_MAIL', true);" "\$GLOBALS['hooks']['pre_wp_mail']" "__return_false"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
