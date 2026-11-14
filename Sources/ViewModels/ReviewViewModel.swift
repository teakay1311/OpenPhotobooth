import Foundation
import SwiftUI
import CoreGraphics

/// ReviewViewModel (§2.8, §9.3): Review & Edit — chỉnh màu/làm mịn/crop từng ảnh, retake,
/// đổi khung, xuất, chia sẻ. Persist debounce 300–500ms; preview render coalesced (§9.3, §17.4).
@MainActor
public final class ReviewViewModel: ObservableObject {
    @Published public private(set) var detail: SessionDetail?
    @Published public private(set) var previewImage: CGImage?
    @Published public var selectedPhotoIndex: Int? = nil
    @Published public var selectedSlotID: String? = nil
    @Published public var inspectorTab: ReviewTab = .color
    @Published public private(set) var isSaving = false
    @Published public private(set) var isExporting = false
    @Published public var showBeforeAfter = false
    @Published public private(set) var canExport = false
    @Published public private(set) var missingPhotos: Int = 0

    public enum ReviewTab: String, CaseIterable {
        case color = "Màu"
        case beauty = "Làm mịn"
        case crop = "Crop/Vị trí"
    }

    // Draft chỉnh đang kéo (chưa persist)
    @Published public var draftPresetID: String?
    @Published public var draftPresetIntensity: Double = 1.0
    @Published public var draftColor: ColorOverrides = ColorOverrides()
    @Published public var draftSkinSmooth: Double?
    @Published public var draftPlacement: PhotoPlacement?
    @Published public var draftCropMode: CropMode?

    public let env: AppEnvironment
    public var engine: CaptureEngine { env.engine }
    private let persistDebouncer = Debouncer(delay: .milliseconds(400))
    private let previewRunner = LatestValueRunner()
    private var undoStack: [UndoAction] = []
    private var redoStack: [UndoAction] = []

    public enum UndoAction {
        case photoOverride(captureIndex: Int, old: PhotoOverride, new: PhotoOverride)
        case applyAll(before: [Int: PhotoOverride], after: [Int: PhotoOverride])
        case retake(shotID: String, from: String, to: String)
        case placement(snapshotSlotID: String, old: SlotPlacement, new: SlotPlacement)
    }

    public init(env: AppEnvironment) {
        self.env = env
    }

    // MARK: - Load

    public func load(sessionID: String) async {
        guard let d = try? env.sessions.getDetail(sessionID: sessionID) else {
            env.showToast("Không đọc được phiên", kind: .warning)
            return
        }
        detail = d
        missingPhotos = d.missingCount
        canExport = d.hasEnoughPhotos
        selectedPhotoIndex = d.currentRevisions().keys.sorted().first
        await regeneratePreview()
    }

    public func reload() async {
        guard let id = detail?.session.id else { return }
        await load(sessionID: id)
    }

    public func regeneratePreview() async {
        guard let detail else { return }
        let snapshotDetail = detail
        previewRunner.scheduleAsync { [weak self] in
            guard let self else { return }
            let image = await self.env.renderBuilder.renderPreview(detail: snapshotDetail, maxDimension: 1100)
            await MainActor.run { self.previewImage = image }
        }
    }

    // MARK: - Selection (§9.3)

    public func selectPhoto(index: Int) {
        selectedPhotoIndex = index
        selectedSlotID = nil
        syncDraftsFromState()
    }

    public func selectSlot(id: String) {
        selectedSlotID = id
        guard let detail,
              let slot = detail.snapshot.slots.first(where: { $0.id == id }) else { return }
        selectedPhotoIndex = slot.captureIndex
        syncDraftsFromState()
    }

    public var selectedRevision: PhotoRevision? {
        guard let idx = selectedPhotoIndex, let detail else { return nil }
        return detail.currentRevisions()[idx]
    }

    public var resolvedForSelection: ResolvedPhotoParams? {
        guard let idx = selectedPhotoIndex, let detail else { return nil }
        return ResolvedPhotoParams.resolve(defaults: detail.session.defaults, override: detail.overrides[idx])
    }

    func syncDraftsFromState() {
        guard let r = resolvedForSelection else { return }
        draftPresetID = r.presetID
        draftPresetIntensity = r.presetIntensity
        draftColor = ColorOverrides(exposure: r.color.exposure, contrast: r.color.contrast,
                                    saturation: r.color.saturation, temperature: r.color.temperature,
                                    tint: r.color.tint, sharpness: r.color.sharpness)
        draftSkinSmooth = r.skinSmooth
        if let slotID = selectedSlotID, let detail, let p = detail.placements[slotID] {
            draftPlacement = p.placement
            draftCropMode = p.cropMode
        } else {
            draftPlacement = nil
            draftCropMode = nil
        }
    }

    // MARK: - Color edits (§8.3 precedence)

    public func setColorValue(_ key: String, _ uiValue: Double) {
        // UI -100..100 → nội bộ -1..1 (sharpness 0..1)
        let v = key == "sharpness" ? (uiValue + 100) / 200 : uiValue / 100
        switch key {
        case "exposure": draftColor.exposure = v
        case "contrast": draftColor.contrast = v
        case "saturation": draftColor.saturation = v
        case "temperature": draftColor.temperature = v
        case "tint": draftColor.tint = v
        case "sharpness": draftColor.sharpness = v
        default: break
        }
        scheduleColorPersist()
        schedulePreviewRefresh()
    }

    public func setPreset(_ id: String) {
        draftPresetID = id
        scheduleColorPersist()
        schedulePreviewRefresh()
    }

    public func setPresetIntensity(_ value: Double) {
        draftPresetIntensity = value
        scheduleColorPersist()
        schedulePreviewRefresh()
    }

    public func setSkinSmooth(_ value: Double) {
        draftSkinSmooth = value
        scheduleColorPersist()
        schedulePreviewRefresh()
    }

    private func scheduleColorPersist() {
        guard let idx = selectedPhotoIndex, let detail, let rev = detail.currentRevisions()[idx] else { return }
        isSaving = true
        let presetID = draftPresetID
        let intensity = draftPresetIntensity
        let color = draftColor
        let smooth = draftSkinSmooth
        let sessionID = detail.session.id
        persistDebouncer.callAsync { [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                let old = try self.env.sessions.getOverride(photoRevisionID: rev.id) ?? PhotoOverride()
                var o = old
                o.presetID = presetID
                o.presetIntensity = intensity
                o.color = color
                o.skinSmooth = smooth
                if let pid = presetID {
                    let params: ColorParameterSet
                    if let rec = try? self.env.presets.getPreset(id: pid) {
                        params = rec.parameters
                    } else {
                        params = BuiltinPreset.byID(pid)?.parameters ?? .natural
                    }
                    o.presetParameters = params
                }
                try self.env.sessions.setOverride(sessionID: sessionID, photoRevisionID: rev.id, override: o)
                await MainActor.run {
                    self.isSaving = false
                    if let d = self.detail { self.detail = self.mergedDetail(d, override: idx, o) }
                    self.undoStack.append(.photoOverride(captureIndex: idx, old: old, new: o))
                    self.redoStack.removeAll()
                }
                EventBus.shared.post(.photoAdjusted(sessionID: sessionID, photoRevisionID: rev.id))
            } catch {
                await MainActor.run {
                    self.isSaving = false
                    self.env.showToast("Không lưu được chỉnh sửa: \((error as? AppError)?.message ?? "")", kind: .warning)
                }
            }
        }
    }

    private func mergedDetail(_ d: SessionDetail, override idx: Int, _ o: PhotoOverride) -> SessionDetail {
        var overrides = d.overrides
        overrides[idx] = o
        return SessionDetail(session: d.session, snapshot: d.snapshot, shots: d.shots,
                             photoRevisions: d.photoRevisions, overrides: overrides,
                             placements: d.placements)
    }

    private func schedulePreviewRefresh() {
        previewRunner.scheduleAsync(delay: .milliseconds(40)) { [weak self] in
            await self?.regeneratePreview()
        }
    }

    /// Áp dụng màu cho tất cả (§8.3 — không đổi crop; một undo action).
    public func applyColorToAll() {
        guard let detail else { return }
        let sessionID = detail.session.id
        let before = detail.overrides
        // Resolve preset parameters thật (giống scheduleColorPersist) — không truyền nil
        // vì applyColorToAll chỉ set presetParameters khi presetID != nil, nil sẽ ghi đè mất params.
        var resolvedParams: ColorParameterSet? = nil
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
                                             skinSmooth: draftSkinSmooth,
                                             presetID: draftPresetID,
                                             presetParameters: resolvedParams,
                                             presetIntensity: draftPresetIntensity)
            // Capture `after` từ DB để redo có dữ liệu thật (không phải [:] rỗng).
            let afterDetail = try? env.sessions.getDetail(sessionID: sessionID)
            let after = afterDetail?.overrides ?? [:]
            Task { await reload(); await regeneratePreview() }
            undoStack.append(.applyAll(before: before, after: after))
            env.showToast("Đã áp dụng màu/làm đẹp cho tất cả ảnh (không đổi crop)")
        } catch {
            env.showToast("Áp dụng thất bại: \((error as? AppError)?.message ?? "")", kind: .warning)
        }
    }

    /// Reset ảnh này về SessionDefault (§9.3) — crop giữ nguyên.
    public func resetThisPhoto() {
        guard let idx = selectedPhotoIndex, let detail, let rev = detail.currentRevisions()[idx] else { return }
        do {
            try env.sessions.clearOverride(sessionID: detail.session.id, photoRevisionID: rev.id)
            Task { await reload(); await regeneratePreview() }
        } catch {
            env.showToast("Reset thất bại", kind: .warning)
        }
    }

    // MARK: - Crop / placement (§9.1, §9.2)

    public func setCropMode(_ mode: CropMode) {
        draftCropMode = mode
        guard let slotID = selectedSlotID else { return }
        if mode == .autoFace {
            recomputeAutoFace()
        } else {
            persistPlacement()
        }
    }

    public func updatePlacement(scale: Double? = nil, offsetX: Double? = nil, offsetY: Double? = nil) {
        var p = draftPlacement ?? PhotoPlacement()
        if let scale { p.scale = max(scale, 0.05) }
        if let offsetX { p.offsetX = offsetX }
        if let offsetY { p.offsetY = offsetY }
        draftPlacement = p
        persistPlacement()
        schedulePreviewRefresh()
    }

    private func persistPlacement() {
        guard let slotID = selectedSlotID, let p = draftPlacement, let mode = draftCropMode,
              let detail else { return }
        let old = detail.placements[slotID]
        do {
            try env.sessions.setPlacement(sessionID: detail.session.id, snapshotSlotID: slotID,
                                          placement: p, cropMode: mode, manualOverride: true)
            if let old {
                undoStack.append(.placement(snapshotSlotID: slotID, old: old,
                                            new: SlotPlacement(id: old.id, sessionID: detail.session.id,
                                                               frameSnapshotID: detail.snapshot.id,
                                                               snapshotSlotID: slotID, cropMode: mode,
                                                               scale: p.scale, offsetX: p.offsetX,
                                                               offsetY: p.offsetY, manualOverride: true)))
            }
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
        return ImageNormalizer.applyOutputMirror(raw, mirrored: detail?.session.defaults.outputMirror ?? false)
    }

    private func placeholder() -> CGImage {
        SampleImageFactory.shared.sample(index: 1, size: CGSize(width: 64, height: 64)) ?? CGImage.createBlank()
    }

    // MARK: - Retake (§3.3, §5.5)

    public func retake(index: Int, keepCrop: Bool) {
        // Retake chỉ khả dụng khi engine đang giữ phiên ở trạng thái Review (vừa chụp xong).
        // Review mở từ Thư viện (engine idle) không chụp lại được — hãy mở phiên từ màn Chụp
        // hoặc chụp phiên mới (bảo vệ theo §5.5: retake hoạt động trong luồng phiên thực).
        guard engine.session != nil, engine.state == .reviewing else {
            env.showToast("Chỉ chụp lại được ngay sau khi chụp xong phiên. Mở phiên từ màn Chụp hoặc tạo phiên mới.", kind: .info)
            return
        }
        do {
            try engine.beginRetake(index: index, keepCrop: keepCrop)
            // §3.3: quay lại màn Chụp để người dùng posing — countdown + camera hiển thị ở đó;
            // engine sẽ tự reset crop (§3.3) và về .reviewing sau khi lưu xong.
            env.route = .capture
        } catch {
            env.showToast((error as? AppError)?.message ?? "Không chụp lại được", kind: .warning)
        }
    }

    /// Chụp lại tất cả: tạo Capture Session mới cùng khung (§5.5) — phiên cũ còn nguyên.
    public func retakeAll() async {
        guard let detail else { return }
        engine.keepSessionAndExit()
        guard let frameID = detail.snapshot.sourceFrameID else { return }
        do {
            let snapshot = try env.frames.createSnapshot(frameID: frameID)
            _ = try engine.beginSession(snapshot: snapshot, mode: detail.session.captureMode,
                                        cameraID: detail.session.cameraID,
                                        defaults: detail.session.defaults,
                                        countdown: env.settings.countdown,
                                        interval: env.settings.interval)
            try engine.startOrContinue()
            env.route = .capture
        } catch {
            env.showToast("Không tạo được phiên chụp lại: \((error as? AppError)?.message ?? "")", kind: .warning)
        }
    }

    // MARK: - Đổi khung (§3.4)

    public func changeFrame(to frameID: String) async {
        guard let detail else { return }
        do {
            let newSnapshot = try env.frames.createSnapshot(frameID: frameID)
            // §3.4.3: N_new > hiện có → hiện thiếu ảnh, không cho xuất đến khi đủ
            try env.sessions.changeFrame(sessionID: detail.session.id, newSnapshot: newSnapshot)
            await reload()
            await regeneratePreview()
            EventBus.shared.post(.frameSnapshotChanged(sessionID: detail.session.id))
            env.showToast("Đã áp dụng khung mới")
        } catch {
            env.showToast("Đổi khung thất bại: \((error as? AppError)?.message ?? "")", kind: .warning)
        }
    }

    // MARK: - Undo / Redo (§2.7 áp dụng cả Review)

    public func undo() {
        guard let action = undoStack.popLast() else { return }
        applyUndo(action, inverted: false)
        redoStack.append(action)
    }

    public func redo() {
        guard let action = redoStack.popLast() else { return }
        applyUndo(action, inverted: true)
        undoStack.append(action)
    }

    private func applyUndo(_ action: UndoAction, inverted: Bool) {
        switch action {
        case .photoOverride(let index, let old, let new):
            guard let detail, let rev = detail.currentRevisions()[index] else { return }
            // Undo → old; Redo → new.
            let target = inverted ? new : old
            try? env.sessions.setOverride(sessionID: detail.session.id, photoRevisionID: rev.id, override: target)
        case .applyAll(let before, let after):
            guard let detail else { return }
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
                    try? env.sessions.setOverride(sessionID: detail.session.id, photoRevisionID: rev.id, override: o)
                }
            }
        case .retake(let shotID, let from, let to):
            guard let detail else { return }
            let target = inverted ? to : from
            try? env.sessions.switchCurrentRevision(shotID: shotID, toRevisionID: target,
                                                    sessionID: detail.session.id)
        case .placement(let slotID, let old, let new):
            // Undo → old; Redo → new.
            let target = inverted ? new : old
            try? env.sessions.setPlacement(sessionID: target.sessionID, snapshotSlotID: slotID,
                                           placement: target.placement, cropMode: target.cropMode,
                                           manualOverride: target.manualOverride)
        }
        Task { await reload(); await regeneratePreview() }
    }

    // MARK: - Export / Share / Complete (§11)

    public func runExport(request: ExportService.ExportRequest) async -> Result<URL, AppError> {
        guard let detail else { return .failure(.invalidState("Không có phiên")) }
        isExporting = true
        engine.beginExport()
        defer {
            isExporting = false
            engine.endExport(success: true)
        }
        do {
            let (record, url) = try await env.exportService.export(detail: detail, request: request)
            env.showToast("Đã xuất \(record.filename)")
            return .success(url)
        } catch let e as AppError {
            engine.endExport(success: false)
            return .failure(e)
        } catch {
            engine.endExport(success: false)
            return .failure(.exportFailed(error.localizedDescription))
        }
    }

    public func prepareShare() async -> URL? {
        guard let detail else { return nil }
        do {
            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd_HHmmss"
            return try await env.shareService.prepareShareFile(detail: detail,
                                                               filenameBase: "Photobooth_\(df.string(from: Date()))")
        } catch {
            env.showToast("Không chuẩn bị được file chia sẻ: \((error as? AppError)?.message ?? "")", kind: .warning)
            return nil
        }
    }

    public func complete() async {
        guard let detail else { return }
        if engine.session?.id == detail.session.id && engine.state == .reviewing {
            engine.complete()
        } else {
            // Review mở từ Thư viện (engine không giữ phiên): cập nhật trạng thái trực tiếp (§11)
            try? env.sessions.setStatus(sessionID: detail.session.id, status: .completed)
            EventBus.shared.post(.sessionChanged(sessionID: detail.session.id, revision: 0))
        }
        if env.settings.autoExport {
            let result = await env.exportService.autoExport(detail: detail,
                                                            folderBookmarkID: env.settings.exportFolderBookmarkID)
            switch result {
            case .success(let url):
                env.showToast("Auto Export xong: \(url.lastPathComponent)")
            case .failure(let error):
                // STO-09: phiên vẫn completed, báo lỗi export để retry
                env.showToast("Auto Export lỗi: \(error.message) — phiên vẫn an toàn trong Thư viện", kind: .warning)
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
