"""Keep the Git mutation surface closed when adding or moving SQLite writes."""
import hashlib
import importlib.util
import json
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('import_boundary', ROOT / 'Plugins/ImportBoundary/check.py')
_boundary = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_boundary)
CATALOG = ROOT / 'tools/git_publication_inventory.json'
# SQLite accepts a quoted identifier right after the keyword: UPDATE"git_commits"SET.
MUTATION = re.compile(r'(?:INSERT(?: OR \w+)? INTO|UPDATE|DELETE FROM|REPLACE INTO)(?:\s|["`\[])', re.I)
SPLIT_KEYWORD = re.compile(r'(?:INSERT|UPDATE|DELETE|REPLACE|WITH)\b', re.I)
# Stands for a concatenated operand that is not a string literal.
CONCATENATED = '\\(+)'
TRIGGER = re.compile(r'CREATE (?:TEMP |TEMPORARY )?TRIGGER\b', re.I)
# After a dynamic start (a non-literal + operand or a leading interpolation) the keyword
# may sit in the variable; a statement tail still shows. "x + \" AND y=?\"" stays out.
DYNAMIC_TAIL = re.compile(r'\b(?:FROM|INTO|SET)(?:\s|["`\[])|git_', re.I)
INTERPOLATION = re.compile(r'\\#*\(')


def swift_sources():
    # Every module, not only Storage: a write moved into another target stays visible.
    return sorted((ROOT / 'Sources').rglob('*.swift'))


def normalized_sql(value):
    """Drop SQL comments and collapse whitespace so spacing cannot hide a keyword."""
    for escape, character in (('\\n', '\n'), ('\\t', '\t'), ('\\r', '\r'), ('\\"', '"')):
        value = value.replace(escape, character)
    value = re.sub(r'/\*.*?\*/', ' ', value, flags=re.S)
    value = re.sub(r'--[^\n]*', ' ', value)
    # A trailing separator is kept: "INSERT INTO " + table is still a mutation prefix.
    return re.sub(r'\s+', ' ', value).lstrip()


def matching(code, start, opening='{', closing='}'):
    depth = 0
    for index in range(start, len(code)):
        if code[index] == opening:
            depth += 1
        elif code[index] == closing:
            depth -= 1
            if depth == 0:
                return index
    raise AssertionError('Unbalanced Swift scope')


def literal_body(source, index):
    """The raw body and end of the Swift string literal opening at index, or None."""
    opening = _boundary.STRING_OPEN.match(source, index)
    if not opening:
        return None
    hashes, quotes = opening.groups()
    index += len(opening.group())
    body_start = index
    closing, escape = quotes + hashes, '\\' + hashes
    while index < len(source):
        if source.startswith(escape, index):
            index += len(escape) + 1
        elif source.startswith(closing, index):
            return source[body_start:index], index + len(closing)
        else:
            index += 1
    return None


def sql_literals(source):
    # Comment stripping and string tokenization follow the build-time boundary
    # checker, so braces/SQL in comments or escaped strings cannot create a gate.
    index = 0
    while index < len(source):
        if source.startswith('//', index):
            end = source.find('\n', index)
            index = len(source) if end < 0 else end
        elif source.startswith('/*', index):
            depth = 1
            index += 2
            while depth and index < len(source):
                if source.startswith('/*', index):
                    depth += 1
                    index += 2
                elif source.startswith('*/', index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
        else:
            literal = literal_body(source, index)
            if not literal:
                index += 1
                continue
            start = index
            body, index = literal
            # A literal reached here was not joined to a literal on its left, so a + before
            # it has a non-literal left operand.
            leading = bool(re.search(r'\+\s*$', source[max(0, start - 64):start]))
            if leading:
                body = CONCATENATED + body
            # "DELETE " + "FROM git_commits" is one statement: join concatenated literals,
            # and mark any other operand so a split keyword stays visible.
            concatenated = False
            while True:
                plus = re.match(r'\s*\+\s*', source[index:])
                if not plus:
                    break
                concatenated = True
                following = literal_body(source, index + plus.end())
                if not following:
                    body += CONCATENATED
                    break
                body += following[0]
                index = following[1]
            value = normalized_sql(body)
            direct = MUTATION.match(value)
            cte = re.match(r'WITH\b', value, re.I) and re.search(r'\b(?:INSERT|UPDATE|DELETE|REPLACE)\b', value, re.I)
            split = concatenated and SPLIT_KEYWORD.match(value)
            tail = (leading or INTERPOLATION.match(value)) and DYNAMIC_TAIL.search(value)
            if direct or cte or split or tail or TRIGGER.match(value):
                yield start, value.strip()


def mutation_sites(path, source):
    code = _boundary.without_comments_and_strings(source)
    functions = []
    for match in re.finditer(r'\bfunc\s+(\w+)\s*(?:<[^>]*>)?\(', code):
        body = code.find('{', match.end())
        if body >= 0:
            functions.append((body, matching(code, body), match.group(1)))
    gates = []
    for match in re.finditer(r'\bpublishGit\s*\(', code):
        if code[max(0, match.start() - 5):match.start()] == 'func ':
            continue
        start = code.find('(', match.start())
        end = matching(code, start, '(', ')')
        body = code.find('{', start, end)
        if body < 0:
            body = end + 1
            while body < len(code) and code[body].isspace():
                body += 1
        if body < len(code) and code[body] == '{':
            gates.append((body, matching(code, body), re.sub(r'\s+', ' ', source[match.start():body]).strip()))
    for start, sql in sql_literals(source):
        if re.match(r'CREATE\s', sql, re.I):
            continue
        dynamic = (re.search(r'^(?:INSERT(?: OR \w+)? INTO|UPDATE|DELETE FROM|REPLACE INTO)\s*(?:\\\(|$)', sql, re.I)
                   or CONCATENATED in sql or INTERPOLATION.match(sql))
        if 'git_' not in sql.lower() and path != 'Sources/Storage/GitCollection.swift' and not dynamic:
            continue
        owners = [item for item in functions if item[0] < start < item[1]]
        owner = min(owners, key=lambda item: item[1] - item[0])[2] if owners else '<file>'
        admission = next((operation for left, right, operation in gates if left < start < right), None)
        yield {'file': path, 'function': owner, 'sql': sql, 'gated': admission is not None, 'operation': admission}


def inventory():
    return [site for path in swift_sources()
            for site in mutation_sites(str(path.relative_to(ROOT)), path.read_text())]


def schema_triggers():
    return [{'file': str(path.relative_to(ROOT)), 'sql': sql}
            for path in swift_sources()
            for _, sql in sql_literals(path.read_text()) if re.match(r'CREATE\s', sql, re.I)]


def dynamic_executions():
    sites = []
    for path in swift_sources():
        source = path.read_text()
        code = _boundary.without_comments_and_strings(source)
        # SQLiteConnection is internal to Storage, so other modules can only reach it
        # through a named receiver; their unqualified run() calls are processes.
        calls = (r'(?:\b(?:run|rows|namedRows|collectionWrite)|\b(?:connection|snapshot|stage)\.integer)\(\s*'
                 if path.parent.name == 'Storage' else
                 r'\b(?:connection|snapshot|stage)\.(?:run|rows|namedRows|integer|collectionWrite)\(\s*')
        for match in re.finditer(calls, source):
            if code[match.start():match.start() + 3].isspace():
                continue
            if source[match.end():].startswith(('"', '#"')):
                continue
            if re.search(r'\bfunc\s+$', code[max(0, match.start() - 10):match.start()]):
                continue
            start = source.find('(', match.start())
            end = matching(code, start, '(', ')')
            sites.append({'file': str(path.relative_to(ROOT)),
                          'call': re.sub(r'\s+', ' ', source[match.start():end + 1])})
    return sites


def ungated(sites):
    return sorted(({key: value for key, value in site.items() if key not in ('gated', 'operation')}
                   for site in sites if not site['gated']), key=lambda item: (item['file'], item['function'], item['sql']))


class GitPublicationInventoryTests(unittest.TestCase):
    def test_all_mutations_are_gated_or_reviewed_nonpublication(self):
        expected = json.loads(CATALOG.read_text())
        sites = inventory()
        self.assertEqual(ungated(sites), expected['nonpublication'],
                         'Unreviewed Git mutation or a publication moved outside publishGit')
        self.assertEqual(sum(site['gated'] for site in sites), expected['gated_sites'])
        self.assertEqual([site for site in sites if site['gated']], expected['publications'],
                         'A publication changed its SQL or authorization operation')
        self.assertEqual(schema_triggers(), expected['schema_triggers'],
                         'A schema trigger changed the transitive mutation surface')
        self.assertEqual(dynamic_executions(), expected['dynamic_executions'],
                         'New dynamic SQL execution requires a mutation-site review')

    def test_schema_trigger_mutations_are_inventoried(self):
        source = 'func schema() throws { try run("CREATE TRIGGER invented AFTER UPDATE ON settings BEGIN INSERT INTO git_commits VALUES(1); END") }'
        statements = list(sql_literals(source))
        self.assertEqual(len(statements), 1)
        self.assertTrue(statements[0][1].startswith('CREATE TRIGGER'))
        self.assertIn('INSERT INTO git_commits', statements[0][1])

    def test_wrong_operation_changes_the_publication_inventory(self):
        source = 'func write() throws { try publishGit(.commitUnit(1), now: 2) { try connection.run("INSERT INTO git_files VALUES(1)") } }'
        changed = source.replace('.commitUnit(1)', '.diagnostic(.folder(1))')
        first = list(mutation_sites('Sources/Storage/Invented.swift', source))
        second = list(mutation_sites('Sources/Storage/Invented.swift', changed))
        self.assertEqual(first[0]['sql'], second[0]['sql'])
        self.assertNotEqual(first[0]['operation'], second[0]['operation'])

    def test_cte_mutation_is_still_a_publication_site(self):
        source = 'func write() throws { try connection.run("WITH value AS (SELECT 1) INSERT INTO git_commits SELECT * FROM value") }'
        sites = list(mutation_sites('Sources/Storage/Invented.swift', source))
        self.assertEqual(len(sites), 1)
        self.assertFalse(sites[0]['gated'])

    def test_lower_and_mixed_case_bypasses_remain_visible(self):
        for sql in ['insert into git_tombstones values(?)',
                    'uPdAtE GiT_Commits set complete=1',
                    'with value as (select 1) delete from git_commits',
                    'WiTh value AS (SELECT 1) InSeRt InTo git_commits SELECT * FROM value',
                    'replace into \\(table) values(?)']:
            with self.subTest(sql=sql):
                source = 'func bypass() throws { try connection.run("' + sql + '") }'
                sites = list(mutation_sites('Sources/Storage/Invented.swift', source))
                self.assertEqual(len(sites), 1)
                self.assertFalse(sites[0]['gated'])
        for sql in ['create trigger invented after update on settings begin insert into git_commits values(1); end',
                    'CrEaTe TrIgGeR invented AFTER UPDATE ON settings BEGIN DELETE FROM git_commits; END']:
            source = 'func schema() throws { try run("' + sql + '") }'
            statements = list(sql_literals(source))
            self.assertEqual(len(statements), 1)
            self.assertTrue(re.match(r'CREATE\s', statements[0][1], re.I))
            self.assertEqual(list(mutation_sites('Sources/Storage/Invented.swift', source)), [])

    def test_no_direct_sqlite_execution_outside_adapter(self):
        temporary = json.loads(CATALOG.read_text())['temporary_sqlite_adapters']
        for path in swift_sources():
            if path.name in temporary:
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), temporary[path.name],
                                 'Temporary SQLite adapter changed; review its isolated mutation surface')
                self.assertIn('sqlite3_open("", &database)', path.read_text())
                continue
            if path.name != 'SQLiteConnection.swift':
                code = _boundary.without_comments_and_strings(path.read_text())
                self.assertIsNone(re.search(r'\bsqlite3_(?:prepare\w*|exec|step)\s*\(', code), str(path))

    def test_detects_bypass_even_inside_an_existing_publisher(self):
        source = '''func append() throws {
          try connection.run("INSERT INTO git_files VALUES(1)")
          try publishGit(.commitUnit(1), now: 2) {
            try connection.run("INSERT INTO git_files VALUES(2)")
          }
        }'''
        sites = list(mutation_sites('Sources/Storage/Invented.swift', source))
        self.assertEqual([site['gated'] for site in sites], [False, True])

    def test_comments_strings_and_argument_closures_cannot_hide_a_bypass(self):
        source = '''func append() throws {
          // publishGit(.commitUnit(1), now: 2) {
          let display = "publishGit { }"
          try connection.run("UPDATE git_commits SET complete=1")
          _ = try publishGit(.commitUnit(1), now: 2, {
            try connection.run("INSERT INTO git_commit_text VALUES(1)")
          })
        }'''
        sites = list(mutation_sites('Sources/Storage/Invented.swift', source))
        self.assertEqual([site['gated'] for site in sites], [False, True])

    def test_spacing_newlines_and_sql_comments_cannot_hide_a_mutation(self):
        # Swift escapes as written in source: \n and \t are SQL whitespace.
        for sql in [r'INSERT   INTO git_commits VALUES(1)',
                    r'INSERT\nINTO git_commits VALUES(1)',
                    r'  DELETE\tFROM git_files',
                    r'-- invented note\nUPDATE git_commits SET complete=1',
                    r'/* invented note */ INSERT OR IGNORE  INTO git_tombstones VALUES(?)']:
            with self.subTest(sql=sql):
                source = 'func bypass() throws { try connection.run("' + sql + '") }'
                sites = list(mutation_sites('Sources/Storage/Invented.swift', source))
                self.assertEqual(len(sites), 1)
                self.assertFalse(sites[0]['gated'])
        multiline = 'func bypass() throws { try connection.run("""\n  -- invented note\n  DELETE\n    FROM git_refs\n  """) }'
        self.assertEqual([site['sql'] for site in mutation_sites('Sources/Storage/Invented.swift', multiline)], ['DELETE FROM git_refs'])
        # Bare keywords used as ordinary strings are not statements.
        self.assertEqual(list(mutation_sites('Sources/Storage/Invented.swift', 'func f() { let a = ["INSERT", "UPDATE", "update"] }')), [])

    def test_quoted_identifier_after_keyword_is_a_mutation(self):
        for sql in [r'UPDATE\"git_commits\"SET complete=1',
                    r'DELETE FROM\"git_files\"',
                    r'INSERT OR IGNORE INTO\"git_tombstones\" VALUES(?)',
                    r'REPLACE INTO[git_commits] VALUES(1)',
                    r'update`git_commits`set complete=1']:
            with self.subTest(sql=sql):
                source = 'func bypass() throws { try connection.run("' + sql + '") }'
                sites = list(mutation_sites('Sources/Storage/Invented.swift', source))
                self.assertEqual(len(sites), 1)
                self.assertFalse(sites[0]['gated'])
        raw = 'func bypass() throws { try connection.run("""\n  UPDATE"git_commits"SET complete=1\n  """) }'
        self.assertEqual([site['sql'] for site in mutation_sites('Sources/Shell/Invented.swift', raw)], ['UPDATE"git_commits"SET complete=1'])

    def test_concatenation_cannot_split_a_mutation_keyword(self):
        for expression, sql in [('"DELETE " + "FROM git_commits"', 'DELETE FROM git_commits'),
                                ('"INSERT OR " +\n "IGNORE INTO " + "git_tombstones VALUES(?)"', 'INSERT OR IGNORE INTO git_tombstones VALUES(?)'),
                                ('"UPD" + "ATE git_commits SET complete=1"', 'UPDATE git_commits SET complete=1'),
                                ('"DELETE " + statement', 'DELETE \\(+)')]:
            with self.subTest(sql=sql):
                source = 'func bypass() throws { try connection.run(' + expression + ') }'
                sites = list(mutation_sites('Sources/Shell/Invented.swift', source))
                self.assertEqual([site['sql'] for site in sites], [sql])
                self.assertFalse(sites[0]['gated'])
        # Concatenated text that is not a statement stays out of the inventory.
        self.assertEqual(list(mutation_sites('Sources/Shell/Invented.swift', 'func f() { let a = " AND x=?" + list }')), [])

    def test_keyword_in_a_variable_or_leading_interpolation_is_dynamic(self):
        for expression, sql in [('verb + " FROM git_commits"', '\\(+) FROM git_commits'),
                                ('"\\(verb) FROM git_commits"', '\\(verb) FROM git_commits'),
                                ('v + "ETE FROM git_commits"', '\\(+)ETE FROM git_commits')]:
            with self.subTest(sql=sql):
                source = 'func bypass() throws { let verb = "DELETE"; let v = "DEL"; try connection.run(' + expression + ') }'
                sites = list(mutation_sites('Sources/Shell/Invented.swift', source))
                self.assertEqual([site['sql'] for site in sites], [sql])
                self.assertFalse(sites[0]['gated'])
        # Without a statement tail, text after a variable stays out; so does a compound append.
        for source in ['func f() { let a = list + " AND x=?" }', 'func f() { let a = name + " <from> <to>" }',
                       'func f() { query += " AND x=?" }']:
            with self.subTest(source=source):
                self.assertEqual(list(mutation_sites('Sources/Shell/Invented.swift', source)), [])

    def test_temporary_triggers_are_schema_mutations(self):
        for sql in ['CREATE TEMP TRIGGER invented AFTER UPDATE ON settings BEGIN DELETE FROM git_commits; END',
                    'create temporary trigger invented after update on settings begin delete from git_commits; end']:
            with self.subTest(sql=sql):
                self.assertEqual(len(list(sql_literals('func schema() throws { try run("' + sql + '") }'))), 1)

    def test_collection_write_and_files_outside_storage_are_scanned(self):
        invented = [(ROOT / 'Sources/Storage/InventedDynamic.swift',
                     'func erase() throws { try connection.collectionWrite(statement, values) }'),
                    (ROOT / 'Sources/Shell/InventedOutsideStorage.swift',
                     'func bypass() throws { try connection.run("INSERT  INTO git_commits VALUES(1)"); try connection.run(statement) }')]
        for path, _ in invented:
            self.assertFalse(path.exists(), path)
        try:
            for path, source in invented:
                path.write_text(source)
            dynamic = dynamic_executions()
            self.assertIn({'file': 'Sources/Storage/InventedDynamic.swift', 'call': 'collectionWrite(statement, values)'}, dynamic)
            self.assertIn({'file': 'Sources/Shell/InventedOutsideStorage.swift', 'call': 'connection.run(statement)'}, dynamic)
            self.assertIn({'file': 'Sources/Shell/InventedOutsideStorage.swift', 'function': 'bypass',
                           'sql': 'INSERT INTO git_commits VALUES(1)'}, ungated(inventory()))
        finally:
            for path, _ in invented:
                path.unlink(missing_ok=True)

if __name__ == '__main__':
    unittest.main()
