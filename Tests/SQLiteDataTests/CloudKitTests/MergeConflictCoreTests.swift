#if canImport(CloudKit)
  import CloudKit
  import Foundation
  import SQLiteData
  import Testing
  import TestLocals

  extension BaseCloudKitTests {
    @MainActor
    @Suite($attachMetadatabase.set(true))
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
    }
  }
#endif
