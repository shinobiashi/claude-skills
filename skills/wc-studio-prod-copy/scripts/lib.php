<?php
/**
 * Pure helpers for anonymize.php (no WordPress needed, so test-lib.sh can run them with plain php).
 * PHP 7.4 compatible.
 */

/**
 * Whether a host name is a local development host.
 *
 * @param string $host Host name (without port).
 * @return bool
 */
function wcspc_is_local_host( $host ) {
	$host = strtolower( trim( (string) $host, '[] ' ) );
	if ( in_array( $host, array( 'localhost', '127.0.0.1', '::1' ), true ) ) {
		return true;
	}
	foreach ( array( '.localhost', '.local', '.test' ) as $suffix ) {
		if ( strlen( $host ) > strlen( $suffix ) && substr( $host, -strlen( $suffix ) ) === $suffix ) {
			return true;
		}
	}
	return false;
}

/**
 * Refuse to run unless this is clearly a local copy.
 *
 * @param string $env_type wp_get_environment_type().
 * @param string $home_url home_url().
 * @return string|null Null when it is safe to run, otherwise the reason to refuse.
 */
function wcspc_refusal_reason( $env_type, $home_url ) {
	if ( ! in_array( $env_type, array( 'local', 'development' ), true ) ) {
		return "WP_ENVIRONMENT_TYPE is '{$env_type}' (expected 'local' or 'development')";
	}
	$host = parse_url( (string) $home_url, PHP_URL_HOST );
	if ( ! is_string( $host ) || ! wcspc_is_local_host( $host ) ) {
		return "home_url host '" . ( is_string( $host ) ? $host : '' ) . "' is not a local host";
	}
	return null;
}

/**
 * Whether a meta key holds a reading of a name (yomigana / furigana / kana).
 *
 * @param string $key Meta key.
 * @return bool
 */
function wcspc_is_kana_key( $key ) {
	return (bool) preg_match( '#(yomigana|furigana|(^|[_/-])kana($|[_/-]))#i', (string) $key );
}

/**
 * Whether a meta key's name looks like it holds personal data.
 *
 * @param string $key Meta key.
 * @return bool
 */
function wcspc_looks_personal( $key ) {
	return (bool) preg_match( '/(e-?mail|phone|tel(_|$)|mobile|fax|contact|name|kana|address|addr|postal|zip|postcode|city|(^|_)ip(_|$)|user_?agent|note|memo|noshi|slip|tracking|secret|token|card|birth)/i', (string) $key );
}

/**
 * Order item meta keys to decide on ("要確認"). Add-on plugins store what the customer typed
 * under display labels ("お名前入れ"), which no name pattern catches, so every key without a
 * leading underscore is listed, apart from WooCommerce's own shipping, fee, tax and coupon item
 * keys and global attributes (pa_*). Underscore keys are listed when their names look personal.
 *
 * @param array<string, int> $counts Meta key => number of rows.
 * @param array              $cfg    Config (order_item_meta rules cover keys).
 * @return array<string, int>
 */
function wcspc_item_meta_todo( array $counts, array $cfg ) {
	$core    = array( 'method_id', 'instance_id', 'cost', 'total_tax', 'taxes', 'Items', 'rate_code', 'rate_id', 'label', 'compound', 'tax_amount', 'shipping_tax_amount', 'rate_percent', 'discount_amount', 'discount_amount_tax', 'coupon_info', 'coupon_data' );
	$rules   = (array) $cfg['order_item_meta'];
	$covered = array_merge( (array) $rules['blank'], (array) $rules['text'], (array) $rules['delete'] );
	$todo    = array();
	foreach ( $counts as $key => $n ) {
		$key = (string) $key;
		if ( in_array( $key, $covered, true ) || wcspc_is_kana_key( $key ) ) {
			continue;
		}
		$listed = '_' === substr( $key, 0, 1 ) ? wcspc_looks_personal( $key ) : ! in_array( $key, $core, true ) && 0 !== strpos( $key, 'pa_' );
		if ( $listed ) {
			$todo[ $key ] = (int) $n;
		}
	}
	return $todo;
}

/**
 * Comment meta keys (of customers' comments) to decide on ("要確認"): every key except
 * WooCommerce's review rating and verified-owner flag and the keys the config deletes.
 *
 * @param array<string, int> $counts Meta key => number of rows.
 * @param array              $cfg    Config (comment_meta rules cover keys).
 * @return array<string, int>
 */
function wcspc_comment_meta_todo( array $counts, array $cfg ) {
	$rules = (array) $cfg['comment_meta'];
	$todo  = array();
	foreach ( $counts as $key => $n ) {
		$key = (string) $key;
		if ( in_array( $key, array( 'rating', 'verified' ), true ) || in_array( $key, (array) $rules['delete'], true ) ) {
			continue;
		}
		foreach ( (array) $rules['delete_prefix'] as $prefix ) {
			if ( 0 === strpos( $key, (string) $prefix ) ) {
				continue 2;
			}
		}
		$todo[ $key ] = (int) $n;
	}
	return $todo;
}

/**
 * Fake values written in place of personal data.
 *
 * @return array<string, string>
 */
function wcspc_fake() {
	return array(
		'first_name' => '顧客',
		'company'    => '',
		'address_1'  => 'テスト町1-2-3',
		'address_2'  => '',
		'city'       => 'テスト市',
		'postcode'   => '000-0000',
		'phone'      => '000-0000-0000',
		'kana'       => 'テスト',
		'text'       => 'テスト',
	);
}

/**
 * Rewrite fields of a decoded JSON value (an object or a list of objects).
 *
 * The map is field => replacement. A string replacement is written when the field exists.
 * array( 'if_nonempty' => 'X' ) is written only when the existing value is not null or ''.
 * Fields that are not in the map, and fields missing from the data, are left alone.
 *
 * @param mixed $data Decoded JSON.
 * @param array $map  Field map.
 * @return mixed
 */
function wcspc_rewrite_fields( $data, array $map ) {
	if ( ! is_array( $data ) ) {
		return $data;
	}
	$is_list = array_keys( $data ) === range( 0, count( $data ) - 1 );
	if ( $is_list ) {
		foreach ( $data as $i => $item ) {
			$data[ $i ] = wcspc_rewrite_fields( $item, $map );
		}
		return $data;
	}
	foreach ( $map as $field => $replacement ) {
		if ( ! array_key_exists( $field, $data ) ) {
			continue;
		}
		if ( is_array( $replacement ) ) {
			if ( array_key_exists( 'if_nonempty', $replacement ) && null !== $data[ $field ] && '' !== $data[ $field ] ) {
				$data[ $field ] = $replacement['if_nonempty'];
			}
			continue;
		}
		$data[ $field ] = $replacement;
	}
	return $data;
}

/**
 * Rewrite a JSON string with wcspc_rewrite_fields(). Invalid JSON becomes '[]'.
 *
 * @param string $json JSON text.
 * @param array  $map  Field map.
 * @return string
 */
function wcspc_rewrite_json( $json, array $map ) {
	$data = json_decode( (string) $json, true );
	if ( ! is_array( $data ) ) {
		return '[]';
	}
	return json_encode( wcspc_rewrite_fields( $data, $map ), JSON_UNESCAPED_UNICODE );
}

/**
 * The address index WooCommerce keeps for searching orders: the fields joined with spaces.
 *
 * @param array $a Address fields.
 * @return string
 */
function wcspc_address_index( array $a ) {
	$keys = array( 'first_name', 'last_name', 'company', 'address_1', 'address_2', 'city', 'state', 'postcode', 'country', 'email', 'phone' );
	$out  = array();
	foreach ( $keys as $k ) {
		$out[] = isset( $a[ $k ] ) ? (string) $a[ $k ] : '';
	}
	return implode( ' ', $out );
}

/**
 * Parse eval-file arguments: config=<path> and dry-run. WP-CLI takes arguments that start
 * with -- as its own options ("unknown --config parameter"), so the scripts are called with
 * bare words; the -- forms are accepted too for direct php use. Unrecognised words are
 * returned in 'unknown' (each script handles its own extra words such as write-allow=).
 *
 * @param array $args Arguments.
 * @return array{config: string|null, dry_run: bool, unknown: array}
 */
function wcspc_parse_args( array $args ) {
	$out = array(
		'config'  => null,
		'dry_run' => false,
		'unknown' => array(),
	);
	foreach ( $args as $arg ) {
		$bare = 0 === strpos( (string) $arg, '--' ) ? substr( (string) $arg, 2 ) : (string) $arg;
		if ( 'dry-run' === $bare ) {
			$out['dry_run'] = true;
		} elseif ( 0 === strpos( $bare, 'config=' ) ) {
			$out['config'] = substr( $bare, 7 );
		} else {
			$out['unknown'][] = $arg;
		}
	}
	return $out;
}

/**
 * Built-in configuration (WooCommerce core plus common Japanese plugins). A site's
 * JSON config adds to these lists; see assets/anonymize-config.example.json.
 *
 * @return array
 */
function wcspc_default_config() {
	return array(
		'staff_roles'     => array( 'administrator', 'shop_manager' ),
		'user_meta'       => array(
			// Keys set to a value that does not depend on the user.
			'const'  => array(
				'first_name'          => '顧客',
				'description'         => '',
				'billing_first_name'  => '顧客',
				'shipping_first_name' => '顧客',
				'billing_company'     => '',
				'shipping_company'    => '',
				'billing_address_1'   => '@address_1',
				'shipping_address_1'  => '@address_1',
				'billing_address_2'   => '',
				'shipping_address_2'  => '',
				'billing_city'        => '@city',
				'shipping_city'       => '@city',
				'billing_postcode'    => '@postcode',
				'shipping_postcode'   => '@postcode',
				'billing_phone'       => '@phone',
				'shipping_phone'      => '@phone',
			),
			// Keys set per user: @id, @email, @login, @display_name.
			'per_user' => array(
				'last_name'             => '@id',
				'billing_last_name'     => '@id',
				'shipping_last_name'    => '@id',
				'nickname'              => '@login',
				'billing_email'         => '@email',
				'_wc_email_verified_wp' => '@email',
			),
			'delete' => array( 'session_tokens', 'community-events-location' ),
			// Keys deleted by prefix.
			'delete_prefix' => array( '_woocommerce_persistent_cart_' ),
		),
		'order_meta'      => array(
			'blank'        => array( '_wc_order_attribution_user_agent', '_wc_order_attribution_referrer', '_wc_order_attribution_session_entry', '_customer_ip_address', '_customer_user_agent', 'jp4wc_tracking_id', '_burst_uid' ),
			'text'         => array( '_wc_other/jp4wc-pro/noshi-name', '_wc_other/jp4wc-pro/noshi-name-request' ),
			'delete'       => array( '_payjp_client_secret' ),
			'json'         => (object) array(),
		),
		// Order item meta (woocommerce_order_itemmeta). Nothing by default: add-on plugins name
		// these keys, so pii-inventory.php lists them and the site config says what to do.
		'order_item_meta' => array(
			'blank'  => array(),
			'text'   => array(),
			'delete' => array(),
		),
		// Meta of customers' comments that remain (approved ones; the rest are deleted).
		'comment_meta'    => array(
			'delete'        => array(),
			'delete_prefix' => array(),
		),
		'truncate_tables' => array( 'woocommerce_sessions', 'wpml_mails', 'wpmailsmtp_debug_events', 'wpmailsmtp_emails_log', 'actionscheduler_logs', 'actionscheduler_claims', 'actionscheduler_actions' ),
		'delete_post_types' => array( 'feedback', 'flamingo_inbound', 'flamingo_contact' ),
		// Options holding addresses typed into plugin screens (WP Mail SMTP's test-email recipient).
		'delete_options'  => array( 'wp_mail_smtp_test_email' ),
	);
}

/**
 * Merge a site config into the defaults: lists are appended, maps are merged (site wins).
 *
 * @param array $defaults Defaults.
 * @param array $site     Site config.
 * @return array
 */
function wcspc_merge_config( array $defaults, array $site ) {
	foreach ( $site as $key => $value ) {
		if ( ! array_key_exists( $key, $defaults ) ) {
			$defaults[ $key ] = $value;
			continue;
		}
		$base = $defaults[ $key ];
		if ( is_object( $base ) ) {
			$base = (array) $base;
		}
		if ( is_array( $base ) && is_array( $value ) ) {
			$base_is_list = array_keys( $base ) === range( 0, count( $base ) - 1 ) || array() === $base;
			$val_is_list  = array_keys( $value ) === range( 0, count( $value ) - 1 );
			if ( $base_is_list && $val_is_list ) {
				$defaults[ $key ] = array_values( array_unique( array_merge( $base, $value ) ) );
			} else {
				$defaults[ $key ] = wcspc_merge_config( $base, $value );
			}
		} else {
			$defaults[ $key ] = $value;
		}
	}
	return $defaults;
}

/**
 * Resolve a configured value: '@address_1' etc. map to the fake values, '@id' / '@email' /
 * '@login' / '@display_name' to the user's anonymized identity.
 *
 * @param string $value Configured value.
 * @param array  $user  array( 'id' => int, 'email' => string, 'login' => string, 'display_name' => string ).
 * @return string
 */
function wcspc_resolve( $value, array $user = array() ) {
	$value = (string) $value;
	if ( '' === $value || '@' !== $value[0] ) {
		return $value;
	}
	$name = substr( $value, 1 );
	$fake = wcspc_fake();
	if ( isset( $fake[ $name ] ) ) {
		return $fake[ $name ];
	}
	if ( 'id' === $name && isset( $user['id'] ) ) {
		return (string) $user['id'];
	}
	if ( isset( $user[ $name ] ) ) {
		return (string) $user[ $name ];
	}
	return $value;
}

/**
 * Anonymized identity of a customer.
 *
 * @param int $id User ID.
 * @return array
 */
function wcspc_customer_identity( $id ) {
	$id = (int) $id;
	return array(
		'id'           => $id,
		'login'        => 'customer' . $id,
		'email'        => 'customer' . $id . '@example.com',
		'display_name' => '顧客 ' . $id,
	);
}
