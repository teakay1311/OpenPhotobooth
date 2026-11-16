import Foundation
import SwiftUI
import CoreGraphics

/// ReviewViewModel (§2.8, §9.3): Review & Edit — chỉnh màu/crop từng ảnh, retake,
/// đổi khung, xuất, chia sẻ. Persist debounce 300–500ms; preview render coalesced (§9.3, §17.4).
@MainActor
public final class ReviewViewModel: ObservableObject {
    @Published public private(set) var detail: SessionDetail?
    @Published public private(set) var previewImage: CGImage?
    @Published public var selectedPhotoIndex: Int? = nil
    @Published public var selectedSlotID: String? = nil
    @Published public var inspectorTab: ReviewTab = .color {
        didSet {
            if inspectorTab == .crop {
                previewMode = .inFrame
                Task { await regeneratePreview() }
            }
        }
    }
    @Published public private(set) var isSaving = false
    @Published public private(set) var isExporting = false
    @Published public var showBeforeAfter = false
    @Published public private(set) var canExport = false
    @Published public private(set) var missingPhotos: Int = 0
    @Published public var previewMode: PreviewDisplayMode = .inFrame
    @Published public private(set) var previewError: String? = nil
    @Published public private(set) var saveErrorMessage: String? = nil

    public enum PreviewDisplayMode: String, CaseIterable {
        case singlePhoto = "Ảnh đang chọn"
        case inFrame = "Trong khung"
    }

    public enum ReviewTab: String, CaseIterable {
        case color = "Màu"
        case crop = "Crop/Vị trí"
    }

    // Draft chỉnh đang kéo (chưa persist)
    @Published public var draftPresetID: String?
    @Published public var draftPresetIntensity: Double = 1.0
    @Published public var draftColor: ColorOverrides = ColorOverrides()
    @Published public var draftPlacement: PhotoPlacement?
    @Published public var draftCropMode: CropMode?

    public let env: AppEnvironment
    public var engine: CaptureEngine { env.engine }
    private let persistDebouncer = Debouncer(delay: .milliseconds(400))
    private var inFlightPreviewTask: Task<Void, Never>?
    private var pendingPreviewRequest: PreviewRenderRequest?
    private(set) var previewSequence: Int = 0
    private(set) var lastDisplayedPreviewSequence: Int = 0
    private var previewEpoch = 0
    private var colorGestureActive = false
    private var placementGestureActive = false

    private var previewContext: String {
        let index = selectedPhotoIndex ?? -1
        let imageID = detail?.currentRevisions()[index]?.id ?? ""
        return "\(previewEpoch):\(detail?.session.id ?? ""):\(detail?.session.revisionNo ?? 0):\(detail?.snapshot.id ?? ""):\(previewMode.rawValue):\(imageID):\(selectedSlotID ?? "")"
    }

    private struct PreviewRenderRequest {
        let sequence: Int
        let contextKey: String
        let detail: SessionDetail
        let mode: PreviewDisplayMode
        let selectedIndex: Int?
    }

    private var undoStack: [UndoAction] = []
    private var redoStack: [UndoAction] = []

    // Pending draft edits (not yet committed to DB)
    // Key: photoRevisionID -> (captureIndex, oldOverride, newOverride)
    private typealias PendingOverrideItem = (index: Int, old: PhotoOverride, new: PhotoOverride)
    private var pendingOverrides: [String: PendingOverrideItem] = [:]
    // Key: snapshotSlotID -> (placement, cropMode, oldPlacement)
    private var pendingPlacements: [String: (placement: PhotoPlacement, cropMode: CropMode, old: SlotPlacement?)] = [:]

    @Published public private(set) var canUndo: Bool = false
    @Published public private(set) var canRedo: Bool = false

    public var hasValidSelectedPhoto: Bool {
        guard let idx = selectedPhotoIndex, let detail else { return false }
        guard let rev = detail.currentRevisions()[idx], rev.state == .available else { return false }
        return true
    }

    public func setPreviewMode(_ mode: PreviewDisplayMode) {
        guard previewMode != mode else { return }
        previewMode = mode
        cancelPreviewPipeline()
        Task { await regeneratePreview() }
    }

    public func updateUndoRedoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    public enum UndoAction {
        case photoOverride(captureIndex: Int, photoRevisionID: String, old: PhotoOverride?, new: PhotoOverride)
        case applyAll(before: [Int: PhotoOverride], after: [Int: PhotoOverride])
        case presetSession(sessionID: String, before: [String: PhotoOverride?], after: [String: PhotoOverride])
        case retake(shotID: String, from: String, to: String)
        case placement(snapshotSlotID: String, old: SlotPlacement, new: SlotPlacement)
    }

    public init(env: AppEnvironment) {
        self.env = env
    }

    // MARK: - Load

    @discardableResult
    public func load(sessionID: String) async -> Bool {
        let isSameSession = (detail?.session.id == sessionID)
        let previousSelectedPhoto = selectedPhotoIndex
        let previousSelectedSlot = selectedSlotID
        let previousSnapshotID = detail?.snapshot.id

        if !isSameSession {
            undoStack.removeAll()
            redoStack.removeAll()
            updateUndoRedoState()
            if env.reviewContext?.sourceRoute == .library {
                previewMode = .singlePhoto
            } else {
                previewMode = .inFrame
            }
        }
        guard let d = try? env.sessions.getDetail(sessionID: sessionID) else {
            env.showToast("Không đọc được phiên", kind: .warning)
            return false
        }
        if !isSameSession || previousSnapshotID != d.snapshot.id {
            cancelPreviewPipeline()
        }
        detail = d
        missingPhotos = d.missingCount
        canExport = d.hasEnoughPhotos

        if isSameSession && previousSnapshotID == d.snapshot.id {
            // Cùng phiên & cùng snapshot (D2-A03): giữ nguyên lựa chọn hợp lệ
            if let prevIdx = previousSelectedPhoto, d.currentRevisions().keys.contains(prevIdx) {
                selectedPhotoIndex = prevIdx
                if let prevSlot = previousSelectedSlot, d.snapshot.slots.contains(where: { $0.id == prevSlot }) {
                    selectedSlotID = prevSlot
                } else {
                    selectedSlotID = d.snapshot.slots.first(where: { $0.captureIndex == prevIdx })?.id
                }
            } else {
                selectedPhotoIndex = d.session.defaults.selectedCaptureOrder?.first(where: { d.currentRevisions()[$0] != nil })
                    ?? d.currentRevisions().keys.sorted().first
                selectedSlotID = d.snapshot.slots.first(where: { $0.captureIndex == selectedPhotoIndex })?.id
            }
        } else {
            // Đổi phiên hoặc đổi snapshot: chọn ô/ảnh đầu tiên
            selectedPhotoIndex = d.session.defaults.selectedCaptureOrder?.first(where: { d.currentRevisions()[$0] != nil })
                    ?? d.currentRevisions().keys.sorted().first
            selectedSlotID = d.snapshot.slots.first(where: { $0.captureIndex == selectedPhotoIndex })?.id
        }
        syncDraftsFromState()
        if d.session.pendingSelectionCount != nil {
            cancelPreviewPipeline()
            previewImage = nil
        } else {
            await regeneratePreview()
        }
        return true
    }

    public func confirmPhotoSelection(order: [Int]) async {
        guard let id = detail?.session.id, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try env.sessions.confirmPhotoSelection(sessionID: id, order: order)
            await reload()
            if let detail, engine.session?.id == id {
                engine.adoptSession(record: detail.session, snapshot: detail.snapshot,
                                    committed: detail.currentRevisions(), forReview: true)
            }
        } catch {
            env.showToast((error as? AppError)?.message ?? "Không thể xác nhận ảnh", kind: .warning)
        }
    }

    public func reload() async {
        guard let id = detail?.session.id else { return }
        await load(sessionID: id)
    }

    public func cancelPreviewPipeline() {
        inFlightPreviewTask?.cancel()
        pendingPreviewRequest = nil
        previewEpoch += 1
        previewImage = nil
        previewError = nil
    }

    public func regeneratePreview() async {
        enqueuePreview()
    }

    private func enqueuePreview() {
        guard let detail else { return }
        var previewOverrides = detail.overrides
        for (_, item) in pendingOverrides {
            previewOverrides[item.index] = item.new
        }
        var previewPlacements = detail.placements
        for (slotID, item) in pendingPlacements {
            let old = detail.placements[slotID]
            previewPlacements[slotID] = SlotPlacement(
                id: old?.id ?? IDFactory.new(),
                sessionID: detail.session.id,
                frameSnapshotID: detail.snapshot.id,
                snapshotSlotID: slotID,
                cropMode: item.cropMode,
                scale: item.placement.scale,
                offsetX: item.placement.offsetX,
                offsetY: item.placement.offsetY,
                manualOverride: true
            )
        }
        let previewDetail = SessionDetail(
            session: detail.session,
            snapshot: detail.snapshot,
            shots: detail.shots,
            photoRevisions: detail.photoRevisions,
            overrides: previewOverrides,
            placements: previewPlacements
        )

        let mode = self.previewMode
        let selIdx = self.selectedPhotoIndex
        let contextKey = previewContext

        previewSequence += 1
        let seq = previewSequence

        let req = PreviewRenderRequest(
            sequence: seq,
            contextKey: contextKey,
            detail: previewDetail,
            mode: mode,
            selectedIndex: selIdx
        )

        if inFlightPreviewTask != nil {
            pendingPreviewRequest = req
        } else {
            dispatchPreviewRequest(req)
        }
    }

    private func dispatchPreviewRequest(_ req: PreviewRenderRequest) {
        inFlightPreviewTask = Task { [weak self] in
            guard let self else { return }
            let image: CGImage?
            var renderError: String? = nil

            if req.mode == .singlePhoto, let idx = req.selectedIndex {
                do {
                    image = try await self.env.renderBuilder.renderSinglePhotoPreview(
                        detail: req.detail,
                        captureIndex: idx,
                        maxDimension: 1100
                    )
                } catch {
                    image = nil
                    renderError = (error as? AppError)?.message ?? "Lỗi đọc tệp ảnh"
                }
            } else {
                image = await self.env.renderBuilder.renderPreview(
                    detail: req.detail,
                    maxDimension: 1100
                )
            }

            await MainActor.run {
                if !Task.isCancelled, self.previewContext == req.contextKey,
                   req.sequence > self.lastDisplayedPreviewSequence {
                    self.previewImage = image
                    self.previewError = renderError
                    self.lastDisplayedPreviewSequence = req.sequence
                }
                self.inFlightPreviewTask = nil

                if let next = self.pendingPreviewRequest {
                    self.pendingPreviewRequest = nil
                    self.dispatchPreviewRequest(next)
                }
            }
        }
    }

    // MARK: - Selection (§9.3)

    public func selectPhoto(index: Int) {
        finishSelectionGesture()
        selectedPhotoIndex = index
        selectedSlotID = detail?.snapshot.slots.first(where: { $0.captureIndex == index })?.id
        syncDraftsFromState()
        Task { await regeneratePreview() }
    }

    public func selectSlot(id: String) {
        finishSelectionGesture()
        selectedSlotID = id
        guard let detail,
              let slot = detail.snapshot.slots.first(where: { $0.id == id }) else { return }
        selectedPhotoIndex = slot.captureIndex
        syncDraftsFromState()
        Task { await regeneratePreview() }
    }

    public var selectedRevision: PhotoRevision? {
        guard let idx = selectedPhotoIndex, let detail else { return nil }
        return detail.currentRevisions()[idx]
    }

    public var resolvedForSelection: ResolvedPhotoParams? {
        guard let idx = selectedPhotoIndex, let detail else { return nil }
        return ResolvedPhotoParams.resolve(defaults: detail.session.defaults, override: detail.overrides[idx])
    }

    private func finishSelectionGesture() {
        if !pendingPlacements.isEmpty || colorGestureActive {
            _ = flushPendingEditsNow()
        }
        colorGestureActive = false
        placementGestureActive = false
        cancelPreviewPipeline()
    }

    func syncDraftsFromState() {
        guard let idx = selectedPhotoIndex, let detail else { return }
        if let rev = detail.currentRevisions()[idx], let pending = pendingOverrides[rev.id] {
            let o = pending.new
            draftPresetID = o.presetID
            draftPresetIntensity = o.presetIntensity ?? 1.0
            draftColor = o.color ?? ColorOverrides()
        } else if let o = detail.overrides[idx] {
            draftPresetID = o.explicitNoPreset == true ? nil : (o.presetID ?? detail.session.defaults.presetID)
            draftPresetIntensity = o.presetIntensity ?? detail.session.defaults.presetIntensity
            draftColor = o.color ?? ColorOverrides()
        } else if let r = resolvedForSelection {
            draftPresetID = r.presetID
            draftPresetIntensity = r.presetIntensity
            draftColor = ColorOverrides()
        }

        if let slotID = selectedSlotID {
            if let pending = pendingPlacements[slotID] {
                draftPlacement = pending.placement
                draftCropMode = pending.cropMode
            } else if let p = detail.placements[slotID] {
                draftPlacement = p.placement
                draftCropMode = p.cropMode
            } else {
                draftPlacement = nil
                draftCropMode = nil
            }
        } else {
            draftPlacement = nil
            draftCropMode = nil
        }
    }

    // MARK: - Color edits (§8.3 precedence)

    private func recordDraftColor() {
        guard let idx = selectedPhotoIndex, let detail, let rev = detail.currentRevisions()[idx] else { return }
        var o = detail.overrides[idx] ?? PhotoOverride()
        let old = pendingOverrides[rev.id]?.old ?? o
        o.color = draftColor
        o.presetID = draftPresetID
        o.presetIntensity = draftPresetIntensity
        if let pid = draftPresetID {
            let params: ColorParameterSet
            if let rec = try? env.presets.getPreset(id: pid) {
                params = rec.parameters
            } else {
                params = BuiltinPreset.byID(pid)?.parameters ?? .natural
            }
            o.presetParameters = params
        }
        pendingOverrides[rev.id] = (index: idx, old: old, new: o)
    }

    public func setColorValue(_ key: String, _ uiValue: Double) {
        // UI -100..100 → nội bộ -1..1 (sharpness 0..1)
        let v = key == "sharpness" ? (uiValue + 100) / 200 : uiValue / 100
        switch key {
        case "exposure": draftColor.exposure = v
        case "contrast": draftColor.contrast = v
        case "highlights": draftColor.highlights = v
        case "shadows": draftColor.shadows = v
        case "saturation": draftColor.saturation = v
        case "temperature": draftColor.temperature = v
        case "tint": draftColor.tint = v
        case "vibrance": draftColor.vibrance = v
        case "sharpness": draftColor.sharpness = v
        default: break
        }
        recordDraftColor()
        scheduleColorPersist()
        schedulePreviewRefresh()
    }

    /// Bấm preset cho cả phiên (§3.2): chốt chỉnh sửa đang chờ, áp dụng cho mọi ảnh còn khả dụng, lưu 1 transaction.
    public func setPreset(_ id: String) {
        guard flushPendingEditsNow(), let detail else { return }
        let sessionID = detail.session.id
        let params = (try? env.presets.getPreset(id: id))?.parameters
            ?? BuiltinPreset.byID(id)?.parameters ?? .natural
        do {
            let result = try env.sessions.applyPresetToSession(sessionID: sessionID, presetID: id, presetParameters: params)
            undoStack.append(.presetSession(sessionID: sessionID, before: result.before, after: result.after))
            redoStack.removeAll()
            updateUndoRedoState()
            self.detail = try env.sessions.getDetail(sessionID: sessionID)
            syncDraftsFromState()
            schedulePreviewRefresh()
            env.showToast("Đã áp dụng preset '\(BuiltinPreset.byID(id)?.nameVN ?? id)' cho cả phiên")
        } catch {
            env.showToast("Không áp dụng được preset: \((error as? AppError)?.message ?? error.localizedDescription)", kind: .warning)
        }
    }

    public func setColorEditing(_ isEditing: Bool) {
        colorGestureActive = isEditing
        if isEditing {
            persistDebouncer.cancel()
        } else if let sessionID = detail?.session.id {
            flushCurrentPendingOverrides(sessionID: sessionID)
        }
    }

    public func setPlacementEditing(_ isEditing: Bool) {
        placementGestureActive = isEditing
        placementDebouncer.cancel()
        if isEditing {
            if previewMode != .inFrame { setPreviewMode(.inFrame) }
        } else {
            persistPlacement()
        }
    }

    public func setPresetIntensity(_ value: Double) {
        draftPresetIntensity = value
        recordDraftColor()
        scheduleColorPersist()
        schedulePreviewRefresh()
    }

    private func finishColorPersistSuccess(sessionID: String, revID: String, item: PendingOverrideItem) {
        if pendingOverrides[revID]?.new == item.new {
            pendingOverrides.removeValue(forKey: revID)
        }
        if pendingOverrides.isEmpty && pendingPlacements.isEmpty {
            isSaving = false
        }
        saveErrorMessage = nil
        undoStack.append(.photoOverride(captureIndex: item.index, photoRevisionID: revID, old: (item.old.isEmpty ? nil : item.old), new: item.new))
        redoStack.removeAll()
        updateUndoRedoState()
        if let fresh = try? env.sessions.getDetail(sessionID: sessionID) {
            detail = fresh
        }
        Task { await regeneratePreview() }
    }

    private func finishColorPersistError(error: Error) {
        isSaving = false
        let msg = (error as? AppError)?.message ?? error.localizedDescription
        saveErrorMessage = "Không lưu được chỉnh sửa"
        env.showToast("Không lưu được chỉnh sửa: \(msg)", kind: .warning)
    }

    private func scheduleColorPersist() {
        guard let detail else { return }
        isSaving = true
        guard !colorGestureActive else { return }
        let sessionID = detail.session.id

        persistDebouncer.callAsync { [weak self] in
            guard let self else { return }
            await MainActor.run {
                self.flushCurrentPendingOverrides(sessionID: sessionID)
            }
        }
    }

    public func retrySave() async {
        guard detail != nil else { return }
        saveErrorMessage = nil
        _ = await flushPendingEdits()
    }

    private func flushCurrentPendingOverrides(sessionID: String) {
        guard !pendingOverrides.isEmpty else {
            isSaving = !pendingPlacements.isEmpty
            return
        }
        let snapshot = pendingOverrides
        for (revID, item) in snapshot {
            do {
                try env.sessions.setOverride(sessionID: sessionID, photoRevisionID: revID, override: item.new)
                EventBus.shared.post(.photoAdjusted(sessionID: sessionID, photoRevisionID: revID))
                self.finishColorPersistSuccess(sessionID: sessionID, revID: revID, item: item)
            } catch {
                self.finishColorPersistError(error: error)
            }
        }
    }

    private func schedulePreviewRefresh() {
        enqueuePreview()
    }

    // MARK: - Sao chép và dán chỉnh sửa màu (§4.1, §4.3)

    public func copyColorAdjustments() {
        guard hasValidSelectedPhoto, let idx = selectedPhotoIndex, let detail else { return }
        guard let rev = detail.currentRevisions()[idx] else { return }

        // Lấy thông số hiệu lực từ snapshot phiên nguồn và ghi đè mới nhất của đúng photoRevisionID,
        // ưu tiên nháp hiện tại nếu có (§4.1).
        let currentOverride = pendingOverrides[rev.id]?.new ?? detail.overrides[idx]
        let defaults = detail.session.defaults
        let resolved = ResolvedPhotoParams.resolve(defaults: defaults, override: currentOverride)

        let c = currentOverride?.color
        let effectiveColor = ColorParameterSet(
            exposure: c?.exposure ?? defaults.color.exposure,
            contrast: c?.contrast ?? defaults.color.contrast,
            highlights: c?.highlights ?? defaults.color.highlights,
            shadows: c?.shadows ?? defaults.color.shadows,
            saturation: c?.saturation ?? defaults.color.saturation,
            temperature: c?.temperature ?? defaults.color.temperature,
            tint: c?.tint ?? defaults.color.tint,
            vibrance: c?.vibrance ?? defaults.color.vibrance,
            sharpness: c?.sharpness ?? defaults.color.sharpness
        )

        let isExplicitNone = (currentOverride?.explicitNoPreset == true) || (currentOverride?.presetID == nil && defaults.presetID == nil)
        let copiedPresetID: String?
        let copiedPresetParams: ColorParameterSet
        let copiedPresetIntensity: Double

        if isExplicitNone {
            copiedPresetID = nil
            copiedPresetParams = .neutral
            copiedPresetIntensity = 0.0
        } else {
            copiedPresetID = resolved.presetID
            copiedPresetParams = resolved.presetParameters
            copiedPresetIntensity = resolved.presetIntensity
        }

        let copied = CopiedColorAdjustments(
            presetID: copiedPresetID,
            presetParameters: copiedPresetParams,
            presetIntensity: copiedPresetIntensity,
            isExplicitNoPreset: isExplicitNone,
            color: effectiveColor
        )

        env.copiedColorAdjustments = copied
        env.showToast("Đã sao chép chỉnh sửa màu", kind: .info)
    }

    public func pasteColorAdjustments() async {
        guard let copied = env.copiedColorAdjustments else { return }
        guard hasValidSelectedPhoto, let idx = selectedPhotoIndex, let detail else { return }
        guard let rev = detail.currentRevisions()[idx] else { return }

        let sessionID = detail.session.id
        let targetIndex = idx
        let targetRevID = rev.id

        if !pendingOverrides.isEmpty || !pendingPlacements.isEmpty {
            _ = await flushPendingEdits()
        }

        guard let freshDetail = try? env.sessions.getDetail(sessionID: sessionID),
              let freshRev = freshDetail.currentRevisions()[targetIndex],
              freshRev.id == targetRevID else {
            env.showToast("Phiên bản ảnh đã thay đổi. Hãy chọn lại ảnh hiện hành.", kind: .warning)
            return
        }

        let defaults = freshDetail.session.defaults
        let existingOverride = freshDetail.overrides[targetIndex]
        let currentResolved = ResolvedPhotoParams.resolve(defaults: defaults, override: existingOverride)

        let sameColor = (currentResolved.color == copied.color)
        let samePresetID = (currentResolved.presetID == copied.presetID)
        let samePresetIntensity = abs(currentResolved.presetIntensity - copied.presetIntensity) < 0.001
        let samePresetParams = (currentResolved.presetParameters == copied.presetParameters)

        if sameColor && samePresetID && samePresetIntensity && samePresetParams {
            return
        }

        var newOverride = existingOverride ?? PhotoOverride()
        newOverride.color = ColorOverrides(
            exposure: copied.color.exposure,
            contrast: copied.color.contrast,
            highlights: copied.color.highlights,
            shadows: copied.color.shadows,
            saturation: copied.color.saturation,
            temperature: copied.color.temperature,
            tint: copied.color.tint,
            vibrance: copied.color.vibrance,
            sharpness: copied.color.sharpness
        )
        if copied.isExplicitNoPreset {
            newOverride.explicitNoPreset = true
            newOverride.presetID = nil
            newOverride.presetParameters = .neutral
            newOverride.presetIntensity = 0.0
        } else {
            newOverride.explicitNoPreset = nil
            newOverride.presetID = copied.presetID
            newOverride.presetParameters = copied.presetParameters
            newOverride.presetIntensity = copied.presetIntensity
        }

        isSaving = true
        defer { isSaving = false }

        do {
            try env.sessions.setOverride(sessionID: sessionID, photoRevisionID: targetRevID, override: newOverride)
            EventBus.shared.post(.photoAdjusted(sessionID: sessionID, photoRevisionID: targetRevID))

            undoStack.append(.photoOverride(captureIndex: targetIndex, photoRevisionID: targetRevID, old: existingOverride, new: newOverride))
            redoStack.removeAll()
            updateUndoRedoState()

            await reload()
            await regeneratePreview()
            env.showToast("Đã dán chỉnh sửa vào ảnh đang chọn", kind: .info)
        } catch {
            env.showToast("Không lưu được chỉnh sửa: \((error as? AppError)?.message ?? error.localizedDescription)", kind: .warning)
        }
    }

    /// Áp dụng màu cho tất cả (§8.3 — không đổi crop; một undo action).
    public func applyColorToAll() {
        guard let detail else { return }
        let sessionID = detail.session.id
        let before = detail.overrides
        var resolvedParams: ColorParameterSet? = nil
        let isExplicitNone = (draftPresetID == nil && detail.session.defaults.presetID != nil && draftPresetIntensity == 0)
        if let pid = draftPresetID {
            if let rec = try? env.presets.getPreset(id: pid) {
                resolvedParams = rec.parameters
            } else {
                resolvedParams = BuiltinPreset.byID(pid)?.parameters ?? .natural
            }
        }
        do {
            try env.sessions.applyColorToAll(sessionID: sessionID,
                                             color: draftColor,
                                             presetID: draftPresetID,
                                             presetParameters: resolvedParams,
                                             presetIntensity: draftPresetIntensity,
                                             explicitNoPreset: isExplicitNone ? true : nil)
            let afterDetail = try? env.sessions.getDetail(sessionID: sessionID)
            let after = afterDetail?.overrides ?? [:]
            pendingOverrides.removeAll()
            Task { await reload(); await regeneratePreview() }
            undoStack.append(.applyAll(before: before, after: after))
            redoStack.removeAll()
            updateUndoRedoState()
            env.showToast("Đã áp dụng màu cho tất cả ảnh (không đổi crop)")
        } catch {
            env.showToast("Áp dụng thất bại: \((error as? AppError)?.message ?? "")", kind: .warning)
        }
    }

    /// Reset ảnh này về SessionDefault (§9.3) — crop giữ nguyên.
    public func resetThisPhoto() {
        guard let idx = selectedPhotoIndex, let detail, let rev = detail.currentRevisions()[idx] else { return }
        let old = detail.overrides[idx]
        do {
            try env.sessions.clearOverride(sessionID: detail.session.id, photoRevisionID: rev.id)
            pendingOverrides.removeValue(forKey: rev.id)
            undoStack.append(.photoOverride(captureIndex: idx, photoRevisionID: rev.id, old: old, new: PhotoOverride()))
            redoStack.removeAll()
            updateUndoRedoState()
            Task { await reload(); await regeneratePreview() }
            env.showToast("Đã đặt lại ảnh này về mặc định")
        } catch {
            env.showToast("Đặt lại thất bại: \((error as? AppError)?.message ?? "")", kind: .warning)
        }
    }

    // MARK: - Crop / placement (§9.1, §9.2)

    private func recordDraftPlacement() {
        guard let slotID = selectedSlotID, let p = draftPlacement, let mode = draftCropMode, let detail else { return }
        let old = pendingPlacements[slotID]?.old ?? detail.placements[slotID]
        pendingPlacements[slotID] = (placement: p, cropMode: mode, old: old)
    }

    public func setCropMode(_ mode: CropMode) {
        draftCropMode = mode
        recordDraftPlacement()
        guard selectedSlotID != nil else { return }
        if mode == .autoFace {
            recomputeAutoFace()
        } else {
            persistPlacement()
        }
    }

    private var placementDebouncer = Debouncer(delay: .milliseconds(150))
    private var dragStartPlacement: SlotPlacement?

    public func updatePlacement(scale: Double? = nil, offsetX: Double? = nil, offsetY: Double? = nil, isFinal: Bool = false) {
        if previewMode != .inFrame {
            previewMode = .inFrame
        }
        guard let slotID = selectedSlotID, let detail else { return }
        if dragStartPlacement == nil {
            dragStartPlacement = detail.placements[slotID]
        }
        var p = draftPlacement ?? PhotoPlacement()
        if let scale { p.scale = max(scale, 0.05) }
        if let offsetX { p.offsetX = offsetX }
        if let offsetY { p.offsetY = offsetY }
        draftPlacement = p
        recordDraftPlacement()
        schedulePreviewRefresh()

        if isFinal {
            placementDebouncer.cancel()
            persistPlacement()
        } else if !placementGestureActive {
            placementDebouncer.callAsync { [weak self] in
                await self?.persistPlacement()
            }
        }
    }

    public func centerPlacement() {
        updatePlacement(offsetX: 0.0, offsetY: 0.0, isFinal: true)
    }

    public func resetPlacement() {
        guard let slotID = selectedSlotID, let detail,
              let slot = detail.snapshot.slots.first(where: { $0.id == slotID }) else { return }
        draftCropMode = slot.defaultCropMode
        updatePlacement(scale: 1.0, offsetX: 0.0, offsetY: 0.0, isFinal: true)
    }

    private func persistPlacement() {
        guard let slotID = selectedSlotID, let pending = pendingPlacements[slotID], let detail else { return }
        let p = pending.placement
        let mode = pending.cropMode
        let old = dragStartPlacement ?? pending.old ?? detail.placements[slotID]
        dragStartPlacement = nil
        let sessionID = detail.session.id
        let env = self.env
        do {
            try env.sessions.setPlacement(sessionID: sessionID, snapshotSlotID: slotID,
                                          placement: p, cropMode: mode, manualOverride: true)
            pendingPlacements.removeValue(forKey: slotID)
            if let old {
                undoStack.append(.placement(snapshotSlotID: slotID, old: old,
                                            new: SlotPlacement(id: old.id, sessionID: sessionID,
                                                               frameSnapshotID: detail.snapshot.id,
                                                               snapshotSlotID: slotID, cropMode: mode,
                                                               scale: p.scale, offsetX: p.offsetX,
                                                               offsetY: p.offsetY, manualOverride: true)))
                redoStack.removeAll()
                updateUndoRedoState()
            }
            if let fresh = try? env.sessions.getDetail(sessionID: sessionID) {
                self.detail = fresh
            }
            Task { await self.regeneratePreview() }
        } catch {
            env.showToast("Không lưu được vị trí: \((error as? AppError)?.message ?? "")", kind: .warning)
        }
    }

    /// "Căn lại" theo Vision (§9.1) — user chủ động, không ghi đè manual.
    public func recomputeAutoFace() {
        guard let slotID = selectedSlotID, let detail,
              let slot = detail.snapshot.slots.first(where: { $0.id == slotID }),
              let idx = selectedPhotoIndex,
              let rev = detail.currentRevisions()[idx] else { return }
        if detail.session.defaults.smartFace == false {
            draftCropMode = .autoFace
            draftPlacement = PhotoPlacement(scale: 1, offsetX: 0, offsetY: 0)
            persistPlacement()
            Task {
                await regeneratePreview()
                env.showToast("Đã căn giữa (Smart Face tắt)", kind: .info)
            }
            return
        }
        Task {
            let faces = await env.faceAnalysis.detectFaces(cgImage: normalizedImage(for: rev) ?? placeholder(),
                                                           cacheKey: rev.id)
            let proposal = SmartFraming.propose(
                sourceWidth: Double(rev.width), sourceHeight: Double(rev.height),
                slotWidth: Double(slot.width * Double(detail.snapshot.canvasWidth)),
                slotHeight: Double(slot.height * Double(detail.snapshot.canvasHeight)),
                faces: faces,
                userManualOverride: false,
                defaultMode: .autoFace)
            draftCropMode = proposal.fitMode
            draftPlacement = PhotoPlacement(scale: proposal.scale, offsetX: proposal.offsetX, offsetY: proposal.offsetY)
            persistPlacement()
            await regeneratePreview()
            env.showToast(proposal.reason, kind: .info)
        }
    }

    private func normalizedImage(for rev: PhotoRevision) -> CGImage? {
        guard let url = try? env.sessions.fileURL(for: rev) else { return nil }
        guard let raw = ImageNormalizer.uprightImage(url: url) else { return nil }
        var img = ImageNormalizer.applyOutputMirror(raw, mirrored: detail?.session.defaults.outputMirror ?? false)
        if let idx = selectedPhotoIndex, let detail {
            let resolved = ResolvedPhotoParams.resolve(defaults: detail.session.defaults, override: detail.overrides[idx])
            if resolved.photoRotation.truncatingRemainder(dividingBy: 360) != 0 {
                img = ImageNormalizer.rotate(img, degrees: resolved.photoRotation)
            }
        }
        return img
    }

    private func placeholder() -> CGImage {
        SampleImageFactory.shared.sample(index: 1, size: CGSize(width: 64, height: 64)) ?? CGImage.createBlank()
    }

    // MARK: - Retake (§3.3, §5.5, D2-A01)

    public func retake(index: Int, keepCrop: Bool) async {
        guard !engine.hasPhotoToSave else {
            env.showToast("Thử lưu lại ảnh của phiên đang mở trước", kind: .warning)
            return
        }
        guard let d = detail else {
            env.showToast("Không tìm thấy phiên để chụp lại.", kind: .info)
            return
        }
        let s = d.session
        // D2-A01: Từ chối nếu engine đang bận thao tác trên một phiên khác
        if engine.state != .idle && engine.state != .ready && engine.session?.id != s.id {
            env.showToast("Máy ảnh đang bận xử lý phiên chụp khác.", kind: .warning)
            return
        }
        // Kiểm tra slot hợp lệ trong snapshot hiện hành
        guard d.snapshot.slots.contains(where: { $0.captureIndex == index }) else {
            env.showToast("Ô ảnh không tồn tại trong khung hiện tại.", kind: .warning)
            return
        }
        guard await flushPendingEdits(), await prepareCameraForRetake(),
              detail?.session.id == s.id, !engine.isCaptureBusy else { return }
        // Nhận lại phiên đúng từ detail đang mở trong Review làm chủ thể (CAP-01)
        guard engine.adoptSession(record: s, snapshot: d.snapshot, committed: d.currentRevisions(), forReview: true) else {
            env.showToast("Không thể chụp lại lúc này — máy đang bận", kind: .warning)
            return
        }
        do {
            env.retakeSessionID = s.id
            try engine.beginRetake(index: index, keepCrop: keepCrop)
            env.requestNavigation(to: .capture)
        } catch {
            env.retakeSessionID = nil
            env.showToast((error as? AppError)?.message ?? "Không chụp lại được", kind: .warning)
        }
    }

    private func prepareCameraForRetake() async -> Bool {
        let route = env.route
        await env.capturePreview.refresh(forRetake: true)
        guard env.route == route else { return false }
        guard env.capturePreview.isReady else {
            env.showToast(env.capturePreview.error ?? "Mở màn Chụp để bật camera trước khi chụp lại.", kind: .warning)
            return false
        }
        return true
    }

    // MARK: - Flush pending edits (§3.1, REV-01, NAV-02)

    public var hasPendingEdits: Bool {
        !pendingPlacements.isEmpty || !pendingOverrides.isEmpty
    }

    public func discardPendingEdits() {
        persistDebouncer.cancel()
        placementDebouncer.cancel()
        pendingPlacements.removeAll()
        pendingOverrides.removeAll()
        dragStartPlacement = nil
        isSaving = false
        if let id = detail?.session.id, let fresh = try? env.sessions.getDetail(sessionID: id) {
            detail = fresh
        }
        syncDraftsFromState()
    }

    @discardableResult
    public func flushPendingEdits() async -> Bool {
        let saved = flushPendingEditsNow()
        await regeneratePreview()
        return saved
    }

    @discardableResult
    private func flushPendingEditsNow() -> Bool {
        persistDebouncer.cancel()
        placementDebouncer.cancel()
        guard let currentDetail = detail else { return true }
        let sessionID = currentDetail.session.id

        let hadPending = hasPendingEdits
        var allSucceeded = true

        if !pendingPlacements.isEmpty {
            let toFlush = pendingPlacements
            for (slotID, item) in toFlush {
                do {
                    try env.sessions.setPlacement(
                        sessionID: sessionID,
                        snapshotSlotID: slotID,
                        placement: item.placement,
                        cropMode: item.cropMode,
                        manualOverride: true
                    )
                    pendingPlacements.removeValue(forKey: slotID)
                    if let old = item.old {
                        undoStack.append(.placement(
                            snapshotSlotID: slotID,
                            old: old,
                            new: SlotPlacement(
                                id: old.id,
                                sessionID: sessionID,
                                frameSnapshotID: currentDetail.snapshot.id,
                                snapshotSlotID: slotID,
                                cropMode: item.cropMode,
                                scale: item.placement.scale,
                                offsetX: item.placement.offsetX,
                                offsetY: item.placement.offsetY,
                                manualOverride: true
                            )
                        ))
                    }
                } catch {
                    allSucceeded = false
                    Log.store.error("Failed to flush placement: \(error)")
                }
            }
            if pendingPlacements.isEmpty {
                dragStartPlacement = nil
            }
        }

        if !pendingOverrides.isEmpty {
            let toFlush = pendingOverrides
            for (revID, item) in toFlush {
                do {
                    try env.sessions.setOverride(sessionID: sessionID, photoRevisionID: revID, override: item.new)
                    if pendingOverrides[revID]?.new == item.new {
                        pendingOverrides.removeValue(forKey: revID)
                    }
                    undoStack.append(.photoOverride(captureIndex: item.index, photoRevisionID: revID, old: (item.old.isEmpty ? nil : item.old), new: item.new))
                    EventBus.shared.post(.photoAdjusted(sessionID: sessionID, photoRevisionID: revID))
                } catch {
                    allSucceeded = false
                    saveErrorMessage = "Không lưu được chỉnh sửa"
                    Log.store.error("Failed to flush override: \(error)")
                }
            }
        }

        if hadPending { redoStack.removeAll() }
        updateUndoRedoState()
        isSaving = !pendingPlacements.isEmpty || !pendingOverrides.isEmpty

        if let fresh = try? env.sessions.getDetail(sessionID: sessionID) {
            self.detail = fresh
        }
        if !allSucceeded {
            env.showToast("Không thể lưu một số chỉnh sửa — bản nháp được giữ lại", kind: .warning)
        }
        return allSucceeded
    }

    /// Tiếp tục chụp các lượt ảnh còn thiếu (A2, C-08).
    public func continueCapture() async {
        guard !engine.hasPhotoToSave else {
            env.showToast("Thử lưu lại ảnh của phiên đang mở trước", kind: .warning)
            return
        }
        guard engine.canAdoptSession else {
            env.showToast("Không thể tiếp tục chụp lúc này — máy đang bận", kind: .warning)
            return
        }
        guard await flushPendingEdits() else { return }
        guard let d = detail else { return }
        let adopted = engine.adoptSession(record: d.session, snapshot: d.snapshot, committed: d.currentRevisions(), forReview: false)
        if adopted {
            env.requestNavigation(to: .capture)
        } else {
            env.showToast("Không thể nhận phiên chụp", kind: .warning)
        }
    }

    /// Chụp lại tất cả: tạo Capture Session mới cùng khung (§5.5) — phiên cũ còn nguyên.
    public func retakeAll() async {
        guard !engine.hasPhotoToSave else {
            env.showToast("Thử lưu lại ảnh của phiên đang mở trước", kind: .warning)
            return
        }
        guard await flushPendingEdits(), await prepareCameraForRetake(), !engine.isCaptureBusy else { return }
        guard let detail else { return }
        engine.keepSessionAndExit()
        guard let frameID = detail.snapshot.sourceFrameID else { return }
        do {
            let snapshot = try env.frames.createSnapshot(frameID: frameID)
            var defaults = detail.session.defaults
            defaults.selectedCaptureOrder = nil
            if let count = defaults.selectionCaptureCount {
                defaults.selectionCaptureCount = max(count, snapshot.requiredCaptureCount)
            }
            let frameName = detail.session.frameNameAtCapture ?? (try? env.frames.getFrame(id: frameID)?.name)
            _ = try engine.beginSession(snapshot: snapshot, mode: detail.session.captureMode,
                                        cameraID: detail.session.cameraID,
                                        defaults: defaults,
                                        countdown: env.settings.countdown,
                                        interval: env.settings.interval,
                                        frameName: frameName)
            try engine.startOrContinue()
            env.route = .capture
        } catch {
            env.showToast("Không tạo được phiên chụp lại: \((error as? AppError)?.message ?? "")", kind: .warning)
        }
    }

    // MARK: - Đổi khung (§3.4, BUG-LIB-01, H-A7)

    public func changeFrame(to frameID: String) async {
        guard let detail else { return }
        // H-A7: Chọn lại đúng khung hiện tại là no-op, không đổi snapshot hay reset crop
        if detail.snapshot.sourceFrameID == frameID {
            return
        }
        guard await flushPendingEdits() else { return }
        do {
            let newSnapshot = try env.frames.createSnapshot(frameID: frameID, persist: false)
            // §3.4.3: N_new > hiện có → hiện thiếu ảnh, không cho xuất đến khi đủ
            try env.sessions.changeFrame(sessionID: detail.session.id, newSnapshot: newSnapshot)
            _ = try? env.assets.collectGarbage()
            undoStack.removeAll()
            redoStack.removeAll()
            updateUndoRedoState()
            await reload()
            if let updated = self.detail, engine.session?.id == updated.session.id {
                engine.adoptSession(record: updated.session, snapshot: updated.snapshot,
                                    committed: updated.currentRevisions(), forReview: updated.missingIndices.isEmpty)
            }
            EventBus.shared.post(.frameSnapshotChanged(sessionID: detail.session.id))
            env.showToast("Đã áp dụng khung mới")
        } catch {
            env.showToast("Đổi khung thất bại: \((error as? AppError)?.message ?? "")", kind: .warning)
        }
    }

    // MARK: - Undo / Redo (§2.7 áp dụng cả Review, BUG-RV-02, D2-A03)

    public func undo() {
        guard flushPendingEditsNow(), let action = undoStack.last else { return }
        do {
            try applyUndo(action, inverted: false)
            _ = undoStack.popLast()
            redoStack.append(action)
            updateUndoRedoState()
        } catch {
            env.showToast("Hoàn tác không thành công: \(error.localizedDescription)", kind: .warning)
        }
    }

    public func redo() {
        guard let action = redoStack.last else { return }
        do {
            try applyUndo(action, inverted: true)
            _ = redoStack.popLast()
            undoStack.append(action)
            updateUndoRedoState()
        } catch {
            env.showToast("Làm lại không thành công: \(error.localizedDescription)", kind: .warning)
        }
    }

    private func applyUndo(_ action: UndoAction, inverted: Bool) throws {
        switch action {
        case .photoOverride(let index, let revID, let old, let new):
            guard let detail else { throw AppError.notFound("Không có phiên") }
            guard let rev = detail.currentRevisions()[index] else {
                throw AppError.notFound("Không tìm thấy ảnh của ô \(index)")
            }
            guard rev.id == revID else {
                throw AppError.invalidState("Phiên bản ảnh đã thay đổi. Không thể áp dụng lịch sử.")
            }
            // Undo → old; Redo → new.
            let target = inverted ? new : old
            if let t = target, !t.isEmpty {
                try env.sessions.setOverride(sessionID: detail.session.id, photoRevisionID: rev.id, override: t)
            } else {
                try env.sessions.clearOverride(sessionID: detail.session.id, photoRevisionID: rev.id)
            }
        case .applyAll(let before, let after):
            guard let detail else { throw AppError.notFound("Không có phiên") }
            let snapshot = inverted ? after : before
            let current = detail.currentRevisions()
            if !inverted {
                // Undo: các ảnh vốn KHÔNG có override trước đó phải được clear về mặc định,
                // nếu không chúng giữ mãi giá trị vừa "áp dụng cho tất cả".
                for idx in Set(after.keys).subtracting(before.keys) {
                    if let rev = current[idx] {
                        try? env.sessions.clearOverride(sessionID: detail.session.id,
                                                        photoRevisionID: rev.id)
                    }
                }
            }
            for (idx, o) in snapshot {
                if let rev = current[idx] {
                    try env.sessions.setOverride(sessionID: detail.session.id, photoRevisionID: rev.id, override: o)
                }
            }
        case .presetSession(let sessionID, let before, let after):
            guard let detail else { throw AppError.notFound("Không có phiên") }
            guard detail.session.id == sessionID else {
                throw AppError.invalidState("Phiên chụp không khớp")
            }
            let target = inverted ? after.mapValues { Optional($0) } : before
            try env.sessions.restorePresetOverrides(sessionID: sessionID, overrides: target)
        case .retake(let shotID, let from, let to):
            guard let detail else { throw AppError.notFound("Không có phiên") }
            let target = inverted ? to : from
            try env.sessions.switchCurrentRevision(shotID: shotID, toRevisionID: target,
                                                    sessionID: detail.session.id)
        case .placement(let slotID, let old, let new):
            // Undo → old; Redo → new.
            let target = inverted ? new : old
            try env.sessions.setPlacement(sessionID: target.sessionID, snapshotSlotID: slotID,
                                           placement: target.placement, cropMode: target.cropMode,
                                           manualOverride: target.manualOverride)
        }
        Task { await reload(); await regeneratePreview() }
    }

    // MARK: - Export / Share / Complete (§11)

    public func runExport(request: ExportService.ExportRequest) async -> Result<URL, AppError> {
        guard await flushPendingEdits() else {
            return .failure(.invalidState("Chưa thể lưu hoàn tất các chỉnh sửa"))
        }
        guard let detail else { return .failure(.invalidState("Không có phiên")) }
        isExporting = true
        engine.beginExport()
        var exportSucceeded = false
        defer {
            isExporting = false
            engine.endExport(success: exportSucceeded)
        }
        do {
            let (record, url) = try await env.exportService.export(detail: detail, request: request)
            exportSucceeded = true
            env.showToast("Đã xuất \(record.filename)")
            return .success(url)
        } catch let e as AppError {
            return .failure(e)
        } catch {
            return .failure(.exportFailed(error.localizedDescription))
        }
    }

    public func prepareShare() async -> URL? {
        guard await flushPendingEdits() else { return nil }
        guard let detail else { return nil }
        do {
            let base = ExportService.defaultFilenameBase()
            return try await env.shareService.prepareShareFile(detail: detail,
                                                               filenameBase: base)
        } catch {
            env.showToast("Không chuẩn bị được file chia sẻ: \((error as? AppError)?.message ?? "")", kind: .warning)
            return nil
        }
    }

    @discardableResult
    public func complete() async -> Bool {
        guard await flushPendingEdits(), let detail else { return false }
        do {
            try await env.completeSession(sessionID: detail.session.id)
            return true
        } catch {
            env.showToast((error as? AppError)?.message ?? "Không thể hoàn thành phiên", kind: .warning)
            return false
        }
    }

    isolated deinit {
        let env = self.env
        let overrides = self.pendingOverrides
        let placements = self.pendingPlacements
        let sessionID = self.detail?.session.id
        if let sessionID, !overrides.isEmpty || !placements.isEmpty {
            Task {
                for (slotID, item) in placements {
                    try? env.sessions.setPlacement(
                        sessionID: sessionID,
                        snapshotSlotID: slotID,
                        placement: item.placement,
                        cropMode: item.cropMode,
                        manualOverride: true
                    )
                }
                for (revID, item) in overrides {
                    try? env.sessions.setOverride(
                        sessionID: sessionID,
                        photoRevisionID: revID,
                        override: item.new
                    )
                }
            }
        }
    }
}

extension CGImage {
    static func createBlank() -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return ctx.makeImage()!
    }
}
