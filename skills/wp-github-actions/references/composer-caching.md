# Composer and npm Caching in GitHub Actions

Proper caching significantly reduces CI run time. This reference covers recommended patterns for both Composer and npm.

---

## Composer caching

### Option A: Cache `vendor/` directly (fastest for large dependency trees)

```yaml
- name: Cache Composer dependencies
  uses: actions/cache@v4
  with:
    path: vendor
    key: composer-php${{ matrix.php }}-${{ hashFiles('composer.lock') }}
    restore-keys: |
      composer-php${{ matrix.php }}-
      composer-

- run: composer install --no-progress --prefer-dist --no-interaction
```

Key design:
- Include PHP version in the key to avoid cross-version cache pollution.
- Hash `composer.lock` so any lock file change busts the cache.
- `restore-keys` allows partial cache hits when the lock file changes.

### Option B: Cache Composer download cache (more portable)

```yaml
- uses: shivammathur/setup-php@v2
  with:
    php-version: '8.3'
    tools: composer
    coverage: none
  env:
    COMPOSER_TOKEN: ${{ secrets.GITHUB_TOKEN }}  # avoids GitHub API rate limits

- name: Get Composer cache dir
  id: composer-cache
  run: echo "dir=$(composer config cache-files-dir)" >> $GITHUB_OUTPUT

- uses: actions/cache@v4
  with:
    path: ${{ steps.composer-cache.outputs.dir }}
    key: composer-${{ hashFiles('composer.lock') }}
```

This caches the Composer download cache (`~/.composer/cache`) rather than `vendor/`. `composer install` still runs but package extraction is fast because archives are already local.

---

## npm caching

`actions/setup-node@v5` has built-in caching — no separate `actions/cache` step needed:

```yaml
- uses: actions/setup-node@v5
  with:
    node-version: '24'
    cache: 'npm'
```

This caches `~/.npm` automatically, keyed by `package-lock.json`. Subsequent `npm ci` calls are dramatically faster.

For Yarn:

```yaml
- uses: actions/setup-node@v5
  with:
    node-version: '24'
    cache: 'yarn'
- run: yarn install --frozen-lockfile
```

### Do not cache `node_modules/` directly

Caching `node_modules/` between runs is fragile and not recommended:
- `node_modules/` contains platform-specific binaries.
- `npm ci` with `~/.npm` cache is fast enough and always produces a clean install.

---

## `--prefer-dist` vs `--prefer-source`

| Flag              | When to use                                                     |
|-------------------|-----------------------------------------------------------------|
| `--prefer-dist`   | Default for CI. Downloads ZIP archives — faster, no git history.|
| `--prefer-source` | Local dev when you need to inspect or patch vendor source.      |

Always use `--prefer-dist` in CI.

---

## `--no-dev` for release/production installs

For release and deployment jobs, exclude dev dependencies from the ZIP:

```yaml
- run: composer install --no-progress --prefer-dist --no-dev
```

For CI quality jobs (PHPCS, PHPStan, PHPUnit), omit `--no-dev` — the tools are in `require-dev`.

---

## Private Composer packages

If the project requires packages from a private registry (e.g., WooCommerce.com extensions or a private Satis/Packagist server), authenticate via `COMPOSER_AUTH`:

```yaml
- run: composer install --no-progress --prefer-dist --no-interaction
  env:
    COMPOSER_AUTH: ${{ secrets.COMPOSER_AUTH }}
```

`COMPOSER_AUTH` should be a JSON string stored as a GitHub Actions secret:

```json
{"http-basic": {"woocommerce.com": {"username": "...", "password": "..."}}}
```

For GitHub-hosted private packages, use `COMPOSER_TOKEN` instead:

```yaml
  env:
    COMPOSER_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

---

## Cache invalidation

If CI is using stale cached dependencies, manually invalidate by:

1. Updating `composer.lock` (any `composer update` will do).
2. Updating `package-lock.json` (any `npm install` change will do).
3. Or: go to the repo's **Actions → Management → Caches** UI and delete the relevant entry.
