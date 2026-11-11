# Pocket ID test stack

Audiobookshelf 2.37.2 with [Pocket ID](https://pocket-id.org) 2.19.2 as its
OpenID Connect provider, for ABS Wear's Pocket ID adapter
(`lib/login/data/sso/pocketid_adapter.dart`). Pocket ID only does passkeys,
so the watch uses "sign in with another device": it shows a code, and a
device already signed in to Pocket ID approves it at `/device`.

```bash
mkdir -p ~/code/abs-wear-idp-pocketid && cd ~/code/abs-wear-idp-pocketid
# Copy docker-compose.yml, setup.sh, passkey.py, .env.example from here and
# ../../env.sh, then fill in .env (alphanumeric secrets; .env is git-ignored).
cp .env.example .env
docker compose up -d
./setup.sh
```

`setup.sh` is idempotent. It creates the ABS root user and a "Test Books"
library on `/audiobooks`, the Pocket ID user `wear` and OIDC client `abs`
(through `STATIC_API_KEY`, no admin passkey needed), a software passkey for
`wear`, and turns on OpenID in ABS with auto-register (the ABS account is
created on the first SSO login).

`passkey.py` stands in for the user's phone: it signs in to Pocket ID with
the software passkey (kept in `data/passkey.json`) and approves or denies a
code the watch shows.

```bash
python3 passkey.py approve <code>
python3 passkey.py deny <code>
python3 passkey.py forget abs   # withdraw consent: the next login asks again
```

Notes:

- `POCKET_ID_URL` must be a host name: Pocket ID refuses to start with an IP
  address (WebAuthn relying party ID).
- Plain `http://` works for the watch and these scripts, but browsers drop
  Pocket ID's `Secure` cookies there; use HTTPS to try it in a browser.
- Approving needs a passkey sign-in less than a minute old, and Pocket ID
  rate-limits approvals (one per 10 s, burst 5).
- A device login request expires after 5 minutes. The exchange endpoint
  holds each poll open for up to 25 s while nothing is decided.
