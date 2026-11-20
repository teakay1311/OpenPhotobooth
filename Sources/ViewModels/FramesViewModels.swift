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
    @Published private(set) var duplicatingFrameIDs: Set<String> = []

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
                let mediaType = try AssetStore.validatedFrameImage(data).mediaType
                let isPNG = mediaType == "image/png"
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

    public func duplicate(_ frameID: String) async {
        guard duplicatingFrameIDs.insert(frameID).inserted else { return }
        defer { duplicatingFrameIDs.remove(frameID) }
        let repository = env.frames
        do {
            // The requested copy completes even if the initiating view disappears.
            let copy = try await Task.detached(priority: .userInitiated) {
                try repository.duplicateFrame(id: frameID)
            }.value
            reload()
            EventBus.shared.post(.frameLibraryChanged(frameID: copy.id))
            env.showToast("Đã nhân bản khung")
        } catch { env.showToast("Nhân bản lỗi: \(error.localizedDescription)", kind: .warning) }
    }

    public func moveToCategory(_ frameIDs: [String], categoryID: String?) {
        let ids = Array(Set(frameIDs))
        guard !ids.isEmpty else { return }
        do {
            try env.frames.setCategory(frameIDs: ids, categoryID: categoryID)
            reload()
            EventBus.shared.post(.categoryChanged)
            EventBus.shared.post(.frameLibraryChanged(frameID: nil))
            env.showToast("Đã chuyển \(ids.count) khung")
        } catch {
            reload()
            env.showToast("Không thể chuyển khung: \(error.localizedDescription)", kind: .warning)
        }
    }

    public func trash(_ frameID: String) {
        do {
            try env.trashService.trashFrame(frameID: frameID)
            reload()
            env.showToast("Đã chuyển vào Thùng rác")
        } catch { env.showToast("\((error as? AppError)?.message ?? "")", kind: .warning) }
    }

    var selectedTrashTargets: [TrashService.FrameTarget] {
        frames.filter { selection.contains($0.id) }
            .map { TrashService.FrameTarget(id: $0.id, name: $0.frame.name) }
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
    var imageOrientation: Int? = nil
    var claritySHA256: String? = nil
    var clarityEdits: [PNGSlotClarity.Edit] = []
    var clarityApprovals: PNGSlotClarity.Approvals = [:]
}

enum SlotClarityApprovals {
    static func retained(_ edits: [PNGSlotClarity.Edit], from old: [FrameSlot], to new: [FrameSlot],
                         canvasWidth: Int, canvasHeight: Int) -> [PNGSlotClarity.Edit] {
        guard !edits.isEmpty else { return [] }
        let affected = affectedIDs(from: old, to: new, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        return edits.filter { !affected.contains($0.slotID) }
    }

    static func retained(_ approvals: PNGSlotClarity.Approvals, from old: [FrameSlot], to new: [FrameSlot],
                         canvasWidth: Int, canvasHeight: Int) -> PNGSlotClarity.Approvals {
        guard !approvals.isEmpty else { return [:] }
        let affected = affectedIDs(from: old, to: new, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        return approvals.filter { !affected.contains($0.key) }
    }

    private static func affectedIDs(from old: [FrameSlot], to new: [FrameSlot],
                                    canvasWidth: Int, canvasHeight: Int) -> Set<String> {
        let before = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let after = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
        let changed = Set(before.keys).union(after.keys).filter { id in
            guard let a = before[id], let b = after[id] else { return true }
            return a.rect != b.rect || a.rotationDegrees != b.rotationDegrees ||
                a.maskType != b.maskType || a.cornerRadius != b.cornerRadius
        }
        guard !changed.isEmpty else { return [] }
        let affected = changed.flatMap { [before[$0], after[$0]].compactMap { $0 } }.compactMap(path)
        return changed.union(new.filter { slot in
            guard let slotPath = path(slot) else { return true }
            return affected.contains {
                $0.boundingBoxOfPath.intersects(slotPath.boundingBoxOfPath) && !$0.intersection(slotPath).isEmpty
            }
        }.map(\.id))

        func path(_ slot: FrameSlot) -> CGPath? {
            guard slot.rect.isFinite, slot.rect.isPositive, slot.rotationDegrees.isFinite, slot.cornerRadius.isFinite else {
                return nil
            }
            let rect = slot.rect.pixelRect(canvasWidth: canvasWidth, canvasHeight: canvasHeight)
            let shape: CGPath
            switch slot.maskType {
            case .rectangle:
                shape = CGPath(rect: rect, transform: nil)
            case .ellipse:
                shape = CGPath(ellipseIn: rect, transform: nil)
            case .roundedRectangle:
                let radius = max(0.5, SlotGeometry.cornerRadiusPixels(slot.cornerRadius, slotPixel: rect,
                                                                       canvasWidth: canvasWidth, canvasHeight: canvasHeight))
                shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            }
            var transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .rotated(by: slot.rotationDegrees * .pi / 180)
                .translatedBy(x: -rect.midX, y: -rect.midY)
            return shape.copy(using: &transform)
        }
    }
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
    @Published private(set) var isSaving = false
    @Published private(set) var isValidating = false
    private var validationTask: Task<Void, Never>?
    private var validationGeneration = 0
    private var originalRevisionID: String?
    private var originalName: String = ""
    private var explicitWhiteSelected = false
    private var sourceHadExplicitWhite = false
    private var backgroundImageOrientation: Int?
    private var foregroundImageOrientation: Int?
    private var imported: FrameEditorImportDraft?
    private var importedClarityEdits: [PNGSlotClarity.Edit] = []
    private var importedClarityApprovals: PNGSlotClarity.Approvals = [:]
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
    deinit { validationTask?.cancel() }

    func load(imported draft: FrameEditorImportDraft) {
        guard imported == nil else { return }
        do {
            let asset = try env.assets.store(data: draft.data, mediaType: draft.mediaType,
                                             purpose: draft.role.rawValue, ownerType: "frame_revision",
                                             ownerID: editorStagingOwnerKey)
            imported = draft
            importedClarityEdits = draft.claritySHA256 == asset.sha256 ? draft.clarityEdits : []
            importedClarityApprovals = draft.claritySHA256 == asset.sha256 ? draft.clarityApprovals : [:]
            draftName = draft.name
            originalName = draft.name
            canvasWidth = draft.width
            canvasHeight = draft.height
            slots = draft.slots
            if draft.role == .frameForeground {
                foregroundAssetID = asset.id
                foregroundImageOrientation = draft.imageOrientation
                foregroundPlacement = .stretchToCanvas
            } else {
                backgroundAssetID = asset.id
                backgroundImageOrientation = draft.imageOrientation
            }
            hasChanges = true
            validate()
            regeneratePreview()
        } catch {
            env.showToast("Không thể mở bản nháp: \(error.localizedDescription)", kind: .warning)
        }
    }

    func importedClarityInput() throws -> FrameClaritySheet.ImportInput? {
        guard imported != nil, let foregroundAssetID,
              env.assets.assetInfo(assetID: foregroundAssetID)?.relativePath.lowercased().hasSuffix(".png") == true else {
            return nil
        }
        let bytes = try env.assets.loadData(assetID: foregroundAssetID)
        guard env.assets.assetInfo(assetID: foregroundAssetID)?.sha256 == Hashing.sha256Hex(bytes) else {
            throw AppError.frameFileCorrupt
        }
        let snapshot = FrameSnapshot(sourceFrameID: nil, sourceFrameRevisionID: nil,
            canvasWidth: canvasWidth, canvasHeight: canvasHeight,
            background: backgroundAssetID.map { SnapshotLayer(assetID: $0, placement: backgroundPlacement, imageOrientation: backgroundImageOrientation) },
            foreground: SnapshotLayer(assetID: foregroundAssetID, placement: foregroundPlacement),
            backgroundColorHex: backgroundColorHex, slots: slots.map(SnapshotSlot.init(from:)),
            snapshotHash: "", explicitWhite: explicitWhiteSelected)
        return FrameClaritySheet.ImportInput(name: draftName, original: bytes, snapshot: snapshot,
            edits: importedClarityEdits, approvals: importedClarityApprovals)
    }

    func saveImportedFrame(approvedPNG: Data? = nil, approvedInput: FrameClaritySheet.ImportInput? = nil) async -> Frame? {
        guard canSave, let imported else { return nil }
        var draft = FrameRevision(frameID: "", revisionNo: 1, canvasWidth: canvasWidth, canvasHeight: canvasHeight,
                                  backgroundAssetID: backgroundAssetID, foregroundAssetID: foregroundAssetID,
                                  backgroundColorHex: backgroundColorHex, backgroundPlacement: backgroundPlacement,
                                  foregroundPlacement: foregroundPlacement)
        draft.backgroundImageOrientation = backgroundImageOrientation
        draft.foregroundImageOrientation = foregroundImageOrientation
        do {
            if let current = try importedClarityInput() {
                guard approvedPNG != nil, let approvedInput,
                      current.original == approvedInput.original,
                      current.snapshot.canvasWidth == approvedInput.snapshot.canvasWidth,
                      current.snapshot.canvasHeight == approvedInput.snapshot.canvasHeight,
                      current.snapshot.foreground == approvedInput.snapshot.foreground,
                      current.snapshot.background == approvedInput.snapshot.background,
                      current.snapshot.backgroundColorHex == approvedInput.snapshot.backgroundColorHex,
                      current.snapshot.explicitWhite == approvedInput.snapshot.explicitWhite,
                      current.snapshot.slots == approvedInput.snapshot.slots else {
                    throw AppError.invalidState("Bản nháp đã thay đổi. Hãy mở lại bản xem trước.")
                }
            }
            let name = draftName
            let category = imported.categoryID
            let slots = slots
            let owner = editorStagingOwnerKey
            let explicitWhite = explicitWhiteSelected
            let repository = env.frames
            let assets = env.assets
            return try await Task.detached(priority: .userInitiated) { [draft] in
                var draft = draft
                if let approvedPNG {
                    let asset = try assets.store(data: approvedPNG, mediaType: "image/png",
                        purpose: AssetKind.frameForeground.rawValue, ownerType: "frame_revision", ownerID: owner)
                    draft.foregroundAssetID = asset.id
                    draft.foregroundImageOrientation = nil
                }
                return try repository.createConfiguredFrame(name: name, categoryID: category, draft: draft, slots: slots,
                                                           stagedOwnerID: owner, explicitWhite: explicitWhite)
            }.value
        } catch {
            env.showToast("Không thể lưu khung: \(error.localizedDescription)", kind: .warning)
            return nil
        }
    }

    func discardImportedFrame() {
        try? env.assets.removeReferences(ownerType: "frame_revision", ownerID: editorStagingOwnerKey)
    }

    public func load(frameID: String?) {
        backgroundImageOrientation = nil
        foregroundImageOrientation = nil
        backgroundAssetID = nil
        foregroundAssetID = nil
        var loadError: String?
        if let frameID, let f = try? env.frames.getFrame(id: frameID) {
            frame = f
            draftName = f.name
            originalName = f.name
            originalRevisionID = f.currentRevisionID
            do {
                if let revID = f.currentRevisionID {
                    guard let rev = try env.frames.getRevision(id: revID) else {
                        throw AppError.notFound("Bản sửa đổi của khung")
                    }
                    canvasWidth = rev.canvasWidth
                    canvasHeight = rev.canvasHeight
                    backgroundAssetID = rev.backgroundAssetID
                    backgroundImageOrientation = rev.backgroundImageOrientation
                    foregroundAssetID = rev.foregroundAssetID
                    foregroundImageOrientation = rev.foregroundImageOrientation
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
            } catch {
                originalRevisionID = nil
                slots = []
                sourceHadExplicitWhite = false
                loadError = (error as? AppError)?.message ?? error.localizedDescription
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
        if let loadError {
            validationTask?.cancel()
            validationGeneration += 1
            isValidating = false
            validationIssues = [ValidationIssue(code: "F-VAL-09", slotID: nil, message: loadError)]
            previewImage = nil
            env.showToast(loadError, kind: .warning)
            return
        }
        validate()
        regeneratePreview()
    }

    // MARK: - Mutations (một thao tác kéo = một undo §7.4)

    private func replaceSlotGeometry(_ next: [FrameSlot]) {
        importedClarityEdits = SlotClarityApprovals.retained(importedClarityEdits, from: slots, to: next,
                                                           canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        importedClarityApprovals = SlotClarityApprovals.retained(importedClarityApprovals, from: slots, to: next,
                                                               canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        slots = next
    }

    public func beginUndoGroup() {
        undoStack.append(slots)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    public func endUndoGroup(_ newSlots: [FrameSlot]) {
        replaceSlotGeometry(newSlots)
        hasChanges = true
        validate()
    }

    public func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(slots)
        replaceSlotGeometry(prev)
        hasChanges = true
        validate()
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(slots)
        replaceSlotGeometry(next)
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
            replaceSlotGeometry(s)
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
        let newWidth = min(max(width, ResourceLimits.canvasMin), ResourceLimits.canvasMax)
        let newHeight = min(max(height, ResourceLimits.canvasMin), ResourceLimits.canvasMax)
        if canvasWidth != newWidth || canvasHeight != newHeight {
            importedClarityEdits.removeAll()
            importedClarityApprovals.removeAll()
        }
        canvasWidth = newWidth
        canvasHeight = newHeight
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
        if !isBackground && foregroundPlacement != kind {
            importedClarityEdits.removeAll()
            importedClarityApprovals.removeAll()
        }
        if isBackground { backgroundPlacement = kind } else { foregroundPlacement = kind }
        hasChanges = true
        validate()
        regeneratePreview()
    }

    // MARK: - Import layer (§6.1)

    public func importLayer(url: URL, role: AssetKind) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let image = try AssetStore.validatedFrameImport(data)
            let mediaType = image.mediaType
            // Dùng 1 ownerKey duy nhất cho phiên editor — save() sẽ moveReferences về revision thật.
            let ownerKey = editorStagingOwnerKey
            let asset = try env.assets.store(data: data, mediaType: mediaType,
                                             purpose: role.rawValue, ownerType: "frame_revision", ownerID: ownerKey)
            if role == .frameForeground {
                if foregroundAssetID != asset.id {
                    importedClarityEdits.removeAll()
                    importedClarityApprovals.removeAll()
                }
                foregroundAssetID = asset.id
                foregroundImageOrientation = image.orientation
                // JPG foreground không alpha sẽ che toàn bộ → cảnh báo (§7.2)
                if mediaType == "image/jpeg" {
                    env.showToast("Ảnh foreground không có vùng trong suốt — sẽ che toàn bộ ảnh", kind: .warning)
                }
            } else {
                backgroundAssetID = asset.id
                backgroundImageOrientation = image.orientation
            }
            hasChanges = true
            validate()
            regeneratePreview()
        } catch {
            env.showToast("Nhập lớp lỗi: \((error as? AppError)?.message ?? "")", kind: .warning)
        }
    }

    // MARK: - Validator (§7.5)

    public func validate() {
        let issues = FrameValidator.validate(
            canvasWidth: canvasWidth, canvasHeight: canvasHeight,
            slots: slots,
            hasBackground: backgroundAssetID != nil,
            hasForeground: foregroundAssetID != nil,
            backgroundColorHex: backgroundColorHex)

        validationTask?.cancel()
        validationGeneration += 1
        let generation = validationGeneration
        validationIssues = issues
        isValidating = false
        guard issues.isEmpty, backgroundAssetID != nil || foregroundAssetID != nil else { return }
        var draft = FrameRevision(frameID: frame?.id ?? "", revisionNo: 1,
            canvasWidth: canvasWidth, canvasHeight: canvasHeight, backgroundAssetID: backgroundAssetID,
            foregroundAssetID: foregroundAssetID, backgroundColorHex: backgroundColorHex,
            backgroundPlacement: backgroundPlacement, foregroundPlacement: foregroundPlacement)
        draft.backgroundImageOrientation = backgroundImageOrientation
        draft.foregroundImageOrientation = foregroundImageOrientation
        let validationDraft = draft
        let repository = env.frames
        let slots = slots
        isValidating = true
        validationTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { try repository.configuredIssues(draft: validationDraft, slots: slots) }
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, !Task.isCancelled, validationGeneration == generation else { return }
                validationIssues = result
                isValidating = false
            } catch {
                guard let self, !Task.isCancelled, validationGeneration == generation else { return }
                validationIssues = [ValidationIssue(code: "F-VAL-09", slotID: nil,
                    message: (error as? AppError)?.message ?? error.localizedDescription)]
                isValidating = false
            }
        }
    }

    private var needsConfigurationSave: Bool {
        imported == nil && frame?.lifecycle == .active && frame?.validationStatus != .ready && originalRevisionID != nil
    }

    public var canSave: Bool {
        !isSaving && !isValidating && (hasAnyChanges || needsConfigurationSave) && validationIssues.isEmpty && !slots.isEmpty && slots.count <= 12
    }

    // MARK: - Save (§6.5 revision mới, không sửa revision cũ, FRM-01)

    public func save() async -> Bool {
        guard canSave, let frame, let expectedRevisionID = originalRevisionID else { return false }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        let repository = env.frames
        let frameID = frame.id
        let owner = editorStagingOwnerKey
        let slots = slots
        let explicit = explicitWhiteSelected || sourceHadExplicitWhite
        var draft = FrameRevision(frameID: frameID, revisionNo: 1,
            canvasWidth: canvasWidth, canvasHeight: canvasHeight, backgroundAssetID: backgroundAssetID,
            foregroundAssetID: foregroundAssetID, backgroundColorHex: backgroundColorHex,
            backgroundPlacement: backgroundPlacement, foregroundPlacement: foregroundPlacement,
            geometryVersion: CompositeRenderer.geometryVersion)
        draft.backgroundImageOrientation = backgroundImageOrientation
        draft.foregroundImageOrientation = foregroundImageOrientation
        let renameOnly = !hasChanges && hasNameChange && !needsConfigurationSave
        isSaving = true
        env.frameEditorIsSaving = true
        defer { isSaving = false; env.frameEditorIsSaving = false }
        do {
            let committed = try await Task.detached(priority: .userInitiated) { [draft] () throws -> FrameRevision? in
                if renameOnly { try repository.renameFrame(id: frameID, to: name, expectedRevisionID: expectedRevisionID); return nil }
                return try repository.saveConfiguredRevision(frameID: frameID, expectedRevisionID: expectedRevisionID,
                    name: name, draft: draft, slots: slots, stagedOwnerID: owner, explicitWhite: explicit)
            }.value
            if let committed {
                originalRevisionID = committed.id
                self.frame?.currentRevisionID = committed.id
                self.frame?.validationStatus = .ready
            }
            self.frame?.name = name
            originalName = name
            editorStagingOwnerKey = "editor-\(IDFactory.new())"
            let white = backgroundColorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
            sourceHadExplicitWhite = (white == "FFFFFF" || white == "FFFFFFFF") && explicit
            explicitWhiteSelected = false
            hasChanges = false
            EventBus.shared.post(.frameLibraryChanged(frameID: frameID))
            env.showToast("Đã lưu khung")
            return true
        } catch {
            env.showToast("Lưu thất bại: \((error as? AppError)?.message ?? error.localizedDescription)", kind: .warning)
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
                                 background: backgroundAssetID.map { SnapshotLayer(assetID: $0, placement: backgroundPlacement, imageOrientation: backgroundImageOrientation) },
                                 foreground: foregroundAssetID.map { SnapshotLayer(assetID: $0, placement: foregroundPlacement, imageOrientation: foregroundImageOrientation) },
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
