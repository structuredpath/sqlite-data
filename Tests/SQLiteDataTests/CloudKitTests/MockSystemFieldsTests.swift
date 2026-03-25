#if canImport(CloudKit)
  import CloudKit
  import SQLiteData
  import Testing

  @Suite
  struct MockSystemFieldsTests {
    @Test func modificationDateOverride() {
      let record = CKRecord(recordType: "record", recordID: CKRecord.ID(recordName: "A"))
      #expect(record.modificationDate == nil)

      record._modificationDate = Date(timeIntervalSinceReferenceDate: 1)
      #expect(record.modificationDate == Date(timeIntervalSinceReferenceDate: 1))
    }

    @Test func recordChangeTagOverride() {
      let record = CKRecord(recordType: "record", recordID: CKRecord.ID(recordName: "A"))
      #expect(record.recordChangeTag == nil)

      record._recordChangeTag = "ab"
      #expect(record.recordChangeTag == "ab")
    }

    @Test func copyPreservesMockSystemFields() {
      let record = CKRecord(recordType: "record", recordID: CKRecord.ID(recordName: "A"))
      record._recordChangeTag = "ab"
      record._modificationDate = Date(timeIntervalSinceReferenceDate: 1)

      let copy = record.copy() as! CKRecord
      #expect(copy.recordChangeTag == "ab")
      #expect(copy.modificationDate == Date(timeIntervalSinceReferenceDate: 1))
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func systemFieldsRepresentationRoundtrip() throws {
      let record = CKRecord(recordType: "record", recordID: CKRecord.ID(recordName: "A"))
      record._recordChangeTag = "ab"
      record._modificationDate = Date(timeIntervalSinceReferenceDate: 1)

      let representation = CKRecord.SystemFieldsRepresentation(queryOutput: record)
      let result = try #require(CKRecord.SystemFieldsRepresentation(queryBinding: representation.queryBinding))

      #expect(result.queryOutput._recordChangeTag == "ab")
      #expect(result.queryOutput._modificationDate == Date(timeIntervalSinceReferenceDate: 1))
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func allFieldsRepresentationRoundtrip() throws {
      let record = CKRecord(recordType: "record", recordID: CKRecord.ID(recordName: "A"))
      record._recordChangeTag = "ab"
      record._modificationDate = Date(timeIntervalSinceReferenceDate: 1)

      let representation = CKRecord._AllFieldsRepresentation(queryOutput: record)
      let result = try #require(CKRecord._AllFieldsRepresentation(queryBinding: representation.queryBinding))

      #expect(result.queryOutput._recordChangeTag == "ab")
      #expect(result.queryOutput._modificationDate == Date(timeIntervalSinceReferenceDate: 1))
    }
      
    @Test func isNewerChangeTag() {
      #expect("0".isNewerChangeTag(than: nil))
      
      #expect(!"0".isNewerChangeTag(than: "0"))
      #expect(!"z".isNewerChangeTag(than: "z"))
      
      #expect("1".isNewerChangeTag(than: "0"))
      #expect(!"0".isNewerChangeTag(than: "1"))
      #expect("a".isNewerChangeTag(than: "9"))
      #expect(!"9".isNewerChangeTag(than: "a"))
      #expect("z".isNewerChangeTag(than: "a"))
      
      #expect("10".isNewerChangeTag(than: "z"))
      #expect(!"z".isNewerChangeTag(than: "10"))
      #expect("100".isNewerChangeTag(than: "zz"))
      #expect(!"zz".isNewerChangeTag(than: "100"))
    }
  }
#endif
