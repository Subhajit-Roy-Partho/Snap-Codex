# Codex Backend

Fastify backend for Codex mobile clients.

## Capabilities

- Token auth (`x-api-token`) + JWT verification endpoint
- Project scanning from allowlisted server roots
- Model/profile catalogs
- Session creation and message flow
- WebSocket event stream for chat and runtime state
- Permission request/response handling
- Push token registration + notification dispatch pipeline
- Runtime readiness endpoint (`/health`) with Codex app-server checks

## Env

See `.env.example`.

## Development

```bash
npm run -w @codex/backend dev
```

## Tests

```bash
npm run -w @codex/backend test
```
