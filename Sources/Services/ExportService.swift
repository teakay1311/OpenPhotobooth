import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Darwin

/// Build CompositionModel từ SessionDetail — DUY NHẤT điểm nạp ảnh + face (I-05).
/// Ảnh nguồn đã chuẩn hóa orientation + OutputMirror + photoRotation trước khi render.
public final class SessionRenderBuilder: @unchecked Sendable {
    private let sessions: SessionRepository
    private let assets: AssetStore
    private let layout: FileLayout
    private let faceAnalysis: FaceAnalysisService
    /// Cache ảnh nguồn đã decode+mirror+rotate theo "revisionID|mirror|rotation" —
    /// tránh decode lại toàn bộ ảnh full-res mỗi lần regen preview (40ms khi kéo slider).
    private let sourceImageCache = NSCache<NSString, CGImage>()

    public init(sessions: SessionRepository, assets: AssetStore, layout: FileLayout,
                faceAnalysis: FaceAnalysisService) {
        self.sessions = sessions
        self.assets = assets
        self.layout = layout
        self.faceAnalysis = faceAnalysis
        sourceImageCache.countLimit = 48
    }

    public func buildModel(detail: SessionDetail, targetWidth: Int, targetHeight: Int,
                           transparentBackground: Bool = false,
                           matteColor: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)) async -> CompositionModel {
        var assetImages: [String: CGImage] = [:]
        if let bg = detail.snapshot.background, let img = try? assets.loadImage(assetID: bg.assetID) {
            assetImages[bg.assetID] = img
        }
        if let fg = detail.snapshot.foreground, let img = try? assets.loadImage(assetID: fg.assetID) {
            assetImages[fg.assetID] = img
        }

        var sources: [Int: RenderSource] = [:]
        var faces: [Int: [FaceBox]] = [:]
        let current = detail.currentRevisions()
        for (index, revision) in current {
            guard revision.state == .available else { continue }
            let resolved = ResolvedPhotoParams.resolve(defaults: detail.session.defaults,
                                                       override: detail.overrides[index])
            let cacheKey = "\(revision.id)|m\(detail.session.defaults.outputMirror ? 1 : 0)|r\(Int(resolved.photoRotation))"
            var image: CGImage
            if let cached = sourceImageCache.object(forKey: cacheKey as NSString) {
                image = cached
            } else {
                guard let url = try? sessions.fileURL(for: revision),
                      let raw = ImageNormalizer.uprightImage(url: url) else { continue }
                var decoded = ImageNormalizer.applyOutputMirror(raw, mirrored: detail.session.defaults.outputMirror)
                if resolved.photoRotation.truncatingRemainder(dividingBy: 360) != 0 {
                    decoded = ImageNormalizer.rotate(decoded, degrees: resolved.photoRotation)
                }
                sourceImageCache.setObject(decoded, forKey: cacheKey as NSString)
                image = decoded
            }
            sources[index] = RenderSource(image: image)
            // Vision trên ảnh đã normalize (§8.4) — cacheKey gắn rotation để không dùng
            // kết quả của ảnh xoay cho ảnh chưa xoay (và ngược lại)
            if Self.requiresAutoFace(detail, index: index) {
                let detected = await faceAnalysis.detectFaces(cgImage: image,
                                                               cacheKey: "\(revision.id)|m\(detail.session.defaults.outputMirror)|rot\(resolved.photoRotation)")
                faces[index] = detected
            } else {
                faces[index] = []
            }
        }

        let (placements, cropModes) = Self.resolvePlacements(detail: detail, sources: sources, faces: faces)

        return CompositionModel(snapshot: detail.snapshot,
                                sources: sources,
                                faces: faces,
                                defaults: detail.session.defaults,
                                overrides: detail.overrides,
                                placements: placements,
                                cropModes: cropModes,
                                assetImages: assetImages,
                                options: RenderOptions(targetWidth: targetWidth, targetHeight: targetHeight,
                                                       transparentBackground: transparentBackground,
                                                       matteColor: matteColor))
    }

    static func requiresAutoFace(_ detail: SessionDetail, index: Int) -> Bool {
        detail.session.defaults.autoFacePlacementVersion == 1 && detail.session.defaults.smartFace != false &&
            detail.snapshot.slots.contains { slot in
                slot.captureIndex == index && detail.placements[slot.id]?.manualOverride != true &&
                    (detail.placements[slot.id]?.cropMode ?? slot.defaultCropMode) == .autoFace
            }
    }

    static func resolvePlacements(detail: SessionDetail, sources: [Int: RenderSource], faces: [Int: [FaceBox]])
        -> (placements: [String: PhotoPlacement], cropModes: [String: CropMode]) {
        var placements: [String: PhotoPlacement] = [:]
        var modes: [String: CropMode] = [:]
        for slot in detail.snapshot.slots {
            let stored = detail.placements[slot.id]
            placements[slot.id] = stored?.placement ?? PhotoPlacement()
            modes[slot.id] = stored?.cropMode ?? slot.defaultCropMode
            guard requiresAutoFace(detail, index: slot.captureIndex), stored?.manualOverride != true,
                  modes[slot.id] == .autoFace, let source = sources[slot.captureIndex] else { continue }
            let result = SmartFraming.propose(sourceWidth: Double(source.width), sourceHeight: Double(source.height),
                slotWidth: slot.width * Double(detail.snapshot.canvasWidth),
                slotHeight: slot.height * Double(detail.snapshot.canvasHeight), faces: faces[slot.captureIndex] ?? [],
                userManualOverride: false, defaultMode: .autoFace)
            placements[slot.id] = PhotoPlacement(scale: result.scale, offsetX: result.offsetX, offsetY: result.offsetY)
            modes[slot.id] = result.fitMode
        }
        return (placements, modes)
    }

    /// A1: Nhánh nghiêm ngặt dùng chung cho Xuất tay, Auto Export và Tạo tệp Chia sẻ.
    /// Xác nhận từng ảnh hiện hành bắt buộc và mỗi lớp nền/lớp phủ được khai báo đều đọc và giải mã được từ đĩa thật.
    func verifiedFrameLayers(_ detail: SessionDetail) throws -> [String: CGImage] {
        if detail.session.awaitsFrame { throw AppError.invalidState("Chọn khung ảnh trước") }
        if detail.needsPhotoSelection { throw AppError.invalidState("Chọn ảnh vào khung trước") }
        guard detail.hasEnoughPhotos else {
            throw AppError.notEnoughPhotos(missing: detail.missingCount)
        }
        return try verifiedFrameLayers(detail.snapshot)
    }

    private func verifiedFrameLayers(_ snapshot: FrameSnapshot) throws -> [String: CGImage] {
        var images: [String: CGImage] = [:]
        for layer in [snapshot.background, snapshot.foreground].compactMap({ $0 }) {
            guard let image = try? assets.loadVerifiedImage(assetID: layer.assetID) else {
                throw AppError.missingFrameAssets
            }
            images[layer.assetID] = image
        }
        return images
    }

    func verifiedSource(_ detail: SessionDetail, index: Int) throws -> CGImage {
        try verifiedSource(detail.currentRevisions()[index], index: index)
    }

    private func verifiedSource(_ revision: PhotoRevision?, index: Int) throws -> CGImage {
        guard let revision, revision.state == .available else {
            throw AppError.notEnoughPhotos(missing: 1)
        }
        do {
            return try sessions.verifiedPhotoImage(revision)
        } catch {
            throw AppError.ioFailure("Tệp ảnh lượt \(index) bị thiếu, hỏng hoặc không khớp checksum")
        }
    }

    func verifyCompletion(_ detail: SessionDetail) throws {
        _ = try verifiedFrameLayers(detail)
        for index in detail.snapshot.requiredIndices.sorted() {
            _ = try verifiedSource(detail, index: index)
        }
    }

    public func buildModelStrict(detail: SessionDetail, targetWidth: Int, targetHeight: Int,
                                 transparentBackground: Bool = false,
                                 matteColor: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)) async throws -> CompositionModel {
        let assetImages = try verifiedFrameLayers(detail)
        return try await buildVerifiedModel(detail: detail, revisions: detail.currentRevisions(),
                                            assetImages: assetImages,
                                            options: RenderOptions(targetWidth: targetWidth,
                                                                   targetHeight: targetHeight,
                                                                   transparentBackground: transparentBackground,
                                                                   matteColor: matteColor))
    }

    func renderChooserPreview(detail: SessionDetail, snapshot: FrameSnapshot, order: [Int],
                              width: Int, height: Int) async throws -> CGImage {
        guard order.count <= snapshot.requiredCaptureCount, Set(order).count == order.count,
              snapshot.canvasWidth > 0, snapshot.canvasHeight > 0, width > 0, height > 0 else {
            throw AppError.invalidState("Không thể dựng bản xem trước")
        }
        let scale = min(Double(width) / Double(snapshot.canvasWidth),
                        Double(height) / Double(snapshot.canvasHeight))
        var draft = detail
        draft.snapshot = snapshot.previewAssigningPhotos(in: order)
        if detail.snapshot.sourceFrameID != snapshot.sourceFrameID ||
            detail.snapshot.sourceFrameRevisionID != snapshot.sourceFrameRevisionID {
            draft.session.defaults.autoFacePlacementVersion = 1
        }
        if detail.snapshot.sourceFrameRevisionID != snapshot.sourceFrameRevisionID ||
            detail.session.defaults.selectedCaptureOrder != order {
            draft.placements = [:]
        }
        let options = RenderOptions(targetWidth: max(1, Int((Double(snapshot.canvasWidth) * scale).rounded())),
                                    targetHeight: max(1, Int((Double(snapshot.canvasHeight) * scale).rounded())),
                                    transparentBackground: true)
        let model = try await buildVerifiedModel(detail: draft,
                                                 revisions: detail.currentRevisions(includeUnassigned: true),
                                                 assetImages: verifiedFrameLayers(snapshot), options: options)
        try Task.checkCancellation()
        return try CompositeRenderer.render(model: model)
    }

    private func buildVerifiedModel(detail: SessionDetail, revisions: [Int: PhotoRevision],
                                    assetImages: [String: CGImage],
                                    options: RenderOptions) async throws -> CompositionModel {
        var sources: [Int: RenderSource] = [:]
        var faces: [Int: [FaceBox]] = [:]
        for index in detail.snapshot.requiredIndices.sorted() {
            try Task.checkCancellation()
            let raw = try verifiedSource(revisions[index], index: index)
            guard let revision = revisions[index] else { throw AppError.notEnoughPhotos(missing: 1) }
            let resolved = ResolvedPhotoParams.resolve(defaults: detail.session.defaults,
                                                       override: detail.overrides[index])
            var decoded = ImageNormalizer.applyOutputMirror(raw, mirrored: detail.session.defaults.outputMirror)
            if resolved.photoRotation.truncatingRemainder(dividingBy: 360) != 0 {
                decoded = ImageNormalizer.rotate(decoded, degrees: resolved.photoRotation)
            }
            let cacheKey = "\(revision.id)|m\(detail.session.defaults.outputMirror ? 1 : 0)|r\(Int(resolved.photoRotation))"
            sourceImageCache.setObject(decoded, forKey: cacheKey as NSString)
            sources[index] = RenderSource(image: decoded)
            if Self.requiresAutoFace(detail, index: index) {
                let detected = await faceAnalysis.detectFaces(cgImage: decoded,
                                                              cacheKey: "\(revision.id)|m\(detail.session.defaults.outputMirror)|rot\(resolved.photoRotation)")
                faces[index] = detected
            } else {
                faces[index] = []
            }
        }

        let (placements, cropModes) = Self.resolvePlacements(detail: detail, sources: sources, faces: faces)

        return CompositionModel(snapshot: detail.snapshot,
                                sources: sources,
                                faces: faces,
                                defaults: detail.session.defaults,
                                overrides: detail.overrides,
                                placements: placements,
                                cropModes: cropModes,
                                assetImages: assetImages,
                                options: options)
    }

    /// Render cache preview (Thư viện / Review / Sheet xuất) — key theo §11.1, D2-A09.
    public func renderPreview(detail: SessionDetail, maxDimension: Int, format: ExportImageFormat = .jpeg,
                              outputSize: (width: Int, height: Int)? = nil,
                              verifiedSources: Bool = false) async -> CGImage? {
        let width = outputSize?.width ?? detail.snapshot.canvasWidth
        let height = outputSize?.height ?? detail.snapshot.canvasHeight
        guard width > 0, height > 0, maxDimension > 0 else { return nil }
        let scale = Double(maxDimension) / Double(max(width, height))
        let previewWidth = max(1, Int((Double(width) * scale).rounded()))
        let previewHeight = max(1, Int((Double(height) * scale).rounded()))
        let model: CompositionModel
        if verifiedSources {
            guard let verified = try? await buildModelStrict(detail: detail, targetWidth: previewWidth,
                                                             targetHeight: previewHeight, transparentBackground: format == .png) else {
                return nil
            }
            model = verified
        } else {
            model = await buildModel(detail: detail, targetWidth: previewWidth, targetHeight: previewHeight,
                                     transparentBackground: format == .png)
        }
        guard !Task.isCancelled else { return nil }
        return try? CompositeRenderer.render(model: model)
    }

    /// Render preview ảnh đơn (§2, §3.2): toàn ảnh theo tỉ lệ gốc, với hướng/lật thành phẩm và màu đã chỉnh,
    /// bỏ phần khung và crop riêng của ô. Giới hạn cạnh dài tối đa maxDimension (1100 px).
    public func renderSinglePhotoPreview(detail: SessionDetail, captureIndex: Int, maxDimension: Int = 1100) async throws -> CGImage {
        guard let revision = detail.currentRevisions()[captureIndex], revision.state == .available else {
            throw AppError.notFound("Không tìm thấy ảnh lượt \(captureIndex)")
        }
        let resolved = ResolvedPhotoParams.resolve(defaults: detail.session.defaults,
                                                   override: detail.overrides[captureIndex])
        let cacheKey = "\(revision.id)|m\(detail.session.defaults.outputMirror ? 1 : 0)|r\(Int(resolved.photoRotation))"
        var image: CGImage
        if let cached = sourceImageCache.object(forKey: cacheKey as NSString) {
            image = cached
        } else {
            guard let url = try? sessions.fileURL(for: revision),
                  FileManager.default.fileExists(atPath: url.path),
                  let raw = ImageNormalizer.uprightImage(url: url) else {
                throw AppError.ioFailure("Không thể đọc tệp ảnh lượt \(captureIndex)")
            }
            var decoded = ImageNormalizer.applyOutputMirror(raw, mirrored: detail.session.defaults.outputMirror)
            if resolved.photoRotation.truncatingRemainder(dividingBy: 360) != 0 {
                decoded = ImageNormalizer.rotate(decoded, degrees: resolved.photoRotation)
            }
            sourceImageCache.setObject(decoded, forKey: cacheKey as NSString)
            image = decoded
        }

        var ci = CIImage(cgImage: image)
        let origW = CGFloat(image.width)
        let origH = CGFloat(image.height)
        let maxDim = max(origW, origH)
        if maxDim > CGFloat(maxDimension) {
            let scale = CGFloat(maxDimension) / maxDim
            ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        // 1. Preset + adjustments (§8.4)
        ci = ImageColorPipeline.applyColor(ci, resolved: resolved)

        guard let out = CIContextHolder.shared.context.createCGImage(ci, from: ci.extent) else {
            throw AppError.exportFailed("Không render được ảnh")
        }
        return out
    }
}

public struct ExportedFile: Equatable, Sendable {
    public let url: URL
    public let sha256: String
}

/// ExportService (§11.2): render → encode → ghi .partial → rename → ExportRecord.
public final class ExportService: @unchecked Sendable {
    private let sessions: SessionRepository
    private let builder: SessionRenderBuilder
    private let trashRepo: TrashRepository
    private let layout: FileLayout

    enum FileCommitStep {
        case beforeCoordination, insideCoordination, beforeMetadata, beforeRename, afterRename, beforeHistoryValidation
    }
    #if DEBUG
    var onFileCommitForTesting: (@Sendable (FileCommitStep, URL) throws -> Void)?
    #endif

    public init(sessions: SessionRepository, builder: SessionRenderBuilder,
                trashRepo: TrashRepository, layout: FileLayout) {
        self.sessions = sessions
        self.builder = builder
        self.trashRepo = trashRepo
        self.layout = layout
    }

    struct PreviewIdentity: Equatable, Sendable {
        let sessionID: String
        let snapshotID: String
        let revisionNo: Int
        let format: ExportImageFormat
        let width: Int
        let height: Int
        let quality: Int

        init(detail: SessionDetail, format: ExportImageFormat, width: Int, height: Int, quality: Int) {
            sessionID = detail.session.id
            snapshotID = detail.snapshot.id
            revisionNo = detail.session.revisionNo
            self.format = format
            self.width = width
            self.height = height
            self.quality = quality
        }
    }

    struct DirectoryIdentity: Equatable, Sendable {
        private let device: dev_t
        private let inode: ino_t
        private let generation: UInt32

        fileprivate init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            generation = info.st_gen
        }

        static func read(_ folder: URL) throws -> Self {
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            let fd = try ExportDestination.openDirectory(folder)
            defer { close(fd) }
            return Self(try ExportDestination.info(fd))
        }
    }

    public struct ExportRequest: Sendable {
        public var sessionID: String
        public var format: ExportImageFormat
        public var quality: Int           // 1..100 (JPG)
        public var width: Int
        public var height: Int
        public var filenameBase: String
        public var destinationFolder: URL
        public var securityScoped: Bool   // folder đến từ bookmark cần start/stop access
        public var replaceExisting: Bool
        var acceptedPreview: PreviewIdentity?
        var destinationBookmark: TrashRepository.BookmarkUse?
        var selectedFolderIdentity: DirectoryIdentity?

        public init(sessionID: String, format: ExportImageFormat, quality: Int,
                    width: Int, height: Int, filenameBase: String,
                    destinationFolder: URL, securityScoped: Bool = false, replaceExisting: Bool = false) {
            self.sessionID = sessionID; self.format = format; self.quality = quality
            self.width = width; self.height = height
            self.filenameBase = filenameBase
            self.destinationFolder = destinationFolder
            self.securityScoped = securityScoped
            self.replaceExisting = replaceExisting
        }
    }

    public enum ExportError: Error { case cancelled, failed(String) }

    public static func defaultFilenameBase(date: Date = Date()) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        return "Photobooth-\(df.string(from: date))"
    }

    /// Xuất theo §11.2. Trả về record + URL file thành công.
    @discardableResult
    public func export(detail: SessionDetail, request: ExportRequest,
                       parentToken: OperationCoordinator.OperationToken? = nil) async throws -> (ExportRecordModel, URL) {
        let (record, file) = try await exportFile(detail: detail, request: request, parentToken: parentToken)
        return (record, file.url)
    }

    func exportFile(detail: SessionDetail, request: ExportRequest,
                    parentToken: OperationCoordinator.OperationToken? = nil) async throws -> (ExportRecordModel, ExportedFile) {
        guard request.sessionID == detail.session.id else {
            throw AppError.invalidState("Session ID không khớp giữa request và dữ liệu phiên")
        }
        // Khóa phiên chống xung đột ghi/xóa/đổi khung (DATA-01 / L7)
        let opToken = try OperationCoordinator.shared.acquire(key: "session:\(request.sessionID)", reason: "ExportService: exporting", parentToken: parentToken)
        defer { opToken.release() }

        // Xác nhận tính nhất quán với DB dưới khóa (§3.2.1)
        guard let latestSession = try sessions.activeSession(id: request.sessionID) else {
            throw AppError.notFound("Phiên chụp không tồn tại hoặc đã bị xóa")
        }
        if let accepted = request.acceptedPreview {
            let requested = PreviewIdentity(detail: detail, format: request.format, width: request.width,
                                            height: request.height, quality: request.quality)
            guard accepted == requested, latestSession.revisionNo == accepted.revisionNo,
                  latestSession.activeFrameSnapshotID == accepted.snapshotID else {
                throw AppError.exportPreviewChanged
            }
        }
        guard latestSession.revisionNo == detail.session.revisionNo,
              latestSession.activeFrameSnapshotID == detail.snapshot.id else {
            throw AppError.invalidState("Dữ liệu phiên đã thay đổi, vui lòng làm mới và thử lại")
        }

        // Bước 1: đủ ảnh required (§11.2.1)
        if detail.needsPhotoSelection { throw AppError.invalidState("Chọn ảnh vào khung trước") }
        guard detail.hasEnoughPhotos else {
            throw AppError.notEnoughPhotos(missing: detail.missingCount)
        }
        guard (ResourceLimits.canvasMin...ResourceLimits.canvasMax).contains(request.width),
              (ResourceLimits.canvasMin...ResourceLimits.canvasMax).contains(request.height),
              Double(request.width) * Double(request.height) <= ResourceLimits.maxMegapixels * 1_000_000 else {
            throw AppError.resourceLimitExceeded("Kích thước xuất phải 256–8192 px mỗi chiều và ≤40MP")
        }

        // Sanitize tên file người dùng nhập: "/" tạo đường dẫn con không tồn tại,
        // ":" là ký tự cấm của APFS trên macOS
        let filenameBase = Self.sanitizedFilenameBase(request.filenameBase)

        var record = ExportRecordModel(sessionID: request.sessionID,
                                       sessionRevisionNo: detail.session.revisionNo,
                                       format: request.format,
                                       filename: filenameBase,
                                       width: request.width, height: request.height,
                                       quality: request.format == .jpeg ? request.quality : nil,
                                       status: .preparing)

        let accessing = request.securityScoped && request.destinationFolder.startAccessingSecurityScopedResource()
        defer { if accessing { request.destinationFolder.stopAccessingSecurityScopedResource() } }

        let destination: ExportDestination
        do {
            if let expected = request.selectedFolderIdentity, let bookmark = request.destinationBookmark {
                guard let resolved = try? resolveExportFolder(bookmarkID: bookmark.id),
                      (try? DirectoryIdentity.read(resolved)) == expected else {
                    throw AppError.exportFolderChanged
                }
            }
            destination = try ExportDestination(folder: request.destinationFolder, base: filenameBase,
                                                ext: request.format.fileExtension, replace: request.replaceExisting,
                                                selectedFolderIdentity: request.selectedFolderIdentity)
        } catch AppError.exportFolderChanged {
            // This selection was rejected before an export was attempted.
            throw AppError.exportFolderChanged
        } catch {
            throw exportWriteFailure(error, record: record, filename: "\(filenameBase).\(request.format.fileExtension)")
        }

        // Bước 2: RenderRequest bất biến từ session revision hiện tại (§17.4) — A1: strict validation
        let model = try await builder.buildModelStrict(detail: detail, targetWidth: request.width,
                                                       targetHeight: request.height,
                                                       transparentBackground: request.format == .png,
                                                       matteColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        record.status = .writing
        let cg: CGImage
        do {
            cg = try CompositeRenderer.render(model: model)
        } catch {
            record.status = .failed
            _ = try? sessions.insertExportRecord(record)
            EventBus.shared.post(.exportFinished(sessionID: request.sessionID, recordID: record.id, success: false))
            throw AppError.exportFailed(error.localizedDescription)
        }

        // Bước 4: encode
        let encoded: Data
        do {
            encoded = try Self.encode(cg: cg, format: request.format, quality: request.quality)
        } catch {
            record.status = .failed
            _ = try? sessions.insertExportRecord(record)
            EventBus.shared.post(.exportFinished(sessionID: request.sessionID, recordID: record.id, success: false))
            throw AppError.exportFailed(error.localizedDescription)
        }

        let finalName = destination.name
        let partialName = "\(finalName).\(record.id).partial"
        #if DEBUG
        let hook = onFileCommitForTesting
        #else
        let hook: (@Sendable (FileCommitStep, URL) throws -> Void)? = nil
        #endif
        let output: ExportDestination.Output
        do {
            try Task.checkCancellation()
            let writer = Task.detached(priority: .userInitiated) {
                try destination.write(encoded, partialName: partialName, hook: hook)
            }
            output = try await withTaskCancellationHandler { try await writer.value } onCancel: { writer.cancel() }
        } catch {
            if error is CancellationError { throw error }
            throw exportWriteFailure(error, record: record, filename: finalName)
        }

        // Bước 6: ExportRecord success (file vẫn giữ nếu DB fail — §11.2.6)
        let file = ExportedFile(url: output.url, sha256: Hashing.sha256Hex(encoded))
        var completed = record
        completed.filename = finalName
        completed.destinationDisplayPath = file.url.path
        completed.destinationBookmarkID = request.destinationBookmark?.id
        completed.sha256 = file.sha256
        completed.status = .success
        completed.completedAtMs = Time.nowMs()
        do {
            try sessions.insertExportRecord(completed, verifyOutput: {
                try hook?(.beforeHistoryValidation, output.url)
                try destination.verify(output)
            })
        } catch AppError.exportLocationUnconfirmed {
            throw exportWriteFailure(AppError.exportLocationUnconfirmed, record: record, filename: finalName)
        } catch {
            // A database error can occur even before the verification closure runs.
            do { try destination.verify(output) }
            catch { throw exportWriteFailure(error, record: record, filename: finalName) }
            Log.export.error("Ảnh đã lưu nhưng chưa ghi lịch sử xuất: \(error.localizedDescription, privacy: .public)")
            EventBus.shared.post(.exportFinished(sessionID: request.sessionID, recordID: record.id, success: false))
            throw AppError.exportHistoryNotSaved(file)
        }
        EventBus.shared.post(.exportFinished(sessionID: request.sessionID, recordID: record.id, success: true))
        return (completed, file)
    }

    private func exportWriteFailure(_ error: Error, record: ExportRecordModel, filename: String) -> AppError {
        var failed = record
        failed.status = .failed
        failed.filename = filename
        _ = try? sessions.insertExportRecord(failed)
        EventBus.shared.post(.exportFinished(sessionID: record.sessionID, recordID: record.id, success: false))
        if let appError = error as? AppError {
            switch appError {
            case .diskFull, .exportFileExists, .exportFailed, .exportLocationUnconfirmed, .exportFolderChanged:
                return appError
            default: break
            }
        }
        if (error as? POSIXError)?.code == .ENOSPC { return .diskFull }
        return .exportFailed(error.localizedDescription)
    }

    /// Chuẩn hóa tên file: bỏ ký tự tạo thư mục con hoặc cấm trên APFS, trim, fallback tên mặc định.
    public static func sanitizedFilenameBase(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Photobooth" : cleaned
    }

    public static func encode(cg: CGImage, format: ExportImageFormat, quality: Int) throws -> Data {
        let out = NSMutableData()
        let uti = format == .jpeg ? UTType.jpeg.identifier as CFString : UTType.png.identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(out, uti, 1, nil) else {
            throw AppError.ioFailure("Tạo encoder thất bại")
        }
        var props: [CFString: Any] = [:]
        if format == .jpeg {
            props[kCGImageDestinationLossyCompressionQuality] = Double(max(1, min(100, quality))) / 100.0
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest), let data = out as Data? else {
            throw AppError.ioFailure("Encode ảnh thất bại")
        }
        return data
    }

    func resolveExportFolder(bookmarkID: String?) throws -> URL {
        guard let bookmarkID, let stored = try trashRepo.bookmark(id: bookmarkID) else {
            throw AppError.externalFolderPermissionLost
        }
        var stale = false
        let url = (try? URL(resolvingBookmarkData: stored.blob, options: [.withSecurityScope, .withoutUI],
                           relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: stored.blob, options: [.withoutUI],
                         relativeTo: nil, bookmarkDataIsStale: &stale))
        guard let url, !stale else { throw AppError.externalFolderPermissionLost }
        return url
    }

    /// Auto Export khi nhấn Hoàn thành (§10.1, mặc định Tắt, A2 + A8).
    public func autoExport(detail: SessionDetail, folderBookmarkID: String?,
                           format: ExportImageFormat = .jpeg, quality: Int = 95,
                           parentToken: OperationCoordinator.OperationToken? = nil) async -> Result<URL, AppError> {
        guard let folderBookmarkID, let use = try? trashRepo.useBookmark(id: folderBookmarkID),
              let folder = try? resolveExportFolder(bookmarkID: use.id) else {
            return .failure(.externalFolderPermissionLost)
        }
        let base = Self.defaultFilenameBase()
        var req = ExportRequest(sessionID: detail.session.id, format: format,
                                quality: quality,
                                width: detail.snapshot.canvasWidth,
                                height: detail.snapshot.canvasHeight,
                                filenameBase: base, destinationFolder: folder,
                                securityScoped: true, replaceExisting: false)
        req.destinationBookmark = use
        do {
            let (_, url) = try await export(detail: detail, request: req, parentToken: parentToken)
            return .success(url)
        } catch let e as AppError {
            return .failure(e)
        } catch {
            return .failure(.exportFailed(error.localizedDescription))
        }
    }
}

/// Keep selection, staging and the final rename relative to the same opened export folder.
private final class ExportDestination: @unchecked Sendable {
    struct Output: Sendable {
        let url: URL
        let version: stat
    }

    let name: String
    private let url: URL
    private let directory: Int32
    private let expected: stat?

    init(folder: URL, base: String, ext: String, replace: Bool,
         selectedFolderIdentity: ExportService.DirectoryIdentity?) throws {
        guard !base.utf8.contains(0) else {
            throw AppError.exportFailed("Tên tệp hoặc thư mục xuất không hợp lệ.")
        }
        let fd: Int32
        do {
            fd = try Self.openDirectory(folder)
        } catch let error as POSIXError where selectedFolderIdentity != nil && [.ENOENT, .ENOTDIR, .EACCES, .EPERM].contains(error.code) {
            throw AppError.exportFolderChanged
        }
        do {
            if let selectedFolderIdentity, ExportService.DirectoryIdentity(try Self.info(fd)) != selectedFolderIdentity {
                throw AppError.exportFolderChanged
            }
            var name = "\(base).\(ext)"
            var entry = try Self.entry(in: fd, name: name)
            if replace {
                if let entry, !Self.isRegular(entry) {
                    throw AppError.exportFailed("Đích trùng tên không phải tệp thường. Hãy chọn tên khác hoặc tắt ghi đè.")
                }
            } else {
                var suffix = 0
                while entry != nil {
                    suffix += 1
                    guard suffix <= 999 else { throw AppError.exportFileExists }
                    name = "\(base) (\(suffix)).\(ext)"
                    entry = try Self.entry(in: fd, name: name)
                }
            }
            self.directory = fd
            self.name = name
            self.url = folder.appendingPathComponent(name)
            self.expected = entry
        } catch {
            close(fd)
            throw error
        }
    }

    deinit { close(directory) }

    func write(_ encoded: Data, partialName: String,
               hook: (@Sendable (ExportService.FileCommitStep, URL) throws -> Void)?) throws -> Output {
        try Task.checkCancellation()
        let fd = openat(directory, partialName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o666))
        guard fd >= 0 else { throw Self.posix(errno) }
        defer {
            if let partial = try? Self.entry(in: directory, name: partialName),
               let opened = try? Self.info(fd), Self.sameItem(partial, opened) {
                _ = unlinkat(directory, partialName, 0)
            }
            close(fd)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: encoded)
        try handle.seek(toOffset: 0)
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        guard !encoded.isEmpty, hash.finalize() == SHA256.hash(data: encoded) else {
            throw AppError.ioFailure("Verify export thất bại")
        }

        try hook?(.beforeCoordination, url)
        if let expected {
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var result: Result<Output, Error>?
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
                result = Result {
                    try hook?(.insideCoordination, self.url)
                    try self.requireSameFolder(coordinatedURL)
                    try self.requireUnchanged(expected)
                    let old = openat(self.directory, self.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard old >= 0 else { throw Self.posix(errno) }
                    defer { close(old) }
                    let metadata = try Self.info(old)
                    guard Self.sameVersion(metadata, expected) else { throw Self.destinationChanged }
                    try hook?(.beforeMetadata, self.url)
                    try Self.copyMetadata(from: old, metadata: metadata, to: fd)
                    return try self.commit(partialName, fd: fd, flags: UInt32(RENAME_NOFOLLOW_ANY), hook: hook)
                }
            }
            if let result { return try result.get() }
            try requireSameFolder(url)
            throw coordinationError ?? Self.destinationChanged as NSError
        } else {
            return try commit(partialName, fd: fd, flags: UInt32(RENAME_NOFOLLOW_ANY | RENAME_EXCL), hook: hook)
        }
    }

    private func commit(_ partial: String, fd: Int32, flags: UInt32,
                        hook: (@Sendable (ExportService.FileCommitStep, URL) throws -> Void)?) throws -> Output {
        try hook?(.beforeRename, url)
        try Task.checkCancellation()
        guard let staged = try Self.entry(in: directory, name: partial), Self.isRegular(staged),
              Self.sameItem(staged, try Self.info(fd)) else { throw Self.destinationChanged }
        try requireSameFolder(url)
        if let expected { try requireUnchanged(expected) }
        // Non-swap rename cannot displace a directory. The final entry is never followed;
        // a process bypassing file coordination can still change it after the check.
        guard renameatx_np(directory, partial, directory, name, flags) == 0 else {
            let code = errno
            if code == EEXIST { throw AppError.exportFileExists }
            if code == EISDIR || code == ELOOP { throw Self.destinationChanged }
            throw Self.posix(code)
        }
        do {
            // Capture the version after rename because rename may change ctime.
            let output = Output(url: url, version: try Self.info(fd))
            try hook?(.afterRename, url)
            try verify(output)
            return output
        } catch {
            throw AppError.exportLocationUnconfirmed
        }
    }

    func verify(_ output: Output) throws {
        do { try requireSameFolder(output.url) }
        catch { throw AppError.exportLocationUnconfirmed }
        var current = stat()
        guard lstat(output.url.path, &current) == 0, Self.sameVersion(current, output.version) else {
            throw AppError.exportLocationUnconfirmed
        }
    }

    private func requireUnchanged(_ expected: stat) throws {
        guard let current = try Self.entry(in: directory, name: name), Self.sameVersion(current, expected) else {
            throw Self.destinationChanged
        }
    }

    private func requireSameFolder(_ coordinatedURL: URL) throws {
        let current = open(coordinatedURL.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { throw AppError.exportFolderChanged }
            throw Self.posix(code)
        }
        defer { close(current) }
        guard Self.sameItem(try Self.info(current), try Self.info(directory)) else {
            throw AppError.exportFolderChanged
        }
        guard coordinatedURL.lastPathComponent == name else { throw Self.destinationChanged }
    }

    private static var destinationChanged: AppError {
        .exportFailed("Tệp đích đã thay đổi. Hãy kiểm tra và xuất lại.")
    }

    static func openDirectory(_ folder: URL) throws -> Int32 {
        guard folder.isFileURL, !folder.path.utf8.contains(0) else {
            throw AppError.exportFailed("Tên tệp hoặc thư mục xuất không hợp lệ.")
        }
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw posix(errno) }
        return fd
    }

    private static func entry(in directory: Int32, name: String) throws -> stat? {
        var value = stat()
        if fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }
        let code = errno
        if code == ENOENT { return nil }
        throw posix(code)
    }

    static func info(_ fd: Int32) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw posix(errno) }
        return value
    }

    private static func isRegular(_ info: stat) -> Bool { info.st_mode & S_IFMT == S_IFREG }

    private static func sameItem(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_gen == b.st_gen
    }

    private static func sameVersion(_ a: stat, _ b: stat) -> Bool {
        isRegular(a) && sameItem(a, b) && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    private static func copyMetadata(from old: Int32, metadata: stat, to staged: Int32) throws {
        var birth = metadata.st_birthtimespec
        if birth.tv_sec != 0 || birth.tv_nsec != 0 {
            var attributes = attrlist()
            attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            attributes.commonattr = UInt32(ATTR_CMN_CRTIME)
            guard fsetattrlist(staged, &attributes, &birth, MemoryLayout<timespec>.size, 0) == 0 else { throw posix(errno) }
        }
        for key in ["com.apple.FinderInfo", "com.apple.metadata:_kMDItemUserTags", "com.apple.metadata:kMDItemFinderComment"] {
            guard var bytes = try attribute(key, fd: old) else { continue }
            if key == "com.apple.FinderInfo" {
                // Only the label/color bits belong to the old image, not its Finder type or flags.
                guard bytes.count == 32 else { throw AppError.ioFailure("Nhãn Finder của tệp đích không hợp lệ") }
                let label = bytes[9] & 0x0e
                bytes = Data(repeating: 0, count: 32)
                bytes[9] = label
            }
            let status = bytes.withUnsafeBytes { fsetxattr(staged, key, $0.baseAddress, $0.count, 0, 0) }
            guard status == 0 else { throw posix(errno) }
        }
        guard fchmod(staged, metadata.st_mode & mode_t(0o777)) == 0 else { throw posix(errno) }
        if let acl = acl_get_fd_np(old, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            guard acl_set_fd_np(staged, acl, ACL_TYPE_EXTENDED) == 0 else { throw posix(errno) }
        } else {
            let code = errno
            guard [ENOENT, ENOATTR, ENOTSUP].contains(code) else { throw posix(code) }
        }
    }

    private static func attribute(_ key: String, fd: Int32) throws -> Data? {
        let count = fgetxattr(fd, key, nil, 0, 0, 0)
        if count < 0 {
            let code = errno
            if code == ENOATTR || code == ENOTSUP { return nil }
            throw posix(code)
        }
        var bytes = Data(count: count)
        let read = bytes.withUnsafeMutableBytes { fgetxattr(fd, key, $0.baseAddress, $0.count, 0, 0) }
        guard read >= 0 else { throw posix(errno) }
        guard read == count else { throw destinationChanged }
        return bytes
    }

    private static func posix(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
