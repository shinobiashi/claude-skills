#!/usr/bin/env bash
# Scenario tests for anonymize.php against a fake $wpdb and stubbed WordPress / WP-CLI (plain
# php, no WordPress, no network). The fake answers every read with one row, so every write in
# the script runs; FAIL_AT=k makes the k-th write fail, and each k must end in a rollback.
# Usage: bash test-anonymize.sh [path/to/anonymize.php]
set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/anonymize.php}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }
has() { if printf '%s\n' "$OUT" | grep -qF -- "$2"; then ok "$1"; else bad "$1 (no line: $2)"; fi }

mkdir -p "$W/uploads"
cat >"$W/config.json" <<'JSON'
{ "order_item_meta": { "blank": [ "お名前入れ" ] }, "comment_meta": { "delete_prefix": [ "spamcheck_" ] } }
JSON

cat >"$W/harness.php" <<'PHP'
<?php
// argv: anonymize.php, FAIL_AT (0 = none), dry (0/1), config path, uploads dir.
list( , $script, $fail_at, $dry, $config, $uploads ) = $argv;

class WP_CLI {
	public static function log( $m ) { echo "LOG $m\n"; }
	public static function warning( $m ) { echo "WARN $m\n"; }
	public static function success( $m ) { echo "SUCCESS $m\n"; }
	public static function error( $m ) { echo "ERROR $m\n"; exit( 1 ); }
}
function wp_get_environment_type() { return 'local'; }
function home_url() { return 'http://localhost:8881'; }
function get_users( $args ) { return array( '1' ); }
function wp_upload_dir() { return array( 'basedir' => $GLOBALS['uploads'] ); }
function wp_cache_flush() { return true; }

class Fake_Wpdb {
	public $prefix = 'wp_', $users = 'wp_users', $usermeta = 'wp_usermeta', $posts = 'wp_posts', $postmeta = 'wp_postmeta';
	public $comments = 'wp_comments', $commentmeta = 'wp_commentmeta', $options = 'wp_options';
	public $last_error = '', $last_query = '', $writes = 0, $fail_at = 0;
	public function prepare( $q, ...$a ) {
		$a = array_map( function ( $v ) { return is_int( $v ) ? $v : "'" . $v . "'"; }, $a );
		return vsprintf( str_replace( array( '%s', '%d' ), array( '%s', '%s' ), $q ), $a );
	}
	public function esc_like( $s ) { return $s; }
	private function write( $sql ) {
		$this->last_query = $sql;
		echo "SQL $sql\n";
		if ( 'ROLLBACK' === $sql ) {
			return 0;
		}
		++$this->writes;
		if ( $this->writes === $this->fail_at ) {
			$this->last_error = 'fake failure';
			echo "FAILED-WRITE {$this->writes}\n";
			return false;
		}
		return 1;
	}
	public function query( $sql ) { return $this->write( $sql ); }
	public function update( $table, $data, $where ) { return $this->write( "UPDATE $table SET " . implode( ', ', array_keys( $data ) ) . ' WHERE ' . implode( ', ', array_keys( $where ) ) ); }
	public function get_col( $sql ) {
		if ( 'SHOW TABLES' === $sql ) {
			return array( 'wp_wc_orders', 'wp_wc_order_addresses', 'wp_wc_orders_meta', 'wp_woocommerce_order_itemmeta', 'wp_wc_customer_lookup', 'wp_woocommerce_downloadable_product_permissions', 'wp_wc_download_log', 'wp_woocommerce_sessions' );
		}
		return false !== strpos( $sql, 'DISTINCT meta_key' ) ? array( 'billing_kana' ) : array( '5' );
	}
	public function get_results( $sql ) {
		return array( (object) array( 'id' => 5, 'ID' => 5, 'customer_id' => 5, 'user_id' => 5, 'order_id' => 5, 'permission_id' => 5, 'row_id' => 5, 'address_type' => 'billing', 'state' => '', 'country' => 'JP', 'meta_value' => '{"name":"x"}' ) );
	}
	public function get_var( $sql ) { return 'JP'; }
}

$GLOBALS['uploads'] = $uploads;
$wpdb          = new Fake_Wpdb();
$wpdb->fail_at = (int) $fail_at;
$args          = array( 'config=' . $config );
if ( '1' === $dry ) {
	$args[] = 'dry-run';
}
register_shutdown_function( function () use ( $wpdb ) { echo "WRITES {$wpdb->writes}\n"; } );
require $script;
PHP

# run FAIL_AT DRY: OUT gets the output, RC the exit status.
run() { OUT="$(php -d display_errors=stderr -d error_reporting=E_ALL "$W/harness.php" "$SCRIPT" "$1" "$2" "$W/config.json" "$W/uploads" 2>&1)"; RC=$?; }

echo "anonymize.php"

run 0 0
if [ "$RC" -eq 0 ]; then ok "a clean run exits 0"; else bad "a clean run exits 0 (exit $RC)"; printf '%s\n' "$OUT" | tail -5 | sed 's/^/         | /'; fi
has "and commits" "SQL COMMIT"
has "and says Done" "SUCCESS Done."
TOTAL="$(printf '%s\n' "$OUT" | sed -n 's/^WRITES //p')"
has "order item meta: a configured key is blanked" "UPDATE wp_woocommerce_order_itemmeta SET meta_value = '' WHERE meta_key = 'お名前入れ'"
has "comments: customers' comments that are not approved are deleted" "DELETE FROM wp_comments WHERE comment_approved <> '1' AND user_id NOT IN (1)"
has "comments: and their meta first" "DELETE FROM wp_commentmeta WHERE comment_id IN (SELECT comment_ID FROM wp_comments WHERE comment_approved <> '1' AND user_id NOT IN (1))"
has "comment meta: a configured prefix is deleted" "DELETE FROM wp_commentmeta WHERE meta_key LIKE 'spamcheck_%' AND comment_id IN"

run 0 1
has "a dry run rolls back" "SQL ROLLBACK"
has "and says so" "SUCCESS Dry run finished and rolled back."

# Every write, in turn, fails: each must roll back, never commit, never say Done.
missed=""
for k in $(seq 1 "${TOTAL:-0}"); do
	run "$k" 0
	tail_sql="$(printf '%s\n' "$OUT" | sed -n 's/^SQL //p' | tail -1)"
	committed="$(printf '%s\n' "$OUT" | grep -c '^SQL COMMIT$')"
	failed_commit="$(printf '%s\n' "$OUT" | grep -c "^FAILED-WRITE $k$")"
	if [ "$RC" -eq 0 ] || [ "$tail_sql" != "ROLLBACK" ] || printf '%s\n' "$OUT" | grep -q '^SUCCESS' || ! printf '%s\n' "$OUT" | grep -q '^ERROR Database error' || { [ "$committed" -gt 0 ] && [ "$k" -ne "$TOTAL" ]; } || [ "$failed_commit" -ne 1 ]; then
		missed="$missed $k"
	fi
done
if [ "${TOTAL:-0}" -gt 20 ] && [ -z "$missed" ]; then
	ok "each of the $TOTAL writes, when it fails, rolls everything back and fails the run"
else
	bad "writes that did not roll back and fail the run when they failed:${missed:- (no writes counted: $TOTAL)}"
fi

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
