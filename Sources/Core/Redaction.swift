import Foundation

/// Masks secret-shaped spans before recording or model use. Rules inspect value shape, never
/// country or parameter-name lists; `vendorPatterns` accepts explicit prefixes and structures.
/// Ordinary login names, short passwords and keys with no recognized shape or adjacent label
/// cannot be recognized this way.
/// A redactor that fires all the time is one nobody trusts.
/// Telephone numbers are not masked: the system detector was
/// the expensive part, and a number in a local record does little harm. No telephone rule
/// replaces it. Text stored earlier keeps its "[phone]" marks; they are ordinary text here.
public enum Redaction {
  /// Kept for historical rows and callers which recognize the old marker.
  static let mark = "[redacted]"
  static let emailMark = "[email]"
  public static let secretMark = "[secret]"

  // The one word list kept on purpose: password/credential values have no reliable shape.
  // Secret key covers named signing/encryption keys and SECRET_KEY environment assignments;
  // passphrase covers encryption or wallet unlocking, passcode covers short authentication codes.
  // A label must end at : or = (or the full-width colon a screen reading gives), so token_count
  // and primary_key are ordinary code. Names ending in a label word are credentials whatever
  // stands before them (dbPassword, PGPASSWORD, clientSecret, openaiApiKey, accessToken,
  // AUTHTOKEN). The one narrowing: the wholly small-letter spelling "token" right after a small
  // letter, because ordinary names end that way ("mytoken = count", "nexttoken = lexer.advance()",
  // "pagetoken=12" stay). Any other casing there (authtOKEN, authtoKEN) is masked. The recovery
  // label refuses the same one shape, with no list.
  private static let openNames = #"password|passwd|passphrase|passcode|secret(?:[_ -]key)?|api[_ -]?key"#
  private static let secretNames = openNames + "|token"
  private static let recoveryNames = #"(?:seed|recovery|mnemonic)[_ -]?phrase"#
  // The small-letter "token" glued after small letters is masked when those letters are
  // words used for credentials, so
  // "authtoken=" and "csrftoken:" are masked and "nexttoken =" is not. A word not here is not
  // masked in that glued form; every other spelling (auth_token, authToken, AUTHTOKEN) never
  // needed the list. Credential-word meanings:
  //   auth                 the token proves who is calling
  //   csrf, xsrf           the per-session value a form or header must repeat
  //   api, access, bearer  the value sent with each request in place of a password
  //   refresh              the long-lived value that buys new access tokens
  //   session              whoever holds it is the signed-in person
  //   deploy               what a build machine uses to fetch or publish code
  // and five more, kept as a deliberate lean towards credentials:
  //   oauth, login         as auth ("oauth" is "auth" with a letter before it, which the
  //                        boundary below would otherwise refuse)
  //   jwt                  a signed token
  //   secret               the name itself says the value is not to be shown
  //   webhook              the value that lets a caller post to an endpoint
  // None of the fourteen is free: a parser's "authtoken = lexer.expect(AUTH_KEYWORD)" and
  // "jwttoken: TokenKind = JWT_TYPE_KEYWORD" lose the right-hand side. That loss is accepted.
  // Left out, because the glued name is ordinary code or names no credential: private (a
  // visibility keyword), registry (a section), bot and app and service (programs), personal
  // (whose it is), invite (an action; a game piece), id (the identifier token of a parser),
  // user (a token the user typed), push (a verb in a parser) and device (an address for
  // notifications), reset (a verb, a flag), client (a value that makes a request repeatable,
  // not a secret), and the names of vendors (a list with no end; their explicit key shapes
  // are masked by `vendorPatterns`).
  static let gluedTokenWords = ["auth", "csrf", "xsrf", "api", "access", "refresh", "bearer", "session", "deploy",
    "oauth", "login", "jwt", "secret", "webhook"]
  // The words must begin where the label rule already accepts a name's start: at the start of
  // the text, after anything but a small letter, or at a hump (the word's own capital). Up to
  // three of them may stand in a row (oauthaccesstoken, oauthRefreshtoken), counted from the
  // last hump: a capital starts the count again. "myauthtoken" and "okapitoken" begin with
  // something else and stay.
  private static let gluedToken: String = {
    let small = gluedTokenWords.joined(separator: "|")
    let hump = gluedTokenWords.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "|")
    let either = gluedTokenWords.map { "[" + $0.prefix(1).uppercased() + $0.prefix(1) + "]" + $0.dropFirst() }.joined(separator: "|")
    return "(?<=(?:(?:^|[^\\p{Ll}])(?:" + small + ")|(?:" + hump + "))(?:" + either + "){0,2}token)"
  }()
  // The label rule as it stood before the credential words. It is not widened: the glued form
  // has its own pass (`gluedTokens`) over the finished text, so a newly recognised outer name
  // can never take the start of a value this rule would have masked whole:
  // authtoken=password:"three invented words" once left the last two words in plain text.
  private static let secretLabel = "(?:(?i:" + openNames + #")|(?!(?<=\p{Ll})token)(?i:token))"#
  private static let recoveryLabel = #"(?!(?<=\p{Ll})(?:"# + recoveryNames + "))(?i:" + recoveryNames + ")"
  // The separator after a label. A quote may close the label first, bare or escaped: JSON
  // written inside a line ({"password":"…"} and {\"password\":\"…\"}).
  private static let labelEnd = #"(?:\\?["'])?\s*[:=：]"#
  private static let labelValue = #"\s*(?:"[^"\r\n]+"|'[^'\r\n]+'|\S+)"#
  private static let gluedLabel = try! NSRegularExpression(pattern: "token" + gluedToken + labelEnd + labelValue)

  private static let patterns: [(rule: String, regex: NSRegularExpression)] = [
    ("private-key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"#),
    // ghp_/gho_/ghu_/ghs_/ghr_ plus 20+ ASCII letters or digits; github_pat_ plus 20+ letters, digits or underscores.
    ("github-token", #"gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}"#),
    // Not after a letter or digit: task-…, flask-… and risk-… names are not keys.
    ("api-key", #"(?<![A-Za-z0-9])sk-[A-Za-z0-9_\-]{20,}"#),
    // AKIA or ASIA plus 16 capitals or digits, with no capital or digit adjoining either end.
    ("aws-key", #"(?<![A-Z0-9])A[KS]IA[0-9A-Z]{16}(?![A-Z0-9])"#),
    // xox[baprs]-, xapp- or xwfp- plus 10+ letters, digits or hyphens; xoxe. may precede these.
    // Bare xapp-/xwfp- require a non-alphanumeric left boundary; xoxe-1- accepts the same body.
    ("slack-token", #"(?:xoxe\.(?:xox[baprs]|xapp|xwfp)|xox[baprs]|(?<![A-Za-z0-9])(?:xapp|xwfp))-[A-Za-z0-9\-]{10,}|xoxe-1-[A-Za-z0-9\-]{10,}"#),
    ("jwt", #"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#),
    // A phrase label and a colon (ASCII/full-width) or equals sign on the same line, then 12/15/18/21/24 words of 3-8 ASCII letters.
    // Reject a partial word run; mask only the captured phrase. No wordlist or checksum check.
    ("wallet-recovery", recoveryLabel + #"[ \t]*[:=：][ \t]*["']?([A-Za-z]{3,8}(?:[ \t]+[A-Za-z]{3,8}){11}(?:(?:[ \t]+[A-Za-z]{3,8}){3}){0,4})(?![A-Za-z0-9_\-]|[ \t]+[A-Za-z0-9_\-])"#),
    // Quoted values can contain spaces; unquoted values retain the existing non-whitespace rule.
    ("labeled-secret", secretLabel + labelEnd + labelValue),
    ("url-credential", #"(?i)(?<![a-z0-9+.-])(?>(?:[a-z0-9+.-]*?)(\b[a-z]))[a-z0-9+.-]*://[^\s/@]+@"#),
    ("email", #"(?<![\p{L}\p{N}._%+\-])[\p{L}\p{N}._%+\-]+@[\p{L}\p{N}](?:[\p{L}\p{N}.\-]*\.)[\p{L}\p{N}\-]{2,}(?![\p{L}\p{N}\-])"#),
    // OCR often loses "@". Start only at a whole prefix run or the preceding match's end
    // (\G preserves adjacent matches after an @). Retrying at every prefix character was
    // quadratic when no provider suffix followed. The greedy match itself is unchanged.
    ("email", #"(?i)(?:(?<![A-Za-z0-9._%+\-])|\G)[A-Za-z0-9._%+\-]{3,}[@8]?(naver|gmail|daum|hanmail|kakao|icloud|outlook|hotmail|nate)\.(com|net)"#),
  ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }
  /// One per entry of `patterns`, in the same order.
  private static let triggers: [(String) -> Bool] = [
    { holds($0, "-----BEGIN") },
    // "github_pat_" holds no "gh": the fine-grained token needs its own literal.
    { holds($0, "gh") || holds($0, "github_pat_") }, { startsWord("sk-", in: $0) },
    { startsWord("AKIA", in: $0, capitalsOnly: true) || startsWord("ASIA", in: $0, capitalsOnly: true) },
    { holds($0, "xox") || startsWord("xapp-", in: $0) || startsWord("xwfp-", in: $0) }, { holds($0, "eyJ") },
    { hasLabelEnd($0) }, { hasLabelEnd($0) },
    { holds($0, "://") && holds($0, "@") }, { holds($0, "@") },
    { holds($0, ".com", anyCase: true) || holds($0, ".net", anyCase: true) },
  ]
  /// Whether the text holds `literal`, unit by unit as the expressions read it. The
  /// character-wise `contains` does not see a ":" that a joiner or a combining mark follows,
  /// and the rule behind the guard does.
  private static func holds(_ text: String, _ literal: String, anyCase: Bool = false) -> Bool {
    (text as NSString).range(of: literal, options: anyCase ? [.literal, .caseInsensitive] : .literal).location != NSNotFound
  }
  private static func hasLabelEnd(_ text: String) -> Bool { holds(text, ":") || holds(text, "=") || holds(text, "：") }
  /// Whether `literal` stands somewhere that is not right after an ASCII letter or digit
  /// (`capitalsOnly`: not right after a capital or digit). The left boundary of the short
  /// prefixes, asked before their expressions run.
  private static func startsWord(_ literal: String, in text: String, capitalsOnly: Bool = false) -> Bool {
    let ns = text as NSString
    var from = 0
    while from < ns.length {
      let found = ns.range(of: literal, options: .literal, range: NSRange(location: from, length: ns.length - from))
      guard found.location != NSNotFound else { return false }
      guard found.location > 0 else { return true }
      let before = ns.character(at: found.location - 1)
      let joined = (48...57).contains(before) || (65...90).contains(before) || (!capitalsOnly && (97...122).contains(before))
      if !joined { return true }
      from = found.location + 1
    }
    return false
  }

  /// Credential shapes with explicit prefixes, lengths, character sets and boundaries.
  /// A capture group limits masking to the credential inside the surrounding text.
  /// Each rule runs only when `vendorHints` saw its anchor (`Hint`).
  private static let vendorPatterns: [(rule: String, hint: UInt64, regex: NSRegularExpression)] = [
    // AIza plus 30+ ASCII letters, digits, underscores or hyphens.
    ("google-key", Hint.google, #"AIza[0-9A-Za-z_\-]{30,}"#),
    // ya29. plus 20+ letters, digits, underscores, hyphens or dots, after a non-alphanumeric boundary.
    ("google-key", Hint.google, #"(?<![A-Za-z0-9])ya29\.[A-Za-z0-9_\-.]{20,}"#),
    // Case-insensitive secret_access_key or secretaccesskey (each underscore optional),
    // optional quotes and whitespace around a colon or equals sign, then a captured 20+ character ASCII-letter/digit/+= value.
    ("aws-key", Hint.accessKey, #"(?i)secret_?access_?key["']?\s*[:=]\s*["']?([A-Za-z0-9/+=]{20,})"#),
    // AccountKey= or SharedAccessKey=, capturing 20+ base64 characters and up to two padding equals signs.
    ("azure-key", Hint.accessKey, #"(?:AccountKey|SharedAccessKey)=([A-Za-z0-9+/]{20,}={0,2})"#),
    // gl plus pat/oas/dt/rt/rtr/cbt/ptt/ft/imt/agent/wt/soat/ffct, then a hyphen
    // and 20+ ASCII letters, digits, underscores, hyphens or dots.
    ("gitlab-token", Hint.gitlab, #"gl(?:pat|oas|dt|rtr?|cbt|ptt|ft|imt|agent|wt|soat|ffct)-[A-Za-z0-9_\-.]{20,}"#),
    // hooks.slack.com/services/, capturing 8+ letters, digits, underscores, hyphens or slashes.
    // Every slash may have a JSON escape backslash.
    ("slack-webhook", Hint.slackHook, #"hooks\.slack\.com\\?/services\\?/((?:[A-Za-z0-9_\-]|\\?/){8,})"#),
    // Non-alphanumeric left boundary, then sk_/rk_ plus live_/test_/org_, optional letters,
    // digits or underscores and 16+ trailing alphanumerics; or whsec_ plus 16+ letters, digits, +/=_-.
    ("stripe-key", Hint.stripe, #"(?<![A-Za-z0-9])(?:[sr]k_(?:live|test|org)_[A-Za-z0-9_]*[A-Za-z0-9]{16,}|whsec_[A-Za-z0-9+/=_\-]{16,})"#),
    // SK plus exactly 32 hexadecimal digits, with no ASCII letter or digit adjoining either end.
    ("twilio-key", Hint.twilio, #"(?<![A-Za-z0-9])SK[0-9a-fA-F]{32}(?![A-Za-z0-9])"#),
    // Non-alphanumeric left boundary, then SG. and two dot-separated groups of 16+ letters, digits, _ or -.
    ("sendgrid-key", Hint.sendgrid, #"(?<![A-Za-z0-9])SG\.[A-Za-z0-9_\-]{16,}\.[A-Za-z0-9_\-]{16,}"#),
    // 31-32 lowercase hexadecimal digits after a non-hex boundary, then -us and 1-2 digits.
    // Refuse a following alphanumeric/underscore, or a dot/hyphen followed by an alphanumeric.
    ("mailchimp-key", Hint.mailchimp, #"(?<![0-9a-fA-F])[0-9a-f]{31,32}-us[0-9]{1,2}(?![0-9A-Za-z_]|[.\-][0-9A-Za-z])"#),
    // npm_ plus 30+ ASCII letters or digits, after a non-alphanumeric left boundary.
    ("npm-token", Hint.npm, #"(?<![A-Za-z0-9])npm_[A-Za-z0-9]{30,}"#),
    // pypi- plus 70+ ASCII letters, digits, underscores or hyphens, after a non-alphanumeric boundary.
    ("pypi-token", Hint.pypi, #"(?<![A-Za-z0-9])pypi-[A-Za-z0-9_\-]{70,}"#),
    // dop_v1_/doo_v1_/dor_v1_ plus 40+ ASCII letters or digits, after a non-alphanumeric boundary.
    ("digitalocean-token", Hint.digitalocean, #"(?<![A-Za-z0-9])do[por]_v1_[A-Za-z0-9]{40,}"#),
    // /api/webhooks/ plus a decimal ID and slash, capturing 16+ letters, digits, underscores or hyphens.
    // Every slash may have a JSON escape backslash.
    ("discord-webhook", Hint.discord, #"/api\\?/webhooks\\?/[0-9]+\\?/([A-Za-z0-9_\-]{16,})"#),
    // 5-12 decimal digits after a non-digit boundary, a colon, then a 30-40 character body of letters, digits, _ or -.
    // Require a capital, lowercase letter, digit and at least one G-Z/g-z/underscore; reject a joined body suffix.
    ("telegram-token", Hint.telegram, #"(?<![0-9])[0-9]{5,12}:(?=[A-Za-z0-9_\-]*[G-Zg-z_])(?=[A-Za-z0-9_\-]*[A-Z])(?=[A-Za-z0-9_\-]*[a-z])(?=[A-Za-z0-9_\-]*[0-9])[A-Za-z0-9_\-]{30,40}(?![A-Za-z0-9_\-])"#),
    // Non-alphanumeric left boundary, then sb_secret_ plus 20+ letters, digits, _ or -,
    // or sbp_ plus 30+ ASCII letters or digits. Public sb_publishable_ values stay.
    ("supabase-key", Hint.supabase, #"(?<![A-Za-z0-9])(?:sb_secret_[A-Za-z0-9_\-]{20,}|sbp_[A-Za-z0-9]{30,})"#),
    // hf_ plus 30+ ASCII letters or digits, after a non-alphanumeric left boundary.
    ("huggingface-token", Hint.huggingface, #"(?<![A-Za-z0-9])hf_[A-Za-z0-9]{30,}"#),
    // cfk_/cfut_/cfat_/cfast_ plus 40+ ASCII letters or digits, after a non-alphanumeric boundary.
    ("cloudflare-token", Hint.cloudflare, #"(?<![A-Za-z0-9])cf(?:k|ut|at|ast)_[A-Za-z0-9]{40,}"#),
    // vcp_/vci_/vca_/vcr_/vck_ plus 24+ ASCII letters or digits, after a non-alphanumeric boundary.
    ("vercel-token", Hint.vercel, #"(?<![A-Za-z0-9])vc[piark]_[A-Za-z0-9]{24,}"#),
    // Non-alphanumeric left boundary, then pat-, two lowercase letters, a digit and a hyphen,
    // followed by lowercase hexadecimal groups of 8-4-4-4-12 characters.
    ("hubspot-token", Hint.hubspot, #"(?<![A-Za-z0-9])pat-[a-z]{2}[0-9]-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#),
    // phx_/phs_ plus 30+ ASCII letters or digits, after a non-alphanumeric boundary. Public phc_ values stay.
    ("posthog-key", Hint.posthog, #"(?<![A-Za-z0-9])ph[xs]_[A-Za-z0-9]{30,}"#),
    // sk_ plus 32+ ASCII letters or digits, after a non-alphanumeric left boundary.
    ("elevenlabs-key", Hint.stripe, #"(?<![A-Za-z0-9])sk_[A-Za-z0-9]{32,}"#),
    // shpat_/shppa_ plus 24+ ASCII letters or digits.
    ("shopify-token", Hint.shopify, #"shp(?:at|pa)_[A-Za-z0-9]{24,}"#),
    // sntryu_/sntrys_/sntrya_/sntryi_ plus 40+ ASCII letters, digits, _+/=-.
    ("sentry-token", Hint.sentry, #"sntry[usai]_[A-Za-z0-9_+/=\-]{40,}"#),
    // Non-alphanumeric left boundary, then dp.ct./dp.pt./dp.st. and 40-44 ASCII alphanumerics.
    // dp.st. may insert a 2-35 character lowercase-letter/digit/_/- segment and another dot.
    ("doppler-token", Hint.doppler, #"(?<![A-Za-z0-9])dp\.(?:ct|pt|st(?:\.[a-z0-9_\-]{2,35})?)\.[A-Za-z0-9]{40,44}"#),
    // hvs./hvb./hvr. plus 24+ ASCII letters, digits, underscores or hyphens, after a non-alphanumeric boundary.
    ("vault-token", Hint.vault, #"(?<![A-Za-z0-9])hv[sbr]\.[A-Za-z0-9_\-]{24,}"#),
    // glsa_/glc_ plus 20+ ASCII letters, digits, underscores or equals signs, after a non-alphanumeric boundary.
    ("grafana-token", Hint.gitlab, #"(?<![A-Za-z0-9])gl(?:sa|c)_[A-Za-z0-9_=]{20,}"#),
    // dapi plus exactly 32 ASCII letters or digits, with no ASCII letter or digit adjoining either end.
    ("databricks-token", Hint.databricks, #"(?<![A-Za-z0-9])dapi[A-Za-z0-9]{32}(?![A-Za-z0-9])"#),
    // dckr_pat_ plus 20+ ASCII letters, digits, underscores or hyphens.
    ("docker-token", Hint.docker, #"dckr_pat_[A-Za-z0-9_\-]{20,}"#),
    // NRAK- plus 20+ ASCII capitals or digits.
    ("newrelic-key", Hint.newrelic, #"NRAK-[A-Z0-9]{20,}"#),
    // tskey-, one or more lowercase ASCII letters, a hyphen and 16+ ASCII letters, digits or hyphens.
    ("tailscale-key", Hint.tailscale, #"tskey-[a-z]+-[A-Za-z0-9\-]{16,}"#),
    // ntn_ plus 30+ ASCII letters or digits, after a non-alphanumeric left boundary.
    ("notion-token", Hint.notion, #"(?<![A-Za-z0-9])ntn_[A-Za-z0-9]{30,}"#),
    // Case-insensitive whole-word Authorization, optional quotes and whitespace around a colon or equals sign,
    // then Bearer/Basic/Bot/token and whitespace. Capture 16+ letters, digits, ._~+/=-.
    ("authorization-header", Hint.authorization, #"(?i)\bAuthorization["']?\s*[:=]\s*["']?(?:Bearer|Basic|Bot|token)\s+([A-Za-z0-9._~+/=\-]{16,})"#),
  ].map { ($0.0, $0.1, try! NSRegularExpression(pattern: $0.2)) }
  /// One bit for each anchor `vendorHints` looks for.
  private enum Hint {
    static let google: UInt64 = 1 << 0
    static let accessKey: UInt64 = 1 << 1
    static let gitlab: UInt64 = 1 << 2
    static let slackHook: UInt64 = 1 << 3
    static let stripe: UInt64 = 1 << 4
    static let twilio: UInt64 = 1 << 5
    static let sendgrid: UInt64 = 1 << 6
    static let mailchimp: UInt64 = 1 << 7
    static let npm: UInt64 = 1 << 8
    static let pypi: UInt64 = 1 << 9
    static let digitalocean: UInt64 = 1 << 10
    static let discord: UInt64 = 1 << 11
    static let telegram: UInt64 = 1 << 12
    static let supabase: UInt64 = 1 << 13
    static let huggingface: UInt64 = 1 << 14
    static let cloudflare: UInt64 = 1 << 15
    static let vercel: UInt64 = 1 << 16
    static let hubspot: UInt64 = 1 << 17
    static let posthog: UInt64 = 1 << 18
    static let shopify: UInt64 = 1 << 19
    static let sentry: UInt64 = 1 << 20
    static let doppler: UInt64 = 1 << 21
    static let vault: UInt64 = 1 << 22
    static let databricks: UInt64 = 1 << 23
    static let docker: UInt64 = 1 << 24
    static let newrelic: UInt64 = 1 << 25
    static let tailscale: UInt64 = 1 << 26
    static let notion: UInt64 = 1 << 27
    static let authorization: UInt64 = 1 << 28
  }

  /// Which vendor rules could match: one pass over the bytes, looking for each rule's literal
  /// anchor. A superset of what `vendorPatterns` can match (the self-test checks every invented
  /// key against it), so zero means none of them needs to run. Keep it in step with the rules.
  static func vendorHints(_ text: String) -> UInt64 {
    var text = text
    return text.withUTF8 { bytes -> UInt64 in
      guard let base = bytes.baseAddress else { return 0 }
      let count = bytes.count
      var hints: UInt64 = 0
      func has(_ at: Int, _ literal: StaticString) -> Bool {
        at + literal.utf8CodeUnitCount <= count && memcmp(base + at, literal.utf8Start, literal.utf8CodeUnitCount) == 0
      }
      func hasAnyCase(_ at: Int, _ literal: StaticString) -> Bool {
        at + literal.utf8CodeUnitCount <= count
          && strncasecmp(UnsafeRawPointer(base + at).assumingMemoryBound(to: CChar.self),
            UnsafeRawPointer(literal.utf8Start).assumingMemoryBound(to: CChar.self), literal.utf8CodeUnitCount) == 0
      }
      func alphanumeric(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) }
      func hex(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) }
      // Number literals and a plain loop: this runs on every stored string, in a debug build too.
      var position = 0
      while position < count {
        let index = position
        position += 1
        let next = index + 1 < count ? base[index + 1] : 0
        switch base[index] {
        case 65, 97:  // A a
          if next == 73 /* I */, has(index, "AIza") { hints |= Hint.google }
          if next | 0x20 == 99 /* c */, hasAnyCase(index, "access") || has(index, "AccountKey=") { hints |= Hint.accessKey }
          if next | 0x20 == 117 /* u */, hasAnyCase(index, "authorization") { hints |= Hint.authorization }
        case 0xC5:  // the long s, which the expression's ignored case reads as "s"
          if next == 0xBF { hints |= Hint.accessKey }
        case 121:  // y
          if next == 97 /* a */, has(index, "ya29.") { hints |= Hint.google }
        case 103:  // g
          // "gl", up to five more lowercase letters, then "-" or "_" (glpat-, glagent-, glsa_).
          if next == 108 /* l */ {
            var end = index + 2
            while end < count, end < index + 8, (97...122).contains(base[end]) { end += 1 }
            if end < count, end > index + 2, base[end] == 45 || base[end] == 95 { hints |= Hint.gitlab }
          }
        case 104:  // h
          if next == 102 /* f */, has(index, "hf_") { hints |= Hint.huggingface }
          if next == 118 /* v */, index + 3 < count, base[index + 3] == 46 /* . */ { hints |= Hint.vault }
          if next == 111 /* o */, has(index, "hooks.slack.com") { hints |= Hint.slackHook }
        case 115, 114:  // s r
          if next == 107 /* k */, has(index + 1, "k_"), index == 0 || !alphanumeric(base[index - 1]) { hints |= Hint.stripe }
          if next == 98 /* b */, has(index, "sb_secret_") || has(index, "sbp_") { hints |= Hint.supabase }
          if next == 104 /* h */, has(index, "shpat_") || has(index, "shppa_") { hints |= Hint.shopify }
          if next == 110 /* n */, has(index, "sntry") { hints |= Hint.sentry }
        case 119:  // w
          if next == 104 /* h */, has(index, "whsec_") { hints |= Hint.stripe }
        case 83:  // S
          if next == 75 /* K */, index + 2 < count, hex(base[index + 2]) { hints |= Hint.twilio }
          if next == 71 /* G */, has(index, "SG.") { hints |= Hint.sendgrid }
        case 45:  // -
          if next == 117 /* u */, index > 0, hex(base[index - 1]), has(index, "-us") { hints |= Hint.mailchimp }
        case 110:  // n
          if next == 112 /* p */, has(index, "npm_") { hints |= Hint.npm }
          if next == 116 /* t */, has(index, "ntn_") { hints |= Hint.notion }
        case 78:  // N
          if next == 82 /* R */, has(index, "NRAK-") { hints |= Hint.newrelic }
        case 112:  // p
          if next == 121 /* y */, has(index, "pypi-") { hints |= Hint.pypi }
          if next == 97 /* a */, has(index, "pat-") { hints |= Hint.hubspot }
          if next == 104 /* h */, has(index, "phx_") || has(index, "phs_") { hints |= Hint.posthog }
        case 100:  // d
          if next == 111 /* o */, has(index + 3, "_v1_") { hints |= Hint.digitalocean }
          if next == 112 /* p */, has(index, "dp.") { hints |= Hint.doppler }
          if next == 97 /* a */, has(index, "dapi") { hints |= Hint.databricks }
          if next == 99 /* c */, has(index, "dckr_pat_") { hints |= Hint.docker }
        case 47:  // /
          if next == 97 /* a */, has(index, "/api/webhooks") || has(index, "/api\\/webhooks") { hints |= Hint.discord }
        case 58:  // :
          if index > 0, (48...57).contains(base[index - 1]), index + 30 < count, alphanumeric(next) || next == 45 || next == 95 { hints |= Hint.telegram }
        case 99:  // c
          if next == 102 /* f */, has(index, "cfk_") || has(index, "cfut_") || has(index, "cfat_") || has(index, "cfast_") { hints |= Hint.cloudflare }
        case 118:  // v
          if next == 99 /* c */, index + 3 < count, base[index + 3] == 95 /* _ */ { hints |= Hint.vercel }
        case 116:  // t
          if next == 115 /* s */, has(index, "tskey-") { hints |= Hint.tailscale }
        default: continue
        }
      }
      return hints
    }
  }

  private static let minimumCardDigits = 13

  /// Every card the candidate expression can match holds this many ASCII digits. Counted
  /// across the whole text, so it admits every such shape and stops at the thirteenth.
  private static func mayHoldCard(_ text: String) -> Bool {
    var digits = 0
    for byte in text.utf8 where (48...57).contains(byte) {
      digits += 1
      if digits >= minimumCardDigits { return true }
    }
    return false
  }
  // In text as written a percent escape is not part of a number: the two digits of "%20" are
  // the space it spells. Counted as card digits, they made "%20" and the number after it one
  // checksum-valid card. A candidate does not begin with the digits of an
  // escape; it may begin right after the escape, as it would after the character
  // (`cardAfterEscape`, its own expression: one expression with both starts read a run of
  // digits six times slower). An encoded URL value is judged decoded and masked whole
  // (`shapeRules`); these two are for what nothing decodes, a URL path and text that is no
  // URL, and they keep a telephone number after "%20" in a value from being marked as a card,
  // which would now mask that whole value.
  private static let cardCandidate = try! NSRegularExpression(pattern:
    #"(?<![\p{L}\p{N}_.-])(?!(?<=%)[0-9A-Fa-f]{2})(?:[0-9][ -]?){12,18}[0-9](?![\p{L}\p{N}_.-])"#)
  private static let cardAfterEscape = try! NSRegularExpression(pattern: #"%[0-9A-Fa-f]{2}((?:[0-9][ -]?){12,18}[0-9])(?![\p{L}\p{N}_.-])"#)

  /// For the self-test: the query and fragment values of every URL in the text, as written.
  static func urlValues(_ text: String) -> [String] {
    let whole = text as NSString
    return urlRanges(text).flatMap { urlRange -> [String] in
      guard let suffix = parameters(of: whole.substring(with: urlRange)) else { return [] }
      return parameter.matches(in: suffix as String, range: NSRange(location: 0, length: suffix.length)).map { suffix.substring(with: $0.range(at: 2)) }
    }
  }
  // Read a scheme run once. Its first word-boundary letter is exactly the old start;
  // the atomic prefix prevents restarting from later letters in the run. The plain greedy
  // tail reads/backtracks once without the possessive loop's engine stack limit.
  // The prefix before capture 1 is only a search aid, never part of the URL range.
  private static let urlCandidate = try! NSRegularExpression(pattern:
    #"(?i)(?<![a-z0-9+.-])(?>(?:[a-z0-9+.-]*?)(\b[a-z]))[a-z0-9+.-]*://[^\s<>\"']+"#)

  private static func urlRanges(_ text: String) -> [NSRange] {
    urlCandidate.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map { match in
      let start = match.range(at: 1).location
      return NSRange(location: start, length: NSMaxRange(match.range) - start)
    }
  }

  /// Exact ranges for the old/new expression differential in the self-test.
  static func regexRanges(_ operation: String, _ text: String) -> [NSRange] {
    if operation == "url" { return urlRanges(text) }
    if operation == "credential" {
      return patterns[8].regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map {
        NSRange(location: $0.range(at: 1).location, length: NSMaxRange($0.range) - $0.range(at: 1).location)
      }
    }
    return patterns[10].regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
  }
  private static let parameter = try! NSRegularExpression(pattern: #"(?:[?&#;]|^)([^=&#;]*=)?([^&#;]*)"#)

  static func passesLuhn(_ digits: String) -> Bool {
    var sum = 0
    var double = false
    for character in digits.reversed() {
      guard var digit = character.wholeNumberValue else { return false }
      if double { digit *= 2; if digit > 9 { digit -= 9 } }
      sum += digit
      double.toggle()
    }
    return sum % 10 == 0
  }

  /// Only URL query/fragment values: high entropy elsewhere commonly describes file/hash IDs.
  /// Asked of one form of a value; it decodes nothing itself.
  static func opaque(_ value: String) -> Bool {
    // By byte: every character of such a value is one, and most values end at the first
    // that is not (a space, a percent sign).
    var bytes = value.utf8[...]
    func closing(_ byte: UInt8?) -> Bool { byte == 41 || byte == 93 || byte == 125 || byte == 44 }
    while closing(bytes.first) { bytes = bytes.dropFirst() }
    while closing(bytes.last) { bytes = bytes.dropLast() }
    guard bytes.count >= 16 else { return false }
    var counts = [Int](repeating: 0, count: 128)
    var letter = false, number = false
    for byte in bytes {
      switch byte {
      case 48...57: number = true
      case 65...90, 97...122: letter = true
      case 95, 45, 43, 47, 61, 46: break
      default: return false
      }
      counts[Int(byte)] += 1
    }
    guard letter, number else { return false }
    let entropy = counts.reduce(0.0) { total, count in
      guard count > 0 else { return total }
      let p = Double(count) / Double(bytes.count)
      return total - p * log2(p)
    }
    return entropy >= 3.3
  }

  /// What the text says with its percent escapes read: every escape written in it once, or
  /// (`fully`) until none is left, so that "%2541" is "A". Whatever is no escape stays as it
  /// is. One pass over the bytes either way: a decoded byte that completes an escape with
  /// what stands before it is read on the spot. Bytes that spell no character are lost when
  /// the string is made, so each form is made from the value as written, never from the other
  /// form: half a letter decoded in one pass is whole only when its other half is too.
  /// The result is only ever read by the rules. It is never written anywhere.
  static func unescaped(_ text: String, fully: Bool) -> String {
    func hex(_ byte: UInt8) -> UInt8? {
      switch byte {
      case 48...57: return byte - 48
      case 65...70: return byte - 55
      case 97...102: return byte - 87
      default: return nil
      }
    }
    var out: [UInt8] = []
    out.reserveCapacity(text.utf8.count)
    // How many bytes at the end stand as written (an escape of one pass is three of them).
    var written = 0
    for byte in text.utf8 {
      out.append(byte)
      written += 1
      while out.count >= 3, fully || written >= 3, out[out.count - 3] == 37, let high = hex(out[out.count - 2]), let low = hex(out[out.count - 1]) {
        out.removeLast(3)
        out.append(high << 4 | low)
        written = 0
      }
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// Whether a rule masks something in what an encoded URL value says: the rules that do, or
  /// nil. Two forms are asked, the value with its escapes read once and the value decoded
  /// until nothing is left to decode, each from the value as written; and, where it differs,
  /// the once-read form decoded to the end.
  private static func decodedSecret(in raw: String, guarded: Bool, glued: Bool) -> [String]? {
    if opaque(raw) { return ["url-secret"] }
    guard holds(raw, "%") else { return nil }
    // A mark beside a percent sign: an earlier reading masked part of the value as written.
    // The rest goes too, and what stays in a URL is a value that still decodes. It is a
    // change like any other and names a rule: a JSON text is written again only when one did.
    if holds(raw, secretMark) || holds(raw, emailMark) { return ["url-secret"] }
    func masked(_ form: String) -> [String]? {
      if opaque(form) { return ["url-secret"] }
      // `mayMatch` admits every text a rule can match: most values end here.
      if !guarded || mayMatch(form) {
        let clean = plainNonURL(form, guarded: guarded)
        if clean.text != form { return clean.rules }
      }
      if glued, !guarded || (holds(form, "token") && hasLabelEnd(form)),
        gluedLabel.firstMatch(in: form, range: NSRange(location: 0, length: (form as NSString).length)) != nil { return ["labeled-secret"] }
      return nil
    }
    let once = unescaped(raw, fully: false)
    guard once != raw else { return nil }
    if let rules = masked(once) { return rules }
    guard holds(once, "%") else { return nil }
    let fully = unescaped(raw, fully: true)
    if fully != once, let rules = masked(fully) { return rules }
    // What a reader that decodes one layer at a time is left with: where half a letter was
    // lost on the way, the text ends differently (a card with no letter after it).
    let stepped = unescaped(once, fully: true)
    return stepped == once || stepped == fully ? nil : masked(stepped)
  }

  /// Hex tokens, UUIDs and comma-separated lists of them are index keys, not content. One 16-digit
  /// hex token in about twenty thousand is all digits and passes the card checksum; masking it
  /// would silently break the key. Digits alone are not exempt (a possible card),
  /// and neither is a comma-separated list of them: a comma is not what makes text a key.
  static func identifierLike(_ text: String) -> Bool {
    var hexLetter = false
    for byte in text.utf8 {
      switch byte {
      case 48...57, 45, 95, 58, 44: continue
      case 97...102, 65...70: hexLetter = true
      default: return false
      }
    }
    return hexLetter
  }

  /// Anchors for the non-label patterns and URL rules. Keep these in step
  /// with their rules. `mayMatch` combines them with `vendorHints` and `labelPrefilter`.
  static let prefilter = try! NSRegularExpression(pattern:
    #"@|:\\?/\\?/|-----BEGIN|gh[pousr]_|github_pat_|(?<![A-Za-z0-9])sk-|(?<![A-Z0-9])A[KS]IA|xox[baprs]-|xoxe-1-|xapp-|xwfp-|eyJ"#
    + #"|(?i:naver|gmail|daum|hanmail|kakao|icloud|outlook|hotmail|nate)\.(?i:com|net)"#)
  // Every labelled value needs :/=; do not search a word list across ordinary prose first.
  // This superset needs no label boundary checks; those belong to the matching rules.
  private static let labelPrefilter = try! NSRegularExpression(pattern:
    "(?i:" + secretNames + "|" + recoveryNames + ")" + labelEnd)

  /// Whether any rule could match (the self-test checks every positive fixture against it).
  static func mayMatch(_ text: String) -> Bool {
    if escapedJSON(text) { return true }
    if vendorHints(text) != 0 { return true }
    if mayHoldCard(text) { return true }
    let range = NSRange(location: 0, length: (text as NSString).length)
    if prefilter.firstMatch(in: text, range: range) != nil { return true }
    return hasLabelEnd(text) && labelPrefilter.firstMatch(in: text, range: range) != nil
  }

  /// Text that will be read as JSON and holds a backslash: its strings are not what the bytes
  /// say ("\u0040" is "@", "\n" is a line break), so the anchors cannot be looked for here.
  /// Each decoded string is asked on its own. Without a backslash every string of the JSON
  /// stands in the text as written, between quotes, and the anchors above see it.
  private static func escapedJSON(_ text: String) -> Bool {
    guard let first = text.utf8.first, first == 123 || first == 91 else { return false }
    return holds(text, "\\")
  }

  /// Individual guards and rules for the bounded, invented-input cost harness.
  static var costOperations: [String] {
    ["apply", "mayMatch", "prefilter", "labelPrefilter", "vendorHints", "escapedJSON", "gluedGuard", "gluedLabel", "gluedTokens",
      "urlCandidate", "parameter", "cardGuard", "cardCandidate", "cardAfterEscape"]
      + patterns.indices.flatMap { ["trigger-\($0)", "pattern-\($0)"] }
      + vendorPatterns.indices.flatMap { ["vendorGuard-\($0)", "vendorPattern-\($0)"] }
  }

  static func costProbe(_ operation: String, _ text: String) -> Int {
    let range = NSRange(location: 0, length: (text as NSString).length)
    switch operation {
    case "apply": forgetCached(); return apply(text).text.utf16.count
    case "mayMatch": return mayMatch(text) ? 1 : 0
    case "prefilter": return prefilter.numberOfMatches(in: text, range: range)
    case "labelPrefilter": return labelPrefilter.numberOfMatches(in: text, range: range)
    case "vendorHints": return Int(truncatingIfNeeded: vendorHints(text))
    case "escapedJSON": return escapedJSON(text) ? 1 : 0
    case "gluedGuard": return holds(text, "token") && hasLabelEnd(text) ? 1 : 0
    case "gluedLabel": return gluedLabel.numberOfMatches(in: text, range: range)
    case "gluedTokens": return gluedTokens(text, guarded: true)?.utf16.count ?? 0
    case "urlCandidate": return urlCandidate.numberOfMatches(in: text, range: range)
    case "parameter": return parameter.numberOfMatches(in: text, range: range)
    case "cardGuard": return mayHoldCard(text) ? 1 : 0
    case "cardCandidate": return cardCandidate.numberOfMatches(in: text, range: range)
    case "cardAfterEscape": return cardAfterEscape.numberOfMatches(in: text, range: range)
    default:
      let parts = operation.split(separator: "-")
      guard parts.count == 2, let index = Int(parts[1]) else { return -1 }
      switch parts[0] {
      case "trigger": return triggers.indices.contains(index) ? (triggers[index](text) ? 1 : 0) : -1
      case "pattern": return patterns.indices.contains(index) ? patterns[index].regex.numberOfMatches(in: text, range: range) : -1
      case "vendorGuard": return vendorPatterns.indices.contains(index) ? (vendorHints(text) & vendorPatterns[index].hint != 0 ? 1 : 0) : -1
      case "vendorPattern": return vendorPatterns.indices.contains(index) ? vendorPatterns[index].regex.numberOfMatches(in: text, range: range) : -1
      default: return -1
      }
    }
  }

  private final class Cached: NSObject {
    let text: String
    let rules: [String]
    init(_ value: (text: String, rules: [String])) { text = value.text; rules = value.rules }
  }
  // Thread-safe, bounded and memory-only. Unchanged titles do not run the rules each second.
  private static let cache: NSCache<NSString, Cached> = {
    let cache = NSCache<NSString, Cached>()
    cache.countLimit = 4096
    cache.totalCostLimit = 4 << 20
    return cache
  }()

  /// JSON state/body strings are sanitized as values, preserving valid escapes and structure.
  /// This prevents percent-encoded/JSON-escaped URLs bypassing the same entry point.
  public static func apply(_ text: String) -> (text: String, rules: [String]) {
    apply(text, includeRandomValues: true)
  }

  /// Structural identities keep their spelling; explicit known secrets still cannot be stored.
  public static func applyKnownSecrets(_ text: String) -> (text: String, rules: [String]) {
    apply(text, includeRandomValues: false)
  }

  private static func apply(_ text: String, includeRandomValues: Bool) -> (text: String, rules: [String]) {
    // Keep the existing bare hex/list identity exemption ahead of both kinds of rules.
    if identifierLike(text) { return (text, []) }
    guard (text as NSString).length >= 6 else { return (text, []) }
    if includeRandomValues, let previous = cache.object(forKey: text as NSString) { return (previous.text, previous.rules) }
    let jsonStart = text.utf8.first == 123 || text.utf8.first == 91
    let result: (text: String, rules: [String]) = jsonStart || mayMatch(text) ? uncached(text, guarded: true, includeRandomValues: includeRandomValues)
      : includeRandomValues ? randomValues(text) : (text, [])
    // The one invariant of the cache: an entry is the result of masking exactly its key.
    // Nothing is stored under any other text. A result was once also stored under itself, on
    // the belief that masked text does not change when masked again; where that was false the
    // entry answered a different input without masking it.
    let cost = (text.utf8.count + result.text.utf8.count) * 2
    if includeRandomValues, cost <= 2 << 20 { cache.setObject(Cached(result), forKey: text as NSString, cost: cost) }
    return result
  }

  /// How often changed text is read again (`plain`). Only the self-test writes it: with one
  /// reading results are not stable, and the cache must answer rightly all the same.
  static var readings = 6

  /// For the self-test: the next `apply` of any text masks it afresh.
  static func forgetCached() { cache.removeAllObjects() }

  /// For the self-test: the text masked with every cheap guard off (the prefilters, the
  /// triggers, the hints, the candidate checks) and no cache. A guard is a superset of its
  /// rule exactly when this never differs from `apply`. `identifierLike` is not a guard: it
  /// exempts id lists on purpose.
  static func withoutGuards(_ text: String) -> String {
    identifierLike(text) ? text : uncached(text, guarded: false).text
  }

  private static func uncached(_ text: String, guarded: Bool, includeRandomValues: Bool = true) -> (text: String, rules: [String]) {
    if ["{", "["].contains(text.unicodeScalars.first.map(String.init) ?? ""),
      let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data),
      json is [String: Any] || json is [Any] {
      var rules = Set<String>()
      func clean(_ value: Any) -> Any {
        if let value = value as? String {
          if !guarded {
            let cleaned = withoutGuards(value)
            if cleaned != value { rules.insert("unguarded") }
            return cleaned
          }
          let result = apply(value, includeRandomValues: includeRandomValues); rules.formUnion(result.rules); return result.text
        }
        // Numbers and keys are machine state (offsets, hashes, times): never rewritten.
        if let values = value as? [Any] { return values.map(clean) }
        if let values = value as? [String: Any] {
          var result: [String: Any] = [:]
          for (key, value) in values { result[key] = clean(value) }
          return result
        }
        return value
      }
      let cleaned = clean(json)
      if !rules.isEmpty, let data = try? JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys, .withoutEscapingSlashes]) {
        return (String(decoding: data, as: UTF8.self), rules.sorted())
      }
      return (text, [])
    }
    return plain(text, guarded: guarded, includeRandomValues: includeRandomValues)
  }

  /// Every rule, then the glued credential-word names over what the rules left. That step
  /// only ever replaces more of the text with the mark, so nothing the rules hid before it
  /// existed can be shown by it. Text that was changed is read once more, until a reading
  /// changes nothing: a mark changes what stands before the next match (the second of two
  /// addresses written together), and the text is masked again whenever it is read back and
  /// stored or sent.
  /// Six readings at most. Nothing depends on the result being stable (the cache does not):
  /// a further reading would only mask more.
  private static func plain(_ text: String, guarded: Bool, includeRandomValues: Bool = true) -> (text: String, rules: [String]) {
    var result = text
    var rules: [String] = []
    for _ in 0..<readings {
      var next = shapeRules(result, guarded: guarded, glued: true)
      if let glued = gluedTokens(next.text, guarded: guarded) {
        next.text = glued
        next.rules.append("labeled-secret")
      }
      for rule in next.rules where !rules.contains(rule) { rules.append(rule) }
      if next.text == result { break }
      result = next.text
    }
    guard includeRandomValues else { return (result, rules) }
    let shaped = randomValues(result)
    for rule in shaped.rules where !rules.contains(rule) { rules.append(rule) }
    return (shaped.text, rules)
  }

  private static func randomValues(_ text: String) -> (text: String, rules: [String]) {
    let whole = text as NSString
    let ranges = RandomValueMask.ranges(text).map { range -> NSRange in
      let end = NSMaxRange(range)
      // Sentence punctuation trimming must not leave half of an earlier mask visible.
      if end < whole.length, whole.character(at: end) == 93 {
        for mark in [secretMark, emailMark] {
          let prefix = String(mark.dropLast()) as NSString
          if range.length >= prefix.length, whole.substring(with: NSRange(location: end - prefix.length, length: prefix.length)) == prefix as String {
            return NSRange(location: range.location, length: range.length + 1)
          }
        }
      }
      return range
    }
    return ranges.isEmpty ? (text, []) : (replacing(ranges.map { ($0, secretMark) }, in: text), ["random-value"])
  }

  /// The query and fragment of a URL, from its first "?" or "#", read by unit as the
  /// expressions read it.
  private static func parameters(of url: String) -> NSString? {
    let ns = url as NSString
    let start = ns.rangeOfCharacter(from: CharacterSet(charactersIn: "?#"), options: .literal)
    return start.location == NSNotFound ? nil : ns.substring(from: start.location) as NSString
  }

  /// The text as written with the glued credential-word names masked, or nil when there is
  /// none. (In an encoded URL value they are looked for with the other rules, `decodedSecret`.)
  private static func gluedTokens(_ text: String, guarded: Bool) -> String? {
    // Every match holds the small-letter word and a separator.
    guard !guarded || (holds(text, "token") && hasLabelEnd(text)) else { return nil }
    let matches = gluedLabel.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    guard !matches.isEmpty else { return nil }
    return replacing(matches.map { ($0.range, secretMark) }, in: text)
  }

  /// The text with each range replaced: ranges in order and apart. One pass, however many.
  private static func replacing(_ edits: [(range: NSRange, with: String)], in text: String) -> String {
    guard !edits.isEmpty else { return text }
    let whole = text as NSString
    let out = NSMutableString(capacity: whole.length)
    var at = 0
    for edit in edits {
      out.append(whole.substring(with: NSRange(location: at, length: edit.range.location - at)))
      out.append(edit.with)
      at = NSMaxRange(edit.range)
    }
    out.append(whole.substring(from: at))
    return out as String
  }

  /// The rules without the glued credential-word pass: what was masked before that pass
  /// existed. The self-test holds `plain` against it.
  static func withoutGluedTokens(_ text: String, guarded: Bool = true) -> (text: String, rules: [String]) {
    shapeRules(text, guarded: guarded, glued: false)
  }

  /// The URL parameter values of the text whose decoded form holds something a rule masks
  /// (`decodedSecret`), in order, and the rules that found them.
  private static func secretValues(_ text: String, guarded: Bool, glued: Bool) -> (ranges: [NSRange], rules: [String]) {
    var ranges: [NSRange] = []
    var found: [String] = []
    // Every URL holds "://".
    guard !guarded || holds(text, "://") else { return (ranges, found) }
    let whole = text as NSString
    for urlRange in urlRanges(text) {
      guard let suffix = parameters(of: whole.substring(with: urlRange)) else { continue }
      let offset = NSMaxRange(urlRange) - suffix.length
      for match in parameter.matches(in: suffix as String, range: NSRange(location: 0, length: suffix.length)) {
        let range = match.range(at: 2)
        guard range.length > 0, let rules = decodedSecret(in: suffix.substring(with: range), guarded: guarded, glued: glued) else { continue }
        ranges.append(NSRange(location: offset + range.location, length: range.length))
        for rule in rules where !found.contains(rule) { found.append(rule) }
      }
    }
    return (ranges, found)
  }

  /// Every rule over the text as written, and the URL parameter values.
  /// If what an encoded value says when decoded holds anything a rule masks, the whole value
  /// as written becomes the mark. Decoded text is never written into the result: written
  /// back, it put spaces and separators into the URL, and what was read next was another URL
  /// than the one that stood there. A value with nothing to mask stays as
  /// written.
  /// The values are read in the text as it stood and again in the text as the rules left
  /// it, and the result is masked wherever any of the three masks. One order alone took
  /// something from the other: a value replaced first cut a card that ran across the end of
  /// its URL in two and left the half outside; a key masked first took the scheme with it,
  /// and what followed was no longer a URL whose values are read.
  private static func shapeRules(_ text: String, guarded: Bool, glued: Bool) -> (text: String, rules: [String]) {
    let before = secretValues(text, guarded: guarded, glued: glued)
    var kept: Kept? = before.ranges.isEmpty ? nil : Kept(length: (text as NSString).length)
    var (result, rules) = plainNonURL(text, guarded: guarded, kept: &kept)
    var values = kept?.now(before.ranges) ?? []
    var found = before.rules
    if result != text {
      let after = secretValues(result, guarded: guarded, glued: glued)
      // Both lists are in order; what touches becomes one range.
      var merged: [NSRange] = []
      var first = 0, second = 0
      while first < values.count || second < after.ranges.count {
        let next: NSRange
        if second == after.ranges.count || (first < values.count && values[first].location <= after.ranges[second].location) { next = values[first]; first += 1 }
        else { next = after.ranges[second]; second += 1 }
        if let last = merged.last, NSMaxRange(last) >= next.location { merged[merged.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), NSMaxRange(next)) - last.location) }
        else { merged.append(next) }
      }
      values = merged
      found += after.rules
    }
    result = replacing(values.map { ($0, secretMark) }, in: result)
    for rule in found where !rules.contains(rule) { rules.append(rule) }
    return (result, rules)
  }

  /// Which stretches of a text still stand after marks replaced the rest: where each is now
  /// and where it was. With it a place in the text as it was is found in the text as it is.
  private struct Kept {
    private var runs: [(now: Int, then: Int, length: Int)]
    private var length: Int
    init(length: Int) { runs = [(0, 0, length)]; self.length = length }

    /// `edits`: ranges of the text as it is now, in order and apart, each with the length of
    /// what replaces it. One pass over the runs.
    mutating func replace(_ edits: [(range: NSRange, length: Int)]) {
      guard !edits.isEmpty else { return }
      var next: [(now: Int, then: Int, length: Int)] = []
      var index = 0, shift = 0
      func passed(_ at: Int) {
        while index < edits.count, NSMaxRange(edits[index].range) <= at { shift += edits[index].length - edits[index].range.length; index += 1 }
      }
      for run in runs {
        var at = run.now
        let end = run.now + run.length
        while at < end {
          passed(at)
          if index < edits.count, edits[index].range.location <= at { at = min(end, NSMaxRange(edits[index].range)); continue }
          let stop = index < edits.count ? min(end, edits[index].range.location) : end
          next.append((at + shift, run.then + at - run.now, stop - at))
          at = stop
        }
      }
      passed(Int.max)
      runs = next
      length += shift
    }

    /// Where the ranges of the text as it was are now, in order, with every mark that
    /// replaced part of one; those that touch are one. `ranges` in order and apart.
    func now(_ ranges: [NSRange]) -> [NSRange] {
      var found: [NSRange] = []
      var index = 0
      for range in ranges {
        let end = NSMaxRange(range)
        // The first run that reaches past the start of the range.
        while index < runs.count, runs[index].then + runs[index].length <= range.location { index += 1 }
        let start: Int
        if index < runs.count, runs[index].then <= range.location { start = runs[index].now + range.location - runs[index].then }
        else { start = index > 0 ? runs[index - 1].now + runs[index - 1].length : 0 }
        // The last run that begins before the end of the range.
        var last = index
        while last < runs.count, runs[last].then < end { last += 1 }
        let stop: Int
        if last > 0, runs[last - 1].then + runs[last - 1].length >= end, runs[last - 1].then < end { stop = runs[last - 1].now + end - runs[last - 1].then }
        else { stop = last < runs.count ? runs[last].now : length }
        if let previous = found.last, NSMaxRange(previous) >= start { found[found.count - 1] = NSRange(location: previous.location, length: max(NSMaxRange(previous), stop) - previous.location) }
        else { found.append(NSRange(location: start, length: stop - start)) }
      }
      return found
    }
  }

  private static func plainNonURL(_ text: String, guarded: Bool) -> (text: String, rules: [String]) {
    var kept: Kept? = nil
    return plainNonURL(text, guarded: guarded, kept: &kept)
  }

  /// Every rule over the text as written. `kept`, where given, follows what the marks left.
  private static func plainNonURL(_ text: String, guarded: Bool, kept: inout Kept?) -> (text: String, rules: [String]) {
    var result = text
    var rules: [String] = []
    // The matches of one expression, in order and apart, each with what replaces it.
    func replace(_ edits: [(range: NSRange, with: String)]) {
      guard !edits.isEmpty else { return }
      result = replacing(edits, in: result)
      kept?.replace(edits.map { ($0.range, ($0.with as NSString).length) })
    }
    let hints = guarded ? vendorHints(result) : ~0
    if hints != 0 {
      for (rule, hint, regex) in vendorPatterns where hints & hint != 0 {
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: (result as NSString).length))
        replace(matches.map { ($0.numberOfRanges > 1 ? $0.range(at: 1) : $0.range, secretMark) })
        if !matches.isEmpty, !rules.contains(rule) { rules.append(rule) }
      }
    }
    for (index, (rule, regex)) in patterns.enumerated() {
      // A literal every match of the rule must contain: skips the regular expression for the
      // paths, titles and ids that reach this far only because of a date or a hyphenated number.
      guard !guarded || triggers[index](result) else { continue }
      let ns = result as NSString
      let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
      replace(matches.compactMap { match in
        let credential = rule == "wallet-recovery" ? match.range(at: 1) : rule == "url-credential"
          ? NSRange(location: match.range(at: 1).location, length: NSMaxRange(match.range) - match.range(at: 1).location) : match.range
        guard rule == "url-credential" else { return (credential, rule == "email" ? emailMark : secretMark) }
        let value = ns.substring(with: credential) as NSString
        let schemeEnd = value.range(of: "://", options: .literal)
        guard schemeEnd.location != NSNotFound else { return nil }
        return (credential, value.substring(to: NSMaxRange(schemeEnd)) + secretMark + "@")
      })
      if !matches.isEmpty { rules.append(rule) }
    }
    var cards = false
    // After an escape first (the captured digits), then everywhere else. A run of digits is
    // read once, from its start: what the first expression read and left is not read again
    // from inside it.
    var read: [NSRange] = []
    for (regex, group) in [(cardAfterEscape, 1), (cardCandidate, 0)] where !guarded || (mayHoldCard(result) && (group == 0 || holds(result, "%"))) {
      let ns = result as NSString
      let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
      var from = 0
      var edits: [(range: NSRange, with: String)] = []
      for match in matches {
        // Both lists are in order: step up to the first range that ends after this match begins.
        while from < read.count, NSMaxRange(read[from]) <= match.range.location { from += 1 }
        if from < read.count, read[from].location < NSMaxRange(match.range) { continue }
        let range = match.range(at: group)
        let digits = ns.substring(with: range).filter(\.isNumber)
        guard (13...19).contains(digits.count), passesLuhn(digits) else { continue }
        edits.append((range, secretMark))
      }
      replace(edits)
      if !edits.isEmpty { cards = true }
      // Where they stand now: a mark is shorter than the digits it replaced.
      if group == 1, !matches.isEmpty { read = regex.matches(in: result, range: NSRange(location: 0, length: (result as NSString).length)).map(\.range) }
    }
    if cards { rules.append("payment-card") }
    return (result, rules)
  }
}

public func redactSecrets(_ text: String) -> String { Redaction.apply(text).text }

/// The value closure must never run for a secure role/subrole, even in a diagnostic caller.
public enum RecordingText {
  public static func focused(role: String, subrole: String?, readValue: () -> String?) -> (role: String, value: String)? {
    guard role != "AXSecureTextField", subrole != "AXSecureTextField",
      let value = readValue(), value.utf8.count <= 200_000 else { return nil }
    return (role, redactSecrets(value))
  }
}

// Keep this tokenizer in step with tools/measure_mask_shape.py. Structure is retained;
// percent-decoded query children replace their entire written value.
enum RandomValueMask {
  static func accepts(_ value: String) -> Bool {
    let chars = Array(value.unicodeScalars)
    return qualifies(chars, 0..<chars.count)
  }

  private static func entropy(_ chars: [Unicode.Scalar], _ range: Range<Int>) -> Double {
    var counts: [UInt32: Int] = [:]
    for i in range { counts[chars[i].value, default: 0] += 1 }
    let n = Double(range.count)
    return counts.values.reduce(0) { sum, count in
      let p = Double(count) / n
      return sum - p * log2(p)
    }
  }

  private static func qualifies(_ chars: [Unicode.Scalar], _ range: Range<Int>) -> Bool {
    guard range.count >= 16 else { return false }
    var counts = [Int](repeating: 0, count: 95)
    var classes = 0
    for i in range {
      let c = chars[i].value
      guard (33...126).contains(c) else { return false }
      counts[Int(c - 32)] += 1
      switch c {
      case 97...122: classes |= 1
      case 65...90: classes |= 2
      case 48...57: classes |= 4
      default: classes |= 8
      }
    }
    guard classes.nonzeroBitCount >= 2, classes & 12 != 0 else { return false }
    let n = Double(range.count)
    let h = counts.reduce(0.0) { sum, count in
      guard count > 0 else { return sum }
      let p = Double(count) / n
      return sum - p * log2(p)
    }
    return h >= 4
  }

  static func ranges(_ text: String, componentsOnly: Bool = false) -> [NSRange] {
    guard text.utf8.count >= 16 else { return [] }
    let chars = Array(text.unicodeScalars)
    var spans: [Range<Int>] = []
    func string(_ range: Range<Int>) -> String { String(String.UnicodeScalarView(chars[range])) }
    func isWord(_ c: Unicode.Scalar) -> Bool {
      if c == "_" { return true }
      switch c.properties.generalCategory {
      case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
           .decimalNumber, .letterNumber, .otherNumber: return true
      default: return false
      }
    }
    func label(_ range: Range<Int>) -> Bool {
      guard let first = range.first, isWord(chars[first]), chars[first].properties.generalCategory != .decimalNumber else { return false }
      return range.allSatisfy { isWord(chars[$0]) || chars[$0] == "-" } && entropy(chars, range) < 3.5
    }
    func readableDirectory(_ range: Range<Int>) -> Bool {
      range.count >= 2 && range.allSatisfy {
        let c = chars[$0].value
        return (65...90).contains(c) || (97...122).contains(c) || c == 95 || c == 45
      }
    }
    func base64(_ range: Range<Int>) -> Bool {
      guard range.count >= 20 else { return false }
      var end = range.upperBound, padding = 0
      while end > range.lowerBound, chars[end - 1] == "=" { end -= 1; padding += 1 }
      guard padding <= 2, end > range.lowerBound else { return false }
      guard range.contains(where: { (48...57).contains(chars[$0].value) || chars[$0] == "+" }) else { return false }
      return (range.lowerBound..<end).allSatisfy {
        let c = chars[$0].value
        return (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c) || [43,47,95,45].contains(c)
      } && entropy(chars, range) >= 3.5
    }
    func bareHostEnd(_ range: Range<Int>) -> Int? {
      var dot = false, labelStart = range.lowerBound, lastLetters = true
      for i in range {
        let c = chars[i].value
        if c == 47 { return dot && i > labelStart && lastLetters ? i : nil }
        if c == 46 {
          guard i > labelStart else { return nil }
          dot = true; labelStart = i + 1; lastLetters = true
        } else {
          let letter = (65...90).contains(c) || (97...122).contains(c)
          guard letter || (48...57).contains(c) || c == 45 else { return nil }
          lastLetters = lastLetters && letter
        }
      }
      return nil
    }
    func select(_ range: Range<Int>) {
      if qualifies(chars, range) { spans.append(range) }
    }
    let punctuation: Set<Unicode.Scalar> = Set("\"'[]{}(),;`".unicodeScalars)
    let pathSeparators: Set<Unicode.Scalar> = Set("/.:=@?&#".unicodeScalars)
    func piece(_ initial: Range<Int>, web: Bool, simple: Bool) {
      if simple, !web { select(initial); return }
      var start = initial.lowerBound, end = initial.upperBound
      while end > start, chars[end - 1] == "." { end -= 1 }
      guard end > start else { return }
      // Consume successive named separators without rescanning their remaining suffix.
      while start < end {
        var separator = start
        while separator < end, chars[separator] != ":", chars[separator] != "=" { separator += 1 }
        guard separator < end - 1, label(start..<separator) else { break }
        select(start..<separator)
        start = separator + 1
      }
      guard start < end else { return }
      if !web, !componentsOnly, let tail = bareHostEnd(start..<end) {
        webTail(tail..<end); return
      }
      let explicit = chars[start] == "/" || (end - start >= 2 && chars[start] == "~" && chars[start+1] == "/")
        || (end - start >= 2 && chars[start] == "." && chars[start+1] == "/")
        || (end - start >= 3 && chars[start] == "." && chars[start+1] == "." && chars[start+2] == "/")
      var path = explicit || web
      if !path, !base64(start..<end) {
        var directory = start
        for i in start..<end where chars[i] == "/" {
          if readableDirectory(directory..<i) { path = true; break }
          directory = i + 1
        }
      }
      if path {
        var at = start
        for i in start..<end where pathSeparators.contains(chars[i]) {
          select(at..<i); at = i + 1
        }
        select(at..<end)
      } else { select(start..<end) }
    }
    func pieces(_ range: Range<Int>, web: Bool = false) {
      var start = range.lowerBound
      var structured = false
      for i in range {
        switch chars[i].value {
        case 34, 39, 91, 93, 123, 125, 40, 41, 44, 59, 96:
          if punctuation.contains(chars[i]) {
            piece(start..<i, web: web, simple: !structured); start = i + 1; structured = false
          }
        case 46, 58, 61, 47: structured = true
        default: break
        }
      }
      piece(start..<range.upperBound, web: web, simple: !structured)
    }
    func queryValue(_ range: Range<Int>) {
      // Python unquote leaves invalid escapes alone and replaces invalid UTF-8.
      let raw = Array(string(range).utf8)
      var decoded: [UInt8] = []; decoded.reserveCapacity(raw.count)
      func hex(_ b: UInt8) -> UInt8? {
        switch b { case 48...57: return b - 48; case 65...70: return b - 55; case 97...102: return b - 87; default: return nil }
      }
      var i = 0
      while i < raw.count {
        if raw[i] == 37, i + 2 < raw.count, let a = hex(raw[i+1]), let b = hex(raw[i+2]) {
          decoded.append(a * 16 + b); i += 3
        } else { decoded.append(raw[i]); i += 1 }
      }
      let value = String(decoding: decoded, as: UTF8.self)
      if !ranges(value, componentsOnly: true).isEmpty { spans.append(range) }
    }
    func webTail(_ range: Range<Int>) {
      let tail = range.lowerBound
      var query = tail
      while query < range.upperBound, chars[query] != "?", chars[query] != "#" { query += 1 }
      pieces(tail..<query, web: true)
      guard query < range.upperBound else { return }
      var at = query + 1
      let trim: Set<Unicode.Scalar> = Set("\"'[]{}(),.".unicodeScalars)
      while at < range.upperBound {
        var end = at
        while end < range.upperBound, !"&#;".unicodeScalars.contains(chars[end]) { end += 1 }
        var valueEnd = end
        while valueEnd > at, trim.contains(chars[valueEnd - 1]) { valueEnd -= 1 }
        var valueStart = at
        if let sep = (at..<valueEnd).first(where: { chars[$0] == "=" }) { valueStart = sep + 1 }
        queryValue(valueStart..<valueEnd)
        at = end + 1
      }
    }
    func run(_ range: Range<Int>) {
      guard range.count >= 16 else { return }
      var url: (start: Int, end: Int)?
      var structured = false
      var i = range.lowerBound
      while i < range.upperBound {
        let c = chars[i].value
        switch c {
        case 34, 39, 91, 93, 123, 125, 40, 41, 44, 59, 96, 46, 58, 61, 47: structured = true
        default: break
        }
        if c | 32 == 104, i + 7 <= range.upperBound, chars[i+1].value | 32 == 116, chars[i+2].value | 32 == 116,
          chars[i+3].value | 32 == 112 {
          var colon = i + 4
          // Python's case-insensitive scheme expression also folds Latin long s.
          if chars[colon].value | 32 == 115 || chars[colon].value == 0x017f { colon += 1 }
          if colon + 2 < range.upperBound, chars[colon] == ":", chars[colon+1] == "/", chars[colon+2] == "/" {
            url = (i, colon + 3); break
          }
        }
        i += 1
      }
      if url == nil, !structured { select(range); return }
      guard let url else { pieces(range); return }
      pieces(range.lowerBound..<url.start)
      var tail = url.end
      while tail < range.upperBound, !"/?#".unicodeScalars.contains(chars[tail]) { tail += 1 }
      guard tail < range.upperBound else { return }
      webTail(tail..<range.upperBound)
    }
    if componentsOnly { pieces(0..<chars.count) }
    else {
      var start = 0
      for i in chars.indices {
        let c = chars[i].value
        let space = c <= 127 ? c == 32 || (9...13).contains(c) || (28...31).contains(c)
          : chars[i].properties.isWhitespace
        if space { run(start..<i); start = i + 1 }
      }
      run(start..<chars.count)
    }
    var merged: [Range<Int>] = []
    for span in spans {
      if let last = merged.last, last.upperBound >= span.lowerBound {
        merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
      } else { merged.append(span) }
    }
    guard !merged.isEmpty else { return [] }
    var offsets = [Int](); offsets.reserveCapacity(chars.count + 1)
    offsets.append(0)
    for c in chars { offsets.append(offsets.last! + (c.value > 0xffff ? 2 : 1)) }
    return merged.map { NSRange(location: offsets[$0.lowerBound], length: offsets[$0.upperBound] - offsets[$0.lowerBound]) }
  }
}
