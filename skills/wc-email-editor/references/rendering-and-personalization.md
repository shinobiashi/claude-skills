# Rendering and personalization

Source: `packages/php/email-editor/docs/{rendering,personalization-tags}.md` (2026-10-07).

## Renderer

```php
$renderer = Package::get( 'Engine\\Renderer\\Renderer' ); // the live copy's (integration-recipe.md)

$out = $renderer->render(
    $post,          // WP_Post of your email post type
    $subject,       // used for <title>
    $preheader,     // preview text
    'ja',           // language attribute
    '',             // meta robots (set e.g. 'noindex' for browser view)
    'my-template'   // optional template slug when the post has none
);
// $out = [ 'html' => '<!doctype html>…', 'text' => '…' ];

// Markup with no saved post (previews, tests):
$out = $renderer->render_from_content( $block_markup, 'my-template', $subject, $preheader );
```

Pipeline: `Preprocessors` (cleanup, block widths, typography, spacing, quotes) →
`Blocks_Renderer` (core block renderers from `Integrations\Core`, table layout) →
`Postprocessors` (highlighting, CSS variables, borders) → CSS inlining (Emogrifier). The
`Renderer` combines template styles and content styles in a single inlining pass; the text
version is derived from the final HTML.

Hooks you will likely use:

- `woocommerce_email_editor_rendering_email_context` — array passed to block renderers
  (`recipient_email`, `user_id`, `order_id`…); add your own keys.
- `woocommerce_email_editor_rendering_theme_styles` — adjust the `WP_Theme_JSON` per post.
- `woocommerce_email_editor_allowed_iframe_style_handles` — styles allowed inside the editor
  canvas.

Templates: register a block template through `Engine\Templates\Templates_Registry` (see how
WooCommerce's `EmailTemplates\WooEmailTemplate` does it) when you want a fixed header/footer
around `core/post-content`; a template is also how a legally required footer becomes
uneditable.

## Personalization tags

Token format: `<!--[ns/name attr="value"]-->` inside block content. Register on the registry
during the `woocommerce_email_editor_register_personalization_tags` filter:

Use the live copy's classes here, not `use` statements for your prefixed ones: while
WooCommerce's copy is live the filter passes its unprefixed registry, and a type hint or a `new`
on your prefixed classes fails the same way as SKILL.md §5 (follows from the measured TypeError;
confirm when you wire it).

```php
add_filter( 'woocommerce_email_editor_register_personalization_tags', static function ( $registry ) {
    $tag = Package::cls( 'Engine\\PersonalizationTags\\Personalization_Tag' );
    $registry->register( new $tag(
        __( 'First name', 'my-plugin' ),   // label in the editor modal
        'customer/first-name',             // token
        __( 'Customer', 'my-plugin' ),     // category
        static fn ( array $context ) => $context['first_name'] ?? '',
        [],                                // attributes with defaults
        null,                              // value interceptor
        $tag::VALUE_TYPE_TEXT              // engine escapes per rendering context
    ) );
    $registry->register( new $tag(
        __( 'Unsubscribe URL', 'my-plugin' ),
        'my-plugin/unsubscribe-url',
        __( 'Compliance', 'my-plugin' ),
        static fn ( array $context ) => $context['unsubscribe_url'] ?? '' // raw URL; HREF context escapes on write
    ) );
    return $registry;
} );
```

Apply at send time, once per recipient:

```php
$personalizer = Package::get( 'Engine\\Personalizer' );
$personalizer->set_context( [
    'recipient_email' => $email,
    'first_name'      => $contact->display_name,
    'unsubscribe_url' => $url,
] );
$html    = $personalizer->personalize_content( $out['html'] );                                        // RENDERING_CONTEXT_HTML
$text    = $personalizer->personalize_content( $out['text'], $personalizer::RENDERING_CONTEXT_TEXT );
$subject = $personalizer->personalize_content( $subject,     $personalizer::RENDERING_CONTEXT_TEXT );
```

Rules: HTML context callbacks return HTML fragments (escape dynamic data) unless
`VALUE_TYPE_TEXT`; TEXT context returns raw text; HREF context returns a raw URL
(`rawurlencode()` components yourself). Check the constructor signature of
`Personalization_Tag` in the pinned version; the value-type argument was added in 2025.

Render the whole campaign once (`Renderer::render()` is the expensive step) and personalize
per recipient; a 100-recipient batch should not render 100 times.
