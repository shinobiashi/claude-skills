# SVN Workflow for WordPress.org Plugins

## Repository Structure

Every WordPress.org plugin SVN repository follows this structure:

```
https://plugins.svn.wordpress.org/my-plugin/
├── trunk/          — Development/latest code
├── tags/           — Versioned releases
│   ├── 1.0.0/
│   ├── 1.1.0/
│   └── 1.2.0/
├── branches/       — Feature branches (optional)
│   └── feature-x/
└── assets/         — Plugin directory images (NOT included in downloads)
    ├── banner-1544x500.png
    ├── banner-772x250.png
    ├── icon-256x256.png
    ├── icon-128x128.png
    └── screenshot-1.png
```

**Important:** The `/assets/` directory is served separately and is not included in plugin ZIP downloads.

---

## Initial Checkout

### Check Out Entire Repository

```bash
svn checkout https://plugins.svn.wordpress.org/my-plugin/ ~/svn/my-plugin
```

This can be slow for plugins with many tags. Use a partial checkout instead:

### Check Out Only What You Need

```bash
# Check out trunk only
svn checkout https://plugins.svn.wordpress.org/my-plugin/trunk ~/svn/my-plugin/trunk

# Check out assets only
svn checkout https://plugins.svn.wordpress.org/my-plugin/assets ~/svn/my-plugin/assets

# Check out a specific tag
svn checkout https://plugins.svn.wordpress.org/my-plugin/tags/1.0.0 ~/svn/my-plugin/tags/1.0.0
```

### Authentication

```bash
# SVN will prompt for credentials on first use
# To specify explicitly:
svn checkout https://plugins.svn.wordpress.org/my-plugin/trunk ~/svn/my-plugin/trunk \
    --username=mywordpressusername
```

Credentials are cached in `~/.subversion/auth/`. If you need to clear them:

```bash
rm -rf ~/.subversion/auth/
```

---

## Releasing a New Version

### Step 1: Update Local trunk

```bash
cd ~/svn/my-plugin/trunk
svn update
```

### Step 2: Sync Plugin Files to trunk

Use `rsync` to copy your development files to the SVN trunk, excluding dev-only files:

```bash
rsync -av --delete \
    --exclude='.git' \
    --exclude='.github' \
    --exclude='node_modules' \
    --exclude='vendor' \
    --exclude='tests' \
    --exclude='bin' \
    --exclude='.phpcs.xml' \
    --exclude='phpstan.neon' \
    --exclude='phpunit.xml' \
    --exclude='package.json' \
    --exclude='package-lock.json' \
    --exclude='composer.json' \
    --exclude='composer.lock' \
    --exclude='webpack.config.js' \
    --exclude='*.map' \
    /path/to/your/dev/plugin/ ~/svn/my-plugin/trunk/
```

### Step 3: Review Changes

```bash
cd ~/svn/my-plugin
svn status trunk/
```

Status codes:
- `M` — Modified
- `?` — Untracked (needs `svn add`)
- `!` — Missing (needs `svn delete`)
- `A` — Scheduled for addition
- `D` — Scheduled for deletion

### Step 4: Add New Files

```bash
# Add all untracked files at once
svn status trunk/ | grep '^\?' | awk '{print $2}' | xargs svn add

# Or add individual files
svn add trunk/includes/new-file.php
```

### Step 5: Remove Deleted Files

```bash
# Remove all missing files at once
svn status trunk/ | grep '^!' | awk '{print $2}' | xargs svn delete

# Or remove individually
svn delete trunk/includes/old-file.php
```

### Step 6: Commit trunk

```bash
svn commit trunk/ -m "Release version 1.2.0"
```

### Step 7: Create a Version Tag

Always tag from the remote trunk (remote-to-remote copy, no local transfer):

```bash
svn copy https://plugins.svn.wordpress.org/my-plugin/trunk \
         https://plugins.svn.wordpress.org/my-plugin/tags/1.2.0 \
         -m "Tagging version 1.2.0"
```

This is the recommended approach as it:
- Does not require downloading files locally
- Is atomic on the SVN server
- Is significantly faster

---

## Viewing Repository Status

```bash
# List tags
svn list https://plugins.svn.wordpress.org/my-plugin/tags/

# View recent commits
svn log https://plugins.svn.wordpress.org/my-plugin/ --limit 10

# Check what's in a specific tag
svn list https://plugins.svn.wordpress.org/my-plugin/tags/1.2.0/

# Diff between tags
svn diff https://plugins.svn.wordpress.org/my-plugin/tags/1.1.0/ \
         https://plugins.svn.wordpress.org/my-plugin/tags/1.2.0/
```

---

## Working with Assets

The `/assets/` directory is special — it holds plugin directory images and is NOT bundled in plugin ZIPs.

```bash
# Check out assets directory
svn checkout https://plugins.svn.wordpress.org/my-plugin/assets ~/svn/my-plugin/assets

# Add a new asset
cp ~/images/icon-256x256.png ~/svn/my-plugin/assets/
svn add ~/svn/my-plugin/assets/icon-256x256.png

# Update an existing asset (just copy, no svn add needed)
cp ~/images/banner-1544x500.png ~/svn/my-plugin/assets/

# Commit assets
svn commit ~/svn/my-plugin/assets/ -m "Update plugin icon and banner"
```

---

## Branching (Advanced)

Branches are rarely needed for WordPress.org plugins but can be useful for long-running feature work:

```bash
# Create a branch from trunk
svn copy https://plugins.svn.wordpress.org/my-plugin/trunk \
         https://plugins.svn.wordpress.org/my-plugin/branches/feature-x \
         -m "Create feature-x branch"

# Merge branch back to trunk (local operation)
cd ~/svn/my-plugin/trunk
svn merge https://plugins.svn.wordpress.org/my-plugin/branches/feature-x

svn commit trunk/ -m "Merge feature-x branch into trunk"
```

---

## Common SVN Commands Reference

| Command | Description |
|---------|-------------|
| `svn checkout <url> <local-path>` | Check out a repository |
| `svn update` | Update local working copy |
| `svn status` | Show changed/untracked files |
| `svn add <path>` | Schedule file for addition |
| `svn delete <path>` | Schedule file for deletion |
| `svn commit <path> -m "message"` | Commit changes |
| `svn copy <src> <dst> -m "message"` | Copy (used for tagging) |
| `svn log <url>` | View commit history |
| `svn diff <url1> <url2>` | Diff between URLs |
| `svn revert <path>` | Discard local changes |
| `svn info` | Show working copy info |

---

## Troubleshooting

### Authentication Error

```bash
# Re-enter credentials
svn info --username=myusername https://plugins.svn.wordpress.org/my-plugin/

# Clear cached credentials
rm -rf ~/.subversion/auth/svn.simple/
```

### Commit Failed — Out of Date

```bash
# Someone else committed; update first
svn update trunk/
# Resolve conflicts if any, then commit
svn commit trunk/ -m "Release version 1.2.0"
```

### File Shows as Modified But Wasn't Changed

This can happen with line ending changes. Check:

```bash
svn diff trunk/my-plugin.php
```

If only line endings differ, you can revert:

```bash
svn revert trunk/my-plugin.php
```

### svn: E200009: 'X' is not under version control

You need to `svn add` the file before committing:

```bash
svn add trunk/includes/new-class.php
```
