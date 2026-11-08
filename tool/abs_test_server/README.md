# ABS test server

Throwaway Audiobookshelf server for development and E2E tests.

```bash
cp .env.example .env          # set passwords; .env is git-ignored
./generate_media.sh           # synthetic test books (needs ffmpeg)
./generate_bulk.sh 1000       # optional: 1000 tiny books for paging/scale tests
docker compose up -d
./seed.sh                     # users, library, in-progress listening
```

Run the E2E suite from the repo root against a device or emulator:

```bash
bash tool/e2e.sh <device-id>  # E2E_ABS_URL overrides the server URL
```
