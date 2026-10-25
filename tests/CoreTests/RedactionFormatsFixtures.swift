import Foundation

/// Invented values shared by the pure masking tests and the standalone harness. No key here is real: every body is generated from a counter.
enum RedactionFormatsTest {
  static let hex = "0123456789abcdef"
  static let alnum = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz0123456789"

  /// A deterministic invented body: looks random, comes from a fixed sequence.
  static func body(_ count: Int, _ alphabet: String = alnum, seed: UInt64 = 7) -> String {
    let letters = Array(alphabet)
    var state = seed &* 6364136223846793005 &+ 1442695040888963407
    return String((0..<count).map { _ in
      state = state &* 6364136223846793005 &+ 1442695040888963407
      return letters[Int((state >> 33) % UInt64(letters.count))]
    })
  }

  /// (rule, the secret part that must disappear, the whole key as it would be written).
  static let keys: [(rule: String, secret: String, written: String)] = {
    func whole(_ rule: String, _ key: String) -> (String, String, String) { (rule, key, key) }
    let uuid = [8, 4, 4, 4, 12].map { body($0, hex, seed: UInt64($0)) }.joined(separator: "-")
    return [
      whole("api-key", "sk-ant-api03-" + body(40) + "-" + body(40, seed: 2) + "AA"),
      whole("api-key", "sk-ant-admin01-" + body(60)),
      whole("api-key", "sk-proj-" + body(48)), whole("api-key", "sk-svcacct-" + body(48)),
      whole("api-key", "sk-admin-" + body(48)), whole("api-key", "sk-" + body(48)),
      whole("github-token", "ghp_" + body(36)), whole("github-token", "gho_" + body(36)),
      whole("github-token", "ghu_" + body(36)), whole("github-token", "ghs_" + body(36)),
      whole("github-token", "ghr_" + body(36)),
      whole("github-token", "github_pat_" + body(22) + "_" + body(59)),
      whole("aws-key", "AKIA" + body(16, "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")),
      whole("aws-key", "ASIA" + body(16, "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")),
      ("aws-key", body(40, alnum + "/+"), "aws_secret_access_key = " + body(40, alnum + "/+")),
      ("aws-key", body(40, alnum + "/+", seed: 3), "\"SecretAccessKey\": \"" + body(40, alnum + "/+", seed: 3) + "\""),
      whole("slack-token", "xoxb-" + body(12, "0123456789") + "-" + body(24)),
      whole("slack-token", "xoxp-" + body(12, "0123456789") + "-" + body(24)),
      whole("slack-token", "xapp-1-A" + body(10) + "-" + body(40)),
      whole("slack-token", "xwfp-" + body(40)), whole("slack-token", "xoxe.xapp-1-" + body(40)),
      whole("slack-token", "xoxe-1-" + body(48)),
      whole("slack-token", "xoxe.xoxb-1-" + body(12, "0123456789") + "-" + body(48)),
      whole("slack-token", "xoxe.xoxp-1-" + body(12, "0123456789") + "-" + body(48)),
      ("slack-webhook", "T" + body(9) + "/B" + body(9) + "/" + body(24), "https://hooks.slack.com/services/T" + body(9) + "/B" + body(9) + "/" + body(24)),
      whole("google-key", "AIza" + body(35, alnum + "_-")), whole("google-key", "ya29." + body(60, alnum + "_-")),
      ("azure-key", body(86, alnum + "+/") + "==", "DefaultEndpointsProtocol=https;AccountName=inventedaccount;AccountKey=" + body(86, alnum + "+/") + "==;EndpointSuffix=core.windows.net"),
      ("azure-key", body(43) + "=", "Endpoint=sb://invented.servicebus.windows.net/;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=" + body(43) + "="),
      whole("gitlab-token", "glpat-" + body(20)), whole("gitlab-token", "gldt-" + body(20)),
      whole("gitlab-token", "glrt-" + body(20)), whole("gitlab-token", "glrtr-" + body(20)),
      whole("gitlab-token", "glcbt-64_" + body(20)), whole("gitlab-token", "glptt-" + body(40, hex)),
      whole("gitlab-token", "glft-" + body(20)), whole("gitlab-token", "glimt-" + body(25)),
      whole("gitlab-token", "glagent-" + body(50)), whole("gitlab-token", "gloas-" + body(64, hex)),
      whole("gitlab-token", "glsoat-" + body(20)), whole("gitlab-token", "glffct-" + body(20)),
      whole("gitlab-token", "glwt-" + body(20)),
      whole("stripe-key", "sk_live_" + body(24)), whole("stripe-key", "sk_test_" + body(99)),
      whole("stripe-key", "rk_live_" + body(24)), whole("stripe-key", "rk_test_" + body(24)),
      whole("stripe-key", "sk_org_live_" + body(24)), whole("stripe-key", "whsec_" + body(32)),
      whole("twilio-key", "SK" + body(32, hex)),
      whole("sendgrid-key", "SG." + body(22, alnum + "_-") + "." + body(43, alnum + "_-")),
      whole("mailchimp-key", body(32, hex) + "-us6"), whole("mailchimp-key", body(32, hex, seed: 4) + "-us21"),
      whole("npm-token", "npm_" + body(36)),
      whole("pypi-token", "pypi-" + body(150, alnum + "_-")),
      whole("digitalocean-token", "dop_v1_" + body(64, hex)), whole("digitalocean-token", "doo_v1_" + body(64, hex)),
      whole("digitalocean-token", "dor_v1_" + body(64, hex)),
      ("discord-webhook", body(68, alnum + "_-"), "https://discord.com/api/webhooks/123456789012345678/" + body(68, alnum + "_-")),
      whole("telegram-token", "123456789:AA" + body(33, alnum + "_-")), whole("telegram-token", "123456:" + body(34, alnum + "_-", seed: 5)),
      whole("supabase-key", "sb_secret_" + body(22) + "_" + body(8)), whole("supabase-key", "sbp_" + body(40, hex)),
      whole("huggingface-token", "hf_" + body(34)),
      whole("cloudflare-token", "cfk_" + body(48)), whole("cloudflare-token", "cfut_" + body(48)),
      whole("cloudflare-token", "cfat_" + body(48)), whole("cloudflare-token", "cfast_" + body(48)),
      whole("vercel-token", "vcp_" + body(40)), whole("vercel-token", "vci_" + body(40)),
      whole("vercel-token", "vca_" + body(40)), whole("vercel-token", "vcr_" + body(40)),
      whole("vercel-token", "vck_" + body(40)),
      whole("hubspot-token", "pat-na1-" + uuid), whole("hubspot-token", "pat-eu1-" + uuid),
      whole("posthog-key", "phx_" + body(43)), whole("posthog-key", "phs_" + body(43)),
      whole("elevenlabs-key", "sk_" + body(48, hex)),
      whole("shopify-token", "shpat_" + body(32, hex)), whole("shopify-token", "shppa_" + body(32, hex)),
      whole("sentry-token", "sntryu_" + body(64, hex)), whole("sentry-token", "sntrys_" + body(120) + "_" + body(43)),
      whole("doppler-token", "dp.pt." + body(43)), whole("doppler-token", "dp.ct." + body(40)),
      whole("doppler-token", "dp.st.dev." + body(43)),
      whole("vault-token", "hvs." + body(90, alnum + "_-")), whole("vault-token", "hvb." + body(120, alnum + "_-")),
      whole("vault-token", "hvr." + body(24)),
      whole("grafana-token", "glsa_" + body(32) + "_" + body(8, hex)), whole("grafana-token", "glc_" + body(80) + "="),
      whole("databricks-token", "dapi" + body(32, hex)),
      whole("docker-token", "dckr_pat_" + body(27, alnum + "_-")),
      whole("newrelic-key", "NRAK-" + body(27, "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")),
      whole("tailscale-key", "tskey-auth-" + body(12) + "-" + body(32)), whole("tailscale-key", "tskey-api-" + body(12) + "-" + body(32)),
      whole("notion-token", "ntn_" + body(46)),
      ("authorization-header", body(30), "Authorization: Bearer " + body(30)),
      ("authorization-header", body(40, alnum + "+/") + "==", "authorization: Basic " + body(40, alnum + "+/") + "=="),
      ("authorization-header", body(24) + "." + body(6) + "." + body(27, alnum + "_-"), "Authorization: Bot " + body(24) + "." + body(6) + "." + body(27, alnum + "_-")),
      ("authorization-header", body(36, seed: 6), "Authorization: token " + body(36, seed: 6)),
      // The same two addresses as they stand inside a JSON payload: every slash escaped.
      ("slack-webhook", "T" + body(9) + #"\/B"# + body(9) + #"\/"# + body(24), #"https:\/\/hooks.slack.com\/services\/T"# + body(9) + #"\/B"# + body(9) + #"\/"# + body(24)),
      ("discord-webhook", body(68, alnum + "_-", seed: 9), #"discord.com\/api\/webhooks\/123456789012345678\/"# + body(68, alnum + "_-", seed: 9)),
    ]
  }()

  /// What a developer's day is full of. None of it may change.
  static let harmless: [String] = {
    let commit = body(40, hex), short = body(7, hex), sha256 = body(64, hex), md5 = body(32, hex)
    let uuid = [8, 4, 4, 4, 12].map { body($0, hex, seed: UInt64($0) + 9) }.joined(separator: "-")
    let base64 = body(88, alnum + "+/") + "=="
    return [
      "commit " + commit, "git checkout " + short, "Merge " + commit + " into " + body(40, hex, seed: 8),
      "sha256:" + sha256, "sha256 " + sha256 + "  archive.tar.gz", "md5 " + md5, "etag \"" + md5 + "\"",
      uuid, "session " + uuid, "1791449173:" + uuid, "request 1791449173:" + uuid + " done",
      "task_" + md5, "task_" + body(12, hex) + " finished", "risk_" + body(40), "shelf_" + body(40),
      "desk_" + md5, "MSG." + body(22) + "." + body(43), "ASK" + md5, "TASK" + md5, "disk_usage_report_" + body(40),
      "npm_config_registry", "npm_package_name_and_version_string_for_builds", "npm_lifecycle_event=test",
      "pypi-publish-action", "pypi-server-with-a-rather-long-hyphenated-name", "pip install pypi-simple",
      "hf_hub_download", "hf_transfer_enabled_for_all_downloads_in_ci", "cf_clearance", "cfg_path_to_configuration_file",
      "vcr_cassette_library_dir", "vcpkg_installed_x64_osx_release_directory", "phx_click", "phx_value_id",
      "gl_FragColor", "glob-parent", "global-agent-bootstrap-configuration", "glib-2.0-development-headers-installed",
      "glft-short", "glpat-", "sk_test_helper", "sk_live_mode", "pk_live_" + body(24), "pk_test_" + body(24),
      "sb_publishable_" + body(22) + "_" + body(8), "phc_" + body(43),
      "dp.st", "hvs.txt", "dapi_client", "dapi-v2", "tskey", "ntn_page", "shpat", "sntry", "whsec_", "xapp-1", "xwfp",
      "AIzaShort", "AKIA", "ASIA region", "SG.short.short", "SKU0123456789", "SK-II",
      md5 + "-user", md5 + "-us-east-1", "bucket-us6", "release-us21.tar.gz",
      "12:34:56", "2026-10-11T12:34:56+09:00", "port 54321:8080", "line 123456:" + short, "123456:ok",
      "Authorization: Bearer $TOKEN", "Authorization: Bearer <token>", "-H \"Authorization: Bearer ${API_TOKEN}\"",
      "Authorization required", "authorization: none", "the Bearer of bad news", "Basic usage of the tool",
      "AccountKey=", "SharedAccessKeyName=RootManageSharedAccessKey", "AccountName=inventedaccount",
      "secret_access_key rotation is due", "SecretAccessKey field", "https://hooks.slack.com/", "https://hooks.slack.com/services/",
      "https://discord.com/api/webhooks/", "https://discord.com/api/webhooks/123456789012345678",
      "https://example.org/a/" + commit + "/b.swift", "https://example.org/blob/" + short + "/README.md#L10-L20",
      "/Users/someone/work/app/Sources/App/NetworkSessionConfigurationProvider.swift",
      "tests/CoreTests/RedactionFormatsTest.swift:42", "node_modules/.pnpm/pkg@1.2.3/node_modules/pkg/index.js".replacingOccurrences(of: "@", with: "-"),
      "data:image/png;base64," + base64, base64, "integrity sha512-" + body(86, alnum + "+/") + "==",
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI" + body(43, alnum + "+/"), "eyJ" + body(20), "v1.2.3-rc.4+build.5678",
      "com.example.app.SomeLongBundleIdentifier", "dev.local.ActivityProbe", "agent_session_id:" + uuid,
      "term_" + uuid, "ctx_" + body(12, hex), "run_" + body(12, hex), "call_" + body(24), "toolu_01" + body(22), "msg_01" + body(22),
      "chatcmpl-" + body(29), "req_" + body(24), "cus_" + body(14), "pi_" + body(24), "evt_" + body(24), "price_" + body(24),
      "arn:aws:iam::123456789012:role/invented-role", "AIDA" + body(17, "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"), "AROA" + body(17, "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"),
      "T" + body(9) + "/B" + body(9), "skeleton_loader_component_with_a_long_name", "The quick brown fox jumps over the lazy dog.",
      "func tokenize(_ text: String) -> [Token]", "let authorization = request.headers", "glsa_", "glc_x",
      // These name data or discuss secrets without assigning one. In particular token_count
      // does not end in the credential label, and keyboard is not api key or secret key.
      "primary_key = id", "cache_key: user", "token_count = 12", "keyboard = us", "the secret is patience",
      "monkey = banana", "mytoken = count", "secretkey = index", "passphrase_length = 12", "passcode_count: 3",
      "secret_key rotation is due", "the passphrase is long", "enter a passcode to continue", "api keyboard = us",
      "xoxe-1-", "xoxe-1-example", "xoxe-2-short", "xoxe.xoxb-1-short", "xoxe.xoxp-1-short",
      "seed phrase", "recovery phrase: choose words with care", "mnemonic phrase length = 12",
      "the seed phrase is written on paper", "recovery_phrase_count = 12", "myrecovery_phrase = count",
      "Please read this ordinary sentence and leave all these words alone.",
      // A short prefix inside a longer name is a name: branches, packages, pods, capitals.
      "open sandboxapp-config-loader.yaml", "kubectl get pod linuxapp-release-candidate-7d", "boxwfp-configuration-loader-module",
      "git checkout someone/task-management-application", "pip install flask-sqlalchemy-migrations-helper",
      "risk-assessment-framework-v2 notes", "ASIAPACIFICREGIONHQ2026 report", "EURASIAPACIFICREGIONS2026X", "AKIAXABCDEFGHIJKLMNOPQRSTUVW",
      // digits:name is search output or a cache key, and a hash-named file is a file.
      "10234:export_default_configuration_settings = {", "user:1697040000:session_cache_key_for_the_dashboard_x",
      "1697040000:SESSION_CACHE_KEY_FOR_THE_DASHBOARD_2", md5 + "-us2.log", md5 + "-us6-backup", md5 + "-us21_copy",
      "Authorization: token $GITHUB_TOKEN", "Authorization: token <token>", "authtoken_count = 3", "authtokens = many",
      // Glued small-letter "token" after letters that are no credential word, or after a
      // credential word that does not begin the name.
      "nexttoken = lexer.advance()", "pagetoken=12", "lasttoken: Token", "synctoken=41", "subtoken: piece", "eoftoken = nil",
      "myauthtoken = count", "okapitoken: 3", "reauthtoken = flag", "idtoken: ident", "usertoken = words[0]", "pushtoken = true",
      "devicetoken: registered", "resettoken = false", "clienttoken=retry-3", "nextauthtoken_count = 2", "authnexttoken = peek()",
    ] + unicodeHarmless
  }()

  static func fullWidth(_ text: String) -> String {
    String(text.unicodeScalars.map { scalar in
      (48...57).contains(scalar.value) ? String(UnicodeScalar(scalar.value - 48 + 0xFF10)!) : String(scalar)
    }.joined())
  }

  static let unicodeHarmless: [String] = {
    let plain = [
      "2019–2024", "10–12", "pp. 100–120", "pages 1000–1200", "years 1999–2001", "chapters 10–12",
      "2026.10.12", "2026/10/12", "2026-10-12", "2026–10–12",
      "12/10/2026", "10.12.2026", "v123.456.7890", "version 1.2.3.4567", "192.168.100.200",
      "12:34:56", "23:59", "2026-10-12T12:34:56+09:00", "$123.45", "price 1,234.56", "₩123,456,789",
      "order 1234567890", "order ORD-123456789012", "invoice INV-1234-5678", "invoice 1234/5678/9012",
      "order 1234–5678–9012", "invoice INV–1234–5678", "12.345678, 98.765432", "coordinates -12.345678 +98.765432",
      "ISBN 978-1-2345-6789-0", "ISBN 978–1–2345–6789–0", "ISBN 1-234-56789-X",
      "id abc1234567890def", "id_123456789012", "id-123456789012", "revision 1234–5678", "range 1234567–1234569",
      "오늘은 2026년 10월 12일, 10–12쪽을 읽고 1200원을 썼다.", "2026年10月12日、100–120ページを読んだ。価格は1200円。",
    ]
    return plain + plain.map(fullWidth)
  }()

  /// Telephone numbers remain readable. The detector was
  /// the expensive part of masking, and a number in a local record does little harm. These
  /// spellings come back as written, alone and inside text, with the guards on or off.
  static let telephoneShaped: [String] = [
    "010-2345-6789", "010 2345 6789", "+82 10 2345 6789", "+82-10-2345-6789", "(415) 234-5678", "+1 415 234 5678",
    "+1 (415) 234-5678", "+81-90-2345-6789", "+33 1 23 45 67 89", "+49 30 2345 6789", "415.234.5678", "tel:+14152345678",
    "010\u{A0}2345\u{A0}6789", "010\u{2011}2345\u{2011}6789", "+82\u{2009}10\u{2009}2345\u{2009}6789", "010\u{2013}2345\u{2013}6789",
    fullWidth("010-2345-6789"), fullWidth("+82 10 2345 6789"), "+1 415 234 5678 ext 12", "+1 415 234 5678;8",
    "2019–2024–2026", "pages 100–120–140", "population 67 390 000", "12 345 678",
  ]

}
