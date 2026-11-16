import Foundation
import SwiftUI
import CoreGraphics
import UniformTypeIdentifiers

/// FramesViewModel (§2.3): quản lý khung — nhập, danh mục, tìm kiếm, yêu thích, thao tác hàng loạt.
@MainActor
public final class FramesViewModel: ObservableObject {
    @Published public private(set) var frames: [FrameCardModel] = []
    @Published public var searchText = ""
    @Published public var selectedCategoryID: String? = nil   // nil = Tất cả
    @Published public var showFavoritesOnly = false
    @Published public var sortNewest = true
    @Published public var selection: Set<String> = []
    @Published public private(set) var categories: [Category] = []
    @Published public var importQueueURLs: [URL] = []
    @Published public var showImportSheet: Bool = false

    public let env: AppEnvironment

    public init(env: AppEnvironment) { self.env = env }

    public func reload() {
        categories = (try? env.frames.listCategories()) ?? []
        var list = (try? env.frames.listFrames()) ?? []
        list.sort { sortNewest ? $0.updatedAtMs > $1.updatedAtMs : $0.updatedAtMs < $1.updatedAtMs }
        var models: [FrameCardModel] = []
        for frame in list {
            if selectedCategoryID == "__favorites__" {
                // Sidebar "Yêu thích" (P2-18) — sentinel riêng, không phải categoryID
                if !frame.isFavorite { continue }
            } else if selectedCategoryID == "unclassified" {
                if frame.categoryID != nil { continue }
            } else if let cid = selectedCategoryID, frame.categoryID != cid { continue }
            if !searchText.isEmpty, !frame.name.localizedCaseInsensitiveContains(searchText) { continue }
            let slots = frame.currentRevisionID.flatMap { (try? env.frames.getSlots(revisionID: $0)) ?? [] } ?? []
            let revID = frame.currentRevisionID ?? frame.id
            let thumb = env.frameThumbnails.cachedThumbnail(frameID: frame.id, revisionID: revID)
            models.append(FrameCardModel(frame: frame, thumbnail: thumb, slotCount: slots.count))
        }
        frames = models
        selection = selection.filter { id in models.contains { $0.frame.id == id } }
    }

    public func generateThumbnailIfNeeded(for model: FrameCardModel) -> Data? {
        if let t = model.thumbnail { return t }
        guard let revID = model.frame.currentRevisionID else { return nil }
        if let cached = env.frameThumbnails.cachedThumbnail(frameID: model.frame.id, revisionID: revID) {
            return cached
        }
        // Kích hoạt request và cập nhật khi hoàn thành
        let fid = model.frame.id
        Task { @MainActor [weak self] in
            if let data = await self?.env.frameThumbnails.requestThumbnail(frameID: fid, revisionID: revID) {
                if let idx = self?.frames.firstIndex(where: { $0.id == fid && $0.frame.currentRevisionID == revID }) {
                    self?.frames[idx].thumbnail = data
                }
            }
        }
        return nil
    }

    // MARK: - Import (§6.2)

    public func importImages(urls: [URL]) async {
        var ok = 0, fail = 0
        var savedToUnclassified = false
        var committedIDs: [String] = []

        // D2-A04: Chuẩn hóa lựa chọn categoryID tại điểm vào nhập.
        // Tất cả (nil), Yêu thích ("__favorites__") và Chưa phân loại ("unclassified") không truyền ID danh mục.
        var targetCategoryID: String? = nil
        if let sel = selectedCategoryID, sel != "__favorites__" && sel != "unclassified" {
            // Xác nhận danh mục thật còn active trong DB
            let activeCats = (try? env.frames.listCategories()) ?? []
            if activeCats.contains(where: { $0.id == sel && $0.lifecycle == .active }) {
                targetCategoryID = sel
            } else {
                // Danh mục đã bị xóa trong lúc picker mở
                targetCategoryID = nil
                savedToUnclassified = true
            }
        }

        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard Self.validateMagicBytes(data) else { throw AppError.frameFileCorrupt }
                // Xác định định dạng thật qua byte nội dung (§5.1, P1-03)
                let isPNG = data.starts(with: Data([0x89, 0x50, 0x4E, 0x47]))
                let mediaType = isPNG ? "image/png" : "image/jpeg"
                let name = url.deletingPathExtension().lastPathComponent
                let hasAlpha = isPNG && Self.hasAlphaChannel(data: data)
                // PNG có alpha mặc định làm lớp phủ, PNG không alpha/JPG làm nền (§5.1)
                let role: AssetKind = hasAlpha ? .frameForeground : .frameBackground
                let newFrame = try env.frames.createFrame(name: name, imageData: data, mediaType: mediaType,
                                               role: role, categoryID: targetCategoryID)
                committedIDs.append(newFrame.id)
                ok += 1
            } catch {
                fail += 1
                Log.app.error("Import khung lỗi: \(error.localizedDescription, privacy: .public)")
            }
        }
        reload()
        EventBus.shared.post(.frameLibraryChanged(frameID: nil))
        if let firstID = committedIDs.first, env.route == .frames {
            env.openFrameEditor(frameID: firstID)
        }
        if fail > 0 {
            env.showToast("Nhập: \(ok) thành công, \(fail) lỗi (E-FRM-01 nếu tệp hỏng)", kind: .warning)
        } else if ok > 0 {
            if savedToUnclassified {
                env.showToast("Đã nhập \(ok) khung vào 'Chưa phân loại' (danh mục trước đó không còn tồn tại)")
            } else if selectedCategoryID == "__favorites__" {
                env.showToast("Đã nhập \(ok) khung vào 'Chưa phân loại' (khung mới chưa nằm trong Yêu thích)")
            } else {
                env.showToast("Đã nhập \(ok) khung — khung chưa thiết lập cần mở Frame Editor")
            }
        }
    }

    /// Kiểm tra content type + magic bytes (§6.2).
    nonisolated public static func validateMagicBytes(_ data: Data) -> Bool {
        if data.starts(with: Data([0x89, 0x50, 0x4E, 0x47])) { return true }           // PNG
        if data.count > 2, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 { return true } // JPEG
        return false
    }

    /// Kiểm tra xem ảnh có kênh alpha trong suốt hay không (§5.1, DEV-P1-01)
    nonisolated public static func hasAlphaChannel(data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return false }
        let alpha = cg.alphaInfo
        return alpha == .first || alpha == .last || alpha == .premultipliedFirst || alpha == .premultipliedLast
    }

    public func importViaOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg]
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            Task { @MainActor in
                self.importQueueURLs = panel.urls
                self.showImportSheet = true
            }
        }
    }

    // MARK: - Actions (§2.3 inspector)

    public func rename(_ frameID: String, to name: String) {
        do {
            try env.frames.renameFrame(id: frameID, to: name)
            reload()
        } catch { env.showToast("\((error as? AppError)?.message ?? "")", kind: .warning) }
    }

    public func toggleFavorite(_ frameID: String) {
        guard let f = try? env.frames.getFrame(id: frameID) else { return }
        try? env.frames.setFavorite(id: frameID, !f.isFavorite)
        reload()
    }

    public func duplicate(_ frameID: String) {
        do {
            _ = try env.frames.duplicateFrame(id: frameID)
            reload()
            env.showToast("Đã nhân bản khung")
        } catch { env.showToast("Nhân bản lỗi", kind: .warning) }
    }

    public func moveToCategory(_ frameIDs: [String], categoryID: String?) {
        for id in frameIDs {
            try? env.frames.setCategory(frameID: id, categoryID: categoryID)
        }
        reload()
        EventBus.shared.post(.categoryChanged)
    }

    public func trash(_ frameID: String) {
        do {
            try env.trashService.trashFrame(frameID: frameID)
            reload()
            env.showToast("Đã chuyển vào Thùng rác")
        } catch { env.showToast("\((error as? AppError)?.message ?? "")", kind: .warning) }
    }

    public func trashSelection() {
        for id in selection { trash(id) }
        selection.removeAll()
    }

    public func createCategory(named name: String) {
        do {
            _ = try env.frames.createCategory(name: name)
            reload()
        } catch { env.showToast("\((error as? AppError)?.message ?? "")", kind: .warning) }
    }

    public func trashCategory(_ categoryID: String) {
        do {
            try env.trashService.trashCategory(categoryID: categoryID)
            if selectedCategoryID == categoryID { selectedCategoryID = nil }
            reload()
            env.showToast("Danh mục vào Thùng rác; các khung chuyển Chưa phân loại")
        } catch { env.showToast("\((error as? AppError)?.message ?? "")", kind: .warning) }
    }

    nonisolated(unsafe) public static var onBeforeFinalExportWriteHook: (() -> Void)? = nil

    public func favoriteSelection() {
        let targets = Array(selection)
        guard !targets.isEmpty else { return }
        do {
            let changed = try env.frames.setFavorites(frameIDs: targets, isFavorite: true)
            if changed > 0 {
                reload()
                env.showToast("Đã thêm \(changed) khung vào Yêu thích")
            }
        } catch {
            env.showToast("Yêu thích lỗi: \((error as? AppError)?.message ?? error.localizedDescription)", kind: .warning)
        }
    }

    /// Xuất gói: kiểm tra vòng đời active trước/sau khi chuẩn bị ZIP (§4, FRM-02, F04, F05).
    public func exportPack(frameIDs: [String], name: String, saveTo url: URL) -> Bool {
        guard !frameIDs.isEmpty else {
            env.showToast("Không có khung nào được chọn để xuất", kind: .warning)
            return false
        }
        do {
            // Bước 1 (§4.3, §4.4): Đọc bắt buộc vòng đời active, revision hiện hành và số slot
            struct FrameBaseline {
                let id: String
                let revisionID: String
                let isDraftZeroSlot: Bool
            }
            var baselines: [String: FrameBaseline] = [:]
            var expectedManifestIDs = Set<String>()

            for fid in frameIDs {
                guard let f = try env.frames.getFrame(id: fid), f.lifecycle == .active else {
                    throw AppError.invalidState("Khung '\(fid)' không tồn tại hoặc đã bị xóa/chuyển vào Thùng rác")
                }
                guard let revID = f.currentRevisionID,
                      let _ = try env.frames.getRevision(id: revID) else {
                    throw AppError.invalidState("Khung '\(f.name)' thiếu phiên bản thiết kế hợp lệ")
                }
                let slots = try env.frames.getSlots(revisionID: revID)
                let isZeroSlot = slots.isEmpty
                baselines[fid] = FrameBaseline(id: fid, revisionID: revID, isDraftZeroSlot: isZeroSlot)
                if !isZeroSlot {
                    expectedManifestIDs.insert(fid)
                }
            }

            guard !expectedManifestIDs.isEmpty else {
                throw AppError.invalidState("Không có khung hợp lệ nào để đóng gói (tất cả là bản nháp 0 ô)")
            }

            // Bước 2: Chuẩn bị dữ liệu ZIP
            let packResult = try env.packService.preparePack(name: name, frameIDs: frameIDs)
            let zipData = packResult.data

            // Điểm kiểm soát cho bài thử F05
            Self.onBeforeFinalExportWriteHook?()

            // Bước 3 (§4.5): Kiểm tra sau khi chuẩn bị, ngay trước khi ghi
            // Đọc manifest từ chính dữ liệu ZIP vừa tạo
            let validation = try FramePackService.validate(data: zipData)
            let manifestIDs = Set(validation.manifest.frames.map(\.frameId))
            guard manifestIDs == expectedManifestIDs else {
                throw AppError.invalidState("Manifest không khớp với tập khung dự kiến")
            }

            // Đọc lại toàn bộ ID đã chốt từ DB
            for fid in frameIDs {
                guard let base = baselines[fid] else {
                    throw AppError.invalidState("Khung '\(fid)' không nằm trong mốc kiểm tra")
                }
                guard let f = try env.frames.getFrame(id: fid), f.lifecycle == .active else {
                    throw AppError.invalidState("Khung '\(fid)' đã bị thay đổi hoặc đưa vào Thùng rác trước khi ghi")
                }
                guard let revID = f.currentRevisionID, revID == base.revisionID,
                      let _ = try env.frames.getRevision(id: revID) else {
                    throw AppError.invalidState("Phiên bản hiện hành của khung '\(f.name)' đã thay đổi trước khi ghi")
                }
                let currentSlots = try env.frames.getSlots(revisionID: revID)
                if currentSlots.isEmpty != base.isDraftZeroSlot {
                    throw AppError.invalidState("Phân loại ô ảnh của khung '\(f.name)' đã thay đổi trước khi ghi")
                }
            }

            // Bước 4: Ghi nguyên tử vào tệp đích
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let target = url.pathExtension.lowercased() == "photoframepack" ? url : url.appendingPathExtension("photoframepack")
            try zipData.write(to: target, options: .atomic)

            if packResult.skippedDraftCount > 0 {
                env.showToast("Đã xuất Frame Pack (\(packResult.packedFramesCount) khung, bỏ qua \(packResult.skippedDraftCount) bản nháp)")
            } else {
                env.showToast("Đã xuất Frame Pack (\(packResult.packedFramesCount) khung)")
            }
            return true
        } catch {
            env.showToast("Xuất gói lỗi: \((error as? AppError)?.message ?? error.localizedDescription)", kind: .warning)
            return false
        }
    }
}

struct FrameEditorImportDraft: Identifiable {
    let id = UUID()
    let name: String
    let categoryID: String?
    let data: Data
    let mediaType: String
    let role: AssetKind
    let width: Int
    let height: Int
    let slots: [FrameSlot]
}

/// FrameEditorViewModel (§2.7): draft geometry, undo/redo, validator F-VAL, lưu revision.
@MainActor
public final class FrameEditorViewModel: ObservableObject {
    @Published public private(set) var frame: Frame?
    @Published public private(set) var canvasWidth: Int = 1200
    @Published public private(set) var canvasHeight: Int = 1800
    @Published public private(set) var slots: [FrameSlot] = []
    @Published public private(set) var backgroundAssetID: String?
    @Published public private(set) var foregroundAssetID: String?
    @Published public private(set) var backgroundColorHex: String = "#FFFFFFFF"
    @Published public private(set) var backgroundPlacement: PlacementKind = .aspectFill
    @Published public private(set) var foregroundPlacement: PlacementKind = .aspectFit
    @Published public private(set) var validationIssues: [ValidationIssue] = []
    @Published public var selectedSlotID: String? = nil
    @Published public var hasChanges = false
    @Published public var showGuides = true
    @Published public var snapEnabled = true
    @Published public var zoom: Double = 1.0
    @Published public private(set) var previewImage: CGImage?
    /// Tên khung dạng draft — chỉ rename DB khi save (P3-8c: không ghi DB từng phím,
    /// và "Bỏ thay đổi" không để lại tên mới).
    @Published public var draftName: String = "Khung mới"

    public let env: AppEnvironment
    private var undoStack: [[FrameSlot]] = []
    private var redoStack: [[FrameSlot]] = []
    private var originalRevisionID: String?
    private var originalName: String = ""
    private var explicitWhiteSelected = false
    private var sourceHadExplicitWhite = false
    private var imported: FrameEditorImportDraft?
    /// OwnerKey tạm cho asset nhập trong editor (§6.5). Một phiên editor dùng 1 key,
    /// moveReferences về revision thật khi save.
    private var editorStagingOwnerKey: String = "editor-\(IDFactory.new())"

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public var hasNameChange: Bool {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != originalName
    }

    public var hasAnyChanges: Bool {
        hasChanges || hasNameChange
    }

    public init(env: AppEnvironment) { self.env = env }

    func load(imported draft: FrameEditorImportDraft) {
        guard imported == nil else { return }
        do {
            let asset = try env.assets.store(data: draft.data, mediaType: draft.mediaType,
                                             purpose: draft.role.rawValue, ownerType: "frame_revision",
                                             ownerID: editorStagingOwnerKey)
            imported = draft
            draftName = draft.name
            originalName = draft.name
            canvasWidth = draft.width
            canvasHeight = draft.height
            slots = draft.slots
            if draft.role == .frameForeground {
                foregroundAssetID = asset.id
                foregroundPlacement = .stretchToCanvas
            } else {
                backgroundAssetID = asset.id
            }
            hasChanges = true
            validate()
            regeneratePreview()
        } catch {
            env.showToast("Không thể mở bản nháp: \(error.localizedDescription)", kind: .warning)
        }
    }

    func saveImportedFrame() -> Frame? {
        guard canSave, let imported else { return nil }
        let draft = FrameRevision(frameID: "", revisionNo: 1, canvasWidth: canvasWidth, canvasHeight: canvasHeight,
                                  backgroundAssetID: backgroundAssetID, foregroundAssetID: foregroundAssetID,
                                  backgroundColorHex: backgroundColorHex, backgroundPlacement: backgroundPlacement,
                                  foregroundPlacement: foregroundPlacement)
        do {
            return try env.frames.createConfiguredFrame(name: draftName, categoryID: imported.categoryID,
                                                        draft: draft, slots: slots, stagedOwnerID: editorStagingOwnerKey,
                                                        explicitWhite: explicitWhiteSelected)
        } catch {
            env.showToast("Không thể lưu khung: \(error.localizedDescription)", kind: .warning)
            return nil
        }
    }

    func discardImportedFrame() {
        try? env.assets.removeReferences(ownerType: "frame_revision", ownerID: editorStagingOwnerKey)
    }

    public func load(frameID: String?) {
        if let frameID, let f = try? env.frames.getFrame(id: frameID) {
            frame = f
            draftName = f.name
            originalName = f.name
            originalRevisionID = f.currentRevisionID
            if let revID = f.currentRevisionID, let rev = try? env.frames.getRevision(id: revID) {
                canvasWidth = rev.canvasWidth
                canvasHeight = rev.canvasHeight
                backgroundAssetID = rev.backgroundAssetID
                foregroundAssetID = rev.foregroundAssetID
                backgroundColorHex = rev.backgroundColorHex
                backgroundPlacement = rev.backgroundPlacement
                foregroundPlacement = rev.foregroundPlacement
                slots = (try? env.frames.getSlots(revisionID: revID)) ?? []
                let explicit = (try? env.db.query("SELECT value FROM app_state WHERE key=?", [.text("explicit_white_\(revID)")]).first?["value"]?.stringValue)
                sourceHadExplicitWhite = (explicit == "1" || explicit == "true")
            } else {
                slots = []
                sourceHadExplicitWhite = false
            }
        } else {
            frame = nil
            slots = []
            originalRevisionID = nil
            sourceHadExplicitWhite = false
        }
        explicitWhiteSelected = false
        hasChanges = false
        undoStack.removeAll(); redoStack.removeAll()
        validate()
        regeneratePreview()
    }

    // MARK: - Mutations (một thao tác kéo = một undo §7.4)

    public func beginUndoGroup() {
        undoStack.append(slots)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    public func endUndoGroup(_ newSlots: [FrameSlot]) {
        slots = newSlots
        hasChanges = true
        validate()
    }

    public func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(slots)
        slots = prev
        hasChanges = true
        validate()
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(slots)
        slots = next
        hasChanges = true
        validate()
    }

    public func addSlot(captureIndex: Int? = nil) {
        guard slots.count < 12 else { return }
        beginUndoGroup()
        let nextIndex = captureIndex ?? (slots.count + 1)
        // Đặt slot mới không chồng hoàn toàn slot hiện có
        let y = min(0.05 + Double(slots.count) * 0.12, 0.8)
        let slot = FrameSlot(captureIndex: nextIndex, x: 0.2, y: y, width: 0.6, height: 0.2,
                             zOrder: slots.count, maskType: .rectangle, cornerRadius: 0,
                             defaultCropMode: env.settings.defaultCrop)
        var updated = slots + [slot]
        for i in updated.indices {
            updated[i].zOrder = i
            updated[i].captureIndex = i + 1
        }
        endUndoGroup(updated)
        selectedSlotID = slot.id
    }

    public func duplicateSlot(_ id: String) {
        guard slots.count < 12 else { return }
        guard let slot = slots.first(where: { $0.id == id }) else { return }
        beginUndoGroup()
        var copy = slot
        copy.id = IDFactory.new()
        copy.y = min(slot.y + slot.height + 0.02, 0.98 - slot.height)
        copy.zOrder = slots.count
        var updated = slots + [copy]
        for i in updated.indices {
            updated[i].zOrder = i
            updated[i].captureIndex = i + 1
        }
        endUndoGroup(updated)
        selectedSlotID = copy.id
    }

    public func deleteSlot(_ id: String) {
        guard slots.count > 1 else { return }  // không để canvas 0 slot mà vẫn save (§7.4)
        beginUndoGroup()
        var remaining = slots.filter { $0.id != id }
        for i in remaining.indices {
            remaining[i].zOrder = i
            remaining[i].captureIndex = i + 1
        }
        endUndoGroup(remaining)
        if selectedSlotID == id { selectedSlotID = nil }
    }

    public func reindexSlotsContinuously() {
        beginUndoGroup()
        var s = slots
        for i in s.indices {
            s[i].zOrder = i
            s[i].captureIndex = i + 1
        }
        endUndoGroup(s)
    }

    public func updateSlot(_ slot: FrameSlot) {
        if let idx = slots.firstIndex(where: { $0.id == slot.id }) {
            var s = slots
            s[idx] = slot
            slots = s
            hasChanges = true
            validate()
        }
    }

    /// Chỉnh slot từ inspector: một commit inspector = một undo group (khớp hành vi
    /// kéo canvas §7.4 — trước đây chỉnh inspector không undo được).
    public func updateSlotFromInspector(_ slot: FrameSlot) {
        beginUndoGroup()
        updateSlot(slot)
    }

    public func moveZOrder(_ id: String, up: Bool) {
        guard let idx = slots.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? idx + 1 : idx - 1
        guard slots.indices.contains(target) else { return }
        beginUndoGroup()
        var s = slots
        s.swapAt(idx, target)
        for i in s.indices {
            s[i].zOrder = i
            s[i].captureIndex = i + 1
        }
        endUndoGroup(s)
    }

    public func setCanvas(width: Int, height: Int) {
        canvasWidth = min(max(width, ResourceLimits.canvasMin), ResourceLimits.canvasMax)
        canvasHeight = min(max(height, ResourceLimits.canvasMin), ResourceLimits.canvasMax)
        hasChanges = true
        validate()
        regeneratePreview()
    }

    public func setBackgroundColor(_ hex: String) {
        backgroundColorHex = hex
        explicitWhiteSelected = true
        hasChanges = true
        regeneratePreview()
    }

    public func setPlacement(kind: PlacementKind, isBackground: Bool) {
        if isBackground { backgroundPlacement = kind } else { foregroundPlacement = kind }
        hasChanges = true
        regeneratePreview()
    }

    // MARK: - Import layer (§6.1)

    public func importLayer(url: URL, role: AssetKind) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard FramesViewModel.validateMagicBytes(data) else { throw AppError.frameFileCorrupt }
            let mediaType = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
            // Dùng 1 ownerKey duy nhất cho phiên editor — save() sẽ moveReferences về revision thật.
            let ownerKey = editorStagingOwnerKey
            let asset = try env.assets.store(data: data, mediaType: mediaType,
                                             purpose: role.rawValue, ownerType: "frame_revision", ownerID: ownerKey)
            if role == .frameForeground {
                foregroundAssetID = asset.id
                // JPG foreground không alpha sẽ che toàn bộ → cảnh báo (§7.2)
                if mediaType == "image/jpeg" {
                    env.showToast("Ảnh foreground không có vùng trong suốt — sẽ che toàn bộ ảnh", kind: .warning)
                }
            } else {
                backgroundAssetID = asset.id
            }
            hasChanges = true
            regeneratePreview()
        } catch {
            env.showToast("Nhập lớp lỗi: \((error as? AppError)?.message ?? "")", kind: .warning)
        }
    }

    // MARK: - Validator (§7.5)

    public func validate() {
        var issues = FrameValidator.validate(
            canvasWidth: canvasWidth, canvasHeight: canvasHeight,
            slots: slots,
            hasBackground: backgroundAssetID != nil,
            hasForeground: foregroundAssetID != nil,
            backgroundColorHex: backgroundColorHex)

        // Cảnh báo và chặn lưu nếu lớp phủ kín che toàn bộ vùng ảnh của ô (DEV-P1-01, P1-03)
        if let fgID = foregroundAssetID {
            let isOpaque: Bool = {
                if let data = try? env.assets.loadData(assetID: fgID) {
                    return !FramesViewModel.hasAlphaChannel(data: data)
                }
                return false
            }()
            if isOpaque {
                issues.append(ValidationIssue(
                    code: "F-VAL-09",
                    slotID: nil,
                    message: "Lớp phủ kín (không có vùng trong suốt) sẽ che toàn bộ vùng ảnh của các ô — hãy đổi vai trò sang Lớp nền hoặc chọn ảnh có alpha"
                ))
            }
        }
        validationIssues = issues
    }

    public var canSave: Bool {
        hasAnyChanges && validationIssues.isEmpty && !slots.isEmpty && slots.count <= 12
    }

    // MARK: - Save (§6.5 revision mới, không sửa revision cũ, FRM-01)

    public func save() -> Bool {
        guard canSave, let frame else { return false }
        guard slots.count >= 1 && slots.count <= 12 else { return false }
        let indices = slots.map(\.captureIndex)
        guard Set(indices).count == slots.count, Set(indices) == Set(1...slots.count) else { return false }
        let trimmedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            env.showToast("Tên khung không được để trống", kind: .warning)
            return false
        }
        if !hasChanges && hasNameChange {
            do {
                try env.frames.renameFrame(id: frame.id, to: trimmedName)
                originalName = trimmedName
                EventBus.shared.post(.frameLibraryChanged(frameID: frame.id))
                env.showToast("Đã đổi tên khung")
                return true
            } catch {
                env.showToast("Đổi tên thất bại: \((error as? AppError)?.message ?? "")", kind: .warning)
                return false
            }
        }
        do {
            if hasNameChange && trimmedName != frame.name {
                try env.frames.renameFrame(id: frame.id, to: trimmedName)
                originalName = trimmedName
            }
            var rev = FrameRevision(frameID: frame.id, revisionNo: 1,
                                    canvasWidth: canvasWidth, canvasHeight: canvasHeight,
                                    backgroundAssetID: backgroundAssetID,
                                    foregroundAssetID: foregroundAssetID,
                                    backgroundColorHex: backgroundColorHex,
                                    backgroundPlacement: backgroundPlacement,
                                    foregroundPlacement: foregroundPlacement)
            _ = rev.revisionNo
            rev.geometryVersion = CompositeRenderer.geometryVersion
            let committed = try env.frames.commitRevision(frameID: frame.id, draft: rev, slots: slots)
            try env.frames.setValidationStatus(frameID: frame.id, status: .ready)
            // §6.5: chuyển owner references từ staging key sang revision thật để asset không bị orphan.
            try env.assets.moveReferences(ownerType: "frame_revision",
                                          fromOwnerID: editorStagingOwnerKey,
                                          toOwnerID: committed.id)
            if let bg = rev.backgroundAssetID {
                try? env.assets.addReference(assetID: bg, ownerType: "frame_revision", ownerID: committed.id, purpose: "background")
            }
            if let fg = rev.foregroundAssetID {
                try? env.assets.addReference(assetID: fg, ownerType: "frame_revision", ownerID: committed.id, purpose: "foreground")
            }
            // D2-A09: Ghi dấu hiệu chọn nền rõ ràng nếu người dùng chọn màu hoặc kế thừa từ revision nguồn
            let isWhite = backgroundColorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased().hasPrefix("FFFFFF")
            if isWhite && (explicitWhiteSelected || sourceHadExplicitWhite) {
                try? env.db.run("INSERT OR REPLACE INTO app_state(key, value) VALUES(?, '1')", [.text("explicit_white_\(committed.id)")])
            }
            // Phiên editor tiếp theo (nếu user tiếp tục chỉnh và save lại) dùng key mới.
            editorStagingOwnerKey = "editor-\(IDFactory.new())"
            sourceHadExplicitWhite = isWhite && (explicitWhiteSelected || sourceHadExplicitWhite)
            explicitWhiteSelected = false
            hasChanges = false
            EventBus.shared.post(.frameLibraryChanged(frameID: frame.id))
            env.showToast("Đã lưu khung")
            return true
        } catch {
            env.showToast("Lưu thất bại: \((error as? AppError)?.message ?? "")", kind: .warning)
            return false
        }
    }

    public func regeneratePreview() {
        var assetImages: [String: CGImage] = [:]
        if let bg = backgroundAssetID, let img = try? env.assets.loadImage(assetID: bg) { assetImages[bg] = img }
        if let fg = foregroundAssetID, let img = try? env.assets.loadImage(assetID: fg) { assetImages[fg] = img }
        var sources: [Int: RenderSource] = [:]
        for idx in Set(slots.map(\.captureIndex)) {
            if let s = SampleImageFactory.shared.sample(index: idx, size: CGSize(width: 320, height: 320)) {
                sources[idx] = RenderSource(image: s)
            }
        }
        let snap = FrameSnapshot(sourceFrameID: frame?.id, sourceFrameRevisionID: originalRevisionID,
                                 canvasWidth: canvasWidth, canvasHeight: canvasHeight,
                                 background: backgroundAssetID.map { SnapshotLayer(assetID: $0, placement: backgroundPlacement) },
                                 foreground: foregroundAssetID.map { SnapshotLayer(assetID: $0, placement: foregroundPlacement) },
                                 backgroundColorHex: backgroundColorHex,
                                 slots: slots.map { SnapshotSlot(from: $0) },
                                 snapshotHash: "editor-preview")
        let scale = min(1, 700.0 / Double(max(canvasWidth, canvasHeight)))
        let model = CompositionModel(snapshot: snap, sources: sources, faces: [:],
                                     defaults: env.settings.sessionDefaultsSnapshot(),
                                     overrides: [:], placements: [:], cropModes: [:],
                                     assetImages: assetImages,
                                     options: RenderOptions(targetWidth: max(1, Int((Double(canvasWidth) * scale).rounded())),
                                                            targetHeight: max(1, Int((Double(canvasHeight) * scale).rounded()))))
        previewImage = try? CompositeRenderer.render(model: model)
    }
}
