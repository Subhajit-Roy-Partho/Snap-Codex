# Codex Mobile (Flutter)

## Features

- Left drawer project list (project metadata + git state)
- Claude Code CLI-style center chat stream
- Model selector + permission profile selector (`xhigh`, `yolo`, custom)
- Session picker and interrupt control
- WebSocket real-time updates
- Firebase push + local notification wiring for all events

## Run

```bash
flutter pub get
flutter run --dart-define=BACKEND_URL=http://127.0.0.1:8787 --dart-define=AUTH_TOKEN=dev-token
```

## Notes

- Configure Firebase for Android/iOS for production push delivery.
- App can still run without Firebase initialized (local dev fallback).
