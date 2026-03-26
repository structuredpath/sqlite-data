#if canImport(CloudKit)
  package import CloudKit
  import CustomDump
  import IssueReporting
  import StructuredQueriesCore

  package struct FieldMergePolicy<Value> {
    package let merge: (
      _ ancestor: FieldVersion<Value>,
      _ server: FieldVersion<Value>,
      _ client: FieldVersion<Value>
    ) -> Value
  }

  extension FieldMergePolicy {
    /// Last-edit-wins merge policy that picks the edited value with the newer modification
    /// timestamp (ties favor the client).
    package static var latest: Self {
      Self { _, server, client in
        server.modificationTime > client.modificationTime ? server.value : client.value
      }
    }
  }

  package struct FieldVersion<Value> {
    /// The field value.
    package let value: Value
    /// The timestamp at which this field was last modified.
    package let modificationTime: Int64
  }

  /// A three-way merge conflict between an ancestor, server, and client version of a row.
  @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
  package struct MergeConflict<T: PrimaryKeyedTable> where T.TableColumns.PrimaryColumn: WritableTableColumnExpression {
    package let ancestor: RowVersion<T>
    package let server: RowVersion<T>
    package let client: RowVersion<T>

    /// Resolves a field conflict by key path, delegating to `mergedValue(column:policy:)`.
    package func mergedValue<C: WritableTableColumnExpression>(
      for keyPath: some KeyPath<T.TableColumns, C>,
      policy: FieldMergePolicy<C.QueryValue.QueryOutput>
    ) -> C.QueryValue.QueryOutput where C.Root == T {
      mergedValue(
        column: T.columns[keyPath: keyPath],
        policy: policy
      )
    }
    
    /// Resolves a field conflict by column, applying the given merge policy. Falls through to
    /// the client or server value when only one side changed.
    package func mergedValue<C: WritableTableColumnExpression>(
      column: C,
      policy: FieldMergePolicy<C.QueryValue.QueryOutput>
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

    /// Generates an UPDATE statement that resolves the merge conflict using the `.latest` policy.
    package func makeUpdateQuery() -> QueryFragment {
      let assignments = T.TableColumns.writableColumns.compactMap { column in
        func open<Root, Value>(
          _ column: some WritableTableColumnExpression<Root, Value>
        ) -> (column: String, value: QueryBinding)? {
          guard column.name != T.primaryKey.name else { return nil }
          let column = column as! (any WritableTableColumnExpression<T, Value>)
          let merged = mergedValue(column: column, policy: .latest)
          return (column: column.name, value: Value(queryOutput: merged).queryBinding)
        }
        return open(column)
      }

      return """
        UPDATE \(T.self)
        SET \(assignments.map { "\(quote: $0.column) = \($0.value)" }.joined(separator: ", "))
        WHERE (\(T.primaryKey)) = (\(T.PrimaryKey(queryOutput: ancestor.row.primaryKey)))
        """
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
