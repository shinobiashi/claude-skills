# Release Workflow

Detailed guide for automated ZIP creation, GitHub Release publication, and WordPress.org SVN deployment.

---

## Trigger: version tags

The release workflow is triggered by pushing a tag that matches `v*`:

```bash
git tag v1.2.0
git push origin v1.2.0
```

Use [Semantic Versioning](https://semver.org/): `v{MAJOR}.{MINOR}.{PATCH}`.

For pre-releases use a hyphen suffix: `v1.2.0-beta.1`, `v1.2.0-rc.1`. The condition `${{ !contains(github.ref, '-') }}` in the deploy job skips WordPress.org deployment for these tags automatically.

---

## Building production assets

Always build JS/CSS before creating the ZIP so the distributed archive contains compiled files:

```yaml
- uses: actions/setup-node@v7
  with:
    node-version: '24'
    cache: 'npm'
- run: npm ci
- run: npm run build
```

`npm ci` installs exact versions from `package-lock.json` and is faster than `npm install` in CI.

---

## Creating the plugin ZIP

### Option A: `wp-scripts plugin-zip` (recommended)

If `@wordpress/scripts` is in `devDependencies`, this command creates a ZIP respecting `.distignore`:

```yaml
- name: Create ZIP
  run: npx wp-scripts plugin-zip
```

The output file is named `{plugin-directory-name}.zip` and placed in the workspace root.

You can also add it as a `package.json` script:

```json
{
  "scripts": {
    "plugin-zip": "wp-scripts plugin-zip"
  }
}
```

### Option B: manual `zip` command

Use when `@wordpress/scripts` is not available:

```yaml
- name: Create ZIP
  run: |
    PLUGIN_SLUG=$(basename "$GITHUB_WORKSPACE")
    zip -r "${PLUGIN_SLUG}.zip" . \
      --exclude="*.git*" \
      --exclude=".github/*" \
      --exclude="node_modules/*" \
      --exclude="vendor/bin/*" \
      --exclude="tests/*" \
      --exclude="*.neon" \
      --exclude="phpunit.xml.dist" \
      --exclude=".phpcs.xml.dist" \
      --exclude="*.distignore" \
      --exclude="*.gitattributes" \
      --exclude="package.json" \
      --exclude="package-lock.json" \
      --exclude="composer.json" \
      --exclude="composer.lock"
```

---

## `.distignore` file

Both `wp-scripts plugin-zip` and custom zip scripts read `.distignore` to exclude files from the distribution ZIP. Commit this file to the plugin root:

```
# Development tools
.github
.phpcs.xml.dist
phpstan.neon
phpstan.neon.dist
phpstan-baseline.neon
phpunit.xml.dist
phpstan-bootstrap.php

# Source files (compiled output is in /build or /assets/build)
src/

# Dependencies source
node_modules
vendor/bin

# Tests
tests
bin

# Config/lock files
composer.json
composer.lock
package.json
package-lock.json
webpack.config.js

# VCS
.git
.gitignore
.gitattributes

# Editor/OS
.editorconfig
.DS_Store
.eslintrc*
.prettierrc*
.wp-env.json

# Keep README.md but exclude other *.md files
*.md
!README.md
```

Note: `vendor/` itself is typically **included** (production dependencies). Only `vendor/bin` is excluded.

Alternatively, use `.gitattributes` with `export-ignore` as a fallback:

```gitattributes
/.github      export-ignore
/tests        export-ignore
/node_modules export-ignore
```

---

## Attaching ZIP to GitHub Release

Use `softprops/action-gh-release@v2`:

```yaml
permissions:
  contents: write   # required at the job or workflow level

- name: Create GitHub Release
  uses: softprops/action-gh-release@v2
  with:
    files: '*.zip'
    generate_release_notes: true
```

`generate_release_notes: true` automatically fills the release body with commits since the last tag.

To mark a pre-release automatically:

```yaml
- name: Create GitHub Release
  uses: softprops/action-gh-release@v2
  with:
    files: '*.zip'
    generate_release_notes: true
    prerelease: ${{ contains(github.ref, '-') }}
```

---

## WordPress.org SVN deployment

Use `10up/action-wordpress-plugin-deploy@stable`:

```yaml
- name: Deploy to WordPress.org SVN
  uses: 10up/action-wordpress-plugin-deploy@stable
  env:
    WORDPRESS_USERNAME: ${{ secrets.WORDPRESS_USERNAME }}
    WORDPRESS_PASSWORD: ${{ secrets.WORDPRESS_PASSWORD }}
    SLUG: your-plugin-slug      # defaults to repo name; set explicitly if different
    BUILD_DIR: .                # directory to deploy from (after build)
    ASSETS_DIR: .wordpress-org  # optional: custom banner/icon/screenshot path
```

What the action does automatically:
1. Reads the `Stable tag` from `readme.txt`.
2. Syncs the workspace to SVN `trunk/`.
3. Creates a new tag in SVN `tags/{version}/`.

The action **does not** bump the `Stable tag` for you — update `readme.txt` before pushing the git tag.

Required secrets (add in repo Settings → Secrets and variables → Actions):

| Secret name           | Description                             |
|-----------------------|-----------------------------------------|
| `WORDPRESS_USERNAME`  | WordPress.org account username          |
| `WORDPRESS_PASSWORD`  | WordPress.org application password      |

Use an [Application Password](https://make.wordpress.org/core/2020/11/05/application-passwords-integration-guide/) rather than your real account password.

---

## Full release checklist

Before pushing the version tag, complete these steps in order:

1. Bump the version in the plugin main file header:
   ```php
   * Version: 1.2.0
   ```
2. Bump the version constant (if defined):
   ```php
   define( 'MY_PLUGIN_VERSION', '1.2.0' );
   ```
3. Update `readme.txt`:
   - Set `Stable tag: 1.2.0`
   - Add the `== Changelog ==` entry for this version
4. Commit all changes:
   ```bash
   git add plugin-name.php readme.txt
   git commit -m "Release 1.2.0"
   git push origin main
   ```
5. Push the version tag:
   ```bash
   git tag v1.2.0
   git push origin v1.2.0
   ```
6. Monitor the Actions tab. The `release` job creates the GitHub Release; the `deploy-wporg` job (if present) deploys to WordPress.org.
7. Verify on the WordPress.org plugin page that the new version appears (may take a few minutes for CDN propagation).

---

## Versioning convention

Use [Semantic Versioning](https://semver.org/) with a `v` prefix for git tags:

| Change type                           | Example                    |
|---------------------------------------|----------------------------|
| Patch (bug fix)                       | `v1.2.3` → `v1.2.4`       |
| Minor (new feature, backward compat)  | `v1.2.x` → `v1.3.0`       |
| Major (breaking change)               | `v1.x.x` → `v2.0.0`       |

The WordPress plugin header and `readme.txt` use the version without the `v` prefix (e.g. `1.2.0`).
