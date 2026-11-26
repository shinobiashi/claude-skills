<?php
/**
 * List where personal data may live in this site, before anonymizing.
 *
 *   wp eval-file <dir>/pii-inventory.php [config=<site-config.json>] [write-allow=<path>]
 *
 * Prints the non-empty tables, staff/customer counts, whether orders use HPOS, active plugins,
 * the user / order meta keys whose names look personal but that neither the built-in rules
 * nor the site config cover, every customer-facing order item meta key, and the meta keys of
 * customers' comments ("要確認"). Add those to the site config (or confirm they are not
 * personal) before running anonymize.php. Read-only, except that write-allow= writes the staff
 * accounts' addresses and the site's own addresses (admin, store sender) to a file for
 * scan-pii.sh --allow-file; only the number of entries is printed.
 */

require __DIR__ . '/lib.php';

$wcspc_opts = wcspc_parse_args( isset( $args ) ? (array) $args : array() );
$wcspc_allow_path = null;
foreach ( $wcspc_opts['unknown'] as $wcspc_arg ) {
	$wcspc_bare = 0 === strpos( $wcspc_arg, '--' ) ? substr( $wcspc_arg, 2 ) : $wcspc_arg;
	if ( 0 === strpos( $wcspc_bare, 'write-allow=' ) ) {
		$wcspc_allow_path = substr( $wcspc_bare, 12 );
	} else {
		WP_CLI::error( 'Unknown argument: ' . $wcspc_arg );
	}
}
$cfg        = wcspc_default_config();
if ( null !== $wcspc_opts['config'] ) {
	$wcspc_json = is_readable( $wcspc_opts['config'] ) ? json_decode( (string) file_get_contents( $wcspc_opts['config'] ), true ) : null;
	if ( ! is_array( $wcspc_json ) ) {
		WP_CLI::error( 'Cannot read config JSON: ' . $wcspc_opts['config'] );
	}
	$cfg = wcspc_merge_config( $cfg, $wcspc_json );
}

global $wpdb;
$p = $wpdb->prefix;

WP_CLI::log( '== environment: ' . wp_get_environment_type() . ' / ' . home_url() );
$reason = wcspc_refusal_reason( wp_get_environment_type(), home_url() );
WP_CLI::log( null === $reason ? '   local copy: yes (anonymize.php will run)' : '   local copy: NO — ' . $reason );

WP_CLI::log( '== non-empty tables' );
foreach ( $wpdb->get_col( 'SHOW TABLES' ) as $t ) {
	$n = (int) $wpdb->get_var( "SELECT COUNT(*) FROM `$t`" );
	if ( $n > 0 ) {
		WP_CLI::log( sprintf( '   %-48s %d', $t, $n ) );
	}
}

$roles = array();
foreach ( get_users( array( 'fields' => array( 'ID' ) ) ) as $u ) {
	foreach ( get_userdata( $u->ID )->roles as $r ) {
		$roles[ $r ] = ( isset( $roles[ $r ] ) ? $roles[ $r ] : 0 ) + 1;
	}
}
WP_CLI::log( '== users by role: ' . wp_json_encode( $roles ) . ' (kept as staff: ' . implode( ', ', (array) $cfg['staff_roles'] ) . ')' );

$hpos = class_exists( 'Automattic\WooCommerce\Utilities\OrderUtil' ) && Automattic\WooCommerce\Utilities\OrderUtil::custom_orders_table_usage_is_enabled();
WP_CLI::log( '== orders: HPOS ' . ( $hpos ? 'on' : 'off' ) . ', sync ' . ( 'yes' === get_option( 'woocommerce_custom_orders_table_data_sync_enabled' ) ? 'on' : 'off' ) . ', legacy order posts ' . (int) $wpdb->get_var( "SELECT COUNT(*) FROM {$wpdb->posts} WHERE post_type IN ('shop_order', 'shop_order_refund')" ) );
WP_CLI::log( '== active plugins: ' . implode( ', ', array_map( 'dirname', (array) get_option( 'active_plugins' ) ) ) );

$covered = function ( $key, array $lists ) {
	foreach ( $lists as $list ) {
		if ( in_array( $key, $list, true ) ) {
			return true;
		}
	}
	return wcspc_is_kana_key( $key );
};

$user_lists = array(
	array_keys( (array) $cfg['user_meta']['const'] ),
	array_keys( (array) $cfg['user_meta']['per_user'] ),
	(array) $cfg['user_meta']['delete'],
	array( 'billing_state', 'shipping_state', 'billing_country', 'shipping_country', 'wp_capabilities', 'wp_user_level', 'admin_color', 'locale', 'rich_editing', 'syntax_highlighting', 'comment_shortcuts', 'show_admin_bar_front', 'use_ssl' ),
);
$order_lists = array(
	(array) $cfg['order_meta']['blank'],
	(array) $cfg['order_meta']['text'],
	(array) $cfg['order_meta']['delete'],
	array_keys( (array) $cfg['order_meta']['json'] ),
	array( '_billing_address_index', '_shipping_address_index' ),
);
$legacy_handled = array();
foreach ( array( 'billing', 'shipping' ) as $type ) {
	foreach ( array( 'first_name', 'last_name', 'company', 'address_1', 'address_2', 'city', 'postcode', 'phone', 'email', 'state', 'country' ) as $f ) {
		$legacy_handled[] = "_{$type}_{$f}";
	}
}
$order_lists[] = $legacy_handled;

$report = function ( $label, $sql, array $lists, $prefixes = array() ) use ( $wpdb, $covered ) {
	$rows = $wpdb->get_results( $sql );
	$todo = array();
	foreach ( $rows as $r ) {
		$skip = false;
		foreach ( $prefixes as $prefix ) {
			if ( 0 === strpos( $r->meta_key, $prefix ) ) {
				$skip = true;
			}
		}
		if ( ! $skip && wcspc_looks_personal( $r->meta_key ) && ! $covered( $r->meta_key, $lists ) ) {
			$todo[] = $r->meta_key . '(' . $r->c . ')';
		}
	}
	WP_CLI::log( "== {$label}: " . count( $rows ) . ' keys' );
	WP_CLI::log( '   要確認: ' . ( $todo ? implode( ' ', $todo ) : 'なし' ) );
};

$report( 'user meta', "SELECT meta_key, COUNT(*) c FROM {$wpdb->usermeta} GROUP BY meta_key ORDER BY c DESC", $user_lists, (array) $cfg['user_meta']['delete_prefix'] );
if ( $hpos || in_array( $p . 'wc_orders_meta', $wpdb->get_col( 'SHOW TABLES' ), true ) ) {
	$report( 'HPOS order meta', "SELECT meta_key, COUNT(*) c FROM {$p}wc_orders_meta GROUP BY meta_key ORDER BY c DESC", $order_lists );
}
$report( 'legacy order post meta', "SELECT pm.meta_key, COUNT(*) c FROM {$wpdb->postmeta} pm JOIN {$wpdb->posts} po ON po.ID = pm.post_id WHERE po.post_type IN ('shop_order', 'shop_order_refund') GROUP BY pm.meta_key ORDER BY c DESC", $order_lists );

// key => count lines for the reports below.
$counted = function ( $sql ) use ( $wpdb ) {
	$out = array();
	foreach ( $wpdb->get_results( $sql ) as $r ) {
		$out[ (string) $r->meta_key ] = (int) $r->c;
	}
	return $out;
};
$listed = function ( array $todo ) {
	$out = array();
	foreach ( $todo as $key => $n ) {
		$out[] = $key . '(' . $n . ')';
	}
	return $out ? implode( ' ', $out ) : 'なし';
};

if ( in_array( $p . 'woocommerce_order_itemmeta', $wpdb->get_col( 'SHOW TABLES' ), true ) ) {
	$items = $counted( "SELECT meta_key, COUNT(*) c FROM {$p}woocommerce_order_itemmeta GROUP BY meta_key ORDER BY c DESC" );
	WP_CLI::log( '== order item meta: ' . count( $items ) . ' keys (every customer-facing key is listed: add-ons store what the customer typed under display labels)' );
	WP_CLI::log( '   要確認: ' . $listed( wcspc_item_meta_todo( $items, $cfg ) ) . ' → order_item_meta (blank / text / delete) in the site config, or confirm they are not personal' );
}

$staff_ids = array_map( 'intval', get_users( array( 'role__in' => (array) $cfg['staff_roles'], 'fields' => 'ID' ) ) );
$customer  = 'user_id NOT IN (' . implode( ',', $staff_ids ? $staff_ids : array( 0 ) ) . ") AND comment_type <> 'order_note'";
WP_CLI::log(
	sprintf(
		"== customers' comments / reviews: %d approved (bodies kept: they are public on production), %d not approved (deleted by anonymize.php)",
		(int) $wpdb->get_var( "SELECT COUNT(*) FROM {$wpdb->comments} WHERE $customer AND comment_approved = '1'" ),
		(int) $wpdb->get_var( "SELECT COUNT(*) FROM {$wpdb->comments} WHERE $customer AND comment_approved <> '1'" )
	)
);
$cmeta = $counted( "SELECT meta_key, COUNT(*) c FROM {$wpdb->commentmeta} WHERE comment_id IN (SELECT comment_ID FROM {$wpdb->comments} WHERE $customer AND comment_approved = '1') GROUP BY meta_key ORDER BY c DESC" );
WP_CLI::log( '   comment meta 要確認: ' . $listed( wcspc_comment_meta_todo( $cmeta, $cfg ) ) . ' → comment_meta (delete / delete_prefix) in the site config, or confirm they are not personal' );

$types = array();
foreach ( $wpdb->get_results( "SELECT post_type, COUNT(*) c FROM {$wpdb->posts} GROUP BY post_type ORDER BY c DESC" ) as $r ) {
	$types[] = $r->post_type . '(' . $r->c . ')';
}
WP_CLI::log( '== post types: ' . implode( ' ', $types ) );
WP_CLI::log( '   deleted by anonymize.php: ' . implode( ', ', (array) $cfg['delete_post_types'] ) );

$base = wp_upload_dir()['basedir'];
$docs = array_merge( glob( $base . '/wpo_wcpdf_*/attachments/*.pdf' ) ?: array(), glob( $base . '/wpo_wcpdf_*/attachments/*/*.pdf' ) ?: array() );
WP_CLI::log( '== generated PDFs in uploads (deleted by anonymize.php): ' . count( $docs ) );

if ( null !== $wcspc_allow_path ) {
	$entries = array();
	foreach ( get_users( array( 'role__in' => (array) $cfg['staff_roles'] ) ) as $u ) {
		$entries[] = strtolower( $u->user_email );
	}
	foreach ( array( 'admin_email', 'new_admin_email', 'woocommerce_email_from_address', 'woocommerce_stock_email_recipient' ) as $option ) {
		foreach ( preg_split( '/[\s,]+/', (string) get_option( $option, '' ) ) as $address ) {
			if ( is_email( $address ) ) {
				$entries[] = strtolower( $address );
			}
		}
	}
	$entries = array_values( array_unique( array_filter( $entries ) ) );
	file_put_contents( $wcspc_allow_path, "# staff accounts and the site's own addresses (pii-inventory.php)\n" . implode( "\n", $entries ) . "\n" );
	WP_CLI::log( '== wrote ' . count( $entries ) . ' allowlisted address(es) to ' . $wcspc_allow_path );
}
