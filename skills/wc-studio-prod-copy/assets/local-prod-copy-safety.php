<?php
/**
 * Plugin Name: Local production copy safety
 * Description: Keeps a local copy of a production site from acting like production. Stops WP-Cron and the Action Scheduler async runner, unloads mail-sending plugins (WordPress Studio then saves mail locally), and blocks outbound HTTP to non-local hosts. Does nothing unless the site is local.
 * Version: 1.0.0
 *
 * Place this file in wp-content/mu-plugins/ of the LOCAL site before pulling production data.
 * It is a template from the wc-studio-prod-copy skill; it is not meant for any repository.
 *
 * Optional constants (wp-config.php):
 * - LOCAL_PROD_COPY_UNLOAD_PLUGINS: comma-separated plugin directory names to unload too
 *   (backups, integrations), e.g. 'updraftplus,cart-bridge-jp'.
 * - LOCAL_PROD_COPY_HTTP_ALLOW: comma-separated hosts outbound HTTP may reach besides local
 *   hosts, the site itself and *.wordpress.org. '*.example.com' matches subdomains.
 * - LOCAL_PROD_COPY_ALLOW_HTTP: true to stop blocking outbound HTTP.
 * - LOCAL_PROD_COPY_BLOCK_MAIL: true to drop all mail instead of letting Studio save it.
 *
 * @package local-prod-copy-safety
 */

defined( 'ABSPATH' ) || exit;

/**
 * Whether a host name is a local development host.
 *
 * @param string $host Host.
 * @return bool
 */
function lpcs_is_local_host( $host ) {
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
 * Whether this site is a local copy (environment local/development and a local host).
 *
 * @param string $env_type Environment type.
 * @param string $home_url Home URL.
 * @return bool
 */
function lpcs_is_local( $env_type, $home_url ) {
	$host = parse_url( (string) $home_url, PHP_URL_HOST );
	return in_array( $env_type, array( 'local', 'development' ), true ) && is_string( $host ) && lpcs_is_local_host( $host );
}

/**
 * Split a comma-separated constant into a list.
 *
 * @param string $name Constant name.
 * @return string[]
 */
function lpcs_list_constant( $name ) {
	if ( ! defined( $name ) ) {
		return array();
	}
	return array_values( array_filter( array_map( 'trim', explode( ',', (string) constant( $name ) ) ) ) );
}

/**
 * Whether a plugin (basename like 'wp-mail-smtp/wp_mail_smtp.php') should not load here.
 *
 * @param string   $basename Plugin basename.
 * @param string[] $extra    Extra directory names to unload.
 * @return bool
 */
function lpcs_should_unload( $basename, array $extra ) {
	$dir = strtolower( strtok( (string) $basename, '/' ) );
	if ( in_array( $dir, array_map( 'strtolower', $extra ), true ) ) {
		return true;
	}
	// Plugins that send mail through an external service or SMTP server.
	return (bool) preg_match( '/(smtp|mailgun|sendgrid|postmark|sparkpost|mailjet|sendinblue|brevo|wp-ses|offload-ses|amazon-ses|mailersend|elastic-email)/', $dir );
}

/**
 * Filter for option_active_plugins.
 *
 * @param mixed $plugins Active plugins.
 * @return mixed
 */
function lpcs_filter_active_plugins( $plugins ) {
	if ( ! is_array( $plugins ) ) {
		return $plugins;
	}
	$extra = lpcs_list_constant( 'LOCAL_PROD_COPY_UNLOAD_PLUGINS' );
	$kept  = array();
	foreach ( $plugins as $basename ) {
		if ( lpcs_should_unload( $basename, $extra ) ) {
			$GLOBALS['lpcs_unloaded'][] = $basename;
			continue;
		}
		$kept[] = $basename;
	}
	return $kept;
}

/**
 * Filter for site_option_active_sitewide_plugins (keys are basenames).
 *
 * @param mixed $plugins Network-active plugins.
 * @return mixed
 */
function lpcs_filter_sitewide_plugins( $plugins ) {
	if ( ! is_array( $plugins ) ) {
		return $plugins;
	}
	$extra = lpcs_list_constant( 'LOCAL_PROD_COPY_UNLOAD_PLUGINS' );
	foreach ( array_keys( $plugins ) as $basename ) {
		if ( lpcs_should_unload( $basename, $extra ) ) {
			$GLOBALS['lpcs_unloaded'][] = $basename;
			unset( $plugins[ $basename ] );
		}
	}
	return $plugins;
}

/**
 * Whether outbound HTTP to a URL is allowed.
 *
 * @param string   $url      Request URL.
 * @param string   $own_host The site's host.
 * @param string[] $allow    Allowed hosts ('*.example.com' matches subdomains).
 * @return bool
 */
function lpcs_http_allowed( $url, $own_host, array $allow ) {
	$host = strtolower( (string) parse_url( (string) $url, PHP_URL_HOST ) );
	if ( '' === $host || lpcs_is_local_host( $host ) || strtolower( (string) $own_host ) === $host ) {
		return true;
	}
	foreach ( $allow as $pattern ) {
		$pattern = strtolower( $pattern );
		if ( $pattern === $host ) {
			return true;
		}
		if ( 0 === strpos( $pattern, '*.' ) ) {
			$suffix = substr( $pattern, 1 );
			if ( substr( $host, -strlen( $suffix ) ) === $suffix ) {
				return true;
			}
		}
	}
	return false;
}

/**
 * Filter for pre_http_request.
 *
 * @param false|array|WP_Error $pre  Short-circuit value.
 * @param array                $args Request arguments.
 * @param string               $url  Request URL.
 * @return false|array|WP_Error
 */
function lpcs_block_http( $pre, $args, $url ) {
	if ( false !== $pre ) {
		return $pre;
	}
	$allow = array_merge( array( 'wordpress.org', '*.wordpress.org' ), lpcs_list_constant( 'LOCAL_PROD_COPY_HTTP_ALLOW' ) );
	if ( lpcs_http_allowed( $url, (string) parse_url( home_url(), PHP_URL_HOST ), $allow ) ) {
		return $pre;
	}
	$GLOBALS['lpcs_blocked_hosts'][ (string) parse_url( (string) $url, PHP_URL_HOST ) ] = true;
	return new WP_Error( 'local_prod_copy_blocked', 'Outbound HTTP is blocked on this local copy of production (local-prod-copy-safety).' );
}

/**
 * Admin notice listing what is switched off.
 */
function lpcs_admin_notice() {
	if ( ! current_user_can( 'manage_options' ) ) {
		return;
	}
	$items   = array( 'WP-Cron', 'Action Scheduler の非同期実行' );
	$items[] = defined( 'LOCAL_PROD_COPY_BLOCK_MAIL' ) && LOCAL_PROD_COPY_BLOCK_MAIL ? 'メール送信（すべて破棄）' : 'メール送信プラグイン（メールは Studio に保存）';
	if ( ! ( defined( 'LOCAL_PROD_COPY_ALLOW_HTTP' ) && LOCAL_PROD_COPY_ALLOW_HTTP ) ) {
		$items[] = '外部への HTTP 通信';
	}
	$unloaded = empty( $GLOBALS['lpcs_unloaded'] ) ? '' : ' 読み込んでいないプラグイン: ' . implode( ', ', array_unique( $GLOBALS['lpcs_unloaded'] ) );
	printf(
		'<div class="notice notice-warning"><p><strong>%s</strong> %s%s</p></div>',
		esc_html( '本番の複製（ローカル）: 止めているもの —' ),
		esc_html( implode( '・', $items ) ),
		esc_html( $unloaded )
	);
}

if ( ! lpcs_is_local( function_exists( 'wp_get_environment_type' ) ? wp_get_environment_type() : 'production', home_url() ) ) {
	return;
}

if ( ! defined( 'DISABLE_WP_CRON' ) ) {
	define( 'DISABLE_WP_CRON', true );
}
// Also covers direct requests to wp-cron.php, which ignore DISABLE_WP_CRON.
add_filter( 'pre_get_ready_cron_jobs', '__return_empty_array' );
add_filter( 'action_scheduler_allow_async_request_runner', '__return_false' );
add_filter( 'option_active_plugins', 'lpcs_filter_active_plugins' );
add_filter( 'site_option_active_sitewide_plugins', 'lpcs_filter_sitewide_plugins' );
if ( ! ( defined( 'LOCAL_PROD_COPY_ALLOW_HTTP' ) && LOCAL_PROD_COPY_ALLOW_HTTP ) ) {
	add_filter( 'pre_http_request', 'lpcs_block_http', 10, 3 );
}
if ( defined( 'LOCAL_PROD_COPY_BLOCK_MAIL' ) && LOCAL_PROD_COPY_BLOCK_MAIL ) {
	add_filter( 'pre_wp_mail', '__return_false' );
}
add_action( 'admin_notices', 'lpcs_admin_notice' );
