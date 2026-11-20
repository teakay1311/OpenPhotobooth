# Báo cáo sửa ba nhóm lỗi Open Photobooth — 19/11/2026

## Phạm vi và trạng thái

Triển khai theo kế hoạch đã chốt: kiểm tra lớp phủ thống nhất, Auto Face lần ghép đầu có tương thích phiên cũ, và nhận diện khung trùng trong Frame Pack. Không thêm tính năng sản phẩm, không build DMG, không cài đè ứng dụng hoặc sửa dữ liệu sản xuất.

HEAD nền: `9792a093bf4710311a44826b729fa9532ec8ce10`. Workspace đã có nhiều thay đổi trước đợt này; chúng được giữ lại, không reset hay commit tự động.

## Những gì đã sửa

### 1. Kiểm tra lớp phủ và ghi dữ liệu

- `FrameRepository.configuredIssues` dùng chung validator hình học và phép kiểm tra pixel gốc theo từng mask/rotation/placement. Tài nguyên thiếu, hỏng hoặc sai checksum không được bỏ qua.
- Áp dụng cho lưu PNG, lưu chỉnh bố cục và nhập Frame Pack Copy/Replace. Frame Pack kiểm tra trước vùng ghi; lỗi không để lại khung rỗng hoặc thay revision của khung đích.
- `validatedSnapshotForUse` kiểm tra cả khung cũ đang mang trạng thái ready khi áp dụng mới hoặc chụp lại tất cả. Đọc snapshot cũ và công cụ sửa khung vẫn truy cập được; không tự migration thư viện.
- `saveConfiguredRevision` ghi revision, slots, references, metadata, dấu nền trắng và trạng thái ready trong transaction; đối chiếu revision/lifecycle trước commit.
- Trình chỉnh bố cục kiểm tra và lưu ngoài main thread, loại bỏ kết quả bất đồng bộ cũ và giữ bản nháp khi lỗi. Chặn điều hướng trong lúc lưu.
- Bổ sung `updated_at_ms` cho dấu nền trắng trong đường ghi đã chỉnh, đúng ràng buộc schema.

### 2. Auto Face và phiên cũ

- Thêm trường JSON tùy chọn `autoFacePlacementVersion`, không đổi schema SQLite. Phiên mới dùng phiên bản 1; thiếu/không hỗ trợ phiên bản tiếp tục dùng placement đã lưu.
- Builder thường, strict và chooser dùng chung `resolvePlacements`. Chỉ tự căn khi Smart Face bật, crop là Auto Face và chưa có chỉnh tay.
- Mirror/rotation được đưa vào khóa face cache. Tính placement theo canvas gốc; không ghi database chỉ để render.
- Review lấy placement hiệu lực để bắt đầu kéo/zoom; bản nháp chỉnh tay được ưu tiên. Undo/Redo phục hồi cả crop và manualOverride.
- Đổi khung có kiểm tra revision phiên và khung dưới khóa; cùng khung/revision không reset crop. Đổi khung thực sự và tạo phiên chụp lại tất cả mới dùng cơ chế mới.
- Phiên cũ mở/xuất lại không tự căn; nút Căn lại chỉ tác động ô đang chọn.

### 3. Frame Pack

- Hai phía dùng một biểu diễn nội dung JSON ổn định trước SHA-256.
- Chuẩn hóa tiền tố/chữ hoa mã SHA, màu RGBA, mặc định của trường tùy chọn và thứ tự dựng thực tế.
- Hash gồm crop, mask, corner radius, layer placement, asset, hình học và explicitWhite; bỏ tên/category/ID/thời gian.
- Nhãn Trùng lặp và mặc định Skip hoạt động qua loadPack/UI model. Copy/Replace chủ động vẫn giữ nguyên ý nghĩa.
- Không đổi schemaVersion hoặc packFormatVersion.

## Bằng chứng kiểm chứng

| Kiểm tra | Kết quả | Bằng chứng |
|---|---|---|
| Ba ca tái hiện trước sửa | Thất bại đúng lỗi cần sửa | [/tmp/opb-frame-fixes-red-retry.log](/tmp/opb-frame-fixes-red-retry.log) |
| Kiểm thử tập trung sau bổ sung chụp lại tất cả | 52/52 đạt | [/tmp/opb-frame-fixes-last-check.log](/tmp/opb-frame-fixes-last-check.log) |
| Hash chuẩn hóa: metadata, giá trị mặc định, màu, SHA và explicitWhite | Đạt | [/tmp/opb-frame-fixes-hash-final.log](/tmp/opb-frame-fixes-hash-final.log) |
| Hồi quy toàn bộ trên mã cuối | 258/258 đạt, 0 lỗi | [/tmp/opb-frame-fixes-acceptance.log](/tmp/opb-frame-fixes-acceptance.log) |
| Build native macOS QA | Thành công | [/tmp/opb-frame-fixes-ui-final-build.log](/tmp/opb-frame-fixes-ui-final-build.log) |
| Identity mã/kiểm thử | Manifest SHA-256 | [/tmp/opb-frame-fixes-final-sha256.json](/tmp/opb-frame-fixes-final-sha256.json) |

Các log và xcresult là artifact QA trong thư mục tạm, có thể bị hệ điều hành dọn sau này.

Các ca mới xác minh trực tiếp:
- Khung che kín bị chặn trước ghi qua cả Copy/Replace; khung cũ ready sai không được áp dụng mới nhưng vẫn sửa được.
- Gây lỗi bằng trigger tại ghi revision, slots, references, app_state và frames: rollback giữ nguyên khung cũ và references tạm để thử lại; revision cũ không bị ghi đè.
- Auto Face lệch mặt cho offset kỳ vọng; hai builder giống nhau; Smart Face tắt/chỉnh tay/phiên cũ không bị ghi đè; render không tăng revision.
- Kéo ảnh bắt đầu từ placement đang thấy; Undo phục hồi tự căn; Redo phục hồi chỉnh tay.
- Năm PNG thực tế: kiểm tra ô, tạo khung, xác minh snapshot, đóng gói/nhận diện trùng và checksum byte không đổi.
- Chụp lại tất cả tạo snapshot đã kiểm tra và phiên mới, giữ nguyên phiên trước.

## Dữ liệu và hạ tầng test

Đã đối chiếu 21 tệp tài nguyên/PNG nguồn với bản trước sửa: không đổi. Năm PNG được sao chép nguyên byte vào fixture test kèm SHA-256, không sửa bản nguồn.

Bộ test cũ thiếu fixture ở đường dẫn /tmp cố định đã được chuyển sang tự sinh fixture trong root riêng của test. Assertion kiểm tra lỗi/chức năng được giữ lại. Test lặp Copy chọn Copy tường minh vì mặc định nhận diện trùng nay là Skip; test validator chờ phép kiểm tra bất đồng bộ hoàn tất.

Chỉ thêm khai báo fixture cho test target trong project.yml/Package.swift và cập nhật project Xcode tương ứng. Fixture không được đóng gói vào app sản phẩm.

## Giới hạn nghiệm thu

**UI native, camera thật và thao tác chia sẻ hệ thống chưa được kiểm chứng trực tiếp trong đợt này.** Hai lần kết nối công cụ điều khiển UI đều thất bại với `unknown or expired node_repl continuation`. Không tính lỗi công cụ này là bug sản phẩm, cũng không dùng kết quả build/unit test để khẳng định UI đã đạt.

Bản native QA dùng AppEnvironment(inMemory: true), FakeCameraService và bundle ID riêng. Đối chiếu Sources chỉ khác entrypoint khởi tạo môi trường QA; không mở ứng dụng sản xuất.

Đã triển khai mã và đạt các kiểm tra tự động nêu trên. Nghiệm thu giao diện/thiết bị thật vẫn còn là bước cần thực hiện trước khi tuyên bố toàn bộ ứng dụng hoạt động hoàn hảo.

