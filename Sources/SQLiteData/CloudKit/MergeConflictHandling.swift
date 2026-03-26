#if canImport(CloudKit)
  import CloudKit
  import CustomDump
  import IssueReporting
  import StructuredQueriesCore

  /// A snapshot of a table row together with per-field modification timestamps,
  /// used for three-way merge conflict resolution.
  @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
  struct RowVersion<T: PrimaryKeyedTable> {
    /// The represented row.
    let row: T
    /// Per-field modification timestamps keyed by column key path.
    private let modificationTimes: [PartialKeyPath<T>: Int64]
    
    init(
      row: T,
      modificationTimes: [PartialKeyPath<T>: Int64]
    ) {
      self.row = row
      self.modificationTimes = modificationTimes
    }
    
    /// Creates a client row version by deriving per-field modification timestamps from the
    /// ancestor: changed fields get the client's modification time, unchanged fields inherit
    /// the ancestor's timestamp.
    init(
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
    init(from record: CKRecord, db: Database) throws {
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
    func modificationTime(for column: PartialKeyPath<T>) -> Int64 {
      return modificationTimes[column] ?? -1
    }
  }

  @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
  extension RowVersion: CustomDumpReflectable {
    var customDumpMirror: Mirror {
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
