# tinyauth SSO test stack

Audiobookshelf 2.37.2 with tinyauth v5.2.0 as its OpenID Connect provider,
for testing `lib/login/data/sso/tinyauth_adapter.dart`. On the dev box it
lives in `~/code/abs-wear-idp-tinyauth` (ABS on 13383, tinyauth on 9003).

```bash
cp .env.example .env    # fill in; alphanumeric secrets only
cp ../../env.sh .       # only when copying this folder elsewhere
./setup.sh              # certificate, users, containers, ABS root + library + SSO
./setup.sh reset-consent  # forget remembered consents (next login asks again)
```

- tinyauth's OpenID provider wants an `https` issuer with a host name (no
  IP address), so a Caddy container serves it over TLS with a throwaway CA
  from `setup.sh`. ABS trusts it through `NODE_EXTRA_CA_CERTS`; clients
  (tests, the watch) need `data/tls/ca.crt`. `TINYAUTH_URL` must resolve to
  the box for both ABS and the watch.
- Users: `ABS_TEST_USER` (password only) and `TOTP_USER` (password plus
  `TOTP_SECRET`). ABS creates their accounts on the first SSO login
  (auto-register).
- tinyauth asks for consent once per user and app, then remembers it.
- The image is `ghcr.io/tinyauthapp/tinyauth` (the project moved from
  `steveiliop56/tinyauth`, where no v5 images exist).
