# Logto test stack

Audiobookshelf with [Logto](https://logto.io) (1.46, with Postgres) as its
OpenID Connect provider, for testing the watch's Logto adapter
(`lib/login/data/sso/logto_adapter.dart`). Runs on the dev box in
`~/code/abs-wear-idp-logto`, next to the main test server, whose test books
it mounts read-only.

| Service             | Port  |
| ------------------- | ----- |
| Audiobookshelf      | 13384 |
| Logto               | 9004  |
| Logto admin console | 9005  |

```bash
cp .env.example .env    # replace every change-me (letters and digits only)
docker compose up -d
./setup.sh              # idempotent; safe to run again
```

`setup.sh` creates:

- the ABS root user and a "Test Books" library on `/audiobooks`;
- a machine-to-machine app with Management API access, inserted straight
  into Logto's database (a fresh Logto has no admin and no API client);
- Logto's sign-in experience: username + password, TOTP as the MFA factor
  for users who set it up (policy `UserControlled`, so Logto suggests MFA to
  the others; the watch skips that). Logto saves a skip to the user's
  account, so `setup.sh` forgets it again for `ABS_TEST_USER`;
- the `abs` app (traditional web, first-party: no consent screen) with
  ABS's callback and mobile redirect URIs;
- the users `ABS_TEST_USER` (password only) and `ABS_MFA_USER` (password +
  TOTP with `ABS_MFA_TOTP_SECRET`); ABS creates their accounts on the first
  SSO login (`authOpenIDAutoRegister`);
- ABS's OpenID settings, with `abswear://oauth` as an allowed mobile
  redirect URI.

`LOGTO_CONSENT=1 ./setup.sh` switches ABS to a third-party app,
`abs-third-party`, so Logto shows its consent screen; run `./setup.sh`
again to switch back. In the same way, `LOGTO_TERMS=1` makes users agree to
terms of use (the watch gives up and leaves it to the phone), and
`LOGTO_PASSKEY=1` turns on passkey sign-in, so Logto suggests a passkey
(the watch skips that too). ABS keeps its OpenID client until it restarts, so
`setup.sh` restarts it when the client changes.

Gotchas:

- Logto names its discovery endpoints after the requested host, so
  `setup.sh` reads them from `LOGTO_URL`, the address the watch uses.
- Logto usernames allow letters, digits and `_` only.
- ABS needs `authOpenIDSubfolderForRedirectURLs: ""`, or it builds
  `/undefined/auth/...` redirect URLs.

The admin console (port 9005) asks you to create an admin account on first
visit; `setup.sh` doesn't need one.
