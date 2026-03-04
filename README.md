# Codex Mobile Platform

Monorepo for a Codex-driven mobile experience:
- `apps/backend`: Fastify API + WebSocket server with Codex runtime adapters.
- `apps/mobile`: Flutter app shell with modern chat UI, project drawer, model/profile selection, and notification plumbing.
- `packages/contracts`: shared runtime/API contracts.

## Quick Start

1. Install dependencies:
   ```bash
   npm install
   ```
2. Run backend in dev mode:
   ```bash
   npm run dev:backend
   ```
3. Backend API default URL: `http://127.0.0.1:8787`
4. Default token: `dev-token`

## Backend Validation

- Build:
  ```bash
  npm run build
  ```
- Test:
  ```bash
  npm run test
  ```

## Mobile App (Flutter)

Flutter SDK is required locally to run the client:
```bash
cd apps/mobile
flutter pub get
flutter run --dart-define=BACKEND_URL=http://<server-ip>:8787 --dart-define=AUTH_TOKEN=dev-token
```

## Docker Compose

```bash
cd deploy
docker compose up --build
```

This starts:
- backend on `:8787`
- postgres on `:5432`
- redis on `:6379`
