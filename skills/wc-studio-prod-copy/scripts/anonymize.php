<?php
/**
 * Anonymize customer data in a LOCAL copy of a production WooCommerce site.
 *
 *   wp eval-file <dir>/anonymize.php [config=<site-config.json>] [dry-run]
 *
 * - Refuses to run unless WP_ENVIRONMENT_TYPE is local/development and home_url is a local host.
 * - Staff accounts (administrator / shop_manager by default) are kept so the local admin works.
 * - Writes with direct queries on purpose: saving orders or users through the WooCommerce /
 *   WordPress APIs fires integration hooks that may call production services.
 * - dry-run runs everything inside a transaction and rolls it back (files are not deleted).
 * - Covers HPOS orders and legacy (posts table) orders; see SKILL.md for what was tested.
 * - After it, run scan-pii.sh: the scan, not this script, decides whether anything is left.
 *
 * Studio runs WP-CLI with access to the site directory only, so copy this directory into the
 * site (for example <site>/.prod-copy-tmp/) and delete the copy afterwards.
 */

require __DIR__ . '/lib.php';

$wcspc_opts = wcspc_parse_args( isset( $args ) ? (array) $args : array() );
if ( $wcspc_opts['unknown'] ) {
	WP_CLI::error( 'Unknown arguments: ' . implode( ' ', $wcspc_opts['unknown'] ) );
}
$wcspc_reason = wcspc_refusal_reason( wp_get_environment_type(), home_url() );
if ( null !== $wcspc_reason ) {
	WP_CLI::error( 'Refusing to run: ' . $wcspc_reason );
}

$cfg = wcspc_default_config();
if ( null !== $wcspc_opts['config'] ) {
	$wcspc_json = is_readable( $wcspc_opts['config'] ) ? json_decode( (string) file_get_contents( $wcspc_opts['config'] ), true ) : null;
	if ( ! is_array( $wcspc_json ) ) {
		WP_CLI::error( 'Cannot read config JSON: ' . $wcspc_opts['config'] );
	}
	$cfg = wcspc_merge_config( $cfg, $wcspc_json );
}
$dry = $wcspc_opts['dry_run'];

global $wpdb;
$p      = $wpdb->prefix;
$tables = array_map( 'strval', $wpdb->get_col( 'SHOW TABLES' ) );
$has    = function ( $suffix ) use ( $tables, $p ) {
	return in_array( $p . $suffix, $tables, true );
};
$log    = function ( $label, $n ) {
	WP_CLI::log( sprintf( '%-52s %s', $label, $n ) );
};

$pdo = null;
if ( isset( $wpdb->dbh ) && is_object( $wpdb->dbh ) && method_exists( $wpdb->dbh, 'get_connection' ) ) {
	$wcspc_conn = $wpdb->dbh->get_connection();
	if ( is_object( $wcspc_conn ) && method_exists( $wcspc_conn, 'get_pdo' ) ) {
		$pdo = $wcspc_conn->get_pdo();
	}
}
if ( $pdo && ! $dry ) {
	// Overwrite deleted content in the SQLite file instead of leaving it in free pages.
	$pdo->exec( 'PRAGMA secure_delete = ON' );
}

WP_CLI::log( $dry ? '== DRY RUN (everything below is rolled back) ==' : '== Anonymizing ==' );
$wpdb->query( 'START TRANSACTION' );

$fake     = wcspc_fake();
$staff    = array_map( 'intval', get_users( array( 'role__in' => (array) $cfg['staff_roles'], 'fields' => 'ID' ) ) );
if ( ! $staff ) {
	WP_CLI::error( 'No account has one of the staff roles (' . implode( ', ', (array) $cfg['staff_roles'] ) . '). Refusing: every user would lose access. Set staff_roles in the config.' );
}
$staff_in = implode( ',', $staff );
$is_staff = function ( $id ) use ( $staff ) {
	return in_array( (int) $id, $staff, true );
};

/* 1. Users and user meta (customers only). */
$uids = array_map( 'intval', $wpdb->get_col( "SELECT ID FROM {$wpdb->users} WHERE ID NOT IN ($staff_in)" ) );
foreach ( $uids as $uid ) {
	$who = wcspc_customer_identity( $uid );
	$wpdb->update(
		$wpdb->users,
		array(
			'user_login'          => $who['login'],
			'user_nicename'       => $who['login'],
			'user_email'          => $who['email'],
			'user_url'            => '',
			'display_name'        => $who['display_name'],
			'user_activation_key' => '',
			'user_pass'           => '*',
		),
		array( 'ID' => $uid )
	);
}
$log( 'users anonymized (staff kept: ' . count( $staff ) . ')', count( $uids ) );

$n = 0;
foreach ( (array) $cfg['user_meta']['const'] as $key => $value ) {
	$n += (int) $wpdb->query( $wpdb->prepare( "UPDATE {$wpdb->usermeta} SET meta_value = %s WHERE meta_key = %s AND user_id NOT IN ($staff_in)", wcspc_resolve( $value ), $key ) );
}
foreach ( $wpdb->get_col( "SELECT DISTINCT meta_key FROM {$wpdb->usermeta}" ) as $key ) {
	if ( wcspc_is_kana_key( $key ) ) {
		$n += (int) $wpdb->query( $wpdb->prepare( "UPDATE {$wpdb->usermeta} SET meta_value = %s WHERE meta_key = %s AND user_id NOT IN ($staff_in) AND meta_value <> ''", $fake['kana'], $key ) );
	}
}
foreach ( $uids as $uid ) {
	$who = wcspc_customer_identity( $uid );
	foreach ( (array) $cfg['user_meta']['per_user'] as $key => $value ) {
		$n += (int) $wpdb->query( $wpdb->prepare( "UPDATE {$wpdb->usermeta} SET meta_value = %s WHERE user_id = %d AND meta_key = %s", wcspc_resolve( $value, $who ), $uid, $key ) );
	}
}
$n_del = 0;
foreach ( (array) $cfg['user_meta']['delete'] as $key ) {
	$n_del += (int) $wpdb->query( $wpdb->prepare( "DELETE FROM {$wpdb->usermeta} WHERE meta_key = %s AND user_id NOT IN ($staff_in)", $key ) );
}
foreach ( (array) $cfg['user_meta']['delete_prefix'] as $prefix ) {
	$n_del += (int) $wpdb->query( $wpdb->prepare( "DELETE FROM {$wpdb->usermeta} WHERE meta_key LIKE %s AND user_id NOT IN ($staff_in)", $wpdb->esc_like( $prefix ) . '%' ) );
}
$log( 'user meta rows updated / deleted', "$n / $n_del" );

/* Order meta rules shared by HPOS (wc_orders_meta) and legacy orders (postmeta). */
$order_meta = function ( $table, $pk, $where ) use ( $wpdb, $cfg, $fake ) {
	$n = 0;
	foreach ( (array) $cfg['order_meta']['blank'] as $key ) {
		$n += (int) $wpdb->query( $wpdb->prepare( "UPDATE $table SET meta_value = '' WHERE meta_key = %s AND $where", $key ) );
	}
	foreach ( (array) $cfg['order_meta']['text'] as $key ) {
		$n += (int) $wpdb->query( $wpdb->prepare( "UPDATE $table SET meta_value = %s WHERE meta_key = %s AND meta_value <> '' AND $where", $fake['text'], $key ) );
	}
	foreach ( $wpdb->get_col( "SELECT DISTINCT meta_key FROM $table WHERE $where" ) as $key ) {
		if ( wcspc_is_kana_key( $key ) ) {
			$n += (int) $wpdb->query( $wpdb->prepare( "UPDATE $table SET meta_value = %s WHERE meta_key = %s AND meta_value <> '' AND $where", $fake['kana'], $key ) );
		}
	}
	$d = 0;
	foreach ( (array) $cfg['order_meta']['delete'] as $key ) {
		$d += (int) $wpdb->query( $wpdb->prepare( "DELETE FROM $table WHERE meta_key = %s AND $where", $key ) );
	}
	$j = 0;
	foreach ( (array) $cfg['order_meta']['json'] as $key => $map ) {
		$rows = $wpdb->get_results( $wpdb->prepare( "SELECT $pk AS row_id, meta_value FROM $table WHERE meta_key = %s AND meta_value <> '' AND $where", $key ) );
		foreach ( $rows as $row ) {
			$wpdb->update( $table, array( 'meta_value' => wcspc_rewrite_json( $row->meta_value, (array) $map ) ), array( $pk => (int) $row->row_id ) );
			++$j;
		}
	}
	return array( $n, $d, $j );
};
$order_identity = function ( $order_id, $customer_id ) use ( $is_staff ) {
	if ( (int) $customer_id > 0 && ! $is_staff( $customer_id ) ) {
		$who = wcspc_customer_identity( $customer_id );
		return array( 'last' => (string) (int) $customer_id, 'email' => $who['email'] );
	}
	return array( 'last' => 'G' . (int) $order_id, 'email' => 'guest' . (int) $order_id . '@example.com' );
};

/* 2. HPOS orders. */
if ( $has( 'wc_orders' ) ) {
	$ident = array();
	foreach ( $wpdb->get_results( "SELECT id, customer_id FROM {$p}wc_orders" ) as $o ) {
		$ident[ (int) $o->id ] = $order_identity( $o->id, $o->customer_id );
		$wpdb->update( "{$p}wc_orders", array( 'billing_email' => $ident[ (int) $o->id ]['email'] ), array( 'id' => (int) $o->id ) );
	}
	$wpdb->query( "UPDATE {$p}wc_orders SET customer_note = '', ip_address = '', user_agent = ''" );
	$log( 'HPOS orders anonymized', count( $ident ) );

	if ( $has( 'wc_order_addresses' ) ) {
		$wpdb->query(
			$wpdb->prepare(
				"UPDATE {$p}wc_order_addresses SET first_name = %s, company = %s, address_1 = %s, address_2 = %s, city = %s, postcode = %s, phone = %s",
				$fake['first_name'], $fake['company'], $fake['address_1'], $fake['address_2'], $fake['city'], $fake['postcode'], $fake['phone']
			)
		);
		$rows = $wpdb->get_results( "SELECT id, order_id, address_type, state, country FROM {$p}wc_order_addresses" );
		foreach ( $rows as $a ) {
			$oid = (int) $a->order_id;
			$i   = isset( $ident[ $oid ] ) ? $ident[ $oid ] : $order_identity( $oid, 0 );
			$wpdb->update( "{$p}wc_order_addresses", array( 'last_name' => $i['last'], 'email' => $i['email'] ), array( 'id' => (int) $a->id ) );
			$index = wcspc_address_index( array_merge( $fake, array( 'last_name' => $i['last'], 'state' => $a->state, 'country' => $a->country, 'email' => $i['email'] ) ) );
			if ( $has( 'wc_orders_meta' ) ) {
				$wpdb->query( $wpdb->prepare( "UPDATE {$p}wc_orders_meta SET meta_value = %s WHERE order_id = %d AND meta_key = %s", $index, $oid, '_' . $a->address_type . '_address_index' ) );
			}
		}
		$log( 'HPOS order addresses anonymized', count( $rows ) );
	}
	if ( $has( 'wc_orders_meta' ) ) {
		list( $n, $d, $j ) = $order_meta( "{$p}wc_orders_meta", 'id', '1 = 1' );
		$log( 'HPOS order meta updated / deleted / json rewritten', "$n / $d / $j" );
	}
}

/* 3. Legacy orders (posts table). Placeholder posts of HPOS hold no personal data. */
$legacy_where = "post_id IN (SELECT ID FROM {$wpdb->posts} WHERE post_type IN ('shop_order', 'shop_order_refund'))";
$legacy       = $wpdb->get_results( "SELECT p.ID, m.meta_value AS customer_id FROM {$wpdb->posts} p LEFT JOIN {$wpdb->postmeta} m ON m.post_id = p.ID AND m.meta_key = '_customer_user' WHERE p.post_type IN ('shop_order', 'shop_order_refund')" );
if ( $legacy ) {
	$const = array();
	foreach ( array( 'billing', 'shipping' ) as $type ) {
		$const[ "_{$type}_first_name" ] = $fake['first_name'];
		$const[ "_{$type}_company" ]    = $fake['company'];
		$const[ "_{$type}_address_1" ]  = $fake['address_1'];
		$const[ "_{$type}_address_2" ]  = $fake['address_2'];
		$const[ "_{$type}_city" ]       = $fake['city'];
		$const[ "_{$type}_postcode" ]   = $fake['postcode'];
		$const[ "_{$type}_phone" ]      = $fake['phone'];
	}
	foreach ( $const as $key => $value ) {
		$wpdb->query( $wpdb->prepare( "UPDATE {$wpdb->postmeta} SET meta_value = %s WHERE meta_key = %s AND $legacy_where", $value, $key ) );
	}
	foreach ( $legacy as $o ) {
		$i = $order_identity( $o->ID, $o->customer_id );
		foreach ( array( '_billing_last_name' => $i['last'], '_shipping_last_name' => $i['last'], '_billing_email' => $i['email'] ) as $key => $value ) {
			$wpdb->query( $wpdb->prepare( "UPDATE {$wpdb->postmeta} SET meta_value = %s WHERE post_id = %d AND meta_key = %s", $value, (int) $o->ID, $key ) );
		}
		foreach ( array( 'billing', 'shipping' ) as $type ) {
			$parts = array( 'state' => '', 'country' => '' );
			foreach ( array( 'state', 'country' ) as $k ) {
				$parts[ $k ] = (string) $wpdb->get_var( $wpdb->prepare( "SELECT meta_value FROM {$wpdb->postmeta} WHERE post_id = %d AND meta_key = %s", (int) $o->ID, "_{$type}_{$k}" ) );
			}
			$index = wcspc_address_index( array_merge( $fake, $parts, array( 'last_name' => $i['last'], 'email' => 'billing' === $type ? $i['email'] : '' ) ) );
			$wpdb->query( $wpdb->prepare( "UPDATE {$wpdb->postmeta} SET meta_value = %s WHERE post_id = %d AND meta_key = %s", $index, (int) $o->ID, "_{$type}_address_index" ) );
		}
	}
	$wpdb->query( "UPDATE {$wpdb->posts} SET post_excerpt = '' WHERE post_type = 'shop_order'" );
	list( $n, $d, $j ) = $order_meta( $wpdb->postmeta, 'meta_id', $legacy_where );
	$log( 'legacy orders anonymized (meta upd / del / json)', count( $legacy ) . " ($n / $d / $j)" );
}

/* 4. Comments: order notes are free text (names, emails, tracking numbers), so delete them. */
$n_meta = (int) $wpdb->query( "DELETE FROM {$wpdb->commentmeta} WHERE comment_id IN (SELECT comment_ID FROM {$wpdb->comments} WHERE comment_type = 'order_note')" );
$n      = (int) $wpdb->query( "DELETE FROM {$wpdb->comments} WHERE comment_type = 'order_note'" );
$log( 'order notes deleted (meta)', "$n ($n_meta)" );
$rows = $wpdb->get_col( "SELECT comment_ID FROM {$wpdb->comments} WHERE user_id NOT IN ($staff_in)" );
foreach ( $rows as $cid ) {
	$wpdb->update(
		$wpdb->comments,
		array(
			'comment_author'       => 'ゲスト',
			'comment_author_email' => 'commenter' . (int) $cid . '@example.com',
			'comment_author_url'   => '',
			'comment_author_IP'    => '',
			'comment_agent'        => '',
		),
		array( 'comment_ID' => (int) $cid )
	);
}
$log( 'other comments / reviews: authors anonymized', count( $rows ) );

/* 5. Analytics, download permissions and logs. */
if ( $has( 'wc_customer_lookup' ) ) {
	$rows = $wpdb->get_results( "SELECT customer_id, user_id FROM {$p}wc_customer_lookup" );
	foreach ( $rows as $r ) {
		if ( (int) $r->user_id > 0 && ! $is_staff( $r->user_id ) ) {
			$who = wcspc_customer_identity( $r->user_id );
			$set = array( 'username' => $who['login'], 'first_name' => $fake['first_name'], 'last_name' => (string) (int) $r->user_id, 'email' => $who['email'] );
		} else {
			$set = array( 'username' => '', 'first_name' => 'ゲスト', 'last_name' => (string) (int) $r->customer_id, 'email' => 'guest-c' . (int) $r->customer_id . '@example.com' );
		}
		$set['city']     = $fake['city'];
		$set['postcode'] = $fake['postcode'];
		$wpdb->update( "{$p}wc_customer_lookup", $set, array( 'customer_id' => (int) $r->customer_id ) );
	}
	$log( 'customer lookup rows anonymized', count( $rows ) );
}
if ( $has( 'woocommerce_downloadable_product_permissions' ) ) {
	$rows = $wpdb->get_results( "SELECT permission_id, user_id FROM {$p}woocommerce_downloadable_product_permissions" );
	foreach ( $rows as $r ) {
		$email = ( (int) $r->user_id > 0 && ! $is_staff( $r->user_id ) ) ? wcspc_customer_identity( $r->user_id )['email'] : 'guest-p' . (int) $r->permission_id . '@example.com';
		$wpdb->update( "{$p}woocommerce_downloadable_product_permissions", array( 'user_email' => $email ), array( 'permission_id' => (int) $r->permission_id ) );
	}
	$log( 'download permissions anonymized', count( $rows ) );
}
if ( $has( 'wc_download_log' ) ) {
	$log( 'download log IPs cleared', (int) $wpdb->query( "UPDATE {$p}wc_download_log SET user_ip_address = ''" ) );
}
foreach ( (array) $cfg['truncate_tables'] as $t ) {
	if ( $has( $t ) ) {
		$log( "table {$p}{$t} emptied", (int) $wpdb->query( "DELETE FROM {$p}{$t}" ) );
	}
}
foreach ( (array) $cfg['delete_post_types'] as $type ) {
	$ids = array_map( 'intval', $wpdb->get_col( $wpdb->prepare( "SELECT ID FROM {$wpdb->posts} WHERE post_type = %s", $type ) ) );
	if ( $ids ) {
		$in = implode( ',', $ids );
		$wpdb->query( "DELETE FROM {$wpdb->postmeta} WHERE post_id IN ($in)" );
		$wpdb->query( "DELETE FROM {$wpdb->posts} WHERE ID IN ($in)" );
	}
	$log( "posts of type {$type} deleted", count( $ids ) );
}

foreach ( (array) $cfg['delete_options'] as $option ) {
	$log( "option {$option} deleted", (int) $wpdb->query( $wpdb->prepare( "DELETE FROM {$wpdb->options} WHERE option_name = %s", $option ) ) );
}

if ( $dry ) {
	$wpdb->query( 'ROLLBACK' );
	WP_CLI::success( 'Dry run finished and rolled back. No files were deleted.' );
	return;
}
$wpdb->query( 'COMMIT' );

/* 6. Generated documents and logs in uploads. */
$base  = wp_upload_dir()['basedir'];
$files = array_merge(
	glob( $base . '/wpo_wcpdf_*/attachments/*.pdf' ) ?: array(),
	glob( $base . '/wpo_wcpdf_*/attachments/*/*.pdf' ) ?: array(),
	glob( $base . '/wpo_wcpdf_*/dompdf/log.htm' ) ?: array(),
	glob( $base . '/wc-logs/*.log' ) ?: array()
);
$n = 0;
foreach ( $files as $file ) {
	if ( is_file( $file ) && unlink( $file ) ) {
		++$n;
	}
}
$log( 'generated PDFs and logs deleted', $n );

wp_cache_flush();

/* 7. SQLite: reclaim freed pages so removed values do not stay in the file. */
if ( $pdo ) {
	$pdo->exec( 'VACUUM' );
	$pdo->exec( 'PRAGMA wal_checkpoint(TRUNCATE)' );
	$log( 'SQLite VACUUM done, freelist pages', $pdo->query( 'PRAGMA freelist_count' )->fetchColumn() );
} else {
	WP_CLI::warning( 'Not SQLite: removed values may stay in the database files until the engine reuses the pages.' );
}
WP_CLI::success( 'Done. Now run scan-pii.sh — it decides whether anything is left.' );
