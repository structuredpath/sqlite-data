#if canImport(CloudKit)
  import CloudKit
  import IssueReporting
  import ObjectiveC

  extension CKRecord {
    package var _modificationDate: Date? {
      get {
        objc_getAssociatedObject(self, &modificationDateKey) as? Date
      }
      set {
        installMockSystemFieldOverridesOnce()
        objc_setAssociatedObject(self, &modificationDateKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
      }
    }

    package var _recordChangeTag: String? {
      get {
        objc_getAssociatedObject(self, &recordChangeTagKey) as? String
      }
      set {
        installMockSystemFieldOverridesOnce()
        objc_setAssociatedObject(self, &recordChangeTagKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
      }
    }

    @objc fileprivate dynamic func _swizzled_modificationDate() -> Date? {
      if let override = objc_getAssociatedObject(self, &modificationDateKey) as? Date {
        return override
      }
      return self._swizzled_modificationDate()
    }

    @objc fileprivate dynamic func _swizzled_recordChangeTag() -> String? {
      if let override = objc_getAssociatedObject(self, &recordChangeTagKey) as? String {
        return override
      }
      return self._swizzled_recordChangeTag()
    }

    @objc fileprivate dynamic func _swizzled_copy(with zone: NSZone?) -> Any {
      let copy = self._swizzled_copy(with: zone)
      if let copy = copy as? CKRecord {
        copy._recordChangeTag = self._recordChangeTag
        copy._modificationDate = self._modificationDate
      }
      return copy
    }
  }

  private func installMockSystemFieldOverridesOnce() {
    _ = token
  }

  private let token: Void = {
    guard
      let originalModificationDate = class_getInstanceMethod(
        CKRecord.self,
        #selector(getter: CKRecord.modificationDate)
      ),
      let swizzledModificationDate = class_getInstanceMethod(
        CKRecord.self,
        #selector(CKRecord._swizzled_modificationDate)
      )
    else {
      reportIssue("Failed to swizzle CKRecord.modificationDate")
      return
    }
    method_exchangeImplementations(originalModificationDate, swizzledModificationDate)

    guard
      let originalRecordChangeTag = class_getInstanceMethod(
        CKRecord.self,
        #selector(getter: CKRecord.recordChangeTag)
      ),
      let swizzledRecordChangeTag = class_getInstanceMethod(
        CKRecord.self,
        #selector(CKRecord._swizzled_recordChangeTag)
      )
    else {
      reportIssue("Failed to swizzle CKRecord.recordChangeTag")
      return
    }
    method_exchangeImplementations(originalRecordChangeTag, swizzledRecordChangeTag)

    guard
      let originalCopy = class_getInstanceMethod(
        CKRecord.self,
        #selector(CKRecord.copy(with:))
      ),
      let swizzledCopy = class_getInstanceMethod(
        CKRecord.self,
        #selector(CKRecord._swizzled_copy(with:))
      )
    else {
      reportIssue("Failed to swizzle CKRecord.copy(with:)")
      return
    }
    method_exchangeImplementations(originalCopy, swizzledCopy)
  }()

  nonisolated(unsafe) private var modificationDateKey: UInt8 = 0
  nonisolated(unsafe) private var recordChangeTagKey: UInt8 = 0
#endif
