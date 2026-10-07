# Coexistence with WooCommerce core's block email editor

WooCommerce bundles the same two packages. When its block email editor feature is enabled it
bootstraps the PHP package on `woocommerce_init` (`Internal\EmailEditor\Integration`) and
enqueues the JS editor on its own `woo_email` screens.

## What is shared (strings, not symbols; prefixing does not isolate them)

| Surface | Value | Effect of double bootstrap |
|---|---|---|
| Hooks | `woocommerce_email_editor_*`, `woocommerce_is_email_editor_page`, `replace_editor` | both instances react to both plugins' filters |
| Post type filter | `woocommerce_email_editor_post_types` | each `Email_Editor::initialize()` registers **every** returned post type → `register_post_type()` twice for yours and WooCommerce's |
| REST | `woocommerce-email-editor/v1` | routes registered twice (`_doing_it_wrong` notices, last registration wins) |
| JS global / DOM | `window.WooCommerceEmailEditor`, `#woocommerce-email-editor` | fine, one editor screen at a time |
| Post status | `sent` | registered twice |
| User theme post | meta type `woocommerce_email_theme` | one shared global-styles post; both editors edit the same email theme |
| Block patterns / templates | package registrations | duplicated entries in the inserter |

## Rule

Bootstrap the bundled copy **only if WooCommerce's is not active**, and always resolve
services from the live instance through one adapter (see `integration-recipe.md`).

## Checklist for the spike / PR

- [ ] Confirm the feature id (`block_email_editor` at research time) in
      `Automattic\WooCommerce\Internal\Features\FeaturesController` for the minimum supported
      WooCommerce; fall back to `did_action( 'woocommerce_email_editor_initialized' )`.
- [ ] With the feature **off**: bundled bootstrap runs; your CPT registers once; editor opens;
      `debug.log` clean.
- [ ] With the feature **on**: bundled bootstrap skipped; your CPT still registers (via
      WooCommerce's instance); editor opens; WooCommerce's own email screens still work.
- [ ] Version drift: WooCommerce's bundled PHP package may be older than your pin. List the
      package APIs you call (`Renderer::render`, `render_from_content`, `Personalizer`,
      `Assets_Manager::set_assets_*`, `Personalization_Tag` constructor arity) and guard with
      `method_exists` / try the call in the spike against the oldest WooCommerce you support.
- [ ] JS: `wp.*` externals are shared; your bundle carries `@woocommerce/email-editor`,
      `@wordpress/ui`, `@wordpress/global-styles-engine`. Two different versions of
      `@wordpress/ui` can coexist because each is bundled, but check for CSS collisions on
      shared class names if both editors are ever on one page (they are not, by design).
- [ ] Strauss prefixed both `EmailEditor\` and `EmailEditorVendor\`; `class_exists(
      '\\Automattic\\WooCommerce\\EmailEditor\\Email_Editor_Container' )` is false when
      WooCommerce's feature is off (proves nothing unprefixed leaked).
- [ ] Record the outcome in an ADR (status update of the "bundle rather than depend on the
      flag" decision) including the exact WooCommerce/package versions tested.
