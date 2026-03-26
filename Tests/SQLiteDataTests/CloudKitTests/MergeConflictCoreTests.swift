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
        // Scenario 6: Both changed, equal timestamps (client wins)
        #expect(conflict.mergedValue(for: \.field6, policy: .latest) == "bar")
        // Scenario 7: Both changed, same value
        #expect(conflict.mergedValue(for: \.field7, policy: .latest) == "bar")
      }
        
      @Test func mergeConflict_resolutionRoundtrip() throws {
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
            SET "field1" = 'foo', "field2" = 'bar', "field3" = 'baz', "field4" = 'baz', "field5" = 'bar', "field6" = 'bar', "field7" = 'bar'
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
            field6: "bar",
            field7: "bar"
          ))
        }
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
