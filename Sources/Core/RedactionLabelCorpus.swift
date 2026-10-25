import Foundation

/// Invented fixtures keep ordinary code and prose unchanged: 214 ordinary lines, 44 holding a glued
/// small-letter "…token" before a separator, and 36 lines holding an
/// invented value that looks like a secret. No line was read from a record; every value holds the word "invented".
enum RedactionLabelCorpus {
  /// Ordinary lines whose glued "…token" name stands before a separator. None may change.
  static let gluedOrdinary: [String] = [
    // Parsers and tokenizers.
    "nexttoken = lexer.advance()", "if nexttoken == EOF: break", "lasttoken: Token", "starttoken: int = 0",
    "private Token pushedtoken = null;", "let currenttoken = stream.peek()", "prevtoken = tokens[i - 1]",
    "var firsttoken: Token? = nil", "endtoken = len(tokens) - 1", "while curtoken == RPAREN:",
    "const eoftoken = Symbol(\"eof\");", "subtoken := scanner.Next()", "peektoken = self.tokens[self.pos]",
    "auto looktoken = parser.lookahead();", "my $thistoken = shift(queue);", "errtoken: Option<Token>,",
    "local roottoken = tree:first()", "val headtoken = buffer.first()", "opentoken = stack.pop()",
    "closetoken: Kind = expect(RBRACE)", "self.wordtoken = text[start:end]",
    // Paging and sync marks.
    "var pagetoken = response.next", "nextpagetoken: null", "continuationtoken = result.continuation", "synctoken=41",
    "GET /items?limit=20&nexttoken=3", "GET /v1/list?pagetoken=12 HTTP/1.1",
    // Logs.
    "parse error: unexpected nexttoken=RBRACE at line 12", "debug lexer state curtoken=IDENT depth=2",
    "trace: lasttoken=COMMA, expecting value", "warn: skipped badtoken=0x3f in column 8",
    // Sentences.
    "Each subtoken: a piece of a word", "The nexttoken: whatever the lexer returns after this one",
    "Rename lasttoken = prev everywhere in the parser", "한 줄의 firsttoken: 줄 맨 앞의 낱말",
    "Note that pagetoken = empty means the last page",
    // A shell line.
    "./list.sh --pagetoken=12 --limit 50",
    // Words taken off the credential list: visibility, sections, programs,
    // ownership and game actions.
    "privatetoken = lexer.expect(PRIVATE_KEYWORD)", "registrytoken = lexer.expect(REGISTRY_SECTION)",
    "bottoken = board.spawn_robot_piece()", "apptoken = lexer.expect(APP_DECLARATION)",
    "servicetoken = lexer.expect(SERVICE_DECLARATION)", "personaltoken = board.player_piece(player_id)",
    "invitetoken = lexer.expect(INVITE_COMMAND)",
  ]

  /// The other ordinary lines: assignments, comparisons, type declarations, settings, logs,
  /// shell lines and sentences in a dozen languages. None may change.
  static let plainOrdinary: [String] = [
    // Python
    "tokens = text.split()", "for token in tokens:", "    if token is None:", "        return token", "max_tokens = 4096",
    "num_tokens: int = len(tokens)", "tokenizer = Tokenizer(vocab)", "def tokenize(text: str) -> list[str]:",
    "count = sum(1 for t in tokens if t.isalpha())", "result = parser.parse(tokens)", "import tokenize", "token_count = 12",
    "assert len(tokens) == 3", "print(f\"{len(tokens)} tokens read\")", "class TokenStream:", "    self.pos += 1",
    // JavaScript and TypeScript
    "const tokens = lexer.tokenize(source);", "let index = 0;", "function peek() { return tokens[index]; }",
    "export interface Token { kind: string; text: string }", "if (token.kind === 'ident') advance();",
    "tokens.forEach((t) => console.log(t.text));", "const total: number = items.length;", "type Kind = 'ident' | 'number' | 'eof';",
    "return tokens.filter(Boolean);", "import { tokenize } from './lexer';", "const pageSize = 20;", "let cursor = response.next;",
    "export default function Page() {", "for (const token of tokens) emit(token);",
    // Swift
    "let tokens = line.split(separator: \" \")", "var position = tokens.startIndex", "guard let first = tokens.first else { return }",
    "struct Token { let kind: Kind; let text: String }", "func advance() -> Token?", "enum Kind { case ident, number, eof }",
    "switch token.kind {", "let total = values.reduce(0, +)", "private var buffer: [Token] = []", "defer { position += 1 }",
    // Go
    "tokens := strings.Fields(line)", "for _, tok := range tokens {", "func (l *Lexer) Next() Token {", "if tok.Kind == EOF {",
    "type Token struct {", "\tKind int", "\tText string", "var count int", "return tokens, nil", "package lexer",
    // Rust
    "let tokens: Vec<Token> = lex(&source)?;", "match token.kind {", "pub struct Token {", "    pub kind: Kind,",
    "impl Iterator for Lexer {", "fn next(&mut self) -> Option<Token> {", "let mut depth = 0usize;", "#[derive(Debug, Clone)]",
    "use std::collections::HashMap;", "while let Some(token) = lexer.next() {",
    // Java and Kotlin
    "List<Token> tokens = lexer.scan();", "public Token next() {", "private int position = 0;", "if (token.type() == Type.EOF) {",
    "final String text = token.text();", "val tokens = lexer.scan()", "fun peek(): Token? = tokens.getOrNull(position)",
    "when (token.kind) {", "data class Token(val kind: Kind, val text: String)", "return tokens.size",
    // C and C++
    "Token *tok = lexer_next(lx);", "if (tok->kind == TK_EOF) break;", "size_t count = 0;", "struct token { int kind; char *text; };",
    "std::vector<Token> tokens;", "auto it = tokens.begin();", "for (const auto &t : tokens) {", "#include \"lexer.h\"",
    "static int depth = 0;", "return tokens.size();",
    // Ruby and PHP
    "tokens = line.split", "tokens.each { |t| puts t }", "def next_token", "  @tokens[@pos]", "end",
    "$tokens = explode(' ', $line);", "foreach ($tokens as $token) {", "echo count($tokens);", "function nextToken(): ?Token {",
    "return $this->tokens[$this->pos] ?? null;",
    // SQL
    "SELECT kind, text FROM tokens WHERE line = 12;", "CREATE TABLE tokens (id INTEGER PRIMARY KEY, kind TEXT);",
    "UPDATE pages SET cursor = 3 WHERE id = 7;", "SELECT COUNT(*) FROM tokens;", "DELETE FROM tokens WHERE kind = 'space';",
    // Settings
    "max_tokens: 4096", "page_size: 20", "tokenizer: whitespace", "retries = 3", "log_level = \"info\"", "[lexer]",
    "primary_key = id", "cache_key: user", "timeout_seconds: 30", "token_limit = 8000", "\"pageSize\": 20,", "\"kind\": \"ident\",",
    "enabled = true", "workers: 4", "name: invoice-parser",
    // Logs
    "info: read 128 tokens in 3 ms", "debug: token kind ident at column 4", "warn: unknown token kind 9, skipped",
    "error: unexpected end of input at line 40", "info: page 3 of 12 fetched", "trace: lexer advanced to column 18",
    "info: tokenizer loaded 32000 entries", "debug: cache hit for page 7", "warn: retry 2 of 3", "info: parse finished, 0 errors",
    "error: token limit reached, input shortened", "debug: 14 tokens left in the buffer",
    // Shell
    "git log --oneline -5", "swift build -c release", "python3 tools/count_tokens.py notes.txt", "ls -la Sources/Lexer",
    "grep -n \"nextToken\" Sources/Lexer/*.swift", "make test", "cargo test lexer::tests", "wc -l tokens.txt",
    "./list.sh --limit 50 --page 3", "cd Sources/Lexer && ls", "npm run lint", "go test ./lexer/...",
    // English sentences
    "The lexer turns text into tokens.", "A token has a kind and a piece of text.", "The next token decides which rule applies.",
    "Count the tokens before sending the request.", "The page token is empty on the last page.",
    "We keep the last token to report errors.", "Each model has a token limit.", "Tokens are split on white space first.",
    "The parser looks one token ahead.", "A sync token marks where the last read ended.", "Read the next page until none is left.",
    "The tokenizer is loaded once at start.",
    // Korean sentences
    "낱말 나누기는 글을 token으로 바꾼다.", "다음 token이 어느 규칙을 쓸지 정한다.", "마지막 쪽에서는 page token이 비어 있다.",
    "요청을 보내기 전에 token 수를 센다.", "오류를 알리려고 마지막 token을 기억한다.", "token 한도를 넘으면 입력을 줄인다.",
    "파서는 token 하나를 미리 본다.", "쪽을 다 읽을 때까지 다음 쪽을 읽는다.", "sync token은 어디까지 읽었는지 적는다.",
    "token은 종류와 글자를 가진다.", "먼저 공백으로 token을 나눈다.", "시작할 때 한 번 tokenizer를 읽는다.",
    // Comparisons and type declarations that name a token without assigning a value.
    "if (tokens.length === 0) return [];", "while (position < tokens.count) {", "if kind == .eof { break }",
    "typedef struct token token_t;", "Token[] tokens = new Token[16];", "let kinds: Set<Kind> = [.ident, .number]",
    "interface Lexer { next(): Token }", "if len(tokens) > limit:", "elif tokens[0].kind != IDENT:",
    "var tokensLeft: Int { tokens.count - position }", "bool done = position >= count;", "tokens.sort(key=lambda t: t.start)",
  ]

  /// Lines holding an invented secret-looking value, and whether the value is masked.
  static let secrets: [(line: String, masked: Bool)] = [
    // A credential word glued to token still identifies a secret value.
    ("authtoken=inventedvalue01", true), ("authtoken = \"invented value 02\"", true), ("export authtoken=inventedvalue03", true),
    ("login ok authtoken=inventedvalue04 user=7", true), ("curl -d 'authtoken=inventedvalue05' example.org/login", true),
    ("authtoken：inventedvalue06", true), ("Then set authtoken: inventedvalue07 in the settings file.", true),
    ("authtoken: inventedvalue08", true), ("my_authtoken = 'inventedvalue09'", true),
    ("09:14 INFO issued authtoken=inventedvalue10", true),
    ("Cookie: csrftoken=inventedvalue11; sessiontoken=inventedvalue12", true), ("csrftoken: inventedvalue13", true),
    ("x-xsrftoken: inventedvalue14", true), ("refreshtoken=inventedvalue15", true), ("refreshtoken: \"inventedvalue16\"", true),
    ("apitoken = inventedvalue17", true), ("accesstoken=inventedvalue19", true), ("deploytoken: inventedvalue20", true),
    ("bearertoken = inventedvalue21", true), ("logintoken: inventedvalue26", true), ("webhooktoken=inventedvalue27", true),
    // Words taken off the list: the glued name is ordinary code too.
    ("bottoken=inventedvalue22", false), ("registrytoken = inventedvalue28", false), ("invitetoken=inventedvalue29", false),
    // A bracket stands between the name and the separator: no label rule reaches it.
    ("settings[\"apitoken\"] = \"inventedvalue18\"", false),
    // The glued name is also ordinary code, or names no credential: left out of the list.
    ("usertoken=inventedvalue23", false), ("idtoken: inventedvalue24", false), ("resettoken=inventedvalue25", false),
    ("pushtoken: inventedvalue30", false), ("devicetoken=inventedvalue31", false),
    // Separated labels and mixed-case spellings also identify secret values.
    ("accessToken=inventedvalue32", true), ("AUTH_TOKEN=inventedvalue33", true), ("authToken: inventedvalue34", true),
    ("token: inventedvalue35", true), ("password=inventedvalue36", true), ("api_key = inventedvalue37", true),
  ]

  static func failures() -> [String] {
    var failures: [String] = []
    let ordinary = gluedOrdinary + plainOrdinary
    if ordinary.count != 214 || gluedOrdinary.count != 44 || secrets.count != 36 || Set(ordinary).count != 214 {
      failures.append("label corpus: \(ordinary.count) ordinary lines (\(gluedOrdinary.count) glued), \(secrets.count) secret lines; expected 214 (44) and 36")
    }
    // The 44 are exactly the ordinary lines a rule without the narrowing would change.
    let glued = try! NSRegularExpression(pattern: #"\p{Ll}token(?:\\?["'])?\s*[:=：]"#)
    for line in ordinary where (glued.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil) != gluedOrdinary.contains(line) {
      failures.append("label corpus: glued form miscounted in " + line)
    }
    for line in ordinary where Redaction.apply(line).text != line {
      failures.append("label corpus: ordinary line changed: " + line + " -> " + Redaction.apply(line).text)
    }
    for (line, masked) in secrets where Redaction.apply(line).text.contains("invented") == masked {
      failures.append("label corpus: secret line " + (masked ? "kept: " : "masked, expected kept: ") + line + " -> " + Redaction.apply(line).text)
    }
    if secrets.filter(\.masked).count != 27 { failures.append("label corpus: \(secrets.filter(\.masked).count) secret lines masked, expected 27") }
    return failures
  }
}
