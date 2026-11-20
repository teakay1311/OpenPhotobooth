# Triển khai sửa UI và điều chỉnh Thùng rác — 19/11/2026

## Kết quả và phạm vi

Đã triển khai đúng 5 hạng mục dưới đây. Không thêm dependency, không đổi schema, không thay bản ứng dụng đã cài và không tạo DMG mới. Các thay đổi có sẵn trước phiên làm việc được lưu baseline và giữ lại.

| Hạng mục | Thay đổi | Kết quả kiểm chứng |
|---|---|---|
| UI-01: Review co giãn khi chỉnh màu/ánh sáng | Thay spinner bị scale bằng spinner nhỏ có khung 16×16 pt. Giới hạn thông báo lỗi lưu một dòng, giữ nội dung đầy đủ qua tooltip. | Cửa sổ Review thật: header luôn 44 pt; preview luôn 1191×668,420166 pt trước/trong/sau editing. |
| UI-02: Chọn khung ban đầu thiếu preview | Service gom validation đang chạy theo frame/revision; hủy viewport không hủy validation dùng chung. Render tuần tự, bỏ request đã hủy, kiểm tra identity trước khi publish. Chỉ retry lỗi busy ở 100/200/400 ms. Cho bấm lại cùng khung khi có lỗi. | 3/3 lần mở ban đầu có composite, không đổi khung. Kiểm tra hủy request, tranh chấp khóa tạm thời, revision cũ và thử lại đều qua. App QA cũng hiện composite 4/4 ngay lần mở đầu. |
| UI-03: Chữ “Chọn khung” bị cắt | Chỉ chỉnh nhóm nút trên card đã chụp đủ nhưng chưa chọn khung. Giữ kích thước nội dung; chuyển sang hai hàng khi thiếu chỗ. Giữ nguyên action. | Card rộng 220/240/300/500 pt đều hiển thị label rộng đủ 82 pt, nằm trong card. Đã quan sát đầy đủ chữ trên app QA. |
| TR-01: Xem ảnh trong Thùng rác | Thumbnail và sheet preview khung/ảnh/phiên. Phiên có dải ảnh để xem từng ảnh bên trong. Đọc đúng vị trí active/trash, kiểm tra SHA và ownership, xử lý orientation; khung dùng renderer chung và snapshot không persist. | Đọc được ảnh sau khi chuyển cả phiên vào Trash; từ chối ID ảnh ngoài phiên và bytes sai SHA. Không ghi DB hoặc tạo tệp khi đọc preview trực tiếp. Đổi sang ảnh số 4 trong sheet hiển thị đúng ảnh mẫu 4. |
| TR-02: Chọn và xóa hàng loạt | Checkbox, chọn tất cả đang hiển thị, bỏ chọn, bộ đếm. Chốt phạm vi xác nhận, kiểm tra lại trong root lock, chuẩn hóa phiên–ảnh con, dừng khi scope thay đổi, lưu kết quả từng mục và giữ các mục chưa xử lý còn tồn tại trong selection. | Chọn hai checkbox lần lượt giữ được 2/2; scope không mở rộng ra mục bị lọc. Xóa cha/con không lặp; bytes không cộng hai lần trong xác nhận. Kiểm tra thay đổi child, tranh chấp khóa và rời màn hình đều qua. |

## Liên kết dữ liệu và xử lý lỗi

1. Xem preview không khôi phục mục, không sửa ảnh gốc, không thêm snapshot/asset reference. Cache chỉ ở bộ nhớ, giới hạn cost 16 MiB/80 ảnh; tối đa một thumbnail và một preview lớn decode đồng thời. Đây là giới hạn cache, không phải cam kết tổng RAM của ứng dụng.
2. Preview dùng ID bản ghi Trash; cache không trả ảnh của mục đã khôi phục. Các waiter dùng chung ảnh không hủy lẫn nhau. Tác vụ hết người xem được hủy; view kiểm tra cancellation trước khi publish.
3. Preview phiên chỉ xem ảnh bên trong; thao tác khôi phục/xóa vẫn áp dụng cho cả phiên. Danh sách preview bao gồm ảnh hiện hành và ảnh đã xóa còn thuộc phiên, không quét mọi revision cũ.
4. Xóa phiên bao gồm các bản ghi ảnh con đã xóa; dialog nêu rõ phần bao gồm này. Ảnh con không bị xóa riêng lần nữa. Nếu chỉ chọn ảnh con mà phiên cha vẫn trong Trash, service giữ quy tắc bảo vệ hiện có và báo lý do bỏ qua.
5. Lỗi/bỏ qua/chưa xử lý được trình bày riêng trong “Kết quả xóa”. Khóa dọn cấp app được giải phóng kể cả khi ViewModel bị hủy do rời màn hình. Scheduler và API purge cũ được giữ tương thích; quy tắc thời hạn khôi phục giữ nguyên.

## Kiểm thử và bằng chứng

Các đường dẫn dưới đây tương đối với thư mục dự án.

| Kiểm tra | Kết quả | Bằng chứng |
|---|---|---|
| Hồi quy toàn bộ tại mốc tích hợp | **272/272**, 0 failure; khoảng 380 giây | [full.log](../Build/QA/UI-Trash-2026-11-19/full.log) |
| Kiểm tra các phần bị tác động trên source cuối | **34/34**, 0 failure; khoảng 40 giây | [verified-final.log](../Build/QA/UI-Trash-2026-11-19/verified-final.log) |
| Release arm64 trên source cuối, không có QA bootstrap | **BUILD SUCCEEDED** | [release-verified.log](../Build/QA/UI-Trash-2026-11-19/release-verified.log) |
| Native UI QA với ảnh mẫu/camera giả | Thumbnail, checkbox, select all/clear, preview phiên/đổi ảnh, hủy dialog, label và preview khung ban đầu hoạt động ở các bước đã kiểm tra | [ui-observation.md](../Build/QA/UI-Trash-2026-11-19/ui-observation.md); AX trees và screenshots trong chat |
| Diff và bảo toàn baseline | Không xóa tệp baseline; chỉ 5 source cũ, 3 source mới, 2 tệp test và project đăng ký source bị thay đổi | [baseline-changes.json](../Build/QA/UI-Trash-2026-11-19/baseline-changes.json), [implementation-only.patch](../Build/QA/UI-Trash-2026-11-19/implementation-only.patch) |
| Khớp source Release với workspace | Tất cả tệp Sources khớp byte-for-byte tại thời điểm build cuối | [source-sha256.json](../Build/QA/UI-Trash-2026-11-19/source-sha256.json) |

Hai bộ test không được cộng thành một lượt chạy: 272 là bộ hồi quy tại mốc tích hợp; sau các điều chỉnh cuối về cancellation, vòng đời khóa và truy vấn ảnh con, 34 kiểm tra liên quan được chạy lại trên source cuối.

Test mới lưu trong `Tests/AuditDataLinkTests.swift` và `Tests/TrashAndSettingsFixTests.swift`: validation preview, cancellation/khóa bận/revision cũ, preview không ghi dữ liệu, sai SHA/ownership, cache sau restore, parent–child purge, scope thay đổi, selection qua bộ lọc, thành công một phần, nhiều waiter và giải phóng khóa sau khi đóng ViewModel.

Các phép đo geometry/label và lifecycle cửa sổ dùng instrumentation chỉ trong bản sao QA, không đưa hook đo vào source phát hành. Toàn bộ lần chạy dùng test host không bootstrap kho production; fixture mới và app UI riêng dùng dữ liệu tạm/in-memory, UserDefaults riêng. Xóa vĩnh viễn được kiểm chứng bằng test trên fixture; qua native UI chỉ mở rồi hủy dialog, không bấm xóa vĩnh viễn.

Ảnh đo Review: [trước](../Build/QA/UI-Trash-2026-11-19/before.png), [trong](../Build/QA/UI-Trash-2026-11-19/during.png), [sau](../Build/QA/UI-Trash-2026-11-19/after.png).

## Tệp triển khai

- `Sources/Views/Review/ReviewView.swift`: spinner, thông báo lỗi lưu, nối chooser service và retry cùng khung.
- `Sources/Services/ChooserPreviewService.swift` mới: validation dùng chung và render tuần tự có cancellation.
- `Sources/Views/Library/LibraryViews.swift`: bố trí nút đúng nhánh, checkbox/selection, dialog và kết quả xóa, mở preview.
- `Sources/Views/Library/TrashPreviewViews.swift` mới: thumbnail, lỗi/thử lại, sheet và dải ảnh trong phiên.
- `Sources/Services/TrashPreviewLoader.swift` mới: cache bộ nhớ và hàng đợi tải có coalescing/cancellation.
- `Sources/Services/TrashService.swift`: đọc preview có kiểm tra; purge plan và kiểm tra scope trong root lock. Truy vấn child chỉ đọc các ảnh con thuộc phiên đang xử lý.
- `Sources/ViewModels/LibraryAndTrashViewModels.swift`: scope/selection/kết quả; giữ mục thất bại, thứ tự restore cha trước con, giải phóng khóa khi đóng view.
- `Sources/App/AppEnvironment.swift`: giữ vòng đời hai preview service.
- `OpenPhotobooth.xcodeproj/project.pbxproj`: đăng ký ba tệp Swift mới; 12 dòng thêm trong project.

## Giới hạn kết luận

Không phát hiện failure trong các kiểm tra nêu trên. Kết quả không đồng nghĩa đã chứng minh mọi cấu hình thiết bị hoặc mọi thao tác có thể có đều không lỗi. Lần này không kiểm tra camera vật lý/USB, giao diện chia sẻ hệ thống, máy Intel hoặc mọi phiên bản macOS. Phép đo Review dùng state editing/lưu trong cửa sổ thật; không phải phép thử mọi kiểu kéo chuột. Không cài bản mới vào `/Applications`, không commit/push và không tạo bản cài đặt trong phạm vi lần triển khai này.
