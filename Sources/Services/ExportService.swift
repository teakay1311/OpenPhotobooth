import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

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
            if detail.session.defaults.smartFace ?? true {
                let detected = await faceAnalysis.detectFaces(cgImage: image,
                                                               cacheKey: "\(revision.id)|rot\(Int(resolved.photoRotation))")
                faces[index] = detected
            } else {
                faces[index] = []
            }
        }

        var placements: [String: PhotoPlacement] = [:]
        var cropModes: [String: CropMode] = [:]
        for slot in detail.snapshot.slots {
            if let p = detail.placements[slot.id] {
                placements[slot.id] = p.placement
                cropModes[slot.id] = p.cropMode
            }
        }

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

    /// A1: Nhánh nghiêm ngặt dùng chung cho Xuất tay, Auto Export và Tạo tệp Chia sẻ.
    /// Xác nhận từng ảnh hiện hành bắt buộc và mỗi lớp nền/lớp phủ được khai báo đều đọc và giải mã được từ đĩa thật.
    public func buildModelStrict(detail: SessionDetail, targetWidth: Int, targetHeight: Int,
                                 transparentBackground: Bool = false,
                                 matteColor: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)) async throws -> CompositionModel {
        if detail.needsPhotoSelection { throw AppError.invalidState("Chọn ảnh vào khung trước") }
        guard detail.hasEnoughPhotos else {
            throw AppError.notEnoughPhotos(missing: detail.missingCount)
        }
        var assetImages: [String: CGImage] = [:]
        if let bg = detail.snapshot.background {
            guard let img = try? assets.loadImage(assetID: bg.assetID) else {
                throw AppError.missingFrameAssets
            }
            assetImages[bg.assetID] = img
        }
        if let fg = detail.snapshot.foreground {
            guard let img = try? assets.loadImage(assetID: fg.assetID) else {
                throw AppError.missingFrameAssets
            }
            assetImages[fg.assetID] = img
        }

        var sources: [Int: RenderSource] = [:]
        var faces: [Int: [FaceBox]] = [:]
        let current = detail.currentRevisions()
        for index in detail.snapshot.requiredIndices {
            guard let revision = current[index], revision.state == .available else {
                throw AppError.notEnoughPhotos(missing: 1)
            }
            guard let url = try? sessions.fileURL(for: revision),
                  FileManager.default.fileExists(atPath: url.path),
                  let raw = ImageNormalizer.uprightImage(url: url) else {
                throw AppError.ioFailure("Tệp ảnh lượt \(index) bị thiếu hoặc hỏng trên ổ đĩa")
            }
            let resolved = ResolvedPhotoParams.resolve(defaults: detail.session.defaults,
                                                       override: detail.overrides[index])
            var decoded = ImageNormalizer.applyOutputMirror(raw, mirrored: detail.session.defaults.outputMirror)
            if resolved.photoRotation.truncatingRemainder(dividingBy: 360) != 0 {
                decoded = ImageNormalizer.rotate(decoded, degrees: resolved.photoRotation)
            }
            let cacheKey = "\(revision.id)|m\(detail.session.defaults.outputMirror ? 1 : 0)|r\(Int(resolved.photoRotation))"
            sourceImageCache.setObject(decoded, forKey: cacheKey as NSString)
            sources[index] = RenderSource(image: decoded)
            if detail.session.defaults.smartFace ?? true {
                let detected = await faceAnalysis.detectFaces(cgImage: decoded,
                                                              cacheKey: "\(revision.id)|rot\(Int(resolved.photoRotation))")
                faces[index] = detected
            } else {
                faces[index] = []
            }
        }

        var placements: [String: PhotoPlacement] = [:]
        var cropModes: [String: CropMode] = [:]
        for slot in detail.snapshot.slots {
            if let p = detail.placements[slot.id] {
                placements[slot.id] = p.placement
                cropModes[slot.id] = p.cropMode
            }
        }

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

    /// Render cache preview (Thư viện / Review / Sheet xuất) — key theo §11.1, D2-A09.
    public func renderPreview(detail: SessionDetail, maxDimension: Int, format: ExportImageFormat = .jpeg,
                              outputSize: (width: Int, height: Int)? = nil) async -> CGImage? {
        let width = outputSize?.width ?? detail.snapshot.canvasWidth
        let height = outputSize?.height ?? detail.snapshot.canvasHeight
        guard width > 0, height > 0, maxDimension > 0 else { return nil }
        let scale = Double(maxDimension) / Double(max(width, height))
        let previewWidth = max(1, Int((Double(width) * scale).rounded()))
        let previewHeight = max(1, Int((Double(height) * scale).rounded()))
        let model = await buildModel(detail: detail, targetWidth: previewWidth, targetHeight: previewHeight,
                                     transparentBackground: format == .png)
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

/// ExportService (§11.2): render → encode → ghi .partial → rename → ExportRecord.
public final class ExportService: @unchecked Sendable {
    private let sessions: SessionRepository
    private let builder: SessionRenderBuilder
    private let trashRepo: TrashRepository
    private let layout: FileLayout

    public init(sessions: SessionRepository, builder: SessionRenderBuilder,
                trashRepo: TrashRepository, layout: FileLayout) {
        self.sessions = sessions
        self.builder = builder
        self.trashRepo = trashRepo
        self.layout = layout
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
        guard request.sessionID == detail.session.id else {
            throw AppError.invalidState("Session ID không khớp giữa request và dữ liệu phiên")
        }
        // Khóa phiên chống xung đột ghi/xóa/đổi khung (DATA-01 / L7)
        let opToken = try OperationCoordinator.shared.acquire(key: "session:\(request.sessionID)", reason: "ExportService: exporting", parentToken: parentToken)
        defer { opToken.release() }

        // Xác nhận tính nhất quán với DB dưới khóa (§3.2.1)
        guard let latestSession = try sessions.getSession(id: request.sessionID),
              latestSession.status != .trashed else {
            throw AppError.notFound("Phiên chụp không tồn tại hoặc đã bị xóa")
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

        // Bước 5: .partial + verify + atomic swap/rename; an toàn với crash và không xóa đích trước verify
        let fm = FileManager.default
        var finalName = "\(filenameBase).\(request.format.fileExtension)"
        var finalURL = request.destinationFolder.appendingPathComponent(finalName)
        if fm.fileExists(atPath: finalURL.path) && !request.replaceExisting {
            var n = 1
            while fm.fileExists(atPath: request.destinationFolder.appendingPathComponent("\(filenameBase) (\(n)).\(request.format.fileExtension)").path) {
                n += 1
                if n > 999 {
                    throw AppError.exportFileExists
                }
            }
            finalName = "\(filenameBase) (\(n)).\(request.format.fileExtension)"
            finalURL = request.destinationFolder.appendingPathComponent(finalName)
        }

        // Tên .partial mang ID của thao tác xuất để tránh xung đột đa tiến trình/luồng
        let partialURL = request.destinationFolder.appendingPathComponent("\(finalName).\(record.id).partial")
        do {
            try encoded.write(to: partialURL, options: .atomic)
            guard encoded.count > 0, Hashing.sha256Hex(encoded) == Hashing.sha256Hex(fileURL: partialURL) else {
                throw AppError.ioFailure("Verify export thất bại")
            }
            if fm.fileExists(atPath: finalURL.path) && request.replaceExisting {
                // Thay thế nguyên tử an toàn: chỉ hoán đổi sau khi .partial đã xác thực, file cũ không bị xóa trước
                _ = try fm.replaceItemAt(finalURL, withItemAt: partialURL, backupItemName: nil, options: [])
            } else {
                try fm.moveItem(at: partialURL, to: finalURL)
            }
        } catch {
            try? fm.removeItem(at: partialURL)
            record.status = .failed
            record.filename = finalName
            _ = try? sessions.insertExportRecord(record)
            EventBus.shared.post(.exportFinished(sessionID: request.sessionID, recordID: record.id, success: false))
            if (error as? AppError)?.code == "E-STO-01" {
                throw AppError.diskFull
            }
            throw AppError.exportFailed(error.localizedDescription)
        }

        // Bước 6: ExportRecord success (file vẫn giữ nếu DB fail — §11.2.6)
        record.filename = finalName
        record.destinationDisplayPath = finalURL.path
        record.sha256 = Hashing.sha256Hex(encoded)
        record.status = .success
        record.completedAtMs = Time.nowMs()
        do {
            _ = try sessions.insertExportRecord(record)
        } catch {
            Log.export.error("Ảnh đã lưu nhưng chưa ghi lịch sử xuất: \(error.localizedDescription, privacy: .public)")
        }
        EventBus.shared.post(.exportFinished(sessionID: request.sessionID, recordID: record.id, success: true))
        return (record, finalURL)
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
        guard let folder = try? resolveExportFolder(bookmarkID: folderBookmarkID) else {
            return .failure(.externalFolderPermissionLost)
        }
        let base = Self.defaultFilenameBase()
        let req = ExportRequest(sessionID: detail.session.id, format: format,
                                quality: quality,
                                width: detail.snapshot.canvasWidth,
                                height: detail.snapshot.canvasHeight,
                                filenameBase: base, destinationFolder: folder,
                                securityScoped: true, replaceExisting: false)
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
