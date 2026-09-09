---
name: wp-github-actions
version: "1.0.0"
description: "Use when setting up or updating GitHub Actions CI/CD workflows for WordPress plugins: PHPCS, PHPStan, PHPUnit matrix testing, JS/CSS linting, automated ZIP release with GitHub Release attachment, and WordPress.org SVN deployment via action."
compatibility: "Targets GitHub Actions with ubuntu-latest (24.04) runners. Uses actions/checkout@v5 (v4 still OK), shivammathur/setup-php@v2, actions/setup-node@v5, actions/cache@v4, actions/upload-artifact@v4 (v3 is retired and fails)."
---

# WP GitHub Actions

## When to use

Use this skill when setting up or updating GitHub Actions CI/CD for a WordPress plugin, for example:

- Adding GitHub Actions to a WordPress plugin repo for the first time
- Adding or updating a PHPCS, PHPStan, or PHPUnit workflow
- Adding a JS/CSS lint workflow (`wp-scripts lint-js`, `wp-scripts lint-style`)
- Setting up automatic ZIP creation and GitHub Release on tag push
- Setting up WordPress.org SVN deployment via `10up/action-wordpress-plugin-deploy`
- Updating PHP/Node version matrices or action versions

## Inputs required

- Which CI checks are needed (PHPCS, PHPStan, PHPUnit, JS lint, E2E)
- PHP version matrix (e.g., `["8.3", "8.4", "8.5"]`; 8.1/8.2 are EOL or nearly so)
- Whether to add release automation (tag push → ZIP → GitHub Release)
- Whether to add WordPress.org SVN deployment
- Node.js version (default: 24 LTS)

## Procedure

### 0) Audit existing workflows

Before creating anything, inspect what is already in place:

```bash
ls .github/workflows/
```

- Note which jobs already exist and which are missing or outdated.
- Note PHP/Node versions and action versions (`@v3` vs `@v4`, etc.).
- Check `composer.json` for `scripts` entries: `phpcs`, `phpstan`, `test`.
- Check `package.json` for `scripts` entries: `lint:js`, `lint:css`, `build`.

### 1) PHP quality workflow (`ci-php.yml`)

Create `.github/workflows/ci-php.yml` with three jobs:

- `phpcs` — PHP_CodeSniffer check via `composer run phpcs`
- `phpstan` — Static analysis via `composer run phpstan`
- `phpunit` — Unit/integration tests with a PHP version matrix and MySQL service

Use `shivammathur/setup-php@v2` for PHP setup.
Add Composer dependency caching keyed by `composer.lock`.

See: `references/workflow-templates.md` — ci-php.yml section

### 2) JS/CSS quality workflow (`ci-js.yml`)

Create `.github/workflows/ci-js.yml` with:

- `lint-js` — `npm run lint:js`
- `lint-css` — `npm run lint:css`
- `build` — `npm run build` (verify build succeeds)

Use `actions/setup-node@v5` with `cache: 'npm'`.

See: `references/workflow-templates.md` — ci-js.yml section

### 3) Release workflow (`release.yml`)

Create `.github/workflows/release.yml` triggered on `push: tags: ['v*']`:

1. Build JS/CSS assets (`npm ci && npm run build`)
2. Install Composer dependencies (no dev)
3. Create ZIP via `wp-scripts plugin-zip` or a custom `zip` command
4. Create GitHub Release and attach the ZIP via `softprops/action-gh-release@v2`
5. (Optional) Deploy to WordPress.org SVN via `10up/action-wordpress-plugin-deploy@stable`

See:
- `references/workflow-templates.md` — release.yml section
- `references/release-workflow.md`

### 4) Add repository secrets for WordPress.org (if needed)

If deploying to WordPress.org, add these secrets in the repo settings:

| Secret name           | Value                          |
|-----------------------|--------------------------------|
| `WORDPRESS_USERNAME`  | WordPress.org account username |
| `WORDPRESS_PASSWORD`  | WordPress.org account password |

### 5) Verify on first run

- Push a small change to `main` or open a PR to trigger `ci-php.yml` and `ci-js.yml`.
- For the release workflow, push a test tag: `git tag v0.0.1-test && git push origin v0.0.1-test`.
- Check the Actions tab for red/yellow jobs and fix any failures before merging.

## Verification

- All jobs in `ci-php.yml` and `ci-js.yml` must pass on the first real PR.
- The release workflow must produce a `.zip` attached to the GitHub Release.
- If WordPress.org deployment is enabled, confirm the SVN tag is created after a release.

## Failure modes / debugging

- `composer install` fails → add `composer validate` step; ensure `composer.lock` is committed.
- PHPUnit fails with DB connection errors → confirm the MySQL service block is present and `install-wp-tests.sh` receives the correct host/port (`127.0.0.1:3306`).
- PHPCS "Standards not found" → verify `dealerdirect/phpcodesniffer-composer-installer` is in `require-dev` and `composer install` runs before the lint step.
- ZIP too large or contains dev files → add a `.distignore` file (see `references/release-workflow.md`).
- `wp-scripts plugin-zip` not found → ensure `@wordpress/scripts` is in `devDependencies` and `npm ci` runs before the zip step.
- `softprops/action-gh-release` permission error → add `permissions: contents: write` to the release job.
- WordPress.org deploy fails with auth error → double-check `WORDPRESS_USERNAME` / `WORDPRESS_PASSWORD` secrets.

## Escalation

- If the project uses a monorepo or a custom build pipeline not covered by `wp-scripts`, ask the user for the exact build command before writing the workflow.
- If the PHP version matrix needs WooCommerce compatibility testing, ask which WooCommerce versions to target.
