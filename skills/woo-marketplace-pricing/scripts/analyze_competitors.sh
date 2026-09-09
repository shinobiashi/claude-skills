#!/bin/bash

# WooCommerce Marketplace Competitor Price Analyzer
#
# Usage: bash analyze_competitors.sh "keyword"
#
# This script searches the WooCommerce.com Marketplace for extensions
# matching the given keyword and extracts pricing information.
# Designed to be used by Claude Code as part of the pricing skill.
#
# Note: This script uses the public wccom-extensions search API
# (the same API used by the in-dashboard marketplace browser).
# The HTML search page at woocommerce.com/search/ is client-side
# rendered and cannot be scraped with curl.
# Results should be verified manually on woocommerce.com.

KEYWORD="${1:?Usage: bash analyze_competitors.sh \"keyword\"}"
ENCODED=$(echo "$KEYWORD" | sed 's/ /%20/g')
API_URL="https://woocommerce.com/wp-json/wccom-extensions/1.0/search?term=${ENCODED}"

echo "============================================"
echo "WooCommerce Marketplace Competitor Analysis"
echo "Search: $KEYWORD"
echo "Date: $(date +%Y-%m-%d)"
echo "============================================"
echo ""
echo "Querying ${API_URL}"
echo ""

# Fetch search results from the public API
RESULT=$(curl -sL "$API_URL" \
  -H "User-Agent: Mozilla/5.0" \
  --max-time 15 2>/dev/null)

if [ -z "$RESULT" ] || ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: Could not fetch marketplace data (or python3 unavailable)."
  echo ""
  echo "Manual research required. Visit:"
  echo "  https://woocommerce.com/search/?q=${ENCODED}"
  echo ""
  echo "For each competitor, collect:"
  echo "  1. Product name"
  echo "  2. Annual price"
  echo "  3. Key features (3-5)"
  echo "  4. Rating and review count"
  echo "  5. Free version available?"
  exit 1
fi

echo "Found products (verify details on woocommerce.com):"
echo "-----------------------------------------------------------"

echo "$RESULT" | python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    print("  ERROR: API response was not valid JSON.")
    sys.exit(1)

products = data.get("products", [])
if not products:
    print("  No products found for this keyword.")
    sys.exit(0)

print("  {:<45} {:>9} {:>7} {:>8}  {}".format("Product", "Price/yr", "Rating", "Reviews", "Vendor"))
for p in products[:20]:
    title = (p.get("title") or "")[:44]
    price = p.get("raw_price")
    price_s = f"${price}" if price is not None else "n/a"
    rating = p.get("rating")
    rating_s = f"{rating}" if rating is not None else "-"
    reviews = p.get("reviews_count")
    reviews_s = f"{reviews}" if reviews is not None else "-"
    vendor = p.get("vendor_name") or ""
    print(f"  {title:<45} {price_s:>9} {rating_s:>7} {reviews_s:>8}  {vendor}")
'

echo ""
echo "-----------------------------------------------------------"
echo ""
echo "NOTE: \$0 usually means a free/provider-subsidized extension."
echo "Verify features and current prices directly at:"
echo "  https://woocommerce.com/search/?q=${ENCODED}"
echo ""
echo "Recommended analysis template:"
echo ""
echo "| Product | Annual Price | Key Differentiator | Rating |"
echo "|---------|-------------|-------------------|--------|"
echo "| [Name]  | \$XX/year   | [Feature]          | X.X/5  |"
echo "| [Name]  | \$XX/year   | [Feature]          | X.X/5  |"
echo "| [Name]  | \$XX/year   | [Feature]          | X.X/5  |"
echo ""
echo "Price positioning options:"
echo "  - Below market:  Set price 10-20% below average (market share strategy)"
echo "  - At market:     Match average competitor price (safe positioning)"
echo "  - Above market:  Set 10-30% above average (premium positioning, needs clear differentiator)"
