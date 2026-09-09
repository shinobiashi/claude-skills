# WordPress Test Case Patterns

Practical patterns for writing tests in WordPress plugins using `WP_UnitTestCase`.

---

## `WP_UnitTestCase` vs plain `TestCase`

| | `WP_UnitTestCase` | Plain `PHPUnit\Framework\TestCase` |
|---|---|---|
| WordPress loaded | Yes | No |
| Database transactions | Automatic rollback per test | None |
| Factory helpers | `$this->factory->*` | Not available |
| Hook cleanup | Automatic | Manual |
| Speed | Slower (full WP boot) | Fast |
| Use for | Integration tests | Unit tests (pure PHP logic) |

**Unit tests without WordPress** — use Brain\Monkey for mocking WP functions:

```php
<?php
use PHPUnit\Framework\TestCase;
use Brain\Monkey;
use Brain\Monkey\Functions;

class MyUtilityTest extends TestCase {

    protected function setUp(): void {
        parent::setUp();
        Monkey\setUp();
    }

    protected function tearDown(): void {
        Monkey\tearDown();
        parent::tearDown();
    }

    public function test_sanitize_custom_field(): void {
        Functions\expect( 'sanitize_text_field' )
            ->once()
            ->with( ' hello ' )
            ->andReturn( 'hello' );

        $result = my_sanitize_field( ' hello ' );
        $this->assertSame( 'hello', $result );
    }
}
```

---

## Factory methods

`WP_UnitTestFactory` provides helpers to create WordPress objects. Data is rolled back after each test.

### Posts

```php
// Create a post and get its ID.
$post_id = $this->factory->post->create();

// Create with specific args.
$post_id = $this->factory->post->create( [
    'post_title'  => 'Test Post',
    'post_status' => 'publish',
    'post_type'   => 'product',
] );

// Create and get the WP_Post object.
$post = $this->factory->post->create_and_get( [
    'post_title' => 'My Post',
] );
$this->assertInstanceOf( WP_Post::class, $post );

// Create multiple posts.
$post_ids = $this->factory->post->create_many( 5 );
$this->assertCount( 5, $post_ids );
```

### Users

```php
// Create a subscriber.
$user_id = $this->factory->user->create();

// Create with role and meta.
$user_id = $this->factory->user->create( [
    'role'       => 'editor',
    'user_email' => 'test@example.com',
] );

// Get the WP_User object.
$user = $this->factory->user->create_and_get( [
    'role' => 'administrator',
] );
wp_set_current_user( $user->ID );
```

### Terms

```php
// Create a category.
$term_id = $this->factory->term->create( [
    'taxonomy' => 'category',
    'name'     => 'Test Category',
] );

// Create and get the WP_Term object.
$term = $this->factory->term->create_and_get( [
    'taxonomy' => 'post_tag',
    'name'     => 'Test Tag',
] );
$this->assertInstanceOf( WP_Term::class, $term );
```

### Comments

```php
$comment_id = $this->factory->comment->create( [
    'comment_post_ID' => $post_id,
    'comment_content' => 'Test comment',
] );
```

---

## Testing hooks

### Verify an action was called

```php
public function test_action_fires_on_save(): void {
    $called = 0;
    add_action( 'my_plugin_after_save', function() use ( &$called ) {
        $called++;
    } );

    my_plugin_save_item( 'value' );

    $this->assertSame( 1, $called, 'my_plugin_after_save should fire once' );
}
```

### Verify `did_action()` count

```php
public function test_init_fires_once(): void {
    // did_action() count is reset between tests by WP_UnitTestCase.
    my_plugin_init();
    $this->assertSame( 1, did_action( 'my_plugin_initialized' ) );
}
```

### Verify a filter is registered

```php
public function test_filter_registered(): void {
    $plugin = new My_Plugin();
    $plugin->register_hooks();

    $this->assertTrue( has_filter( 'the_content', [ $plugin, 'modify_content' ] ) !== false );
}
```

### Capture filter output

```php
public function test_filter_modifies_title(): void {
    $post_id = $this->factory->post->create( [ 'post_title' => 'Original' ] );

    $filtered = apply_filters( 'my_plugin_post_title', 'Original', $post_id );

    $this->assertStringContainsString( '[Modified]', $filtered );
}
```

---

## Testing options

Always clean up after modifying options to avoid bleed-through to other tests.

```php
class OptionTest extends WP_UnitTestCase {

    private string $option_name = 'my_plugin_setting';

    protected function setUp(): void {
        parent::setUp();
        // Reset option before each test.
        delete_option( $this->option_name );
    }

    protected function tearDown(): void {
        delete_option( $this->option_name );
        parent::tearDown();
    }

    public function test_default_option_value(): void {
        $value = get_option( $this->option_name, 'default' );
        $this->assertSame( 'default', $value );
    }

    public function test_save_option(): void {
        update_option( $this->option_name, 'new_value' );
        $this->assertSame( 'new_value', get_option( $this->option_name ) );
    }
}
```

---

## Testing REST API endpoints

```php
class My_REST_Test extends WP_UnitTestCase {

    private WP_REST_Server $server;

    protected function setUp(): void {
        parent::setUp();
        global $wp_rest_server;
        $wp_rest_server = new WP_REST_Server();
        $this->server   = $wp_rest_server;
        do_action( 'rest_api_init' );
    }

    public function test_get_items_returns_200(): void {
        $admin = $this->factory->user->create( [ 'role' => 'administrator' ] );
        wp_set_current_user( $admin );

        $request  = new WP_REST_Request( 'GET', '/my-plugin/v1/items' );
        $response = $this->server->dispatch( $request );

        $this->assertSame( 200, $response->get_status() );
        $this->assertIsArray( $response->get_data() );
    }

    public function test_unauthenticated_returns_401(): void {
        wp_set_current_user( 0 );

        $request  = new WP_REST_Request( 'POST', '/my-plugin/v1/items' );
        $response = $this->server->dispatch( $request );

        $this->assertSame( 401, $response->get_status() );
    }

    public function test_create_item_stores_data(): void {
        $admin = $this->factory->user->create( [ 'role' => 'administrator' ] );
        wp_set_current_user( $admin );

        $request = new WP_REST_Request( 'POST', '/my-plugin/v1/items' );
        $request->set_body_params( [ 'name' => 'Test Item' ] );

        $response = $this->server->dispatch( $request );
        $data     = $response->get_data();

        $this->assertSame( 201, $response->get_status() );
        $this->assertSame( 'Test Item', $data['name'] );
    }
}
```

---

## Testing AJAX handlers

```php
class Ajax_Test extends WP_Ajax_UnitTestCase {

    public function test_ajax_handler_returns_success(): void {
        $admin = $this->factory->user->create( [ 'role' => 'administrator' ] );
        wp_set_current_user( $admin );

        // Set up POST data.
        $_POST['nonce'] = wp_create_nonce( 'my_plugin_nonce' );
        $_POST['value'] = 'test_value';

        // Trigger the AJAX handler; it calls wp_send_json_success() which throws.
        try {
            $this->_handleAjax( 'my_plugin_save' );
        } catch ( WPAjaxDieContinueException $e ) {
            // Expected: handler called wp_die( 0 ) or wp_send_json_success().
        }

        $response = json_decode( $this->_last_response, true );
        $this->assertTrue( $response['success'] );
    }
}
```

---

## Testing transients and caching

```php
public function test_transient_is_set_after_fetch(): void {
    delete_transient( 'my_plugin_data' );

    // Call the function that should set the transient.
    my_plugin_get_data();

    $cached = get_transient( 'my_plugin_data' );
    $this->assertNotFalse( $cached );
}

public function test_returns_cached_value(): void {
    set_transient( 'my_plugin_data', [ 'cached' => true ], HOUR_IN_SECONDS );

    $result = my_plugin_get_data();

    $this->assertTrue( $result['cached'] );
}
```

---

## Mocking HTTP requests with `pre_http_request`

Intercept `wp_remote_get()` / `wp_remote_post()` without making real network calls.

```php
class Http_Test extends WP_UnitTestCase {

    protected function setUp(): void {
        parent::setUp();
        // Register mock before each test.
        add_filter( 'pre_http_request', [ $this, 'mock_http_request' ], 10, 3 );
    }

    protected function tearDown(): void {
        remove_filter( 'pre_http_request', [ $this, 'mock_http_request' ], 10 );
        parent::tearDown();
    }

    public function mock_http_request( $preempt, array $args, string $url ) {
        if ( str_contains( $url, 'api.example.com' ) ) {
            return [
                'response' => [ 'code' => 200, 'message' => 'OK' ],
                'body'     => wp_json_encode( [ 'status' => 'ok', 'items' => [ 1, 2, 3 ] ] ),
                'headers'  => [ 'content-type' => 'application/json' ],
            ];
        }
        // Let other requests pass through (or return WP_Error to block them).
        return new WP_Error( 'http_request_failed', 'Mock: unexpected URL ' . $url );
    }

    public function test_api_call_parses_response(): void {
        $result = my_plugin_call_api();

        $this->assertSame( 'ok', $result['status'] );
        $this->assertCount( 3, $result['items'] );
    }

    public function test_api_error_handled_gracefully(): void {
        // Override mock to return an error for this test.
        remove_filter( 'pre_http_request', [ $this, 'mock_http_request' ], 10 );
        add_filter( 'pre_http_request', static function() {
            return new WP_Error( 'http_request_failed', 'Connection refused' );
        } );

        $result = my_plugin_call_api();

        $this->assertNull( $result );
    }
}
```

---

## Testing custom post meta

```php
public function test_saves_custom_meta(): void {
    $post_id = $this->factory->post->create();

    my_plugin_save_meta( $post_id, 'custom_field', 'my_value' );

    $stored = get_post_meta( $post_id, 'custom_field', true );
    $this->assertSame( 'my_value', $stored );
}

public function test_meta_is_sanitized_on_save(): void {
    $post_id = $this->factory->post->create();

    my_plugin_save_meta( $post_id, 'custom_field', '<script>alert(1)</script>' );

    $stored = get_post_meta( $post_id, 'custom_field', true );
    $this->assertStringNotContainsString( '<script>', $stored );
}
```

---

## Data providers

Use `#[DataProvider]` (PHPUnit 10+) or `@dataProvider` (PHPUnit 9):

```php
// PHPUnit 10+ attribute syntax:
#[\PHPUnit\Framework\Attributes\DataProvider( 'valid_email_provider' )]
public function test_valid_emails( string $email ): void {
    $this->assertTrue( my_plugin_is_valid_email( $email ) );
}

public static function valid_email_provider(): array {
    return [
        'simple'        => [ 'user@example.com' ],
        'with subdomain' => [ 'user@mail.example.com' ],
        'with plus'     => [ 'user+tag@example.com' ],
    ];
}

// PHPUnit 9 annotation syntax:
/**
 * @dataProvider invalid_email_provider
 */
public function test_invalid_emails( string $email ): void {
    $this->assertFalse( my_plugin_is_valid_email( $email ) );
}

public function invalid_email_provider(): array {
    return [
        'no at sign'    => [ 'userexample.com' ],
        'no domain'     => [ 'user@' ],
        'empty string'  => [ '' ],
    ];
}
```

---

## Expecting exceptions

```php
// PHPUnit 9+
public function test_throws_on_invalid_input(): void {
    $this->expectException( InvalidArgumentException::class );
    $this->expectExceptionMessage( 'Value cannot be empty' );

    my_plugin_process( '' );
}
```

Do not use `@expectedException` — it is removed in PHPUnit 10+.
