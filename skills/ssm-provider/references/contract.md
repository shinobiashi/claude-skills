# ProviderInterface (copy of core docs/ARCHITECTURE.md §3–4, keep in sync)

```php
namespace Saai\SignalMail\Provider;

interface ProviderInterface {
    public function id(): string;                 // 'resend', 'brevo', 'log'
    public function label(): string;
    public function settings_fields(): array;     // [ ['key'=>'api_key','type'=>'secret','label'=>…], … ]
    public function verify_credentials( array $settings ): ProviderStatus;
    /** @return null|array{source:string,settings:array} */
    public function discover_settings(): ?array;  // ADR-0009

    public function send( OutboundMessage $m ): SendResult;
    public function supports_batch(): bool;
    public function batch_size(): int;            // 1 when !supports_batch()
    /** @param OutboundMessage[] $messages @return SendResult[] keyed like input */
    public function send_batch( array $messages ): array;

    /** @throws WebhookVerificationException */
    public function verify_webhook( \WP_REST_Request $r ): void;
    /** @return DeliveryEvent[] */
    public function parse_webhook( \WP_REST_Request $r ): array;

    public function default_daily_quota(): ?int;  // null = unknown / unlimited
    public function tracking_supported(): array;  // ['open'=>bool,'click'=>bool]
}
```

`AbstractProvider` supplies `request()` (15 s timeout, JSON, secret masking),
`classify_http_error()` → retryable flag, `settings()` backed by `ssm_provider_settings_{id}`,
and `discover_settings()` returning `null`.

```php
final class OutboundMessage {
    public function __construct(
        public readonly int    $recipient_id,     // idempotency key source
        public readonly string $to,
        public readonly string $from_name,
        public readonly string $from_email,
        public readonly string $reply_to,
        public readonly string $subject,
        public readonly string $html,
        public readonly string $text,
        public readonly array  $headers,          // List-Unsubscribe etc., already rendered
        public readonly array  $tags,             // ['campaign'=>123]
    ) {}
}

final class SendResult {
    public static function ok( string $provider_message_id ): self;
    public static function failed( string $reason, bool $retryable, ?int $retry_after = null ): self;
}

final class DeliveryEvent {
    public const DELIVERED='delivered', HARD_BOUNCE='hard_bounce', SOFT_BOUNCE='soft_bounce',
                 COMPLAINT='complaint', DEFERRED='deferred', OPENED='opened', CLICKED='clicked',
                 UNSUBSCRIBED='unsubscribed';
    public function __construct(
        public readonly string $type,
        public readonly string $provider,
        public readonly string $provider_message_id,
        public readonly string $recipient_email,
        public readonly \DateTimeImmutable $occurred_at,
        public readonly ?string $reason = null,
        public readonly ?string $url = null,
        public readonly array $raw = [],
    ) {}
    public function dedupe_key(): string;          // sha1(provider|message_id|type|occurred_at minute)
}
```

Registry: `apply_filters( 'ssm_providers', [ 'resend' => ResendProvider::class, 'log' => LogProvider::class ] )`;
`ProviderRegistry::active()` reads option `ssm_provider`, falls back to `resend` with an admin
notice when the configured id is not registered.
