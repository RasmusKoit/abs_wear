<!-- cspell:words Keycloak Gitea Forgejo TOTP OIDC healthz -->
# SSO test stack: HTML-form providers

A separate Audiobookshelf (port 13381) with Keycloak (9001) and, optionally,
Gitea (9011) as OpenID Connect providers, for ABS Wear's generic HTML-form
SSO adapter (`lib/login/data/sso/html_form_adapter.dart`). It runs next to
the main test server and doesn't touch it; the books come read-only from its
`data/audiobooks`.

Deployed outside the repo (as on the dev box), copy this folder and the
main test server's `tool/abs_test_server/env.sh` into one directory; in the
repo, `setup.sh` finds `../../env.sh` by itself.

```bash
cp <repo>/tool/abs_test_server/env.sh .   # only outside the repo
cp .env.example .env     # letters and digits only; .env is git-ignored
docker compose up -d     # add --profile gitea for Gitea
./setup.sh               # or: ./setup.sh gitea
```

`setup.sh` is idempotent. It creates the ABS root user and a "Test Books"
library, then in Keycloak the realm `abs` with the confidential client `abs`
("Consent required" on) and two users: `ABS_TEST_USER` (password only) and
`ABS_OTP_USER` (password and TOTP). With Gitea running it also creates
`wear-gitea`, `wear-gitea-otp` (TOTP enrolled through Gitea's settings page)
and an OAuth2 app, and points ABS at the provider given (default
`ABS_IDP`). ABS registers SSO users on their first login.

- Keycloak's TOTP key is the ASCII bytes of `ABS_OTP_SECRET` (for an
  authenticator app, enter its base32 form). Gitea's secret is written to
  `data/gitea-otp.env`, its OAuth2 client to `data/gitea-oauth.env`.
- `./setup.sh reset-consent` makes Keycloak forget the users' consent, so
  the next login shows it again. Gitea's OAuth2 app is made anew on every
  `./setup.sh gitea`, which does the same there.
- ABS 2.37 only picks up a new provider or client secret after a restart;
  `setup.sh` restarts it when they change.
- One ABS account links to one provider's user, so the Gitea users have
  their own names.
