# Báo cáo nghiệm thu kỹ thuật & Ma trận kiểm nghiệm QA (v1.2 Bản 4)

- **Ứng dụng**: Open Photobooth
- **Phiên bản**: v1.2 (Release Candidate)
- **Kiến trúc phát hành**: Universal Binary (x86_64 + arm64)
- **Chữ ký mã**: Ad-hoc signed (`codesign --sign -`)
- **Mã định danh gói (Bundle ID)**: `vn.openphotobooth.app`
- **Tệp thực thi**: `Build/Release/Open Photobooth.app/Contents/MacOS/Open Photobooth`
- **Mã băm SHA-256 binary**: `1371cf6fb8983a7c15110cc807255bf7ae94d74280dd0e372ff789031bd7dbd8`
- **Môi trường kiểm tra**: macOS 15.0+ (Apple Silicon), Xcode 16.x / Swift 6.4

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

## 2. Danh mục 4 đầu ra bàn giao (Deliverables)

1. **Dự án Xcode hoàn chỉnh**:
   - `OpenPhotobooth.xcodeproj` (tạo tự động bằng `xcodegen`).
   - Cấu hình nguồn `project.yml` và kịch bản đóng gói `Scripts/make_app.sh`.
2. **Ứng dụng đóng gói sẵn sàng chạy**:
   - `Build/Release/Open Photobooth.app` (ký ad-hoc, mở chạy trực tiếp từ Finder).
3. **Tài liệu hướng dẫn sử dụng tiếng Việt**:
   - `DOCS/HUONG_DAN_SU_DUNG.md`.
4. **Báo cáo nghiệm thu kỹ thuật**:
   - `DOCS/BAO_CAO_NGHIEM_THU_QA.md`.
