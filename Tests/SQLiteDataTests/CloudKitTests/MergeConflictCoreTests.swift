#if canImport(CloudKit)
  import CloudKit
  import Foundation
  import InlineSnapshotTesting
  import SQLiteData
  import StructuredQueriesTestSupport
  import Testing

  extension BaseCloudKitTests {
    @MainActor
    @Suite(.attachMetadatabase)
    final class MergeConflictCoreTests: BaseCloudKitTests, @unchecked Sendable {

      // MARK: - RowVersion

      @Test func rowVersion_initWithModificationTimes() {
        let version = RowVersion(
          row: Post(id: 1, title: "My Post"),
          modificationTimes: [
            \.title: 60,
            \.isPublished: 0,
          ]
        )

        #expect(version.row.title == "My Post")
        #expect(version.modificationTime(for: \.title) == 60)
        #expect(version.modificationTime(for: \.isPublished) == 0)
        #expect(version.modificationTime(for: \.body) == -1)
      }

      @Test func rowVersion_initClientRow() {
        let ancestor = RowVersion(
          row: Post(id: 1, title: ""),
          modificationTimes: [
            \.title: 30,
            \.body: 30,
            \.isPublished: 0,
          ]
        )

        let client = RowVersion(
          clientRow: Post(id: 1, title: "My Post"),
          userModificationTime: 60,
          ancestorVersion: ancestor
        )

        // Changed field gets client time
        #expect(client.modificationTime(for: \.title) == 60)
        // Unchanged fields inherit ancestor time
        #expect(client.modificationTime(for: \.body) == 30)
        #expect(client.modificationTime(for: \.isPublished) == 0)
      }

      @Test func rowVersion_initFromRecord() throws {
        let record = CKRecord(recordType: "posts")
        record.setValue(1, forKey: "id", at: 0)
        record.setValue("My Post", forKey: "title", at: 60)
        record.removeValue(forKey: "body", at: 0)
        record.setValue(false, forKey: "isPublished", at: 30)

        let version = try userDatabase.read { db in
          try RowVersion<Post>(from: record, db: db)
        }

        #expect(version.row == Post(id: 1, title: "My Post"))

        #expect(version.modificationTime(for: \.id) == 0)
        #expect(version.modificationTime(for: \.title) == 60)
        #expect(version.modificationTime(for: \.body) == 0)
        #expect(version.modificationTime(for: \.isPublished) == 30)
      }

      // MARK: - MergeConflict

      @Test func mergeConflict_mergedValues_canonicalConflict() {
        let conflict = MergeModel.makeCanonicalConflict()

        // Scenario 1: No changes
        #expect(conflict.mergedValue(for: \.field1, policy: .latest) == "foo")
        // Scenario 2: Client-only change
        #expect(conflict.mergedValue(for: \.field2, policy: .latest) == "bar")
        // Scenario 3: Server-only change
        #expect(conflict.mergedValue(for: \.field3, policy: .latest) == "baz")
        // Scenario 4: Both changed, server newer
        #expect(conflict.mergedValue(for: \.field4, policy: .latest) == "baz")
        // Scenario 5: Both changed, client newer
        #expect(conflict.mergedValue(for: \.field5, policy: .latest) == "bar")
        // Scenario 6: Both changed, equal timestamps (server wins)
        #expect(conflict.mergedValue(for: \.field6, policy: .latest) == "baz")
        // Scenario 7: Both changed, same value
        #expect(conflict.mergedValue(for: \.field7, policy: .latest) == "bar")
      }
        
      @Test func mergeConflict_resolutionRoundtrip_canonicalConflict() throws {
        try userDatabase.write { db in
          try #sql(
            """
            CREATE TABLE "mergeModels" (
              "id" INTEGER PRIMARY KEY NOT NULL,
              "field1" TEXT NOT NULL,
              "field2" TEXT NOT NULL,
              "field3" TEXT NOT NULL,
              "field4" TEXT NOT NULL,
              "field5" TEXT NOT NULL,
              "field6" TEXT NOT NULL,
              "field7" TEXT NOT NULL
            )
            """
          ).execute(db)
          
          let conflict = MergeModel.makeCanonicalConflict()
          try MergeModel.insert { conflict.client.row }.execute(db)
          
          let query = #sql(conflict.makeUpdateQuery(), as: Void.self)
          
          assertInlineSnapshot(of: query, as: .sql) {
            """
            UPDATE "mergeModels"
            SET "field1" = 'foo', "field2" = 'bar', "field3" = 'baz', "field4" = 'baz', "field5" = 'bar', "field6" = 'baz', "field7" = 'bar'
            WHERE ("mergeModels"."id") = (0)
            """
          }

          try query.execute(db)
          let merged = try MergeModel.fetchOne(db)!

          #expect(merged == MergeModel(
            id: 0,
            field1: "foo",
            field2: "bar",
            field3: "baz",
            field4: "baz",
            field5: "bar",
            field6: "baz",
            field7: "bar"
          ))
        }
      }
      
      @Test func mergeConflict_resolutionRoundtrip_customMergePolicies() throws {
        typealias Post = Post_CustomMergeConflictResolvable
        
        try userDatabase.write { db in
          try #sql(
            """
            CREATE TABLE "customPosts" (
              "id" INTEGER PRIMARY KEY NOT NULL,
              "title" TEXT NOT NULL DEFAULT '',
              "likes" INTEGER NOT NULL DEFAULT 0,
              "tags" TEXT NOT NULL DEFAULT '[]'
            ) STRICT
            """
          ).execute(db)
          
          let conflict = MergeConflict(
            ancestor: RowVersion(
              row: Post(id: 0, title: "Hello", likes: 10, tags: ["bar", "foo"]),
              modificationTimes: [\.title: 0, \.likes: 0, \.tags: 0]
            ),
            server: RowVersion(
              row: Post(id: 0, title: "Hello from server", likes: 13, tags: ["foo"]),
              modificationTimes: [\.title: 60, \.likes: 60, \.tags: 60]
            ),
            client: RowVersion(
              row: Post(id: 0, title: "Hello from client", likes: 12, tags: ["foo", "baz"]),
              modificationTimes: [\.title: 30, \.likes: 30, \.tags: 30]
            )
          )
          
          try Post.insert { conflict.client.row }.execute(db)

          try #sql(conflict.makeUpdateQuery()).execute(db)
          let merged = try Post.fetchOne(db)!

          // `FieldMergePolicy.latest` (default): "Hello from server" (server newer)
          #expect(merged.title == "Hello from server")
          // `FieldMergePolicy.counter`: 10 + (13 - 10) + (12 - 10) = 15
          #expect(merged.likes == 15)
          // `FieldMergePolicy.set`: kept "foo", server removed "bar", client added "baz"
          #expect(merged.tags == ["foo", "baz"])
        }
      }

      // MARK: - ReconciliationConflict
      //
      // Unit-level coverage of the two-way reconciliation primitive. End-to-end coverage
      // through the SyncEngine for the no-ancestor case lives in `MergeConflictTests`
      // under the `reconciliation_*` tests.

      @Test func reconciliationConflict_reconciledValues_clientNewer() {
        let conflict = ReconciliationConflict(
          server: RowVersion(
            row: Post(id: 1, title: "Server title", body: "Server body"),
            modificationTimes: [\.title: 30, \.body: 30, \.isPublished: 30]
          ),
          client: RowVersion(
            row: Post(id: 1, title: "Client title", body: "Client body"),
            modificationTimes: [\.title: 60, \.body: 60, \.isPublished: 60]
          )
        )

        #expect(conflict.reconciledValue(for: \.title, policy: .latest) == "Client title")
        #expect(conflict.reconciledValue(for: \.body, policy: .latest) == "Client body")
      }

      @Test func reconciliationConflict_reconciledValues_serverNewer() {
        let conflict = ReconciliationConflict(
          server: RowVersion(
            row: Post(id: 1, title: "Server title", body: "Server body"),
            modificationTimes: [\.title: 60, \.body: 60, \.isPublished: 60]
          ),
          client: RowVersion(
            row: Post(id: 1, title: "Client title", body: "Client body"),
            modificationTimes: [\.title: 30, \.body: 30, \.isPublished: 30]
          )
        )

        #expect(conflict.reconciledValue(for: \.title, policy: .latest) == "Server title")
        #expect(conflict.reconciledValue(for: \.body, policy: .latest) == "Server body")
      }

      @Test func reconciliationConflict_reconciledValues_equalTimestamps_serverWins() {
        let conflict = ReconciliationConflict(
          server: RowVersion(
            row: Post(id: 1, title: "Server title"),
            modificationTimes: [\.title: 60]
          ),
          client: RowVersion(
            row: Post(id: 1, title: "Client title"),
            modificationTimes: [\.title: 60]
          )
        )

        #expect(conflict.reconciledValue(for: \.title, policy: .latest) == "Server title")
      }

      @Test func reconciliationConflict_reconciledValues_sameValue() {
        let conflict = ReconciliationConflict(
          server: RowVersion(
            row: Post(id: 1, title: "Shared title"),
            modificationTimes: [\.title: 60]
          ),
          client: RowVersion(
            row: Post(id: 1, title: "Shared title"),
            modificationTimes: [\.title: 30]
          )
        )

        // Identical values short-circuit the policy.
        #expect(conflict.reconciledValue(for: \.title, policy: .latest) == "Shared title")
      }

      @Test func reconciliationConflict_makeUpdateQuery_isNilForPrimaryKeyOnlyTables() {
        // A table whose only writable column is the primary key has no meaningful merge:
        // there is nothing to assign. `makeUpdateQuery()` returns nil rather than emit
        // an UPDATE with an empty SET clause.
        let conflict = ReconciliationConflict(
          server: RowVersion(
            row: Tag(title: "Swift"),
            modificationTimes: [\.title: 60]
          ),
          client: RowVersion(
            row: Tag(title: "Swift"),
            modificationTimes: [\.title: 30]
          )
        )

        #expect(conflict.makeUpdateQuery() == nil)
      }
    }
  }

  @Table("customPosts")
  private struct Post_CustomMergeConflictResolvable: Equatable {
    let id: Int
    var title: String
    var likes: Int
    @Column(as: Set<String>.JSONRepresentation.self)
    var tags: Set<String>
  }

  extension Post_CustomMergeConflictResolvable: CustomMergeConflictResolvable {
    static var mergePolicies: MergePolicyRegistry<Self> {
      MergePolicyRegistry<Self> {
        $0[\.likes] = .counter
        $0[\.tags] = .set
      }
    }
  }

  @Table
  private struct MergeModel: Equatable {
    let id: Int
    var field1: String
    var field2: String
    var field3: String
    var field4: String
    var field5: String
    var field6: String
    var field7: String
  }

  extension MergeModel {
    /// Creates a three-way merge conflict covering all seven canonical merge scenarios.
    fileprivate static func makeCanonicalConflict() -> MergeConflict<Self> {
      MergeConflict(
        ancestor: RowVersion(
          row: MergeModel(
            id: 0,
            field1: "foo",
            field2: "foo",
            field3: "foo",
            field4: "foo",
            field5: "foo",
            field6: "foo",
            field7: "foo"
          ),
          modificationTimes: [
            \.field1: 0,
            \.field2: 0,
            \.field3: 0,
            \.field4: 0,
            \.field5: 0,
            \.field6: 0,
            \.field7: 0,
          ]
        ),
        server: RowVersion(
          row: MergeModel(
            id: 0,
            field1: "foo",
            field2: "foo",
            field3: "baz",
            field4: "baz",
            field5: "baz",
            field6: "baz",
            field7: "bar"
          ),
          modificationTimes: [
            \.field1: 0,
            \.field2: 0,
            \.field3: 60,
            \.field4: 60,
            \.field5: 30,
            \.field6: 60,
            \.field7: 60,
          ]
        ),
        client: RowVersion(
          row: MergeModel(
            id: 0,
            field1: "foo",
            field2: "bar",
            field3: "foo",
            field4: "bar",
            field5: "bar",
            field6: "bar",
            field7: "bar"
          ),
          modificationTimes: [
            \.field1: 0,
            \.field2: 60,
            \.field3: 0,
            \.field4: 30,
            \.field5: 60,
            \.field6: 60,
            \.field7: 30,
          ]
        )
      )
    }
  }
#endif
