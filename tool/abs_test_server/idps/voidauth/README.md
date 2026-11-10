# VoidAuth test stack

Audiobookshelf 2.37.2 with [VoidAuth](https://voidauth.app) 1.19.0 as its
OpenID Connect provider, for testing the watch's VoidAuth SSO adapter
(`lib/login/data/sso/voidauth_adapter.dart`).

| Service | Port | Notes |
|---|---|---|
| Audiobookshelf | 13386 | Books from `../abs-wear-test/data/audiobooks` (read-only) |
| VoidAuth | 9006 | SQLite, data in `./data/voidauth` |

## Set up

On the dev box, in `~/code/abs-wear-idp-voidauth`:

```sh
cp .env.example .env   # replace every change-me with random alphanumerics
docker compose up -d
./setup.sh             # idempotent
```

`setup.sh`:

- sets the password of VoidAuth's built-in `auth_admin` (through a password
  reset link from VoidAuth's CLI);
- invites and registers `ABS_TEST_USER` (password only) and `ABS_TOTP_USER`
  (password + TOTP), resetting their passwords if they changed;
- registers a TOTP for `ABS_TOTP_USER` and writes its secret to `.env` as
  `VOIDAUTH_TOTP_SECRET` (generate codes from it for tests);
- creates the ABS root user and a "Test Books" library, and points ABS's
  OpenID settings at VoidAuth with auto-register on, so both users get an
  ABS account on their first SSO login.

The `abs` OIDC app is declared in `docker-compose.yml` (`OIDC_abs_*`), with
consent left on: each user sees VoidAuth's consent screen once per redirect
URI, after that VoidAuth skips it.

## What the watch sees

ABS `/auth/openid` → VoidAuth `/oidc/auth` → `/api/interaction` → the app's
`/login` page. The adapter then uses the JSON API the app itself uses:

| Screen | Call | Wrong answer |
|---|---|---|
| `/login` | `POST /api/interaction/login {input, password}` → `{location}` | 401 |
| `/mfa` | `GET /api/user/me` (`hasTotp`), `POST /api/interaction/totp {token}` → `{location}` | 401 (423 when locked) |
| `/consent/<uid>` | `GET /api/interaction/<uid>/detail`, `POST /api/interaction/<uid>/confirm/` → 302 | |

Passkeys, setting up a first second factor, email verification and sign-up
need VoidAuth's web app: the adapter reports them as unsupported steps.
