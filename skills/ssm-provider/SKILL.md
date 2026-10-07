---
name: ssm-provider
description: >
  How to implement, extend or review an email delivery provider for Signal Mail for WooCommerce
  (Saai\SignalMail\Provider\ProviderInterface): the core ResendProvider, the dev LogProvider, and
  paid add-on providers (Brevo, Amazon SES, Mailgun, SMTP2GO) that register through the
  ssm_providers filter. Covers the contract, directory layout, SendResult retryable rules,
  webhook verify/parse into DeliveryEvent, discover_settings(), the mandatory PHPUnit test
  list with HTTP-mock and fixture conventions, the add-on plugin skeleton, and a script that
  signs webhook fixtures (Svix or raw HMAC) for tests and local replays. Use this whenever a
  task mentions a provider, ProviderInterface, ssm_providers, send_batch, verify_webhook,
  parse_webhook, DeliveryEvent normalization, a new email service, or a Signal Mail add-on
  plugin, even if the word "provider" is not used (e.g. "add Brevo support", "handle Mailgun
  bounces", "the SES add-on").
---

# ssm-provider

A provider is the only code in Signal Mail that knows an external email service exists. It does
three things: send (`send` / `send_batch`), verify an inbound webhook (`verify_webhook`), and
normalize raw events (`parse_webhook`) into `DeliveryEvent`. Queueing, quota, consent,
suppression, stats and UI live outside and never see provider-specific names. Keeping that line
clean is what lets add-ons be small and lets WordPress.org review the free core without any
paid-provider awareness (ADR-0001, ADR-0008).

## 0) Read first

- In the core repo: `docs/ARCHITECTURE.md` §3 (contract), §3.2 (per-provider notes), §4
  (value objects), §6 (webhook pipeline), `docs/adr/0001`, `0003`, `0009`, and
  `.claude/rules/provider.md`. In an add-on repo these are not present: the contract is
  reproduced in `references/contract.md` of this skill, but the core repo is the source of truth,
  so open it if it is on disk.
- If the task changes `ProviderInterface` itself, stop and write an ADR first (`adr` skill);
  every add-on breaks otherwise.
- For Resend specifics use the `resend-api` skill in the core repo (`.claude/skills/resend-api`).

## 1) Layout

```
src/Provider/{Id}/
├── {Id}Provider.php      # extends AbstractProvider; the only class the registry sees
├── EventMap.php          # raw event name/type → DeliveryEvent type (+ reason builder)
└── (optional) Signature.php / Client.php when verify or request logic is long
tests/phpunit/Provider/{Id}ProviderTest.php
tests/phpunit/fixtures/providers/{id}/*.json     # HTTP responses (success, 429, 401, 5xx…)
tests/phpunit/fixtures/webhooks/{id}/*.json      # real payloads, PII masked, one per event type
```

Endpoint URLs, header names, event names and option keys of the service appear only under
`src/Provider/{Id}/`. If you find yourself writing `if ( 'brevo' === $provider->id() )` anywhere
else, the capability belongs in the interface (`supports_batch()`, `tracking_supported()`, …).

## 2) Sending

- Go through `AbstractProvider::request()` for all HTTP. It wraps `wp_remote_request` with a
  15 s timeout, JSON encode/decode, and masks secrets in logs. Do not call `wp_remote_*`
  directly in a provider.
- `send()` never throws. Return `SendResult::ok( $provider_message_id )` or
  `SendResult::failed( $reason, $retryable, $retry_after )`. The queue decides what to do with
  `retryable`; the provider only classifies. Baseline classification (override per service only
  with a documented reason):
  - 429, 5xx, `WP_Error` (timeout, DNS, TLS) → `retryable: true`; pass `retry_after` from the
    service's header when present.
  - Other 4xx (validation, auth, not found) → `retryable: false`. The recipient becomes
    `failed`, with `reason` short enough for `ssm_recipients.failure_reason` (255 chars).
  - Daily/monthly quota responses are retryable, but set `retry_after` to "next site-local
    day" so the queue defers rather than hammers.
- `send_batch()` must return results **keyed like the input** so the queue can update each
  recipient. When the service has no batch endpoint, `supports_batch()` returns `false`,
  `batch_size()` returns 1, and `send_batch()` loops over `send()`; do not partially implement.
- Idempotency: use the service's mechanism if it has one (`Idempotency-Key: ssm-{recipient_id}`
  for Resend). Without one, document in the docblock that duplicate protection relies on the
  `ssm_recipients.status` guard in the queue.
- Put every custom header from `OutboundMessage::$headers` on the wire. `List-Unsubscribe`
  and `List-Unsubscribe-Post` are a legal requirement here (REQUIREMENTS F11), so a provider
  that cannot send custom headers must say so in `settings_fields()` notes and in
  ARCHITECTURE §3.2, and the Compliance layer will refuse to use it.
- `tags`: send the campaign id when the service supports metadata; sanitize to the service's
  allowed character set.

## 3) Webhooks

- `verify_webhook()` throws `WebhookVerificationException` on failure and returns void on
  success. Layers: the controller already checked the URL secret; the provider checks the
  service signature (HMAC over the raw body, timestamp tolerance 5 min, constant-time compare)
  or, for services without signatures, a source-IP allowlist, and says which in the docblock.
  Always read `$request->get_body()`; a re-encoded JSON body breaks signatures.
- `parse_webhook()` returns `DeliveryEvent[]` (possibly empty, possibly several). Map with
  `EventMap`; unknown event types are skipped, not errors. `occurred_at` is the service's
  timestamp converted to UTC `DateTimeImmutable`; `provider_message_id` is whatever `send()`
  returned so the controller can find the recipient row; `recipient_email` is lower-cased.
  Keep `raw` to the fragment useful for debugging, not the whole request.
- Bounce semantics vary. Normalize to: permanent/hard → `HARD_BOUNCE`; transient/soft/
  deferred-but-bounced → `SOFT_BOUNCE`; delayed-not-bounced → `DEFERRED`; spam/abuse report →
  `COMPLAINT`; service-side suppression ("we refused to send because this address bounced
  before") → `HARD_BOUNCE` with a reason prefix naming the service. Write the mapping table into
  ARCHITECTURE §3.2 in the same PR.
- Dedupe is the controller's job (`DeliveryEvent::dedupe_key()`); the provider just has to be
  deterministic for the same payload.

## 4) Settings and discovery

- `settings_fields()` declares what the admin UI renders: `[ ['key'=>'api_key','type'=>'secret',
  'label'=>…], ['key'=>'webhook_secret','type'=>'secret',…], … ]`. Core stores them in
  `ssm_provider_settings_{id}` and masks secrets. No provider renders its own admin page.
- `verify_credentials( array $settings ): ProviderStatus` is the "Test connection" button.
  Distinguish "key invalid" from "key valid but limited scope" from "domain not verified".
- `discover_settings(): ?array` (ADR-0009) returns `null` or `['source' => 'Resend plugin',
  'settings' => ['api_key' => …]]` when another plugin on the site already holds usable
  credentials. Read the other plugin's option only inside this method, only when its class exists,
  and never log the value. Import happens on an explicit admin action, never on load.
- `default_daily_quota(): ?int` is the service's free-tier daily cap (`null` when unknown);
  `tracking_supported()` reports open/click availability so the UI can hide toggles.

## 5) Tests (mandatory, from `.claude/rules/provider.md`)

Checklist and copy-paste helpers in `references/test-checklist.md`. Summary:

1. Successful send → `SendResult::ok()` with the message id.
2. 429 → `retryable: true` (and `retry_after` when the service sends one).
3. Invalid API key → `retryable: false`.
4. Webhook with bad signature / stale timestamp → `WebhookVerificationException`.
5. Each event type (`delivered`, `hard_bounce`, `soft_bounce`, `complaint`, `unsubscribed`
   where applicable, plus service-specific ones) parses to the expected `DeliveryEvent`.
6. Same payload twice → second is `already_seen` at the controller (integration test in
   `tests/phpunit/Webhook/`).
7. `discover_settings()` returns `null` without the other plugin and the key with it.
8. Run under both `--group hpos-on` and `--group hpos-off` (CI matrix).

Mock HTTP with the `pre_http_request` filter returning fixtures from
`tests/phpunit/fixtures/providers/{id}/`. Sign webhook fixtures with
`scripts/sign-webhook.php` so the signature path is exercised with a fixed secret.

## 6) Local replay against wp-env

```bash
php ~/.claude/skills/ssm-provider/scripts/sign-webhook.php \
  --scheme svix --secret "$WEBHOOK_SECRET" \
  --body tests/phpunit/fixtures/webhooks/resend/bounced-permanent.json \
  --url "https://ssm-dev.example/wp-json/signal-mail/v1/webhook/resend/$URL_SECRET"
```

Without `--url` it prints `-H` lines for curl. `--scheme hmac` signs the raw body with
hex HMAC-SHA256 into a header you name (`--header X-Signature`) for services that use that
style; `--scheme none` sends unsigned (URL-secret-only providers).

## 7) Add-on plugin

An add-on is a plugin that registers one provider and nothing else. Skeleton and rules in
`references/addon-skeleton.md`: check for `ProviderInterface` on `plugins_loaded` priority 20,
bail with an admin notice if core is missing, `add_filter( 'ssm_providers', … )`, own
namespace (`Saai\SignalMail\{Id}`), own text domain, licensing entirely on the add-on side.
Core never special-cases an add-on by name, so do not ask for a core change to make an add-on
work; if the contract is insufficient, that is an ADR in core.

## 8) Done when

- `composer phpcs` and `composer phpunit` pass; fixtures committed with PII masked.
- ARCHITECTURE §3.2 has the provider's row (endpoints, auth, idempotency, headers,
  signature, event mapping, free quota, webhook endpoint count).
- readme.txt "External services" names the service with links to its terms and privacy policy
  (core) or the add-on's readme does (add-on).
- No `wp_mail()`, no provider name outside `src/Provider/{Id}/`, no secrets in logs.
