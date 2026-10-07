---
name: wc-email-editor
description: >
  How to bundle and drive WooCommerce's block email editor packages inside your own plugin:
  Composer woocommerce/email-editor (PHP; Bootstrap, Email_Editor_Container, Renderer,
  Personalization tags, Templates) and npm @woocommerce/email-editor (JS; initializeEditor,
  window.WooCommerceEmailEditor). Covers registering a custom post type with the editor via
  woocommerce_email_editor_post_types, replacing the classic editor screen, Assets_Manager
  paths and localization, rendering block content to email-safe HTML + text, personalization
  tags (<!--[ns/tag]-->), the webpack/Strauss setup, and the coexistence rules when WooCommerce
  core's own block email editor is also active (shared hook names, REST namespace
  woocommerce-email-editor/v1, JS global). Use this for any task that mentions the email
  editor package, "block email editor", "MailPoet-style editor", rendering email blocks,
  Gutenberg for emails, ssm_campaign editing, or Signal Mail Phase 6 — even when the user just
  says "let users design the newsletter in the block editor". Facts verified 2026-10-07
  against the WooCommerce monorepo (PHP 2.18.0, JS 2.5.0); re-check versions before pinning.
---

# wc-email-editor

The two packages are developed in the WooCommerce monorepo (`packages/php/email-editor`,
`packages/js/email-editor`) and mirrored for installation. They are usable without
WooCommerce's feature flag; WooCommerce core is itself just one consumer (its integration
lives in `plugins/woocommerce/src/Internal/EmailEditor/` and is the best reference
implementation, read `Integration.php` and `PageRenderer.php` there before writing yours).

## 1) Versions and requirements (2026-10-07)

| | PHP `woocommerce/email-editor` | JS `@woocommerce/email-editor` |
|---|---|---|
| Latest | 2.18.0 (2026-10-05), Packagist mirror `woocommerce/email-editor` | 2.5.0 (2026-10-05) |
| Requires | PHP ≥ 7.4; WordPress ≥ 6.7 (`Engine\Dependency_Check::MIN_WP_VERSION`) | peer `react` / `react-dom` ^18.3 |
| Autoload | classmap `src/` + `vendor-prefixed/` | `build/index.js` (cjs), `build-module/index.js` (esm), types |
| Bundled deps | `vendor-prefixed/` holds Mozart-prefixed `pelago/emogrifier`, `sabberworm/php-css-parser`, Symfony polyfills under namespace `Automattic\WooCommerce\EmailEditorVendor\` and classmap prefix `EmailEditorVendor_` | pins many `@wordpress/*`; **`@wordpress/ui` and `@wordpress/global-styles-engine` must be bundled by you**, they are not provided by WordPress as externals |
| Namespace | `Automattic\WooCommerce\EmailEditor\` | — |

Pin exact versions in both `composer.json` and `package.json`; the PHP and JS halves must
come from the same release window (the JS posts to REST routes the PHP registers).

## 2) Bootstrap (PHP)

```php
use Automattic\WooCommerce\EmailEditor\Email_Editor_Container; // prefixed in your plugin
use Automattic\WooCommerce\EmailEditor\Bootstrap;

// At or before plugins_loaded; it hooks `init` and block registration.
Email_Editor_Container::container()->get( Bootstrap::class )->init();
```

What `Bootstrap::init()` → `Email_Editor::initialize()` (on `init`) does, in order:
fires `woocommerce_email_editor_initialized`; registers block patterns; registers every post
type returned by the **`woocommerce_email_editor_post_types`** filter (`array<{name, args,
meta[]}>`, merged over the package defaults); registers block templates
(`Templates_Registry`); registers the `sent` post status; initializes
`Personalization_Tags_Registry` (tags added through
`woocommerce_email_editor_register_personalization_tags`); if the
**`woocommerce_is_email_editor_page`** filter returns true it extends the post REST API and
initializes `Assets_Manager` (editor styles, media, `enqueue_block_editor_assets`); on
`rest_api_init` it registers `woocommerce-email-editor/v1` routes (send preview email etc.).

So your integration is three filters plus one screen override. Full code in
`references/integration-recipe.md`:

1. `woocommerce_email_editor_post_types` → add your CPT (capabilities `manage_woocommerce`,
   `map_meta_cap => false`, `supports.editor.default-mode => 'template-locked'` like
   WooCommerce). Do **not** also call `register_post_type()` yourself.
2. `woocommerce_is_email_editor_page` → return true early (`is_admin()`, `$_GET['post']`,
   `action=edit`, post type matches). It runs before `current_screen` exists.
3. `replace_editor` → for your post type: configure `Assets_Manager`
   (`set_assets_path()` / `set_assets_url()` to the folder holding your built `style.css` +
   `style.asset.php`), register your editor script, `load_editor_assets( $post, $handle )`,
   adjust `woocommerce_email_editor_script_localization_data` (`urls.listings/send/back`,
   `editor_settings.isFullScreenForced`, `displaySendEmailButton`), then
   `render_email_editor_html()` and return `true`.
4. Your script: `import { initializeEditor } from '@woocommerce/email-editor';
   initializeEditor( 'woocommerce-email-editor' );` on DOM ready. The PHP side already put
   `window.WooCommerceEmailEditor` (`current_post_type`, `current_post_id`,
   `current_wp_user_email`, `editor_settings`, `editor_theme`, `user_theme_post_id`, `urls`)
   on the page via `wp_localize_script` on your handle.

## 3) Rendering and personalization

```php
$renderer = Email_Editor_Container::container()->get( Renderer::class );
[ 'html' => $html, 'text' => $text ] = $renderer->render( $post, $subject, $preheader, 'ja' );
```

`Renderer::render()` wraps the post content in its block template (or a blank fallback),
runs preprocessors → block renderers → postprocessors, inlines CSS, and returns both an HTML
document and a plain-text version. `render_from_content( $markup, $template_slug, … )` renders
markup with no post. `Content_Renderer` renders just the body. Context for block renderers
comes through `woocommerce_email_editor_rendering_email_context`.

Personalization tags are HTML comments `<!--[ns/tag attr="v"]-->`; register them on
`Personalization_Tags_Registry` with a callback that receives the context array and the
rendering context (`Personalizer::RENDERING_CONTEXT_HTML` / `_TEXT` / `_HREF`); declare
`VALUE_TYPE_TEXT` for plain values so the engine escapes for you. Run `Personalizer` on the
rendered HTML, then separately on subject / preheader / text with the TEXT context. Details and
code in `references/rendering-and-personalization.md`.

The editor's "Send test email" button posts to the package's REST route, which sends through
**`wp_mail()`**. If your plugin must not send through `wp_mail()`, either hide the button
(`displaySendEmailButton: false`) and provide your own, or hook
`woocommerce_email_editor_send_preview_email` at priority < 11 and return `true` after sending
through your own transport.

## 4) Build and namespace prefixing

- JS: `@wordpress/scripts` with `@woocommerce/dependency-extraction-webpack-plugin`, but
  override `requestToExternal` so `@woocommerce/email-editor`, `@wordpress/ui` and
  `@wordpress/global-styles-engine` are **bundled**, and add `DefinePlugin
  { __i18n_text_domain__: JSON.stringify( 'your-text-domain' ) }` so the editor's strings land
  under your domain for `make-pot`. Produce `style.css` + `style.asset.php` next to the script
  (that is what `Assets_Manager::load_editor_assets()` enqueues). See
  `references/build-config.md`.
- PHP: with Strauss prefix **both** `Automattic\WooCommerce\EmailEditor\` and
  `Automattic\WooCommerce\EmailEditorVendor\` (the package's own prefixed deps) and include
  `vendor-prefixed/` in the classmap, otherwise you ship a second unprefixed Emogrifier that
  collides with WooCommerce core's. Hook names, REST namespace, the JS global and the DOM id are
  plain strings and stay shared; that is by design, see §5.

## 5) Coexisting with WooCommerce core's editor

WooCommerce ships the same packages and bootstraps them when its block email editor feature
is enabled. Shared, non-prefixable surface: hooks `woocommerce_email_editor_*`, filter
`woocommerce_email_editor_post_types` (every bootstrapped instance registers **all** post
types returned by it), REST namespace `woocommerce-email-editor/v1`, JS global
`window.WooCommerceEmailEditor`, DOM id `woocommerce-email-editor`, post status `sent`.
Bootstrapping your bundled copy while WooCommerce's is active therefore registers post types,
patterns and REST routes twice.

Rule: bootstrap the bundled copy **only when WooCommerce's is not**. Detect at
`plugins_loaded` priority 20 (WooCommerce initializes on `woocommerce_init`): use
`FeaturesUtil::feature_is_enabled( '<block email editor feature id>' )` (confirm the id in
`FeaturesController` for your minimum WooCommerce version) and, as a belt-and-braces check,
`did_action( 'woocommerce_email_editor_initialized' )` before your own init. When WooCommerce's
instance is active, resolve `Renderer` / `Assets_Manager` from **its** container (unprefixed
class names) through a small adapter, so your post type is still registered (the filter is
shared) and rendering uses one engine. Keep the adapter the only place that knows both
namespaces. Checklist and the adapter in `references/coexistence-checklist.md`. Test both
states in Playwright; this is the risk WooCommerce's own CHANGELOG cannot cover for you.

## 6) Done when

- Editor opens for your post type with WooCommerce's feature on and off; saving round-trips
  block markup; no duplicate-registration notices in `debug.log`.
- `Renderer::render()` output passes through your own post-processing (footer, unsubscribe
  link) and the text version contains the same links.
- Strings from the editor appear in your POT under your text domain.
- `composer strauss` leaves no `Automattic\WooCommerce\EmailEditor` or
  `…\EmailEditorVendor` symbols unprefixed in `vendor-prefixed/`.
