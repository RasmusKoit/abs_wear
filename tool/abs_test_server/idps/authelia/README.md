# Authelia test stack

Audiobookshelf + [Authelia](https://www.authelia.com/) 4.39 as its OpenID
Connect provider, for the watch's Authelia SSO adapter
(`lib/login/data/sso/authelia_adapter.dart`). It is a compose project of its
own and doesn't touch the main test server (`../../docker-compose.yml`).

```bash
cp .env.example .env   # alphanumeric secrets; .env is git-ignored
./setup.sh             # certificates, hashes, containers, TOTP, ABS settings
```

`setup.sh` is idempotent. Deployed outside the repo (e.g. on the dev box in
`~/code/abs-wear-idp-authelia/`), copy `../../env.sh` next to it.

- ABS: `http://<IDP_HOST>:13382`, root user from `.env`, library "Test
  Books" on `AUDIOBOOKS_DIR`. OpenID is on next to password login, with
  `abswear://oauth` allowed and auto-registration (ABS accounts are made on
  the first SSO login).
- Authelia: `https://<IDP_HOST>:9002`, client `abs` (confidential, PKCE,
  `consent_mode: explicit` so the consent screen is always shown). Users in
  a file backend:
  - `ABS_TEST_USER` (`wear`): password only (one factor);
  - `ABS_TOTP_USER` (`weartotp`): password and a TOTP code from
    `ABS_TOTP_SECRET` (a `two_factor` rule for this user in the client's
    authorization policy).

## Things to know

- **Authelia requires HTTPS** (`authelia_url` must be `https`; there is no
  plain-HTTP switch). `setup.sh` makes a test CA in
  `data/authelia/certs/ca.crt` and a certificate for `IDP_HOST`
  (reissued from the same CA when `IDP_HOST` changes); Authelia serves
  TLS itself and ABS trusts the CA through `NODE_EXTRA_CA_CERTS`.
  Clients (the watch, tests) must trust `ca.crt` too: on a real server
  Authelia sits behind a proxy with a public certificate.
- An IP address works as the session cookie domain (no nip.io needed).
- Regulation is loosened (10 failures a minute, 1 minute ban): a banned
  user gets the same 401 as a wrong password.
- `authelia storage user totp generate --secret` sets the TOTP secret. The
  user's `GET /api/user/info` then still says `has_totp: false` until the
  session reloads it; `POST /api/user/info` (what the adapter uses) reads
  the database.
- The OpenID flow over the API: `/api/oidc/authorization` → portal
  `/?flow=openid_connect&flow_id=…` → `POST /api/firstfactor` →
  (`POST /api/secondfactor/totp`) → redirect to the authorization endpoint
  with `consent_id` → `/consent/openid/decision` → `GET`/`POST
  /api/oidc/consent` → authorization endpoint → ABS
  `/auth/openid/mobile-redirect` → `abswear://oauth?code=…`.
