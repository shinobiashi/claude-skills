# PAY.JP v2 API Overview

Source: https://docs.pay.jp/v2/guide
Last updated: 2026-07-02

> Note: API v2 is **generally available** (account enablement may be required). Same API keys as v1. No 定期課金/subscription API yet (planned for 2026) — for WooCommerce Subscriptions / automatic recurring billing stay on API v1; for one-off merchant-initiated repeat charges use Customer + `confirm: true`.

## Core Objects

| Object | ID prefix | Description | Key fields |
|--------|-----------|-------------|------------|
| **Payment Flow** | `pfw_` | Manages complete payment lifecycle | `id`, `status`, `amount`, `currency`, `client_secret` |
| **Checkout Session** | `cs_` | Hosted payment page session (`open`/`complete`/`expired`) | `id`, `status`, `url`, `success_url`, `cancel_url` |
| **Payment Method** | `pm_` | Stored payment instrument (card) | `id`, `type`, `card` |
| **Customer** | `cus_` | Merchant's customer record (same IDs as v1) | `id`, `default_payment_method_id` |
| **Setup Flow** | `sflw_` | Registers payment method without charging | `id`, `status`, `client_secret` |
| **Refund** | `pyr_` | Refund against a Payment Flow (`succeeded`/`pending`/`requires_action`/`failed`/`canceled`) | `id`, `amount`, `payment_flow`, `reason`, `status` |

## API Base URL

```
https://api.pay.jp/v2/
```

## Authentication

All server-side requests use HTTP Basic Auth or Bearer token:
```
Authorization: Bearer sk_live_xxxxxxxxxxxx
```

Public key (`pk_live_xxx`) is used only in payments.js (frontend).

## Payment Flow Status Lifecycle

```
requires_payment_method
        ↓ (payment method set)
requires_confirmation
        ↓ (confirm)
    processing ──→ requires_action (3DS etc.) ──→ processing
        ↓
requires_capture (if capture_method=manual)
        ↓ (capture)
    succeeded

(non-terminal states → canceled)
```

| Status | Description |
|--------|-------------|
| `requires_payment_method` | Awaiting payment method setup |
| `requires_confirmation` | Awaiting confirm call |
| `requires_action` | Customer action needed (3DS redirect) |
| `processing` | Processing in progress |
| `requires_capture` | Auth complete, awaiting manual capture |
| `succeeded` | Payment complete |
| `canceled` | Canceled (terminal state) |

## Key API Endpoints

### Payment Flow
| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/v2/payment_flows` | Create Payment Flow |
| GET | `/v2/payment_flows/{id}` | Retrieve Payment Flow |
| POST | `/v2/payment_flows/{id}/capture` | Capture (manual mode; optional `amount_to_capture`) |
| POST | `/v2/payment_flows/{id}/cancel` | Cancel |

### Checkout Session
| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/v2/checkout/sessions` | Create session |
| GET | `/v2/checkout/sessions/{id}` | Retrieve session |

### Refund
| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/v2/payment_refunds` | Create refund |
| GET | `/v2/payment_refunds/{id}` | Retrieve refund |

### Customer & Payment Method
| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/v2/customers` | Create customer |
| GET | `/v2/customers/{id}` | Retrieve customer |
| GET | `/v2/payment_methods?customer_id={id}` | List customer's PMs |
| POST | `/v2/payment_methods/{id}/attach` | Attach PM to customer |
| POST | `/v2/payment_methods/{id}/detach` | Detach PM (unusable afterwards) |
| POST | `/v2/setup_flows` | Create Setup Flow (`customer` param) |

## Create Payment Flow — Request Body

```json
{
  "amount": 1000,
  "currency": "jpy",
  "payment_method_types": ["card", "paypay"],
  "capture_method": "automatic",
  "customer_id": "cus_xxx",
  "confirm": false,
  "metadata": { "order_id": "12345" }
}
```

`capture_method`:
- `"automatic"` (default) — capture on confirmation
- `"manual"` — requires separate `/capture` call; PayPay requires prior approval

## Checkout Session — Request Body

```json
{
  "mode": "payment",
  "line_items": [
    { "price": "price_xxx", "quantity": 1 }
  ],
  "payment_method_types": ["card", "paypay"],
  "success_url": "https://example.com/success",
  "cancel_url": "https://example.com/cancel",
  "customer_id": "cus_xxx",
  "metadata": { "order_id": "12345" }
}
```

Instead of a pre-registered `price`, `line_items[].price_data` can create the price inline
(`{ "price_data": { "currency": "jpy", "unit_amount": 1000, "product_data": { "name": "..." } }, "quantity": 1 }`) —
useful for dynamic cart totals. `{CHECKOUT_SESSION_ID}` placeholder is supported in `success_url`.
`payment_flow_data.metadata` / `setup_flow_data.metadata` propagate metadata to the generated flow.

`mode` values:
- `"payment"` — one-time payment
- `"setup"` — payment method registration only

## Supported Payment Methods

| Method | Reusable | 3DS | Auth (manual capture) | Min | Max |
|--------|----------|-----|----------------------|-----|-----|
| `card` | Yes | Required at registration or first use | Yes (7d, extendable 30d) | ¥50 | ¥9,999,999 |
| `paypay` | No | N/A | Yes, prior approval required (30d) | ¥50 | User limit |
| `apple_pay` | No | N/A | Yes (7d, extendable 30d) | ¥50 | ¥9,999,999 |

Apple Pay via Payment Widgets requires domain registration in the dashboard (not needed for Checkout v2).

## Error Response Format (RFC 9457)

Content type: `application/problem+json`.

```json
{
  "status": 400,
  "code": "invalid_status",
  "title": "Invalid Status",
  "detail": "Human-readable message",
  "instance": "/v2/payment_flows/pfw_xxx",
  "type": "https://docs.pay.jp/v2/errors/invalid-status",
  "errors": [
    { "field": "amount", "message": "..." }
  ]
}
```

Retry only 500/503/504 and timeouts. 402 = payment failure (`card_declined`, `three_d_secure_failed`, etc.); 409 = idempotency conflict; 422 = validation (`errors` array).

## Webhook Events

| Event | Trigger |
|-------|---------|
| `payment_flow.succeeded` | Payment completed |
| `payment_flow.payment_failed` | Payment failed |
| `payment_flow.requires_action` | Customer action needed (3DS etc.) |
| `payment_flow.canceled` | Payment Flow canceled |
| `refund.created` / `refund.updated` / `refund.failed` | Refund lifecycle |
| `checkout.session.completed` / `checkout.session.expired` | Checkout session done / expired |
| `setup_flow.succeeded` / `setup_flow.setup_failed` | Setup Flow result |
| `payment_method.attached` / `detached` / `updated` | PM lifecycle |
| `customer.created` / `updated` / `deleted` | Customer lifecycle |

Event payload: `data` contains the resource object **directly** (not `data.object`).
Webhook auth: `X-Payjp-Webhook-Token: whook_xxx` header — compare with registered token.
Retry: 3 attempts at 3-minute intervals on non-2xx / timeout. Respond within 10 seconds.

## Idempotency

Add `Idempotency-Key` header to prevent duplicate charges on network failure:
```
Idempotency-Key: order-12345-attempt-1
```

Max 255 chars; alphanumeric plus `-` `_` only; applies to POST/PUT/PATCH.

## Card Constraints

- Refunds: within 180 days of payment creation (usually immediate, `status: succeeded`)
- Authorization hold: 7 days (extendable to 30 days; not extendable for overseas-issued cards)
- 3DS: mandatory at card registration or first use in v2 (skippable at registration via Setup Flow `usage: 'on_session'`)
- Partial capture (`amount_to_capture`): only once; remainder is auto-canceled

## PayPay Constraints

- One-time payments only (cannot bind to customer)
- `capture_method: 'manual'` ("出荷売上") requires prior PAY.JP approval per merchant/product category; auth hold 30 days
- Refunds are **async**: create returns `status: pending`; confirm final result via `refund.created` webhook
- Test limit: ¥100 per transaction; must fully refund after each test; wait 5+ min between same-amount tests
- Test accounts: 080-1111-5912 to 080-1111-5921 (password `Pay2test`, SMS code `1234`)
- Refund window: 365 days from confirmation (until 23:59:59)
- Fees: 3.5% (physical) / 9.0% (digital)
