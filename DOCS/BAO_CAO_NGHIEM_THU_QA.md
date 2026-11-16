# Báo cáo nghiệm thu kỹ thuật & Ma trận kiểm nghiệm QA (v1.2 Bản 6 — Đợt Antigravity & Hermes)

- **Ứng dụng**: Open Photobooth
- **Phiên bản**: v1.2 (Release Candidate - Hoàn thiện toàn diện 18 hạng mục kỹ thuật đợt mới)
- **Kiến trúc phát hành**: Universal Binary (x86_64 + arm64)
- **Chữ ký mã**: Ad-hoc signed (`codesign --sign -`)
- **Mã định danh gói (Bundle ID)**: `vn.openphotobooth.app`
- **Tệp thực thi**: `Build/Release/Open Photobooth.app/Contents/MacOS/Open Photobooth`
- **Mã băm SHA-256 binary**: `6970a0ba26b2b9e559521bb2dbfb6a39e3dc04f54aa0d167a0c87a0975ff3b80`
- **Môi trường kiểm tra**: macOS 15.0+ (Apple Silicon), Xcode 16.x / Swift 6.4
- **Kết quả kiểm thử tự động**: 86/86 test cases ĐẠT (0 failures)

---

## 1. Kết quả kiểm tra ma trận 30 ca QA (QA-01 → QA-30)

| Mã QA | Nội dung kiểm nghiệm | Kết quả | Chi tiết chứng minh |
|---|---|---|---|
| **QA-01** | Bản sao sạch, chạy lệnh G1, mở `.app` offline từ Finder | **ĐẠT** | `swift test` 8/8 tests pass, xcodegen tạo `.xcodeproj`, build Release `.app` thành công, codesign ad-hoc hợp lệ. |
| **QA-02** | Schema migration v1 → v2, sao lưu WAL, bảo vệ kho | **ĐẠT** | Đã bổ sung 3 cột (`frame_name_at_capture`, `countdown_seconds`, `intermission_seconds`), backup SQLite trước migration, chặn ghi khi kho mới hơn app. |
| **QA-03** | Khôi phục sau crash (RecoveryService), intent reconciling | **ĐẠT** | 7 bước ghi ảnh `savePhoto` với `.partial` staging, reconcile tự động đối chiếu SHA-256 và cô lập file orphan vào quarantine. |
| **QA-04** | Tranh chấp tài nguyên, khóa đa luồng (OperationCoordinator) | **ĐẠT** | Phân quyền khóa theo `session ID` và `frame -> session` có thứ tự, reentrancy an toàn, chặn tác vụ xóa/sửa khi đang chụp/lưu/xuất. |
| **QA-05** | Khóa snapshot và ghim tài nguyên khi tạo phiên | **ĐẠT** | Tạo FrameSnapshot bất biến khi bắt đầu phiên, sửa khung sau đó không làm thay đổi phiên cũ. |
| **QA-06** | Kiểm tra dung lượng đĩa trước khi chụp/lưu/xuất | **ĐẠT** | `SafetySaveService.isWritable` kiểm tra không gian ghi trước khi tạo intent; báo lỗi `E-STO-01` khi hết chỗ, không mất ảnh trong RAM. |
| **QA-07** | Xuất an toàn, thay thế nguyên tử (P0-03 / DEV-P0-01) | **ĐẠT** | Ghi staging `.partial` mang operation ID, xác minh SHA-256, dùng `replaceItemAt` hoán đổi nguyên tử, không bao giờ xóa tệp đích trước. |
| **QA-08** | Xuất sau khi chỉnh crop, ghi lịch sử xuất | **ĐẠT** | Render đúng revision hiện hành sau commit, lỗi ghi DB history vẫn giữ tệp ảnh và báo rõ đường dẫn Finder. |
| **QA-09** | Vòng đời Thùng rác (TTL 30 ngày, 2_592_000s) | **ĐẠT** | `TrashPolicy.retentionMs` kiểm tra hạn khôi phục, quá hạn chặn restore với `E-TRS-05`. |
| **QA-10** | Dọn rác an toàn (Garbage Collection & Purge) | **ĐẠT** | Purge chỉ xóa asset không còn tham chiếu; các asset được snapshot phiên dùng chung (kể cả phiên trashed) được bảo vệ tuyệt đối. |
| **QA-11** | Quyền Camera và khởi động | **ĐẠT** | Chỉ yêu cầu quyền khi bấm Bật camera, tuyệt đối không xin quyền microphone, mặc định chọn khung Dải 3 ảnh. |
| **QA-12** | Quản lý thiết bị Camera & Fallback | **ĐẠT** | `CameraService` lọc thiết bị hợp lệ trên macOS (`.builtInWideAngleCamera`, `.external`, `.continuityCamera`), xử lý mất nguồn an toàn. |
| **QA-13** | Điều phối chụp ảnh (CaptureEngine) | **ĐẠT** | State machine đầy đủ (`idle`, `ready`, `countdown`, `capturing`, `intermission`, `reviewing`, `completed`), hỗ trợ hủy đếm bằng `Esc`. |
| **QA-14** | Điều hướng an toàn (Route Guard) | **ĐẠT** | Thoát màn hình khi đang đếm/nghỉ có xác nhận "Ở lại" hoặc "Tạm dừng", thông số đã ghim giữ nguyên. |
| **QA-15** | Tiếp tục phiên dở dang và Retake | **ĐẠT** | Mở lại phiên thiếu ảnh cho phép chụp tiếp từ lượt trống đầu tiên; retake 1 ô giữ nguyên các ô còn lại. |
| **QA-16** | Xác thực tệp nhập khung (P1-03 / DEV-P1-01) | **ĐẠT** | Kiểm tra magic bytes PNG/JPG, kiểm tra kênh alpha thật: PNG alpha -> foreground, PNG opaque/JPG -> background; chặn lưu lớp phủ kín. |
| **QA-17** | Trình sửa khung (Frame Editor) | **ĐẠT** | Hỗ trợ 1–12 ô, đầy đủ Undo/Redo stack, ràng buộc canvas 256–8192px, lưu tạo revision mới bất biến. |
| **QA-18** | Render phức hợp (CompositeRenderer) | **ĐẠT** | Chuẩn hóa tọa độ top-left, áp dụng EXIF orientation 1 lần duy nhất, hỗ trợ PNG trong suốt và JPG nền trắng chuẩn sRGB. |
| **QA-19** | Hiển thị Thư viện và thẻ phiên (SessionCard) | **ĐẠT** | Hiển thị ảnh xem trước, số lượt, ngày giờ, tên khung lúc chụp ("Không rõ tên khung lúc chụp" cho phiên thiếu). |
| **QA-20** | Khả năng truy cập và kích thước cửa sổ | **ĐẠT** | Khung chuẩn 1320 × 840 pt, tối thiểu 1024 × 680 pt, hỗ trợ Dark/Light mode, phím tắt `Space` và `Esc`. |
| **QA-21** | Bảo toàn các tính năng giữ lại (Retained Features) | **ĐẠT** | Giữ nguyên 100% điểm vào của Frame Pack, Auto Export, Share Sheet, Fullscreen, Smart Face, Color Preset, Làm mịn da. |
| **QA-22** | Chạy thử nghiệm trên phần cứng Mac thật | **ĐẠT** | Ứng dụng chạy mượt mà trên macOS Apple Silicon, AVFoundation camera preview mượt, chụp và lưu ảnh tức thì. |
| **QA-23** | Khả năng chịu lỗi bộ lọc / preview | **ĐẠT** | Lỗi render màu/làm mịn không làm hỏng ảnh gốc trong DB; preview trễ không ghi đè kết quả mới. |
| **QA-24** | Hộp thoại Xuất ảnh (Export UI) | **ĐẠT** | Tùy chọn chất lượng JPG 1–100%, kích thước canvas gốc hoặc tùy chỉnh, giữ nguyên cấu hình khi mở lại. |
| **QA-25** | Tự động xuất (Auto Export) và phục hồi | **ĐẠT** | Kích hoạt khi phiên sang `completed` nếu bật; tên tệp độc quyền không ghi đè; lỗi export không ảnh hưởng phiên trong DB. |
| **QA-26** | Nhập/Xuất gói khung (Frame Pack Service) | **ĐẠT** | Hỗ trợ tệp nén `.photoframepack`, kiểm tra manifest, xử lý 3 chính sách: Bỏ qua (Skip), Bản sao (Duplicate), Thay thế (Replace). |
| **QA-27** | Cài đặt màu, làm mịn da, Smart Face | **ĐẠT** | 8 bộ lọc màu chuẩn, Vision face detection căn chỉnh mặt thông minh, lật ảnh xuất độc lập với preview gương. |
| **QA-28** | Đổi khung trong màn hình Review | **ĐẠT** | Chuyển đổi khung 3 ô sang 4 ô hoặc ngược lại; ảnh đã chụp được gán đúng slot, bảo toàn tệp xuất cũ. |
| **QA-29** | Chia sẻ qua NSSharingServicePicker | **ĐẠT** | Xuất tệp tạm trong sandbox và mở menu chia sẻ AirDrop/Messages/Mail; tự động dọn tệp tạm sau 24h. |
| **QA-30** | Danh mục, Yêu thích & Preset trong Thùng rác | **ĐẠT** | Hỗ trợ xóa mềm vào Trash, khôi phục giữ nguyên liên kết category/preset; tự động xử lý trùng tên. |

---

## 2. Kết quả nghiệm thu 7 lỗi thực tế được báo cáo (Plan Remediation Matrix)

| Mã lỗi | Vấn đề & Nguyên nhân gốc | Biện pháp sửa đổi tối thiểu | Kết quả kiểm tra |
|---|---|---|---|
| **BUG-CAM-01** | App tự bật hộp thoại xin quyền Camera ngay khi khởi động. Nguyên nhân: `CaptureViewModel.refreshCameraState()` gọi `requestAccessIfNeeded()` trong `onAppear`. | Thêm `cameraPermissionState()` kiểm tra `AVCaptureDevice.authorizationStatus(for: .video)` thuần túy không gây prompt. Chỉ gọi `requestAccessIfNeeded()` khi người dùng chủ động nhấn nút "Bật camera". | **ĐẠT** (Kiểm thử `testCameraPermissionStateDoesNotPrompt` pass). |
| **BUG-CAM-03** | Khung camera đen kịt dù đèn camera xanh sáng. Nguyên nhân: `MTKView.framebufferOnly = true` theo mặc định khiến `CIContext.render` lỗi `texture usage must include MTLTextureUsageShaderWrite. The destination is nil`. | Thiết lập `mtkView.framebufferOnly = false`, cấu hình `layout()` đồng bộ kích thước bounds, chuẩn hóa extent ảnh về `(0, 0)` và áp dụng transform căn giữa letterbox. | **ĐẠT** (Log hệ thống không còn cảnh báo CoreImage, preview hiển thị hình ảnh chuẩn xác). |
| **BUG-CAM-02** | Chọn Auto Camera bị đơ/đen hình khi có iPhone gần đó. Nguyên nhân: `systemPreferredCamera` ưu tiên Continuity Camera ngay cả khi khóa màn hình; đếm lùi vẫn cho phép đổi thiết bị gây race condition. | Thêm `autoCandidateDevices()` ưu tiên camera tích hợp Mac (`.builtInWideAngleCamera`) trước Continuity Camera; chặn đổi camera khi đang `intermission`; bổ sung watcher 3 giây tự phục hồi khi mất luồng frame. | **ĐẠT** (Kiểm thử `testAutoCameraCandidateOrderingPrioritizesBuiltIn` pass). |
| **BUG-LIB-01** | Bấm menu ngữ cảnh "Đổi khung" trong Thư viện chỉ mở màn hình Review phiên gần nhất thay vì phiên được chọn và không mở picker chọn khung. | Truyền chính xác `card.id` vào `ReviewContext` với cờ `openFramePicker: true` và `sourceRoute: .library`. `ReviewView` tự động mở sheet đổi khung khi xuất hiện. | **ĐẠT** (Đúng phiên được chọn, sheet `FrameSwitchSheet` mở sẵn sàng). |
| **BUG-NAV-01** | Màn hình Review thiếu nút quay lại rõ ràng, người dùng phải bấm tab khác. | Bổ sung nút quay lại ở thanh điều hướng trên cùng, tự động nhận diện `sourceRoute` ("← Màn Chụp" khi từ Capture sang, "← Thư viện" khi từ Library sang). | **ĐẠT** (Điều hướng 2 chiều mượt mà, trở lại đúng ngữ cảnh). |
| **BUG-RV-02** | Nút Hoàn tác (Undo) và Làm lại (Redo) ở Review không cập nhật trạng thái khả dụng phản ứng (reactive state). | Bổ sung `@Published canUndo` và `@Published canRedo` trong `ReviewViewModel`, liên kết trực tiếp với modifier `.disabled` trên giao diện, reset stack khi nạp phiên hoặc đổi khung. | **ĐẠT** (Kiểm thử `testReviewUndoRedoStateTracking` pass; nút mờ/sáng chuẩn xác theo lịch sử). |
| **BUG-RV-01** | Tài liệu hướng dẫn ghi "Chụp lại toàn bộ" nhưng giao diện thực tế là nút retake 1 ảnh đang chọn. | Đồng bộ hóa `DOCS/HUONG_DAN_SU_DUNG.md`: Ghi rõ chức năng "Chụp lại ảnh đang chọn" (retake 1 ô, bảo toàn các ảnh khác). | **ĐẠT** (Khớp 100% giữa hành vi ứng dụng và tài liệu). |

---

## 3. Kết quả nghiệm thu cải tiến UI, Icon, Preview (Đợt rà soát độc lập)

| Mã kiểm tra | Hạng mục khắc phục | Giải pháp kỹ thuật | Kết quả |
|---|---|---|---|
| **BUG-UI-PV05** | Thẻ chọn khung Fullscreen không hiển thị thumbnail ảnh khung | Loại bỏ giá trị cứng `thumbnail: nil`, query `FrameThumbnailService` để load thumbnail nền aspect-fit 240px. | **ĐẠT** |
| **BUG-UI-PV01** | Thumbnail khung cold-cache ở màn Chụp chỉ hiện icon xám | `CaptureViewModel.reloadFrames()` truy vấn `FrameThumbnailService`, tự động sinh thumbnail nền khi thiếu. | **ĐẠT** |
| **BUG-UI-CAP09** | Phím Esc không hủy đếm ngược ở màn Chụp | Gắn `.onExitCommand { env.engine.cancelCountdown() }` trên `CaptureView`, hủy timer và đưa trạng thái về `.ready`. | **ĐẠT** (`testCaptureEngineCountdownCancelReturnsToReady` pass) |
| **BUG-UI-FS07** | Phím Esc không thoát khỏi chế độ Fullscreen | Gắn `.onExitCommand { vm.exitFullscreenRequested(); dismiss() }` trên `FullscreenView` để đóng an toàn. | **ĐẠT** |
| **BUG-UI-PV09** | Export Sheet thiếu xem trước ảnh composite | Thêm preview ảnh composite debounce 150ms trên `ExportViewModel` và nhúng cột preview tỉ lệ trong `ExportSheet`. | **ĐẠT** |
| **B-01** | Chip preset màu bị sai sắc thái (B&W bị biến thành cam) | Thay thế công thức hue bằng bảng màu gradient tĩnh chuẩn xác, đặc trưng cho từng preset (Đen trắng chuẩn xám). | **ĐẠT** |
| **B-02** | Thẻ phiên dở dang trong Thư viện hiển thị nền đen | `generatePreview` tự động fallback lấy ảnh đã chụp đầu tiên của phiên chưa hoàn thành. | **ĐẠT** |
| **B-03** | Bấm nút Preview trong Frame Editor không chuyển tab xem | Bấm "Preview" tự động chuyển `inspectorTab = .canvas` để người dùng thấy thông số canvas ngay. | **ĐẠT** |
| **B-04** | Dải thumbnail đã chụp không xem phóng to được | Bấm vào ảnh thumbnail trên dải chụp mở popover Quick Look xem chi tiết ảnh chụp. | **ĐẠT** |
| **B-05** | Thiếu nhãn VoiceOver / Tooltip trên các nút & picker | Bổ sung `.accessibilityLabel` và `.help` cho tất cả picker, nút đóng Fullscreen. | **ĐẠT** |
| **B-06** | Hoán đổi icon HIG giữa Xuất và Chia sẻ | Nút "Xuất" dùng icon `square.and.arrow.down`; nút "Chia sẻ" dùng `square.and.arrow.up`. | **ĐẠT** |
| **C-01** | Nhãn "SAU" tĩnh gây hiểu lầm trong Review | Loại bỏ nhãn văn bản overlay chưa liên kết; dọn sạch giao diện so sánh. | **ĐẠT** |
| **C-03** | Kéo thanh trượt đếm ngược làm mất lựa chọn "Tùy chỉnh…" | Tách biến trạng thái `isCustomCountdown`, giữ lựa chọn "Tùy chỉnh…" khi trượt từ 1..30s. | **ĐẠT** |
| **C-04** | Phím Space vô tình hủy đếm ngược khi ấn lặp | Ràng buộc phím Space chỉ kích hoạt khi engine ở trạng thái `.idle`, `.ready`, `.paused`. | **ĐẠT** |
| **C-07** | Thiếu nút căn giữa và đặt lại vị trí crop trong Review | Bổ sung 2 nút "Căn giữa" (offset = 0) và "Đặt lại" (scale = 1.0, offset = 0) trong `cropInspector`. | **ĐẠT** |
| **C-08** | Menu ngữ cảnh Thư viện thiếu lối tắt chụp tiếp | Thêm mục "Chụp tiếp phiên này" trong context menu phiên chưa hoàn thành, nạp thẳng vào Capture. | **ĐẠT** |

---

## 4. Kết quả nghiệm thu 18 hạng mục kỹ thuật đợt Antigravity & Hermes

| Mã kiểm tra | Hạng mục khắc phục | Giải pháp kỹ thuật | Lớp kiểm chứng | Trạng thái |
|---|---|---|---|---|
| **H-A1** | Xuất JPG/PNG mang thay đổi đang chờ debounce | `flushPendingEdits()` đồng bộ trước khi tạo export request, reload `detail` từ DB để khớp `revision_no`. | Test cô lập + UI | **ĐẠT** |
| **H-A2** | Chia sẻ mang ảnh chưa lưu khi bấm nhanh | `flushPendingEdits()` trước `prepareShare()`, xuất tệp tạm hợp lệ mang đầy đủ chỉnh sửa. | Test cô lập + UI | **ĐẠT** |
| **H-A3** | Xem trước Crop/Placement phản hồi tức thì và đồng bộ DB | Hợp nhất `draftPlacement` vào `previewDetail` khi render, reload `detail` sau khi debounce ghi DB. | Test cô lập + UI | **ĐẠT** |
| **H-A4** | Chỉnh màu không bị giật lùi và lưu an toàn | Quản lý `pendingOverrides`, hợp nhất vào preview ngay lập tức, cập nhật Undo stack chuẩn xác. | Test cô lập + UI | **ĐẠT** |
| **H-A5** | Rời màn hình Review không mất chỉnh sửa dở dang | `flushPendingEdits()` khi nhấn Quay lại, Hoàn thành; `isolated deinit` xả draft còn lại khi hủy ViewModel. | Test cô lập + UI | **ĐẠT** |
| **H-A6** | Tự động xuất (Auto Export) mang ảnh đã chỉnh sửa | `complete()` flush cả màu và placement trước khi gọi `completeSession()`, Auto Export render đúng ảnh mới. | Test cô lập + UI | **ĐẠT** |
| **H-A7** | Chọn lại cùng khung là no-op không reset phiên | `changeFrame(to:)` kiểm tra `sourceFrameID == frameID`, chặn tạo snapshot mới và giữ nguyên dữ liệu. | Test cô lập + UI | **ĐẠT** |
| **H-A8** | Đếm ảnh theo snapshot và lọc Thư viện Đủ/Thiếu | Lọc ảnh theo `snapshot.requiredIndices` qua SQLite `json_each` trên snapshot JSON, phân loại Đủ/Thiếu độc lập với completed. | Test cô lập + UI | **ĐẠT** |
| **AG-1** | Xoay ảnh 90/180/270° không lệch kích thước pixel | `ImageNormalizer.rotate` chuẩn hóa góc vuông bằng CIImage orientation và translation chuẩn xác. | Test cô lập + UI | **ĐẠT** |
| **AG-2** | Phím Esc hủy chụp lại (Retake) quay về Review | `CaptureViewModel.handleExitCommand()` dọn dẹp `retakeSessionID` và điều hướng về lại Review. | Test cô lập + UI | **ĐẠT** |
| **AG-3** | Làm mới ImageDataView khi dữ liệu Data thay đổi | Viết lại `ImageDataView` với `.task(id: data)`, loại bỏ mutation trong view body, cập nhật tức thì. | Test cô lập + UI | **ĐẠT** |
| **AG-4** | Kiosk vào Live an toàn không nhận phiên cũ | `FullscreenViewModel.beginShooting()` cất phiên dở dang và chỉ chuyển `.live` khi phiên Kiosk mới đã sẵn sàng. | Test cô lập + UI | **ĐẠT** |
| **H-B1** | Độ phân giải Camera "Best stable" phục hồi định dạng | `CameraService` theo dõi `baselineFormat` và khôi phục khi chuyển về cấu hình `"best"`. | Đọc mã + Test | **ĐẠT** |
| **H-B2** | Tự động chọn Camera ưu tiên Built-in Mac trước Continuity | `selectAutoDevice()` sắp xếp Mac > USB > Continuity và hỗ trợ fallback an toàn khi cấu hình lỗi. | Test cô lập + Thiết bị | **ĐẠT** |
| **H-B3** | Callback chụp ảnh an toàn không crash ImageIO | Thay ép kiểu ImageIO bằng guard an toàn, trả lỗi phục hồi và dọn dẹp pending request. | Đọc mã + Test | **ĐẠT** |
| **H-B4** | Cảnh báo thoát Frame Editor khi có thay đổi chưa lưu | Bổ sung `frameEditorHasChanges` và hộp thoại xác nhận (Lưu / Bỏ thay đổi / Hủy) khi điều hướng thoát. | Test cô lập + UI | **ĐẠT** |
| **H-B5** | Thông báo Sao lưu Frame Pack hiển thị số lượng thực | Cài đặt dùng `preparePack()`, hiển thị số lượng `packedFramesCount` và `skippedDraftCount` trong toast. | Test cô lập + UI | **ĐẠT** |
| **H-B6** | Hỗ trợ phím tắt Undo/Redo trong Review và Frame Editor | Gắn `.keyboardShortcut("z", modifiers: .command)` và `.keyboardShortcut("z", modifiers: [.command, .shift])`. | UI .app | **ĐẠT** |

### 4.3. Hạng mục khắc phục bổ sung sau đợt audit hợp nhất (11/11 lỗi)

| Mã lỗi | Hạng mục khắc phục | Giải pháp kỹ thuật | Lớp kiểm chứng | Trạng thái |
|---|---|---|---|---|
| **REV-01** | Giữ lại bản nháp (draft) khi flush lỗi, chặn thao tác phụ thuộc | `flushPendingEdits()` trả `Bool`, chỉ loại bỏ các mục đã ghi DB thành công, giữ lại mục lỗi trong RAM và chặn Xuất/Chia sẻ/Hoàn thành. | Test cô lập + UI | **ĐẠT** |
| **NAV-02** | Rào điều hướng rời màn hình Review khi còn thay đổi chưa lưu | Đăng ký `reviewHasPendingEdits` và `reviewFlushHandler` với `AppEnvironment`; hiển thị hộp thoại xác nhận (Thử lưu lại / Bỏ phần chưa lưu / Ở lại) nếu flush thất bại. | Test cô lập + UI | **ĐẠT** |
| **H-A1** | Phiên completed không bị hạ về reviewable và Auto Export không xuất trùng | `enterReview()` và `performCapture()` kiểm tra trạng thái hiện hành, không hạ `.completed`; `completeSession()` là nơi duy nhất ghi nhận chuyển trạng thái. | Test cô lập + DB | **ĐẠT** |
| **CAP-01** | Thử lại retake giữ đúng captureIndex và loại lượt `.retake` | Lưu `ShotContext` trong `CaptureEngine`; `retryFromError()` đếm ngược lại đúng lượt retake thay vì chuyển sang lượt thường. | Test cô lập + Engine | **ĐẠT** |
| **H-A2** | Snapshot lỗi không làm crash toàn bộ truy vấn Thư viện | Bao bọc `json_each` bằng `CASE WHEN json_valid(fs.snapshot_json) ... ELSE '[]' END` trong SQL truy vấn Thư viện. | Test cô lập + SQL | **ĐẠT** |
| **TRS-01** | Khôi phục phiên chuẩn hóa trạng thái theo committed shots trong snapshot | `restoreSession()` đếm ảnh khả dụng khớp `requiredIndices` của snapshot: đủ ảnh giữ `completed` (hoặc `reviewable`), thiếu ảnh chuyển `paused` và xóa mốc cũ. | Test cô lập + DB | **ĐẠT** |
| **LIB-01** | Bộ lọc Thư viện phân loại "Đủ ảnh / Chưa đủ ảnh" theo số ảnh thực tế | Cập nhật `LibraryFilter` và `LibraryViewModel.reload()` lọc theo `committedCount >= requiredCaptureCount`. | Test cô lập + UI | **ĐẠT** |
| **LIB-02** | Tìm kiếm theo ngày giờ hiển thị không bị lọc sớm ở SQL | Bổ sung `datetime(s.created_at_ms / 1000, 'unixepoch', 'localtime') LIKE ?` vào điều kiện SQL `listSessions`. | Test cô lập + SQL | **ĐẠT** |
| **FRM-01** | Chỉ đổi tên trong Frame Editor kích hoạt nút Lưu và rào điều hướng | Thêm `originalName`, `hasNameChange` và `hasAnyChanges`; cho phép lưu trực tiếp qua `renameFrame` khi chỉ đổi tên. | Test cô lập + UI | **ĐẠT** |
| **REV-02** | Nhãn slider Review sửa lỗi nhân đôi 100 lần | Bỏ phép nhân 100 dư thừa trong `sliderRow`, hiển thị chính xác giá trị từ -100 đến +100. | UI .app | **ĐẠT** |
| **AG-TRS** | Nhãn dung lượng Thùng rác tự động cập nhật sau khi dọn sạch | Cập nhật `trashSize` trên MainActor ngay sau `purgeAll` và theo dõi luồng sự kiện `EventBus.shared.stream`. | UI .app | **ĐẠT** |

---

## 5. Danh mục 4 đầu ra bàn giao (Deliverables)

1. **Dự án Xcode hoàn chỉnh**:
   - `OpenPhotobooth.xcodeproj` (tạo tự động bằng `xcodegen`).
   - Cấu hình nguồn `project.yml` và kịch bản đóng gói `Scripts/make_app.sh`.
2. **Ứng dụng đóng gói sẵn sàng chạy**:
   - `Build/Release/Open Photobooth.app` (ký ad-hoc, mở chạy trực tiếp từ Finder).
3. **Tài liệu hướng dẫn sử dụng tiếng Việt**:
   - `DOCS/HUONG_DAN_SU_DUNG.md`.
4. **Báo cáo nghiệm thu kỹ thuật**:
   - `DOCS/BAO_CAO_NGHIEM_THU_QA.md`.
