import Core

/// Native ancestry uses the same exact identity boundary as ownership receipts.
/// Keep raw spellings only for replies; never use protocol String equality as proof.
func conversationIdentity(_ raw: String) -> AgentLogNativeComponent {
  AgentLogIdentity.decoded(raw).component
}

struct ConversationIdentityMap<Value>: ExpressibleByDictionaryLiteral, Sequence {
  private var entries: [AgentLogNativeComponent: (raw: String, value: Value)] = [:]

  init(dictionaryLiteral elements: (String, Value)...) {
    for (raw, value) in elements { self[raw] = value }
  }

  subscript(_ raw: String) -> Value? {
    get { entries[conversationIdentity(raw)]?.value }
    set { entries[conversationIdentity(raw)] = newValue.map { (raw, $0) } }
  }

  var keys: [String] { entries.values.map(\.raw) }
  var values: [Value] { entries.values.map(\.value) }
  var identities: Set<AgentLogNativeComponent> { Set(entries.keys) }
  var count: Int { entries.count }
  var isEmpty: Bool { entries.isEmpty }

  @discardableResult mutating func removeValue(forKey raw: String) -> Value? {
    entries.removeValue(forKey: conversationIdentity(raw))?.value
  }

  func makeIterator() -> IndexingIterator<[(String, Value)]> {
    entries.values.map { ($0.raw, $0.value) }.makeIterator()
  }
}

struct ConversationIdentitySet {
  private var entries: ConversationIdentityMap<Bool> = [:]
  var isEmpty: Bool { entries.isEmpty }
  func contains(_ raw: String) -> Bool { entries[raw] != nil }
  mutating func insert(_ raw: String) -> (inserted: Bool, memberAfterInsert: String) {
    let inserted = entries[raw] == nil
    entries[raw] = true
    return (inserted, raw)
  }
  @discardableResult mutating func remove(_ raw: String) -> String? {
    entries.removeValue(forKey: raw).map { _ in raw }
  }
  mutating func removeAll() { entries = [:] }
  func sorted() -> [String] { entries.keys.sorted { conversationIdentity($0) < conversationIdentity($1) } }
}
