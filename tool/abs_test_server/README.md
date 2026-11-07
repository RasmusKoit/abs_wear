# ABS test server

Throwaway Audiobookshelf server for development and E2E tests.

```bash
cp .env.example .env          # set passwords; .env is git-ignored
./generate_media.sh           # synthetic test books (needs ffmpeg)
docker compose up -d
./seed.sh                     # users, library, in-progress listening
```

Run the E2E suite from the repo root against a device or emulator:

```bash
bash tool/e2e.sh <device-id>  # E2E_ABS_URL overrides the server URL
```
