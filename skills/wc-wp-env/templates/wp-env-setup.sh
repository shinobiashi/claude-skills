#!/usr/bin/env bash
#
# Provisions the wp-env development site into a store you can check out on.
# Runs after every `wp-env start` (.wp-env.json lifecycleScripts.afterStart), so every
# step must be idempotent: re-running never duplicates products, customers or coupons.
#
# Only the development environment is provisioned. The tests environment stays pristine
# so automated tests start from a known-empty store.

set -euo pipefail

# On the host, re-run this same file once inside the cli container. Each `wp-env run`
# pays a docker exec round trip; ~20 separate wp calls would pay it on every start.
if [ "${1:-}" != "in-container" ]; then
	PLUGIN_DIR="$(basename "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")"
	# The tests site gets the production-default order storage and nothing else, so E2E
	# runs exercise HPOS like a real store does. Non-fatal: there may be no tests environment.
	npx wp-env run tests-cli wp wc hpos enable >/dev/null 2>&1 ||
		echo "NOTE: HPOS not enabled on the tests environment (no tests environment, or a plugin blocks it)."
	exec npx wp-env run cli bash "wp-content/plugins/${PLUGIN_DIR}/bin/wp-env-setup.sh" in-container
fi

echo "Skipping the WooCommerce setup wizard…"
wp option update woocommerce_onboarding_profile '{"skipped":true}' --format=json >/dev/null

echo "Store: Japan (Tokyo), JPY, 0 decimals…"
wp option update woocommerce_default_country 'JP:JP13' >/dev/null
wp option update woocommerce_currency JPY >/dev/null
wp option update woocommerce_price_num_decimals 0 >/dev/null

echo "Order storage: HPOS (what a newly installed WooCommerce store uses)…"
# A store created by `wp plugin activate` alone comes up on legacy posts storage. Plain
# `enable`, not `--for-new-shop`: that flag refuses as soon as the store holds any data,
# i.e. on every run after the first. `enable` is idempotent ("already enabled", exit 0).
# A plugin that has not declared custom_order_tables compatibility blocks it, and that
# must not stop the environment from starting — verify-env.sh reports the HPOS state.
if ! wp wc hpos enable >/dev/null 2>&1; then
	echo "  WARNING: HPOS could not be enabled — inspect with: wp wc hpos compatibility-info"
fi

echo "Permalinks: /%postname%/…"
wp rewrite structure '/%postname%/' --hard >/dev/null

echo "Payment methods: Cash on Delivery + Direct Bank Transfer…"
# `wp option patch` can't be used here: on a fresh WC install
# woocommerce_{cod,bacs}_settings doesn't exist yet, so get_option() returns
# its own `false` default — a non-array `option patch` refuses to add a key
# to. `wp eval` merges 'enabled' into whatever is there (array or not),
# which is idempotent on every re-run.
for gateway in cod bacs; do
	wp eval "update_option( 'woocommerce_${gateway}_settings', array_merge( (array) get_option( 'woocommerce_${gateway}_settings', array() ), array( 'enabled' => 'yes' ) ) );" >/dev/null
done

echo "Shipping: flat rate zone…"
# Zone id 0 ("Locations not covered by your other zones") always exists, so
# checking for *any* zone would never create ours — look for it by name.
if ! wp wc shipping_zone list --user=1 --format=json 2>/dev/null | grep -q '"name":"Everywhere"'; then
	ZONE_ID="$(wp wc shipping_zone create --name='Everywhere' --user=1 --porcelain)"
	wp wc shipping_zone_method create "$ZONE_ID" --method_id=flat_rate --enabled=true --user=1 >/dev/null
	# "wc shipping_zone_location" only has a "list" subcommand (no "create"),
	# so set the location directly through the WC_Shipping_Zone API. '*' is
	# not a valid continent code (WC_Countries::get_continents() keys are
	# ISO continent codes like 'AF', 'EU', ...) — a zone with no locations
	# that actually match an address never matches that address, so the
	# zone must list every continent explicitly to behave as "everywhere".
	wp eval "\$z = new WC_Shipping_Zone( ${ZONE_ID} ); foreach ( array_keys( WC()->countries->get_continents() ) as \$continent ) { \$z->add_location( \$continent, 'continent' ); } \$z->save();" >/dev/null
else
	echo "  shipping zone already exists, skipping."
fi

echo "Test customer (customer@example.com / password)…"
if ! wp user get customer@example.com --field=ID >/dev/null 2>&1; then
	wp user create customer customer@example.com --role=customer --user_pass=password >/dev/null
else
	echo "  customer already exists, skipping."
fi

echo "Sample products…"
for product in 'Sample Product A:1000' 'Sample Product B:2500'; do
	name="${product%%:*}"
	price="${product##*:}"
	if [ -z "$(wp post list --post_type=product --title="$name" --field=ID 2>/dev/null)" ]; then
		wp wc product create --name="$name" --type=simple --regular_price="$price" --user=1 >/dev/null
	else
		echo "  ${name} already exists, skipping."
	fi
done

echo "Test coupon (TESTCOUPON, 10% off)…"
if [ -z "$(wp post list --post_type=shop_coupon --title=TESTCOUPON --field=ID 2>/dev/null)" ]; then
	wp wc shop_coupon create --code=TESTCOUPON --discount_type=percent --amount=10 --user=1 >/dev/null
else
	echo "  coupon already exists, skipping."
fi

# ---- Plugin-specific provisioning goes below (keep it idempotent) ----

echo "wp-env-setup.sh done."
