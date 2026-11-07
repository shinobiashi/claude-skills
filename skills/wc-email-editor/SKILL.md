---
name: wc-email-editor
description: >
  How to bundle and drive WooCommerce's block email editor packages inside your own plugin:
  Composer woocommerce/email-editor (PHP; Bootstrap, Email_Editor_Container, Renderer,
  Personalization tags, Templates) and npm @woocommerce/email-editor (JS; initializeEditor,
  window.WooCommerceEmailEditor). Covers registering a custom post type with the editor via
  woocommerce_email_editor_post_types, replacing the classic editor screen, Assets_Manager
  paths and localization, rendering block content to email-safe HTML + text, personalization
  tags (<!--[ns/tag]-->), the webpack/Strauss setup and release packaging, removing the
  package's wp_mail() test send, and running one engine per request when WooCommerce core's
  own block email editor (or another plugin's copy) is also present (shared hook names, REST
  namespace woocommerce-email-editor/v1, JS global, TypeError when both boot). Use this for any
  task that mentions the email editor package, "block email editor", "MailPoet-style editor",
  rendering email blocks, Gutenberg for emails, ssm_campaign editing, or Signal Mail Phase 6 —
  even when the user just says "let users design the newsletter in the block editor". Facts
  verified 2026-10-07 against the WooCommerce monorepo and measured 2026-10-24 in a shipped
  integration (Signal Mail PR-17: PHP 2.19.0, JS 2.5.1, WooCommerce 10.0.6 and 11.2.1 with
  its block email editor on and off); re-check versions before pinning.
---

# wc-email-editor

The two packages are developed in the WooCommerce monorepo (`packages/php/email-editor`,
`packages/js/email-editor`) and mirrored for installation. They are usable without
WooCommerce's feature flag; WooCommerce core is itself just one consumer (its integration
lives in `plugins/woocommerce/src/Internal/EmailEditor/` and is the best reference
implementation, read `Integration.php` and `PageRenderer.php` there before writing yours).

## 1) Versions and requirements (2026-10-24)

| | PHP `woocommerce/email-editor` | JS `@woocommerce/email-editor` |
|---|---|---|
| Latest | 2.19.0, Packagist mirror `woocommerce/email-editor` (2.18.0 → 2.19.0 changed only renderer files) | 2.5.1 |
| Requires | PHP ≥ 7.4; WordPress ≥ 6.7 (`Engine\Dependency_Check::MIN_WP_VERSION`) | peer `react` / `react-dom` ^18.3 |
| Autoload | classmap `src/` + `vendor-prefixed/` | `build/index.js` (cjs), `build-module/index.js` (esm), types; `exports` maps only `.` |
| Bundled deps | `vendor-prefixed/` holds Mozart-prefixed `pelago/emogrifier`, `sabberworm/php-css-parser`, Symfony polyfills under namespace `Automattic\WooCommerce\EmailEditorVendor\` and classmap prefix `EmailEditorVendor_` | pins many `@wordpress/*`; **`@wordpress/ui` and `@wordpress/global-styles-engine` must be bundled by you**, they are not provided by WordPress as externals |
| Namespace | `Automattic\WooCommerce\EmailEditor\` | — |
| Copy inside WooCommerce | 11.2.1 ships 2.17.2 (has every API below); 10.0.6 ships one without `Engine\Assets_Manager` (incompatible, §5) | — |

Pin exact versions in both `composer.json` and `package.json`; the PHP and JS halves must
come from the same release window (the JS posts to REST routes the PHP registers).

## 2) Bootstrap (PHP)

```php
use Automattic\WooCommerce\EmailEditor\Email_Editor_Container; // prefixed in your plugin
use Automattic\WooCommerce\EmailEditor\Bootstrap;
use Automattic\WooCommerce\EmailEditor\Engine\Logger\Email_Editor_Logger;

// On `init` 9, and only when no other copy of the package is set to run (§5).
$container = Email_Editor_Container::container();
$container->get( Email_Editor_Logger::class )->set_logger( new My_Logger() ); // see below
$container->get( Bootstrap::class )->init();
```

`Bootstrap::init()` only adds hooks (the work runs on `init` 10 and `rest_api_init`), so calling
it on `init` 9 is in time, and late enough to see whether WooCommerce's copy already hooked
itself (§5). The package's default logger appends four INFO lines per request to `debug.log`;
pass your own `Email_Editor_Logger_Interface` (e.g. to `wc_get_logger()`, warning and above)
before `init()`. WooCommerce sets its own logger on its copy.

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
   WooCommerce). The package `array_merge`s your args over its defaults (`public`,
   `publicly_queryable`, `has_archive`, …), so set every default key if you want exactly your
   arguments. Let whichever copy is live register it; call `register_post_type()` yourself only
   as a fallback when no copy did by `init` 11 (a host copy too old for the filter, or your copy
   could not run).
2. `woocommerce_is_email_editor_page` → return true for `post.php?action=edit` of your post and
   `post-new.php?post_type=<yours>`. It runs on `init` 10, before `current_screen` exists, so
   read the query string.
3. `replace_editor` → WordPress applies it three times on those screens: inside
   `WP_Screen::get()` before a current screen exists (pass through: rendering there logs
   deprecations from admin-header.php), then in post.php / post-new.php (render here), and
   possibly again while admin-header.php prints (return true without rendering). For your post
   type: configure the live copy's `Assets_Manager` (`set_assets_path()` / `set_assets_url()` to
   the folder holding your built `style.css` + `style.asset.php`), register your editor script,
   `load_editor_assets( $post, $handle )`, adjust `woocommerce_email_editor_script_localization_data`
   (`urls.listings/send/back` to pages that exist, `editor_settings.isFullScreenForced`,
   `displaySendEmailButton`), then `render_email_editor_html()` and return `true`. That call
   includes admin-header.php itself, so it cannot run under PHPUnit: unit-test the gate and
   cover the screen with Playwright.
4. Your script: `import { initializeEditor } from '@woocommerce/email-editor';
   initializeEditor( 'woocommerce-email-editor' );` on DOM ready. The PHP side already put
   `window.WooCommerceEmailEditor` (`current_post_type`, `current_post_id`,
   `current_wp_user_email`, `editor_settings`, `editor_theme`, `user_theme_post_id`, `urls`)
   on the page via `wp_localize_script` on your handle.

## 3) Rendering and personalization

```php
$renderer = $live_container->get( Renderer::class ); // the live copy's (§5)
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

The editor's test send posts to the package's REST route, which sends through **`wp_mail()`**.
`displaySendEmailButton: false` hides only the header's send button: the Preview menu's "Send a
test email" item and its modal are rendered unconditionally
(`build-module/components/block-editor/editor.js`), with no setting to drop them. If your
plugin must not send through `wp_mail()`:

- swap the package's `SendPreview` component at build time (`NormalModuleReplacementPlugin`,
  `references/build-config.md`); your bundle is the one on your post type's screen in both
  engine states, so the swap holds there, while WooCommerce's own `woo_email` screen keeps its
  test send;
- hook `woocommerce_email_editor_send_preview_email` at priority < 11 and return `false` (the
  route answers 400) or `true` after sending through your own transport.

An E2E test must open the Preview menu to prove the item is gone: looking for a "send test
email" button on the page with the menu closed always passes.

## 4) Build, namespace prefixing, release

- JS: `@wordpress/scripts` with `@woocommerce/dependency-extraction-webpack-plugin`, overriding
  `requestToExternal` **and** `requestToHandle` to return `false` for `@woocommerce/email-editor`,
  `@wordpress/ui` and `@wordpress/global-styles-engine` (`undefined` defers to the default
  mapping, which externalizes them), and `DefinePlugin { __i18n_text_domain__:
  JSON.stringify( 'your-text-domain' ) }` so the editor's strings run under your domain. Produce
  `style.css` + `style.asset.php` next to the script (that is what
  `Assets_Manager::load_editor_assets()` enqueues). `make-pot` does not read your excluded build
  directory: add a second pass over the built editor (`--include=<build>/editor/index.js
  --merge=<your pot>`) after `npm run build`. See `references/build-config.md`.
- PHP: with Strauss prefix **both** `Automattic\WooCommerce\EmailEditor\` and
  `Automattic\WooCommerce\EmailEditorVendor\` (the package's own prefixed deps), include
  `vendor-prefixed/` in the classmap, delete the original package from `vendor/` and regenerate
  the autoloader, otherwise you ship a second unprefixed Emogrifier that collides with
  WooCommerce core's. Hook names, REST namespace, the JS global and the DOM id are plain strings
  and stay shared; that is by design, see §5.
- Release: `composer install --no-dev` puts the unprefixed package back into `vendor/` (it is a
  `require`; Strauss is a dev package and does not run again). The zip script must remove
  `vendor/woocommerce/email-editor`, regenerate the autoloader, check that `vendor-prefixed/`
  holds the version `composer.lock` locks (after a lock update and a `--no-dev` install alone it
  still holds the previous one), and refuse a stage whose classmap lists unprefixed
  `Automattic\WooCommerce\EmailEditor` or `EmailEditorVendor_` classes or that carries Strauss'
  `vendor/composer/autoload_aliases.php`.

## 5) Coexisting with WooCommerce core's editor: one engine per request

WooCommerce ships the same packages and boots its copy when its block email editor feature
is enabled (10.0 as well as 11.x). Shared, non-prefixable surface: hooks
`woocommerce_email_editor_*`, filter `woocommerce_email_editor_post_types` (every booted copy
registers **all** post types returned by it), REST namespace `woocommerce-email-editor/v1`, JS
global `window.WooCommerceEmailEditor`, DOM id `woocommerce-email-editor`, post status `sent`,
the email theme post. Booting a second copy is not a duplicate-registration nuisance: it is a
**TypeError on `init`**, because WooCommerce hooks type-hinted callbacks on the shared filters
(`TemplatesController::register_templates( Templates_Registry $registry )`) and receives the
other copy's objects (measured).

- Decide on `init` 9, once. Another copy is set to run if `$wp_filter['init']` holds an object
  callback that is an `Automattic\WooCommerce\EmailEditor\Bootstrap` (WooCommerce, or any plugin
  bundling the package unprefixed), or whose class ends with
  `\Automattic\WooCommerce\EmailEditor\Bootstrap` and is not yours (another plugin's prefixed
  copy shares the hook names and type hints just the same), or if
  `did_action( 'woocommerce_email_editor_initialized' ) > 0`. Use that copy; otherwise boot yours.
  Do not decide from WooCommerce's feature flag: the hook table is what will actually run, and
  it also catches other plugins' copies.
- A copy seen only through the action count (it initialized before `init` 9 with no Bootstrap in
  the hook table) cannot be named: take nothing from it, do not boot yours either, and say so on
  your edit screen (fail closed).
- Resolve every service (`Assets_Manager`, `Renderer`, `Templates_Registry`,
  `Personalization_Tags_Registry`) from the live copy through one adapter, the only class that
  knows both namespaces (`references/integration-recipe.md`).
- The host copy may be older than yours (§1). Check it on **instances** from its container:
  `method_exists( $service, … )` for every method you call, and the class file is outside your
  plugin. Not on class names: `method_exists( 'Class', … )` autoloads, and Strauss' dev alias
  loader or a stray unprefixed copy in your `vendor/` answers for a class the host lacks. If it
  is incompatible, replace your edit screen with a notice (update WooCommerce or turn its block
  email editor off; never ask to turn it on) instead of booting yours.
- At `init` `PHP_INT_MAX`, `did_action( 'woocommerce_email_editor_initialized' ) > 1` means a
  copy booted after your decision: show an admin notice.
- Shared state while WooCommerce's copy runs: the email theme (`wp_global_styles` post
  `wp-global-styles-woocommerce-email`; a theme changed in your editor is also the theme of
  WooCommerce's block transactional emails) and the `sent` status.

Testing both states: in PHPUnit set `woocommerce_feature_block_email_editor_enabled` = `yes`
before WooCommerce loads and again after `WC_Install::install()`, and run that in CI for the
oldest and the latest WooCommerce you support. Compare container identity rather than class
names, and assert host compatibility only for versions you measured. With WooCommerce's editor
on, WooCommerce generates its transactional email posts the first time a WooCommerce admin
screen is set up, inside its own `START TRANSACTION` … `COMMIT`, which commits the running
test's transaction (its writes survive the rollback and leak into later tests): set
`woocommerce_page_wc-settings` and then `front` as the current screen once in the PHPUnit
bootstrap. In Playwright, run the editor spec with the option on and off; wp-env's tests site
shares its database with PHPUnit, so set the option explicitly rather than inheriting what the
last PHPUnit run left. Checklist in `references/coexistence-checklist.md`.

## 6) Done when

- Editor opens for your post type with WooCommerce's feature on and off (including the oldest
  WooCommerce you support); saving round-trips block markup; an incompatible host copy gets a
  notice instead of a broken editor.
- `woocommerce_email_editor_initialized` fires once per request; no duplicate-registration
  notices in `debug.log`.
- If you must not use `wp_mail()`: no header send button, no "Send a test email" in the Preview
  menu (E2E opens the menu), and the preview REST route refuses your post type.
- `Renderer::render()` output passes through your own post-processing (footer, unsubscribe
  link) and the text version contains the same links.
- Strings from the editor appear in your POT under your text domain (second `make-pot` pass).
- `composer strauss` leaves no `Automattic\WooCommerce\EmailEditor` or `…\EmailEditorVendor`
  symbols unprefixed in `vendor-prefixed/`, and the release zip carries only the prefixed copy,
  of the locked version.
