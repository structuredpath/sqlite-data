#if canImport(CloudKit)
  package import CloudKit
  import CustomDump
  import Dependencies
  package import GRDB
  import IssueReporting
  import StructuredQueries
  public import StructuredQueriesCore

  public protocol CustomConflictResolvable: PrimaryKeyedTable
    where TableColumns.PrimaryColumn: WritableTableColumnExpression
  {
    static var fieldPolicies: FieldConflictPolicyRegistry<Self> { get }
  }

  public struct FieldConflictPolicyRegistry<T> {
    private var storage: [PartialKeyPath<T>: Any] = [:]

    public init(_ build: (inout Self) -> Void) {
      build(&self)
    }

    public subscript<Value>(
      keyPath: KeyPath<T, Value>
    ) -> FieldConflictPolicy<Value>? {
      get { storage[keyPath] as? FieldConflictPolicy<Value> }
      set { storage[keyPath] = newValue as Any? }
    }
  }

  public struct FieldConflictPolicy<Value> {
    public init(
      merge: @escaping (
        _ ancestor: FieldVersion<Value>,
        _ server: FieldVersion<Value>,
        _ client: FieldVersion<Value>
      ) -> Value,
      reconcile: @escaping (
        _ server: FieldVersion<Value>,
        _ client: FieldVersion<Value>
      ) -> Value
    ) {
      self.merge = merge
      self.reconcile = reconcile
    }

    /// Creates a policy from a resolution that does not depend on the ancestor version.
    /// The same resolution is applied in three-way merges and in two-way reconciliation.
    public init(
      _ resolve: @escaping (
        _ server: FieldVersion<Value>,
        _ client: FieldVersion<Value>
      ) -> Value
    ) {
      self.init(
        merge: { _, server, client in resolve(server, client) },
        reconcile: resolve
      )
    }

    /// Resolves a field conflict given the ancestor, server, and client versions.
    public let merge: (
      _ ancestor: FieldVersion<Value>,
      _ server: FieldVersion<Value>,
      _ client: FieldVersion<Value>
    ) -> Value

    /// Resolves a field conflict between the server and client versions when no shared
    /// ancestor is available, e.g. when re-signing into iCloud after the sync metadata
    /// was cleared while the user data was kept or when both sides independently created
    /// a row with the same primary key before ever synchronizing.
    public let reconcile: (
      _ server: FieldVersion<Value>,
      _ client: FieldVersion<Value>
    ) -> Value
  }

  extension FieldConflictPolicy {
    /// Last-edit-wins conflict policy that picks the edited value with the newer modification
    /// timestamp (ties favor the server).
    public static var latest: Self {
      Self { server, client in
        client.modificationTime > server.modificationTime ? client.value : server.value
      }
    }
  }

  /// A strategy for reconciling a counter field when no shared ancestor is available.
  public struct CounterFieldReconciliationStrategy<Value: BinaryInteger> {
    package let reconcile: (
      _ server: FieldVersion<Value>,
      _ client: FieldVersion<Value>
    ) -> Value

    public init(
      _ reconcile: @escaping (
        _ server: FieldVersion<Value>,
        _ client: FieldVersion<Value>
      ) -> Value
    ) {
      self.reconcile = reconcile
    }

    /// Picks the count with the newer modification timestamp (ties favor the server). Without
    /// an ancestor, the deltas cannot be reconstructed from the absolute counts.
    public static var latest: Self {
      Self(FieldConflictPolicy<Value>.latest.reconcile)
    }
  }

  extension FieldConflictPolicy where Value: BinaryInteger {
    /// Counter conflict policy that combines the independent increments and decrements from
    /// both edited values. Reconciliation picks the count with the newer modification timestamp.
    public static var counter: Self {
      .counter(reconciliation: .latest)
    }

    /// Counter conflict policy that combines the independent increments and decrements from
    /// both edited values. Without an ancestor, the deltas cannot be reconstructed, so
    /// reconciliation follows the given strategy.
    public static func counter(reconciliation strategy: CounterFieldReconciliationStrategy<Value>) -> Self {
      Self(
        merge: { ancestor, server, client in
          ancestor.value
            + (server.value - ancestor.value)
            + (client.value - ancestor.value)
        },
        reconcile: strategy.reconcile
      )
    }
  }

  /// A strategy for reconciling a set field when no shared ancestor is available.
  public struct SetFieldReconciliationStrategy<Value: SetAlgebra> where Value.Element: Equatable {
    package let reconcile: (
      _ server: FieldVersion<Value>,
      _ client: FieldVersion<Value>
    ) -> Value

    public init(
      _ reconcile: @escaping (
        _ server: FieldVersion<Value>,
        _ client: FieldVersion<Value>
      ) -> Value
    ) {
      self.reconcile = reconcile
    }

    /// Unions both sides. Without an ancestor, no element is known to have been deleted, so
    /// this preserves every element at the cost of possibly resurrecting deletions.
    public static var union: Self {
      Self { server, client in
        server.value.union(client.value)
      }
    }

    /// Picks the set with the newer modification timestamp (ties favor the server). Suited
    /// to sets where resurrecting removed elements is unacceptable.
    public static var latest: Self {
      Self(FieldConflictPolicy<Value>.latest.reconcile)
    }
  }

  extension FieldConflictPolicy where Value: SetAlgebra, Value.Element: Equatable {
    /// Set conflict policy that preserves elements not deleted on either side and adds new elements
    /// from both sides. Reconciliation unions both sides.
    public static var set: Self {
      .set(reconciliation: .union)
    }

    /// Set conflict policy that preserves elements not deleted on either side and adds new elements
    /// from both sides. Without an ancestor, deletions cannot be detected, so reconciliation
    /// follows the given strategy.
    public static func set(reconciliation strategy: SetFieldReconciliationStrategy<Value>) -> Self {
      Self(
        merge: { ancestor, server, client in
          let notDeleted = ancestor.value
            .intersection(server.value)
            .intersection(client.value)

          let addedByServer = server.value.subtracting(ancestor.value)
          let addedByClient = client.value.subtracting(ancestor.value)

          return notDeleted
            .union(addedByServer)
            .union(addedByClient)
        },
        reconcile: strategy.reconcile
      )
    }
  }

  public struct FieldVersion<Value> {
    /// The field value.
    public let value: Value
    /// The timestamp at which this field was last modified.
    public let modificationTime: Int64
  }

  /// A row-level conflict that resolves each field against a per-field conflict policy and can
  /// generate an UPDATE statement applying the resolution.
  @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
  package protocol RowConflict<T> {
    associatedtype T: PrimaryKeyedTable
    where T.TableColumns.PrimaryColumn: WritableTableColumnExpression

    /// The primary key of the conflicting row, targeted by the update statement.
    var primaryKey: T.PrimaryKey.QueryOutput { get }

    /// Resolves a field conflict by column, applying the given conflict policy.
    func resolvedValue<C: WritableTableColumnExpression>(
      column: C,
      policy: FieldConflictPolicy<C.QueryValue.QueryOutput>
    ) -> C.QueryValue.QueryOutput where C.Root == T
  }

  @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
  extension RowConflict {
    /// Resolves a field conflict by key path, delegating to `resolvedValue(column:policy:)`.
    package func resolvedValue<C: WritableTableColumnExpression>(
      for keyPath: some KeyPath<T.TableColumns, C>,
      policy: FieldConflictPolicy<C.QueryValue.QueryOutput>
    ) -> C.QueryValue.QueryOutput where C.Root == T {
      resolvedValue(
        column: T.columns[keyPath: keyPath],
        policy: policy
      )
    }

    /// Generates an UPDATE statement that resolves the conflict, using per-field policies
    /// from `CustomConflictResolvable` when available, falling back to `.latest`.
    ///
    /// Returns `nil` when the table has no writable columns besides the primary key, in which
    /// case there is nothing to resolve.
    package func makeUpdateQuery() -> QueryFragment? {
      let assignments = T.TableColumns.writableColumns.compactMap { column in
        func open<Root, Value>(
          _ column: some WritableTableColumnExpression<Root, Value>
        ) -> (column: String, value: QueryBinding)? {
          guard column.name != T.primaryKey.name else { return nil }
          let column = column as! (any WritableTableColumnExpression<T, Value>)
          let policy = policy(for: column.keyPath)
          let resolved = resolvedValue(column: column, policy: policy)
          return (column: column.name, value: Value(queryOutput: resolved).queryBinding)
        }
        return open(column)
      }
      guard !assignments.isEmpty else { return nil }

      return """
        UPDATE \(T.self)
        SET \(assignments.map { "\(quote: $0.column) = \($0.value)" }.joined(separator: ", "))
        WHERE (\(T.primaryKey)) = (\(T.PrimaryKey(queryOutput: primaryKey)))
        """
    }

    /// Resolves the conflict policy for the given column from `CustomConflictResolvable`,
    /// falling back to `.latest`.
    private func policy<Value>(
      for keyPath: KeyPath<T, Value>
    ) -> FieldConflictPolicy<Value> {
      func open<U: CustomConflictResolvable>(_ table: U.Type) -> FieldConflictPolicy<Value>? {
        table.fieldPolicies[keyPath as! KeyPath<U, Value>]
      }
      if let table = T.self as? any CustomConflictResolvable.Type, let policy = open(table) {
        return policy
      }
      return .latest
    }
  }

  /// A three-way merge conflict between an ancestor, server, and client version of a row.
  @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
  package struct MergeConflict<T: PrimaryKeyedTable>: RowConflict
  where
    T.PrimaryKey.QueryOutput: IdentifierStringConvertible,
    T.TableColumns.PrimaryColumn: WritableTableColumnExpression
  {
    package let ancestor: RowVersion<T>
    package let server: RowVersion<T>
    package let client: RowVersion<T>

    package init(
      ancestor: RowVersion<T>,
      server: RowVersion<T>,
      client: RowVersion<T>
    ) {
      precondition(
        ancestor.row.primaryKey.rawIdentifier == client.row.primaryKey.rawIdentifier
          && server.row.primaryKey.rawIdentifier == client.row.primaryKey.rawIdentifier,
        "All versions of a merge conflict must describe the same row."
      )
      self.ancestor = ancestor
      self.server = server
      self.client = client
    }

    /// The primary key of the conflicting row.
    package var primaryKey: T.PrimaryKey.QueryOutput {
      client.row.primaryKey
    }

    /// Resolves a field conflict by column, applying the given conflict policy. Falls through to
    /// the client or server value when only one side changed.
    package func resolvedValue<C: WritableTableColumnExpression>(
      column: C,
      policy: FieldConflictPolicy<C.QueryValue.QueryOutput>
    ) -> C.QueryValue.QueryOutput where C.Root == T {
      let keyPath = column.keyPath
      let ancestorValue = ancestor.row[keyPath: keyPath]
      let clientValue = client.row[keyPath: keyPath]
      let serverValue = server.row[keyPath: keyPath]

      let hasClientChanged = !areEqual(ancestorValue, clientValue, as: C.QueryValue.self)
      let hasServerChanged = !areEqual(ancestorValue, serverValue, as: C.QueryValue.self)

      switch (hasClientChanged, hasServerChanged) {
      case (false, false):
        return ancestorValue
      case (true, false):
        return clientValue
      case (false, true):
        return serverValue
      case (true, true):
        let ancestorField = FieldVersion(
          value: ancestorValue,
          modificationTime: ancestor.modificationTime(for: keyPath)
        )
        let clientField = FieldVersion(
          value: clientValue,
          modificationTime: client.modificationTime(for: keyPath)
        )
        let serverField = FieldVersion(
          value: serverValue,
          modificationTime: server.modificationTime(for: keyPath)
        )
        return policy.merge(ancestorField, serverField, clientField)
      }
    }
  }

  @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
  extension MergeConflict: CustomDumpReflectable {
    package var customDumpMirror: Mirror {
      Mirror(
        self,
        children: [
          ("ancestor", ancestor),
          ("server", server),
          ("client", client),
        ],
        displayStyle: .struct
      )
    }
  }

  /// A two-way reconciliation conflict between a server and client version of a row when no
  /// shared ancestor is available, e.g. when re-signing into iCloud after the sync metadata
  /// was cleared while the user data was kept or when both sides independently created a row
  /// with the same primary key before ever synchronizing.
  @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
  package struct ReconciliationConflict<T: PrimaryKeyedTable>: RowConflict
  where
    T.PrimaryKey.QueryOutput: IdentifierStringConvertible,
    T.TableColumns.PrimaryColumn: WritableTableColumnExpression
  {
    package let server: RowVersion<T>
    package let client: RowVersion<T>

    package init(
      server: RowVersion<T>,
      client: RowVersion<T>
    ) {
      precondition(
        server.row.primaryKey.rawIdentifier == client.row.primaryKey.rawIdentifier,
        "Both versions of a reconciliation conflict must describe the same row."
      )
      self.server = server
      self.client = client
    }

      /// The primary key of the conflicting row.
    package var primaryKey: T.PrimaryKey.QueryOutput {
      client.row.primaryKey
    }

    /// Resolves a field conflict by column, applying the given conflict policy. Falls through
    /// to the shared value when both sides agree.
    package func resolvedValue<C: WritableTableColumnExpression>(
      column: C,
      policy: FieldConflictPolicy<C.QueryValue.QueryOutput>
    ) -> C.QueryValue.QueryOutput where C.Root == T {
      let keyPath = column.keyPath
      let clientValue = client.row[keyPath: keyPath]
      let serverValue = server.row[keyPath: keyPath]

      if areEqual(clientValue, serverValue, as: C.QueryValue.self) {
        return clientValue
      }

      let clientField = FieldVersion(
        value: clientValue,
        modificationTime: client.modificationTime(for: keyPath)
      )
      let serverField = FieldVersion(
        value: serverValue,
        modificationTime: server.modificationTime(for: keyPath)
      )
      return policy.reconcile(serverField, clientField)
    }
  }

  @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
  extension ReconciliationConflict: CustomDumpReflectable {
    package var customDumpMirror: Mirror {
      Mirror(
        self,
        children: [
          ("server", server),
          ("client", client),
        ],
        displayStyle: .struct
      )
    }
  }

  /// A snapshot of a table row together with per-field modification timestamps,
  /// used for three-way merge conflict resolution.
  @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
  package struct RowVersion<T: PrimaryKeyedTable> {
    /// The represented row.
    package let row: T
    /// Per-field modification timestamps keyed by column key path.
    private let modificationTimes: [PartialKeyPath<T>: Int64]
    
    package init(
      row: T,
      modificationTimes: [PartialKeyPath<T>: Int64]
    ) {
      self.row = row
      self.modificationTimes = modificationTimes
    }
    
    /// Creates a client row version without an ancestor by applying the row-level
    /// modification time to every writable column. Used for two-way reconciliation when
    /// no shared baseline exists.
    package init(
      clientRow row: T,
      userModificationTime: Int64
    ) {
      var modificationTimes: [PartialKeyPath<T>: Int64] = [:]
      for column in T.TableColumns.writableColumns {
        func open<Root, Value>(_ column: some WritableTableColumnExpression<Root, Value>) {
          modificationTimes[column.keyPath as! PartialKeyPath<T>] = userModificationTime
        }
        open(column)
      }

      self.init(
        row: row,
        modificationTimes: modificationTimes
      )
    }

    /// Creates a client row version by deriving per-field modification timestamps from the
    /// ancestor: changed fields get the client's modification time, unchanged fields inherit
    /// the ancestor's timestamp.
    package init(
      clientRow row: T,
      userModificationTime: Int64,
      ancestorVersion: RowVersion<T>
    ) {
      var modificationTimes: [PartialKeyPath<T>: Int64] = [:]
      for column in T.TableColumns.writableColumns {
        func open<Root, Value>(_ column: some WritableTableColumnExpression<Root, Value>) {
          let keyPath = column.keyPath as! KeyPath<T, Value.QueryOutput>
          let clientValue = row[keyPath: keyPath]
          let ancestorValue = ancestorVersion.row[keyPath: keyPath]
          
          if areEqual(clientValue, ancestorValue, as: Value.self) {
            modificationTimes[keyPath] = ancestorVersion.modificationTime(for: keyPath)
          } else {
            modificationTimes[keyPath] = userModificationTime
          }
        }
        open(column)
      }
      
      self.init(
        row: row,
        modificationTimes: modificationTimes
      )
    }

    /// Creates a row version from a `CKRecord` by decoding its encrypted values into a row
    /// and reading per-field modification timestamps. Requires a database connection to execute
    /// a synthetic SQL SELECT for type-safe decoding.
    package init(from record: CKRecord, db: Database) throws {
      @Dependency(\.dataManager) var dataManager
      
      func makeQuery() -> SQLQueryExpression<T> {
        let values = T.TableColumns.allColumns.map { column in
          let value = record.encryptedValues[column.name]
          
          if let asset = value as? CKAsset,
             let data = try? asset.fileURL.map({ try dataManager.load($0) }) {
            return data.queryFragment
          }
          
          if let value {
            return value.queryFragment
          }
          
          return "NULL"
        }
        
        return #sql("SELECT \(values.joined(separator: ", "))")
      }
      
      let query = makeQuery()
      let row = T(queryOutput: try query.fetchOne(db)!)
      
      var modificationTimes: [PartialKeyPath<T>: Int64] = [:]
      for column in T.TableColumns.writableColumns {
        func open<Root, Value>(_ column: some WritableTableColumnExpression<Root, Value>) {
          let keyPath = column.keyPath as! PartialKeyPath<T>
          modificationTimes[keyPath] = record.encryptedValues[at: column.name]
        }
        open(column)
      }
      
      self.init(
        row: row,
        modificationTimes: modificationTimes
      )
    }
    
    /// Returns the modification timestamp for the given column.
    package func modificationTime(for column: PartialKeyPath<T>) -> Int64 {
      return modificationTimes[column] ?? -1
    }
  }

  @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
  extension RowVersion: CustomDumpReflectable {
    package var customDumpMirror: Mirror {
      var children: [(label: String?, value: Any)] = []
      for column in T.TableColumns.writableColumns {
        func open<Root, Value>(_ column: some WritableTableColumnExpression<Root, Value>) {
          let keyPath = column.keyPath as! KeyPath<T, Value.QueryOutput>
          let value = row[keyPath: keyPath]
          let time = modificationTime(for: keyPath)
          children.append((column.name, TimestampedValue(value: value, modificationTime: time)))
        }
        open(column)
      }
      return Mirror(row, children: children, displayStyle: .struct)
    }
  }

  private struct TimestampedValue: CustomDumpStringConvertible {
    let value: Any
    let modificationTime: Int64
    var customDumpDescription: String { "\(formatValue(value)) @\(modificationTime)" }

    private func formatValue(_ value: Any) -> String {
      let mirror = Mirror(reflecting: value)
      if mirror.displayStyle == .optional {
        guard let child = mirror.children.first else { return "nil" }
        return formatValue(child.value)
      }
      if value is any StringProtocol {
        return "\"\(value)\""
      }
      return "\(value)"
    }
  }

  /// Compares values using their database representation (`QueryBinding`), which eliminates
  /// the need for `Equatable` conformance and efficiently handles special cases.
  func areEqual<Value: QueryRepresentable & QueryBindable>(
    _ lhs: Value.QueryOutput,
    _ rhs: Value.QueryOutput,
    as: Value.Type
  ) -> Bool {
    let lhsBinding = Value(queryOutput: lhs).queryBinding
    let rhsBinding = Value(queryOutput: rhs).queryBinding
    
    switch (lhsBinding, rhsBinding) {
    case (.blob(let lhsValue), .blob(let rhsValue)):
      return lhsValue.sha256 == rhsValue.sha256
    case (.bool(let lhsValue), .bool(let rhsValue)):
      return lhsValue == rhsValue
    case (.double(let lhsValue), .double(let rhsValue)):
      return lhsValue == rhsValue
    case (.date(let lhsValue), .date(let rhsValue)):
      return lhsValue == rhsValue
    case (.int(let lhsValue), .int(let rhsValue)):
      return lhsValue == rhsValue
    case (.null, .null):
      return true
    case (.text(let lhsValue), .text(let rhsValue)):
      return lhsValue == rhsValue
    case (.uint(let lhsValue), .uint(let rhsValue)):
      return lhsValue == rhsValue
    case (.uuid(let lhsValue), .uuid(let rhsValue)):
      return lhsValue.uuidString.lowercased() == rhsValue.uuidString.lowercased()
    case (.invalid(let error), _), (_, .invalid(let error)):
      reportIssue(error)
      return false
    default:
      return false
    }
  }
#endif
