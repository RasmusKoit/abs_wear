# ABS test server

Throwaway Audiobookshelf server for development and E2E tests.

```bash
cp .env.example .env          # set passwords; .env is git-ignored
./generate_media.sh           # synthetic test books (needs ffmpeg)
./generate_bulk.sh 1000       # optional: 1000 tiny books for paging/scale tests
mkdir -p data/demo            # before compose up, or Docker creates it as root
./generate_demo.sh            # optional: public-domain demo library for screenshots
docker compose up -d
./seed.sh                     # users, library, in-progress listening
```

Run the E2E suite from the repo root against a device or emulator:

```bash
bash tool/e2e.sh <device-id>  # E2E_ABS_URL overrides the server URL
```

## SSO (OpenID Connect)

`docker compose up -d` also starts Authentik on port 9000 (see `authentik/blueprints/abs.yaml`), and `seed.sh` points ABS at it with `abswear://oauth` as the allowed mobile redirect URI. The E2E suite logs in through it.

The SSO tests need the server URL the device uses to equal `ABS_E2E_URL`. Authentik only allows redirect URIs built from `ABS_E2E_URL`, so if you set `E2E_ABS_URL`, it must match.

Every other identity provider the watch supports has its own throwaway stack (an ABS server plus the provider) in `idps/<name>/`, with a `setup.sh` and a README: `html-form` (Keycloak and Gitea), `authelia`, `logto`, `voidauth`, `tinyauth` and `pocketid`.
