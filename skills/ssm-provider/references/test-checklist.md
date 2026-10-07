# Provider test checklist and helpers

## Mandatory cases (`tests/phpunit/Provider/{Id}ProviderTest.php`)

| # | Case | Fixture | Expectation |
|---|---|---|---|
| 1 | send ok | `providers/{id}/send-ok.json` | `SendResult::$ok === true`, `provider_message_id` equals fixture id |
| 2 | send 429 | `providers/{id}/send-429.json` (+ `retry-after` header) | `retryable === true`, `retry_after` parsed |
| 3 | send 401 invalid key | `providers/{id}/send-401.json` | `retryable === false`, reason names the service error |
| 4 | send 500 / WP_Error timeout | — (return `WP_Error` from the mock) | `retryable === true` |
| 5 | batch ok (if `supports_batch()`) | `providers/{id}/batch-ok.json` | results keyed like input, ids index-aligned |
| 6 | verify: bad signature | `webhooks/{id}/delivered.json` signed with wrong secret | `WebhookVerificationException` |
| 7 | verify: stale timestamp | same, timestamp now − 600 s | exception |
| 8 | verify: ok | signed with test secret | no exception |
| 9 | parse: each event type | `webhooks/{id}/*.json` | `DeliveryEvent::$type`, `reason`, `url`, `recipient_email` lower-cased, `occurred_at` UTC |
| 10 | parse: unknown type | `webhooks/{id}/unknown.json` | `[]` |
| 11 | controller: same payload twice | integration, `tests/phpunit/Webhook/` | second call stores nothing, still 200 |
| 12 | `discover_settings()` | with/without the other plugin's class | `null` / array with `source` |
| 13 | `verify_credentials()` | `providers/{id}/domains-ok.json`, `-401.json`, `-restricted.json` | `ProviderStatus` ok / invalid / limited |

Run both `--group hpos-on` and `--group hpos-off`; providers do not touch orders, but the suite
must stay green in the CI matrix.

## HTTP mock helper

```php
/**
 * Return a fixture for the next matching request. Use in setUp() and remove in tearDown().
 */
protected function mock_http( string $fixture, int $code = 200, array $headers = [] ): void {
    $body = file_get_contents( __DIR__ . '/../fixtures/providers/' . $fixture );
    add_filter(
        'pre_http_request',
        $this->http_mock = static function ( $pre, array $args, string $url ) use ( $body, $code, $headers ) {
            return [
                'headers'  => $headers,
                'body'     => $body,
                'response' => [ 'code' => $code, 'message' => '' ],
                'cookies'  => [],
                'filename' => null,
            ];
        },
        10,
        3
    );
}
```

Assert on the captured `$args` (method, `Authorization` header masked in logs, `Idempotency-Key`,
JSON body fields) by storing them in a property inside the closure.

## Webhook request helper

```php
protected function signed_request( string $fixture, string $secret, int $ts = null ): \WP_REST_Request {
    $body = file_get_contents( __DIR__ . '/../fixtures/webhooks/' . $fixture );
    $out  = json_decode( shell_exec( sprintf(
        'php %s --scheme svix --secret %s --body %s --timestamp %d --json',
        escapeshellarg( getenv( 'HOME' ) . '/.claude/skills/ssm-provider/scripts/sign-webhook.php' ),
        escapeshellarg( $secret ),
        escapeshellarg( __DIR__ . '/../fixtures/webhooks/' . $fixture ),
        $ts ?? time()
    ) ), true );
    $req = new \WP_REST_Request( 'POST', '/signal-mail/v1/webhook/resend/test-secret' );
    foreach ( $out['headers'] as $k => $v ) { $req->set_header( $k, $v ); }
    $req->set_body( $body );
    return $req;
}
```

Prefer re-implementing the HMAC inline in the test (5 lines) over shelling out when the suite
runs in CI without this skill on disk; the script is for local replays and fixture generation.

## Fixture hygiene

- Real payloads from the service, then mask: addresses → `user-{n}@example.com`, ids kept.
- One file per event type and per bounce subtype; file name = `{event}-{variant}.json`.
- Never commit a real webhook secret; tests use `whsec_` + base64 of a fixed 32-byte string.
