#!/usr/bin/env bash
# Idempotently sets up the VoidAuth test stack (docker-compose.yml): the ABS
# root user and book library, VoidAuth's admin password, the test users
# (one password-only, one with TOTP, via admin invitations), and ABS's
# OpenID settings pointing at VoidAuth. Reads ./.env (see .env.example) and
# writes the TOTP secret VoidAuth generates back to it.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "Missing .env (copy .env.example and fill it in)" >&2; exit 1; }
exec python3 - <<'PY'
import base64, hashlib, hmac, http.cookiejar, json, os, re, struct
import subprocess, sys, time, urllib.error, urllib.parse, urllib.request

env = {}
for line in open('.env'):
    line = line.strip()
    if line and not line.startswith('#') and '=' in line:
        k, v = line.split('=', 1)
        env[k.strip()] = v.strip().strip('"\'')

ABS = 'http://localhost:13386'
# VoidAuth redirects to (and sets cookies for) its public URL only.
VA = env['VOIDAUTH_URL'].rstrip('/')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


class Browser:
    """urllib with a cookie jar; follows redirects unless told not to."""

    def __init__(self):
        jar = http.cookiejar.CookieJar()
        cookies = urllib.request.HTTPCookieProcessor(jar)
        self.follow = urllib.request.build_opener(cookies)
        self.manual = urllib.request.build_opener(cookies, NoRedirect)

    def req(self, method, url, body=None, headers=None, follow=True):
        h = {'Accept': 'application/json', **(headers or {})}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            h['Content-Type'] = 'application/json'
        r = urllib.request.Request(url, data=data, headers=h, method=method)
        try:
            with (self.follow if follow else self.manual).open(r, timeout=30) as res:
                return res.status, res.read().decode(), res.geturl()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode(errors='replace'), url


def js(text):
    return json.loads(text) if text else None


def wait(url, what):
    print(f'Waiting for {what} ...')
    for _ in range(90):
        try:
            urllib.request.urlopen(url, timeout=5)
            return
        except Exception:
            time.sleep(2)
    sys.exit(f'{what} at {url} did not come up')


def totp(secret, at=None):
    key = base64.b32decode(secret.upper() + '=' * (-len(secret) % 8))
    counter = int((at or time.time()) // 30)
    mac = hmac.new(key, struct.pack('>Q', counter), hashlib.sha1).digest()
    o = mac[-1] & 15
    return '%06d' % ((struct.unpack('>I', mac[o:o + 4])[0] & 0x7fffffff) % 10**6)


def save_env(key, value):
    lines = open('.env').read().splitlines()
    lines = [l for l in lines if not l.startswith(key + '=')]
    lines.append(f'{key}={value}')
    open('.env', 'w').write('\n'.join(lines) + '\n')
    env[key] = value


# --- VoidAuth --------------------------------------------------------------

def va_login(user, password):
    """Logs in through VoidAuth's own (internal client) flow. Returns the
    browser and the login response status."""
    b = Browser()
    q = urllib.parse.urlencode({
        'client_id': 'auth_internal_client', 'response_type': 'none',
        'scope': 'openid', 'redirect_uri': VA + '/api/cb',
        'prompt': 'login'})
    b.req('GET', f'{VA}/oidc/auth?{q}', headers={'Accept': 'text/html'})
    status, body, _ = b.req('POST', f'{VA}/api/interaction/login',
                            {'input': user, 'password': password})
    if status == 200 and body:
        loc = js(body)['location']
        b.req('GET', loc, headers={'Accept': 'text/html'})
    return b, status


def cli(*args):
    return subprocess.run(
        ['docker', 'compose', 'exec', '-T', 'voidauth', 'node',
         './dist/index.mjs', *args],
        check=True, capture_output=True, text=True).stdout


def reset_password(username, password):
    link = re.search(r'reset_password\?id=([\w-]+)&challenge=([\w-]+)',
                     cli('user', 'password-reset', username))
    status, body, _ = Browser().req('POST', f'{VA}/api/public/reset_password', {
        'userId': link.group(1), 'challenge': link.group(2),
        'newPassword': password})
    if status != 200:
        sys.exit(f'Password reset for {username} failed: {status} {body}')


wait(f'{VA}/healthcheck', 'VoidAuth')
admin, status = va_login('auth_admin', env['VOIDAUTH_ADMIN_PASSWORD'])
if status != 200:
    print('Setting the VoidAuth admin password')
    reset_password('auth_admin', env['VOIDAUTH_ADMIN_PASSWORD'])
    admin, status = va_login('auth_admin', env['VOIDAUTH_ADMIN_PASSWORD'])
    if status != 200:
        sys.exit(f'VoidAuth admin login failed: {status}')

_, body, _ = admin.req('GET', f'{VA}/api/admin/users?page=0&pageSize=1000')
users = js(body)
existing = {u['username'] for u in users.get('users', users.get('data', []))}


def ensure_user(username, password):
    if username in existing:
        if va_login(username, password)[1] != 200:
            print(f'Resetting the VoidAuth password of {username}')
            reset_password(username, password)
        return
    print(f'Inviting and registering VoidAuth user {username}')
    status, body, _ = admin.req('POST', f'{VA}/api/admin/invitation', {
        'username': username, 'name': username, 'email': None,
        'userExpiresAt': None, 'emailVerified': False,
        'mfaRequired': False, 'groups': [], 'customClaims': []})
    if status != 200:
        sys.exit(f'Invitation for {username} failed: {status} {body}')
    invite = js(body)
    b = Browser()
    q = urllib.parse.urlencode({
        'client_id': 'auth_internal_client', 'response_type': 'none',
        'scope': 'openid', 'redirect_uri': VA + '/api/cb'})
    b.req('GET', f'{VA}/oidc/auth?{q}', headers={'Accept': 'text/html'})
    status, body, _ = b.req('POST', f'{VA}/api/interaction/register', {
        'username': username, 'name': username, 'password': password,
        'inviteId': invite['id'], 'challenge': invite['challenge']})
    if status != 200:
        sys.exit(f'Registering {username} failed: {status} {body}')


ensure_user(env['ABS_TEST_USER'], env['ABS_TEST_PASSWORD'])
ensure_user(env['ABS_TOTP_USER'], env['ABS_TOTP_PASSWORD'])

# TOTP for the second user: register a secret while logged in, then confirm
# it with a code (which also makes MFA required for that user).
b, status = va_login(env['ABS_TOTP_USER'], env['ABS_TOTP_PASSWORD'])
_, body, _ = b.req('GET', f'{VA}/api/user/me')
me = js(body)
if not (me['hasTotp'] and me['mfaRequired']):
    print(f'Adding TOTP to {env["ABS_TOTP_USER"]}')
    status, body, _ = b.req('POST', f'{VA}/api/interaction/totp/registration')
    if status != 200:
        sys.exit(f'TOTP registration failed: {status} {body}')
    secret = js(body)['secret']
    status, body, _ = b.req('POST', f'{VA}/api/interaction/totp',
                            {'token': totp(secret)})
    if status != 200:
        sys.exit(f'TOTP confirmation failed: {status} {body}')
    save_env('VOIDAUTH_TOTP_SECRET', secret)
elif not env.get('VOIDAUTH_TOTP_SECRET'):
    sys.exit('The TOTP user has a TOTP but VOIDAUTH_TOTP_SECRET is not in '
             '.env: remove its MFA in VoidAuth and run this again')

# --- Audiobookshelf ---------------------------------------------------------

wait(f'{ABS}/status', 'Audiobookshelf')
abs_ = Browser()
_, body, _ = abs_.req('GET', f'{ABS}/status')
if not js(body)['isInit']:
    print('Creating the ABS root user')
    abs_.req('POST', f'{ABS}/init', {'newRoot': {
        'username': env['ABS_ROOT_USER'],
        'password': env['ABS_ROOT_PASSWORD']}})
status, body, _ = abs_.req('POST', f'{ABS}/login', {
    'username': env['ABS_ROOT_USER'], 'password': env['ABS_ROOT_PASSWORD']})
if status != 200:
    sys.exit(f'ABS root login failed: {status}')
auth = {'Authorization': 'Bearer ' + js(body)['user']['token']}

_, body, _ = abs_.req('GET', f'{ABS}/api/libraries', headers=auth)
lib = next((l['id'] for l in js(body)['libraries']
            if l['name'] == 'Test Books'), None)
if not lib:
    print('Creating the book library')
    _, body, _ = abs_.req('POST', f'{ABS}/api/libraries', {
        'name': 'Test Books', 'folders': [{'fullPath': '/audiobooks'}],
        'mediaType': 'book', 'settings': {'autoScanCronExpression': None},
    }, headers=auth)
    lib = js(body)['id']
    abs_.req('POST', f'{ABS}/api/libraries/{lib}/scan', headers=auth)

# OpenID: VoidAuth's issuer is APP_URL/oidc. New SSO users get an ABS
# account on their first login.
_, body, _ = abs_.req('GET', f'{VA}/oidc/.well-known/openid-configuration')
wk = js(body)
status, body, _ = abs_.req('PATCH', f'{ABS}/api/auth-settings', {
    'authActiveAuthMethods': ['local', 'openid'],
    'authOpenIDIssuerURL': wk['issuer'],
    'authOpenIDAuthorizationURL': wk['authorization_endpoint'],
    'authOpenIDTokenURL': wk['token_endpoint'],
    'authOpenIDUserInfoURL': wk['userinfo_endpoint'],
    'authOpenIDJwksURL': wk['jwks_uri'],
    'authOpenIDLogoutURL': wk.get('end_session_endpoint'),
    'authOpenIDClientID': 'abs',
    'authOpenIDClientSecret': env['ABS_OIDC_CLIENT_SECRET'],
    'authOpenIDTokenSigningAlgorithm':
        wk['id_token_signing_alg_values_supported'][0],
    'authOpenIDButtonText': 'Login with VoidAuth',
    'authOpenIDAutoLaunch': False,
    'authOpenIDAutoRegister': True,
    'authOpenIDMatchExistingBy': 'username',
    'authOpenIDMobileRedirectURIs': ['abswear://oauth'],
    # Unset, ABS builds ".../undefined/auth/openid/..." URLs.
    'authOpenIDSubfolderForRedirectURLs': '',
}, headers=auth)
if status != 200:
    sys.exit(f'ABS auth settings failed: {status} {body}')
print(f'Setup complete. ABS {env["ABS_URL"]} uses VoidAuth {wk["issuer"]}')
PY
