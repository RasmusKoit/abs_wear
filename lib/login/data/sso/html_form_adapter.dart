import 'package:abs_wear/login/data/sso/sso_http.dart';
import 'package:abs_wear/login/data/sso/sso_types.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

/// Server-rendered login pages: every screen is a plain HTML `<form>`,
/// filled in and posted like a browser would (hidden fields copied, the
/// right button sent along), then redirects followed to the next page.
///
/// The handling is generic, but it only takes over the login pages of
/// these providers, recognised by:
/// - Keycloak: `<form id="kc-form-login">`, or another `kc-` form on a
///   `/realms/<realm>/` page.
/// - Gitea / Forgejo: a form posting to `/user/login` with a `user_name`
///   (or `_csrf`) field.
/// - Dex: a password form on `/auth/<connector>/login`.
/// - Zitadel (login V1): a form posting to `/ui/login/...` with an
///   `authRequestID` field.
/// - Kanidm: any other form posting to `/ui/login...`.
///
/// A form with nothing to type is only answered on these providers' app
/// consent pages (see [_Form.consentPath]); other such forms, like
/// Keycloak's terms and conditions, are unsupported steps.
///
/// Keycloak and Gitea are tested against the real servers; the others
/// follow their templates. (Nextcloud is not here: it draws its login form
/// in the browser.)
class HtmlFormAdapter implements IdpAdapter {
  HtmlFormAdapter._(this.name, IdpContext context)
    : _http = context.http,
      _follow = context.follow;

  /// The adapter for [page] if it is a known provider's login form.
  static IdpAdapter? forPage(SsoPage page, IdpContext context) {
    final name = provider(page);
    return name == null ? null : HtmlFormAdapter._(name, context);
  }

  final SsoHttp _http;
  final FollowRedirects _follow;

  @override
  final String name;

  @override
  Uri? redirect;

  /// The form on the current screen.
  _Form? _form;
  String? _user;

  /// Where the first page says to go once signed in (Gitea's
  /// `?redirect_to=`, same server only).
  Uri? _resume;

  /// Which provider's login page [page] is (see the class doc), or null.
  static String? provider(SsoPage page) {
    if (!page.body.contains('<form')) return null;
    final doc = html.parse(page.body);
    final url = page.url;
    final s = url.pathSegments;
    final dex = s.length >= 3 && s[s.length - 3] == 'auth' && s.last == 'login';
    for (final form in doc.querySelectorAll('form')) {
      final id = form.attributes['id'] ?? '';
      final action = _action(form, url).path;
      bool has(String input) =>
          form.querySelector('input[name="$input"]') != null;
      if (id == 'kc-form-login' ||
          (id.startsWith('kc-') && s.contains('realms'))) {
        return 'Keycloak';
      }
      // Older Gitea / Forgejo have a _csrf field, newer ones don't.
      if (action.endsWith('/user/login') &&
          (has('user_name') || has('_csrf'))) {
        return page.body.toLowerCase().contains('forgejo')
            ? 'Forgejo'
            : 'Gitea';
      }
      if (dex && has('password')) return 'Dex';
      if (action.contains('/ui/login/') && has('authRequestID')) {
        return 'Zitadel';
      }
      if (action.startsWith('/ui/login')) return 'Kanidm';
    }
    return null;
  }

  @override
  Future<SsoStep> begin(SsoPage page) async {
    final to = page.url.queryParameters['redirect_to'];
    if (to != null && to.startsWith('/') && !to.startsWith('//')) {
      _resume = page.url.resolve(to);
    }
    return _step(page) ?? (throw _unsupported(page));
  }

  @override
  Future<SsoStep?> submit(Map<SsoField, String> answer) async {
    final form = _form;
    if (form == null) throw const SsoException(SsoError.failed, 'no form');
    final user = answer[SsoField.username] ?? answer[SsoField.email];
    if (user != null && user.isNotEmpty) _user = user;
    final response = await _http.send(
      'POST',
      form.action,
      form: [
        ...form.fixed,
        for (final (name, field) in form.inputs) (name, answer[field] ?? ''),
        ?form.button,
      ],
      headers: const {'Accept': 'text/html'},
    );
    final SsoPage page;
    final next = SsoHttp.redirectTarget(form.action, response);
    if (next != null) {
      final (p, back) = await _follow(next);
      if (back != null) {
        redirect = back;
        _form = null;
        return null;
      }
      page = p!;
    } else if (response.statusCode < 500 && response.body.contains('<form')) {
      // A wrong password is usually answered with the same form (200, or
      // 400/401 on some servers) and an error message.
      page = SsoPage(form.action, response.body);
    } else {
      throw SsoException(
        SsoError.failed,
        '${response.statusCode} at ${form.action.path}',
      );
    }
    if (_step(page, after: form) case final step?) return step;
    final resume = _resume;
    if (resume == null) throw _unsupported(page);
    // Signed in, but not sent on: Gitea forgets where it was going after a
    // TOTP code and shows its home page. Go where the first page said.
    _resume = null;
    final (p, back) = await _follow(resume);
    if (back != null) {
      redirect = back;
      _form = null;
      return null;
    }
    return _step(p!) ?? (throw _unsupported(p));
  }

  /// The step for [page]'s form, or null if it has none the watch can
  /// answer. [after] is the form just sent: the same form again means the
  /// answer was wrong.
  SsoStep? _step(SsoPage page, {_Form? after}) {
    if (_captcha.hasMatch(page.body)) {
      throw const SsoException(SsoError.unsupportedStep, 'captcha');
    }
    final doc = html.parse(page.body);
    // Keycloak shows who is logging in above its later screens.
    _user =
        doc.getElementById('kc-attempted-username')?.attributes['value'] ??
        _user;
    final forms = [
      for (final f in doc.querySelectorAll('form')) ?_Form.parse(f, page.url),
    ];
    // A form to fill in first; a consent form only if there is none.
    final form =
        forms.where((f) => f.inputs.isNotEmpty).firstOrNull ??
        forms.firstOrNull;
    if (form == null) return null;
    _form = form;
    if (form.inputs.isEmpty) return SsoConsent(_app(doc) ?? 'Audiobookshelf');
    final fields = [for (final (_, field) in form.inputs) field];
    final asksUser =
        fields.contains(SsoField.username) || fields.contains(SsoField.email);
    return SsoPrompt(
      fields,
      user: asksUser ? null : _user,
      retry: after != null && after.key == form.key,
    );
  }

  /// A page with nothing the watch can answer: a new password, a passkey,
  /// an error page, ... Keycloak names its pages in data-page-id.
  static SsoException _unsupported(SsoPage page) => SsoException(
    SsoError.unsupportedStep,
    html.parse(page.body).body?.attributes['data-page-id'] ?? page.url.path,
  );

  /// The app named on a consent page, if found.
  static String? _app(Document doc) {
    for (final heading in doc.querySelectorAll('#kc-page-title, h1, h2, h3')) {
      final text = heading.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      for (final pattern in _consentTitles) {
        final app = pattern.firstMatch(text)?.group(1)?.trim();
        if (app != null && app.isNotEmpty && app.length <= 60) {
          return app.replaceAll(RegExp(r'^["“]|["”?]+$'), '');
        }
      }
    }
    return null;
  }

  static final _consentTitles = [
    // Keycloak: "Grant Access to <client>".
    RegExp('grant access to (.+)', caseSensitive: false),
    // Gitea / Forgejo: "Authorize "<app>" to access your account?".
    RegExp('authorize (.+?) to access', caseSensitive: false),
    // Kanidm: "Consent to Proceed to <client>".
    RegExp('consent to proceed to (.+)', caseSensitive: false),
  ];

  static final _captcha = RegExp(
    'g-recaptcha|h-captcha|cf-turnstile|frc-captcha|data-sitekey',
  );

  static Uri _action(Element form, Uri page) => page.resolve(
    form.attributes['action'] ?? form.attributes['hx-post'] ?? '',
  );
}

/// A form the watch can fill in: [inputs] are asked for, [fixed] fields
/// (hidden, read-only, preselected, or only there for password managers)
/// are sent as they are, with [button]. Without inputs it is an app
/// consent form and [button] accepts.
class _Form {
  _Form(this.action, this.fixed, this.inputs, this.button);

  final Uri action;
  final List<(String, String)> fixed;
  final List<(String, SsoField)> inputs;
  final (String, String)? button;

  /// The same key for the same form shown again.
  String get key =>
      '${action.path} ${[for (final (_, f) in inputs) f.name].join(',')}';

  /// [form] if it is a sign-in or consent form the watch can answer.
  static _Form? parse(Element form, Uri page) {
    final method = form.attributes['method']?.toUpperCase() ?? 'GET';
    if (method != 'POST') return null;
    final fixed = <(String, String)>[];
    final inputs = <(String, SsoField)>[];
    final buttons = <Element>[];
    for (final e in form.querySelectorAll('input, button, select, textarea')) {
      final a = e.attributes;
      if (a.containsKey('disabled')) continue;
      final tag = e.localName;
      final type = (a['type'] ?? (tag == 'button' ? 'submit' : 'text'))
          .toLowerCase();
      if (type == 'submit' || type == 'image') {
        buttons.add(e);
        continue;
      }
      final name = a['name'];
      if (tag == 'button' || name == null || name.isEmpty) continue;
      if (tag == 'textarea') return null;
      if (tag == 'select') {
        final option =
            e.querySelector('option[selected]') ?? e.querySelector('option');
        if (option != null) {
          fixed.add((name, option.attributes['value'] ?? option.text));
        }
        continue;
      }
      switch (type) {
        case 'hidden':
          fixed.add((name, a['value'] ?? ''));
        case 'checkbox' || 'radio':
          // "Remember me" and the like stay as the page has them.
          if (a.containsKey('checked')) fixed.add((name, a['value'] ?? 'on'));
        case 'button' || 'reset':
          break;
        case _ when a.containsKey('readonly') || _hidden(e, form):
          // Read-only, or hidden with CSS for a password manager to fill
          // (Kanidm, Zitadel): sent as the page has it, not asked for.
          fixed.add((name, a['value'] ?? ''));
        default:
          final field = _field(type, name, a);
          // A field the watch can't fill (new password, a name, ...), or
          // the same one twice.
          if (field == null || inputs.any((i) => i.$2 == field)) return null;
          inputs.add((name, field));
      }
    }
    final action = HtmlFormAdapter._action(form, page);
    // Answers (the password) only go back to the server showing the form.
    if (action.scheme != page.scheme ||
        action.host != page.host ||
        action.port != page.port) {
      return null;
    }
    if (inputs.isNotEmpty) {
      final button = buttons.where((b) => !_isCancel(b)).firstOrNull;
      return _Form(action, fixed, inputs, _pair(button));
    }
    // Nothing to type: only a known app consent page is answered. Other
    // forms like it (Keycloak's terms and conditions) are not the watch's
    // to accept.
    if (!consentPath.hasMatch(action.path)) return null;
    // The accept button, else the one that isn't cancel (Kanidm's
    // "Proceed").
    final ok = buttons.where((b) => !_isCancel(b));
    final accept =
        ok.where((b) => _accept.hasMatch(_describe(b))).firstOrNull ??
        ok.firstOrNull;
    return accept == null ? null : _Form(action, fixed, inputs, _pair(accept));
  }

  /// Where the app consent forms post: Keycloak, Gitea / Forgejo, Dex,
  /// Kanidm.
  static final consentPath = RegExp(
    '(/login-actions/consent|/login/oauth/grant|/approval|'
    r'/ui/oauth2/consent)$',
  );

  /// Whether [e], or a parent inside [form], is hidden from the user.
  static bool _hidden(Element e, Element form) {
    for (Element? x = e; x != null && x != form; x = x.parent) {
      final a = x.attributes;
      final classes = (a['class'] ?? '').split(RegExp(r'\s+'));
      if (a.containsKey('hidden') ||
          a['aria-hidden'] == 'true' ||
          _displayNone.hasMatch(a['style'] ?? '') ||
          classes.any(_hiddenClasses.contains)) {
        return true;
      }
    }
    return false;
  }

  static const _hiddenClasses = {'hidden', 'd-none', 'tw-hidden'};
  static final _displayNone = RegExp(r'display\s*:\s*none');

  /// What a visible input asks for, from its type, name and autocomplete.
  static SsoField? _field(String type, String name, Map<Object, String> a) {
    final hint = '$name ${a['id'] ?? ''} ${a['autocomplete'] ?? ''}'
        .toLowerCase();
    if (type == 'password') {
      return _newPassword.hasMatch(hint) ? null : SsoField.password;
    }
    if (!const {'text', 'email', 'tel', 'number'}.contains(type)) return null;
    if (hint.contains('one-time-code') || _code.hasMatch(name)) {
      return SsoField.code;
    }
    if (type == 'email' || name.toLowerCase() == 'email') {
      return SsoField.email;
    }
    if (_username.hasMatch(name) || hint.contains('username')) {
      return SsoField.username;
    }
    return null;
  }

  /// A button's name=value as a browser sends it (nothing if unnamed).
  static (String, String)? _pair(Element? button) {
    final name = button?.attributes['name'];
    if (name == null || name.isEmpty) return null;
    return (name, button!.attributes['value'] ?? '');
  }

  static String _describe(Element b) => [
    b.attributes['name'],
    b.attributes['value'],
    b.attributes['id'],
    b.text,
  ].whereType<String>().join(' ').toLowerCase();

  static bool _isCancel(Element b) => _cancel.hasMatch(_describe(b));

  static final _newPassword = RegExp(r'\bnew\b|confirm');
  static final _code = RegExp(
    r'^(otp|totp|passcode|code|challenge|backup_?code)$',
    caseSensitive: false,
  );
  static final _username = RegExp(
    r'^(username|user_?name|user|login|login_?name|identifier|uid)$',
    caseSensitive: false,
  );
  static final _accept = RegExp(
    r'\b(accept|approve|allow|grant(ed)?|authori[sz]e|yes|true|consent)\b',
  );
  static final _cancel = RegExp(
    r'\b(cancel|deny|reject|decline|no|false|back|restart|reset)\b',
  );
}
