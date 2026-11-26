<?php
/**
 * Find which table, column and row (and meta key) contain a string — for example a domain
 * that scan-pii.sh reported.
 *
 *   wp eval-file <dir>/find-string.php '@gmail.com' [limit=20]
 *
 * Email local parts in the printed context are masked. Read-only.
 */

$wcspc_needle = null;
$wcspc_limit  = 20;
foreach ( isset( $args ) ? (array) $args : array() as $wcspc_arg ) {
	if ( preg_match( '/^(--)?limit=(\d+)$/', (string) $wcspc_arg, $wcspc_m ) ) {
		$wcspc_limit = max( 1, (int) $wcspc_m[2] );
	} elseif ( null === $wcspc_needle ) {
		$wcspc_needle = (string) $wcspc_arg;
	}
}
if ( null === $wcspc_needle || '' === $wcspc_needle ) {
	WP_CLI::error( "Usage: wp eval-file find-string.php '<string>' [limit=20]" );
}

global $wpdb;
$mask = function ( $text ) use ( $wcspc_needle ) {
	$text = (string) $text;
	$pos  = stripos( $text, $wcspc_needle );
	$from = false === $pos ? 0 : max( 0, $pos - 60 );
	$part = substr( $text, $from, 160 );
	return preg_replace( '/[A-Za-z0-9._%+-]+@/', '*@', $part );
};

$hits = 0;
foreach ( $wpdb->get_col( 'SHOW TABLES' ) as $table ) {
	$cols = $wpdb->get_results( "SHOW COLUMNS FROM `$table`" );
	if ( ! $cols ) {
		continue;
	}
	$pk       = $cols[0]->Field;
	$has_key  = false;
	$text_col = array();
	foreach ( $cols as $c ) {
		if ( isset( $c->Key ) && 'PRI' === $c->Key ) {
			$pk = $c->Field;
		}
		if ( 'meta_key' === $c->Field || 'option_name' === $c->Field ) {
			$has_key = $c->Field;
		}
		if ( preg_match( '/char|text|blob|json/i', (string) $c->Type ) ) {
			$text_col[] = $c->Field;
		}
	}
	foreach ( $text_col as $col ) {
		$select = "`$pk` AS row_id" . ( $has_key ? ", `$has_key` AS k" : '' ) . ", `$col` AS v";
		$rows   = $wpdb->get_results( $wpdb->prepare( "SELECT $select FROM `$table` WHERE `$col` LIKE %s LIMIT %d", '%' . $wpdb->esc_like( $wcspc_needle ) . '%', $wcspc_limit ) );
		foreach ( $rows as $r ) {
			++$hits;
			WP_CLI::log( sprintf( '%s.%s  %s=%s%s  %s', $table, $col, $pk, $r->row_id, isset( $r->k ) ? '  key=' . $r->k : '', $mask( $r->v ) ) );
		}
	}
}
WP_CLI::log( $hits ? "{$hits} row(s)" : 'not found in any table' );
