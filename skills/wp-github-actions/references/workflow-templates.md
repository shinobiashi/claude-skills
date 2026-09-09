# Workflow Templates

Copy-paste ready YAML templates for WordPress plugin CI/CD.

---

## ci-php.yml

Full PHP quality workflow: PHPCS, PHPStan, and PHPUnit with a PHP version matrix.

```yaml
name: PHP Quality

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main, develop]

jobs:
  phpcs:
    name: PHPCS
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - uses: shivammathur/setup-php@v2
        with:
          php-version: '8.3'
          tools: composer
          coverage: none

      - name: Cache Composer dependencies
        uses: actions/cache@v6
        with:
          path: vendor
          key: composer-${{ hashFiles('composer.lock') }}
          restore-keys: composer-

      - run: composer install --no-progress --prefer-dist

      - run: composer run phpcs

  phpstan:
    name: PHPStan
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - uses: shivammathur/setup-php@v2
        with:
          php-version: '8.3'
          tools: composer
          coverage: none

      - name: Cache Composer dependencies
        uses: actions/cache@v6
        with:
          path: vendor
          key: composer-${{ hashFiles('composer.lock') }}
          restore-keys: composer-

      - run: composer install --no-progress --prefer-dist

      - run: composer run phpstan

  phpunit:
    name: PHPUnit (PHP ${{ matrix.php }})
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        php: ['8.3', '8.4', '8.5']
    services:
      mysql:
        image: mysql:8.0
        env:
          MYSQL_ROOT_PASSWORD: root
          MYSQL_DATABASE: wordpress_test
        ports:
          - 3306:3306
        options: >-
          --health-cmd="mysqladmin ping"
          --health-interval=10s
          --health-timeout=5s
          --health-retries=5
    steps:
      - uses: actions/checkout@v7

      - uses: shivammathur/setup-php@v2
        with:
          php-version: ${{ matrix.php }}
          tools: composer
          coverage: none

      - name: Cache Composer dependencies
        uses: actions/cache@v6
        with:
          path: vendor
          key: composer-${{ matrix.php }}-${{ hashFiles('composer.lock') }}
          restore-keys: composer-${{ matrix.php }}-

      - run: composer install --no-progress --prefer-dist

      - name: Install WordPress test suite
        run: bash bin/install-wp-tests.sh wordpress_test root root 127.0.0.1:3306 latest

      - run: composer run test
```

Notes:
- Replace `composer run phpcs`, `composer run phpstan`, `composer run test` with the actual script names from `composer.json`.
- `fail-fast: false` keeps the matrix running all PHP versions even if one fails, giving you full visibility.
- `bin/install-wp-tests.sh` is the standard WordPress test bootstrap script. If your project stores it elsewhere, adjust the path.

---

## ci-js.yml

JS/CSS linting and production build verification.

```yaml
name: JS Quality

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main, develop]

jobs:
  lint-js:
    name: Lint JS
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - uses: actions/setup-node@v7
        with:
          node-version: '24'
          cache: 'npm'

      - run: npm ci

      - run: npm run lint:js

  lint-css:
    name: Lint CSS
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - uses: actions/setup-node@v7
        with:
          node-version: '24'
          cache: 'npm'

      - run: npm ci

      - run: npm run lint:css

  build:
    name: Build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - uses: actions/setup-node@v7
        with:
          node-version: '24'
          cache: 'npm'

      - run: npm ci

      - run: npm run build
```

Notes:
- `cache: 'npm'` in `actions/setup-node@v7` caches `~/.npm` automatically.
- Script names (`lint:js`, `lint:css`, `build`) must match entries in `package.json`.
- If the project does not have separate `lint:js` / `lint:css` scripts, use a single `lint` script or inline `wp-scripts lint-js` / `wp-scripts lint-style`.

---

## release.yml

Automated release on version tag push: build assets, create ZIP, publish GitHub Release, and optionally deploy to WordPress.org SVN.

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: write

jobs:
  release:
    name: Build & Release
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      # ── Build JS/CSS assets ──────────────────────────────────────────────
      - uses: actions/setup-node@v7
        with:
          node-version: '24'
          cache: 'npm'

      - run: npm ci

      - run: npm run build

      # ── Install Composer dependencies (no dev) ───────────────────────────
      - uses: shivammathur/setup-php@v2
        with:
          php-version: '8.3'
          tools: composer
          coverage: none

      - run: composer install --no-progress --prefer-dist --no-dev

      # ── Create plugin ZIP ────────────────────────────────────────────────
      # Option A: wp-scripts plugin-zip (recommended when @wordpress/scripts is installed)
      - name: Create ZIP (wp-scripts)
        run: npx wp-scripts plugin-zip

      # Option B: manual zip (uncomment if wp-scripts is not available)
      # - name: Create ZIP (manual)
      #   run: |
      #     PLUGIN_SLUG=$(basename "$GITHUB_WORKSPACE")
      #     zip -r "${PLUGIN_SLUG}.zip" . \
      #       --exclude="*.git*" \
      #       --exclude="node_modules/*" \
      #       --exclude="tests/*" \
      #       --exclude=".github/*" \
      #       --exclude="*.neon" \
      #       --exclude="phpunit.xml.dist" \
      #       --exclude="*.distignore"

      # ── Publish GitHub Release ───────────────────────────────────────────
      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          files: '*.zip'
          generate_release_notes: true

  deploy-wporg:
    name: Deploy to WordPress.org
    runs-on: ubuntu-latest
    needs: release
    # Remove the `if` line to always deploy on tag push
    if: ${{ !contains(github.ref, '-') }}   # skip pre-release tags like v1.0.0-beta
    steps:
      - uses: actions/checkout@v7

      - uses: actions/setup-node@v7
        with:
          node-version: '24'
          cache: 'npm'

      - run: npm ci && npm run build

      - uses: shivammathur/setup-php@v2
        with:
          php-version: '8.3'
          tools: composer
          coverage: none

      - run: composer install --no-progress --prefer-dist --no-dev

      - name: Deploy to WordPress.org SVN
        uses: 10up/action-wordpress-plugin-deploy@stable
        env:
          WORDPRESS_USERNAME: ${{ secrets.WORDPRESS_USERNAME }}
          WORDPRESS_PASSWORD: ${{ secrets.WORDPRESS_PASSWORD }}
          SLUG: your-plugin-slug   # replace with the actual WordPress.org slug
```

Notes:
- `permissions: contents: write` is required for `softprops/action-gh-release` to create releases.
- Replace `your-plugin-slug` with the actual slug registered on WordPress.org.
- The `deploy-wporg` job is separate and optional. Remove it if WordPress.org deployment is not needed.
- The `if: ${{ !contains(github.ref, '-') }}` condition skips deployment for pre-release tags (e.g. `v1.0.0-beta`).
- `10up/action-wordpress-plugin-deploy` reads `readme.txt` to determine the `Stable tag` and syncs trunk + creates the SVN tag automatically.
