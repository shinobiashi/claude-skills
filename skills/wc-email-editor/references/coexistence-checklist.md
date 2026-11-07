# Coexistence with WooCommerce core's block email editor

WooCommerce bundles the same two packages. When its block email editor feature is enabled it
boots the PHP package before `init` (its `Bootstrap::initialize` is hooked on `init` 10) and
enqueues the JS editor on its own `woo_email` screens. Measured 2026-10-24 on WooCommerce
10.0.6 and 11.2.1 (Signal Mail ADR-0010 / PR-17).

## What is shared (strings, not symbols; prefixing does not isolate them)

| Surface | Value | Effect of booting two copies |
|---|---|---|
| Hooks | `woocommerce_email_editor_*`, `woocommerce_is_email_editor_page`, `replace_editor` | both copies react to both plugins' filters; WooCommerce's type-hinted callbacks (`TemplatesController::register_templates( Templates_Registry )`) receive the other copy's objects → **TypeError on `init`** |
| Post type filter | `woocommerce_email_editor_post_types` | each `Email_Editor::initialize()` registers **every** returned post type → `register_post_type()` twice for yours and WooCommerce's |
| REST | `woocommerce-email-editor/v1` | routes registered twice (`_doing_it_wrong` notices, last registration wins) |
| JS global / DOM | `window.WooCommerceEmailEditor`, `#woocommerce-email-editor` | fine, one editor screen at a time |
| Post status | `sent` | registered twice |
| User theme post | `wp_global_styles` post `wp-global-styles-woocommerce-email` (meta type `woocommerce_email_theme`) | one shared post: both editors edit the same email theme, also while only one copy runs |
| Block patterns / templates | package registrations | duplicated entries in the inserter |

## Rule

One engine per request: decide on `init` 9 from the `init` hook table and
`did_action( 'woocommerce_email_editor_initialized' )`, never from the feature flag, and
resolve services from the live copy through one adapter (`integration-recipe.md`).

## Checklist for the spike / PR

- [ ] Detection reads the hook table (an unprefixed `Bootstrap`, or a class ending in
      `\Automattic\WooCommerce\EmailEditor\Bootstrap` that is not yours) and the action count. A
      copy seen only through the count is used for nothing and your copy is not booted (fail
      closed, with a notice).
- [ ] WooCommerce's editor **off**: your copy boots; your CPT registers once; the editor opens;
      `debug.log` clean (your own logger set before `Bootstrap::init()`).
- [ ] WooCommerce's editor **on**: your copy is not booted; your CPT still registers (through
      WooCommerce's copy and the shared filter); the editor opens with your bundle;
      WooCommerce's own email screens still work.
- [ ] Version drift: list the package APIs you call (`Assets_Manager::set_assets_path` /
      `set_assets_url` / `load_editor_assets` / `render_email_editor_html`, `Renderer::render`,
      `Templates_Registry::get_all`, `Personalization_Tags_Registry::register` / `get_all`, and
      anything you add later) and check them on instances taken from the host container, with
      the class file outside your plugin. Measured: 10.0.6 incompatible (no `Assets_Manager`),
      11.2.1 compatible. An incompatible copy gets a notice on your edit screen ("update
      WooCommerce or turn its block email editor off"), not your copy.
- [ ] `did_action( 'woocommerce_email_editor_initialized' )` at `init` `PHP_INT_MAX` is 1;
      more than 1 shows an admin notice.
- [ ] JS: `wp.*` externals are shared; your bundle carries `@woocommerce/email-editor`,
      `@wordpress/ui`, `@wordpress/global-styles-engine`. Two different versions of
      `@wordpress/ui` can coexist because each is bundled, but check for CSS collisions on
      shared class names if both editors are ever on one page (they are not, by design).
- [ ] Strauss prefixed both `EmailEditor\` and `EmailEditorVendor\`: nothing in
      `vendor-prefixed/` declares an original name, `vendor/` holds no unprefixed copy, and
      Composer never loads Strauss' `autoload_aliases.php` (a dev install generates it; with it
      loaded, `class_exists()` answers true for the original names and hides a leak).
- [ ] PHPUnit runs with WooCommerce's editor on in CI for the oldest and the latest supported
      WooCommerce, and the PHPUnit bootstrap lets WooCommerce generate its email posts before
      any test (it commits the running test's transaction otherwise; SKILL.md §5).
- [ ] Record the outcome in an ADR including the exact WooCommerce/package versions tested.
