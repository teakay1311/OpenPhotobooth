# PHOTOBOOTH STUDIO — ĐẶC TẢ BẢN CÁ NHÂN

> Phạm vi triển khai bản đầu · Cập nhật 13/11/2026 · Giao diện tiếng Việt · Đầu ra là ứng dụng macOS `.app`.

## Mục lục

1. [Phạm vi và cấu hình mặc định](#scope)
2. [Giao diện và điều hướng](#ui)
3. [Camera và luồng chụp](#capture)
4. [Khung, chỉnh ảnh và kết xuất](#render)
5. [Thư viện, xuất ảnh và Finder](#library)
6. [Lưu trữ, khôi phục và Thùng rác](#storage)
7. [Mô hình dữ liệu và liên kết chức năng](#data)
8. [Bàn giao và nghiệm thu](#acceptance)

<a id="scope"></a>
## 1. Phạm vi và cấu hình mặc định

Ứng dụng native cho một người dùng trên Mac, mục tiêu macOS 14 trở lên và Apple Silicon M1 trở lên. SwiftUI cho giao diện, AppKit cho tích hợp cửa sổ và hộp thoại tệp khi cần, AVFoundation cho camera, Core Image hoặc Core Graphics cho kết xuất, SQLite và tệp cục bộ cho dữ liệu. Dùng UserDefaults cho cài đặt nhẹ. Bản đầu chạy offline, dùng trực tiếp dưới dạng `.app` trên máy cá nhân và không yêu cầu tài khoản Apple Developer, chứng chỉ Developer ID, notarization, Mac App Store hay `.dmg`. Nếu công cụ build cần ký cục bộ để chạy thì dùng cấu hình ký cục bộ không cần tài khoản Apple Developer.

| Có trong bản đầu | Giới hạn |
|---|---|
| Chụp, đếm ngược, chụp lại từng ảnh | Camera Mac là nguồn cơ bản. Bộ chọn hiển thị Continuity Camera nếu macOS cung cấp và thiết bị dùng được. Nghiệm thu bằng iPhone thật nếu iPhone là nguồn sử dụng chính. Camera USB tương thích có thể xuất hiện cùng danh sách; không cam kết cho từng mẫu. |
| Ba khung có sẵn, nhập PNG/JPG, trình chỉnh khung | Khung 1, 3 và 4 ảnh. Thư viện khung phẳng có tìm kiếm theo tên. Tối đa một ảnh nền và một lớp phủ. |
| Xem lại và chỉnh vị trí | Kéo, thu phóng và chọn Lấp đầy/Vừa khung cho từng ô. Mỗi ô có một lượt chụp riêng. |
| Lưu phiên, mở lại và xuất | Lưu ảnh gốc ngay sau từng lượt. Xuất JPG/PNG theo yêu cầu, mở trong Finder và dùng AirDrop từ Finder nếu cần. |
| Thùng rác nội bộ | Phiên và khung do người dùng tạo hoặc nhập. Khôi phục, xóa vĩnh viễn thủ công và tự dọn khi đủ 30 × 24 giờ. |

**Để sau:** preset màu và làm mịn da, Smart Face, xem camera trực tiếp bên trong khung, Frame Pack, sao lưu trong app, Auto Export, Share Sheet trong app, chế độ photobooth toàn màn hình riêng, danh mục/yêu thích và chụp lại toàn bộ bằng nút riêng. Bản cá nhân không có tài khoản, PIN, quản trị, cloud, backend, đồng bộ, thanh toán, in ảnh hoặc quay video. Không đưa nút chờ cho các mục ngoài phạm vi vào UI.

| Cài đặt | Mặc định và hiệu lực |
|---|---|
| Giao diện | Theo hệ thống. Cho phép Sáng/Tối trong Cài đặt. |
| Camera | Tự động chọn nguồn khả dụng khi chưa chụp. Người dùng có thể chọn thiết bị khác. |
| Xem camera | Gương bật mặc định cho camera tích hợp, áp dụng cho màn hình camera. Ảnh chụp, Xem lại và ảnh xuất dùng chiều chuẩn của ảnh. |
| Chụp | Tự động, đếm ngược 3 giây, nghỉ 2 giây giữa các lượt. Chọn 0/3/5/10 giây, khoảng nghỉ 0–15 giây. Cố định bộ thông số khi tạo phiên. |
| Chỉnh ô ảnh | Lấp đầy, căn giữa, mức zoom nhỏ nhất hợp lệ theo ô. |
| Xuất | JPG chất lượng 95, kích thước gốc của canvas. Cho phép PNG và đổi chất lượng JPG. |
| Lưu và xóa | Lưu ảnh gốc luôn bật. Không có quota tự xóa ảnh gốc. Thời hạn Thùng rác cố định 30 × 24 giờ. |

<a id="ui"></a>
## 2. Giao diện và điều hướng

Cửa sổ chính dùng sidebar gồm **Chụp ảnh**, **Khung ảnh**, **Thư viện**, **Thùng rác**. **Cài đặt** mở bằng menu ứng dụng hoặc ⌘,. Cửa sổ mục tiêu 1320 × 840 pt, tối thiểu 1024 × 680 pt. Ở cửa sổ hẹp, đưa tùy chọn ít dùng vào popover và giữ vùng ảnh, tiến độ, nút chính luôn nhìn thấy. Frame Editor và Xem lại dùng vùng nội dung chính. Xuất ảnh và xác nhận thao tác dùng sheet hoặc hộp thoại. Mỗi thời điểm chỉ có một sheet đang thao tác.

| Màn hình | Bố cục và thao tác |
|---|---|
| **Chụp ảnh** | Bên trái là khung đang chọn và lưới khung đã thiết lập. Giữa là camera giữ đúng tỷ lệ, số đếm lớn và dải thumbnail. Bên phải hoặc trong popover là nguồn camera, chế độ, đếm ngược và khoảng nghỉ. Phía dưới hiện tiến độ đã lưu, ví dụ **2/4 ảnh**, và nút chính theo trạng thái ở §3. Bấm thumbnail đã lưu để xem lớn tại chỗ khi đang chờ, không đổi thứ tự lượt. |
| **Khung ảnh** | Thanh trên có **Nhập khung** và ô tìm tên. Thẻ khung có thumbnail, tên, số ảnh và nhãn **Chưa thiết lập** nếu chưa lưu được bố cục. Khung sẵn sàng có **Dùng để chụp**. Khung của người dùng có **Chỉnh khung**, **Đổi tên**, **Chuyển vào Thùng rác**. Khung có sẵn đi kèm app được chọn để chụp. |
| **Thư viện** | Lưới mới nhất trước, có lọc **Tất cả / Đủ ảnh / Chưa đủ ảnh**. Thẻ hiển thị tên khung tại thời điểm chụp, ngày, thumbnail và số ảnh đã lưu. Chọn thẻ mở Xem lại. Phiên thiếu ảnh có nút **Chụp tiếp**. Phiên đủ ảnh có **Xuất ảnh**. Menu phiên có **Chuyển vào Thùng rác**, cùng **Hiện trong Finder** nếu biết vị trí tệp xuất gần nhất. |
| **Thùng rác** | Danh sách mục kèm loại, tên, thời điểm xóa, thời gian còn lại và trạng thái. Chọn mục để **Khôi phục** hoặc **Xóa vĩnh viễn**. Mục đang dọn bị khóa thao tác. Mục lỗi hiển thị lý do và hành động thử lại phù hợp. |
| **Cài đặt** | Giao diện, mặc định chụp, tùy chọn gương preview, tổng dung lượng ước tính theo phiên/khung/cache, **Hiện thư mục dữ liệu** và **Dọn bộ nhớ đệm**. Thay đổi mặc định chụp áp dụng cho phiên mới. |

### 2.1. Frame Editor

- Cột trái liệt kê các ô theo thứ tự chụp. Giữa là canvas với ảnh nền/lớp phủ và placeholder có đánh số. Cột phải hiển thị tên khung, kích thước canvas và tọa độ/kích thước của ô đang chọn.
- **Thêm ô** tạo hình chữ nhật trong canvas. Kéo ô để di chuyển, kéo tay nắm để đổi kích thước. Có thao tác xóa và lên/xuống trong danh sách. Số lượt chụp luôn bằng số ô, đánh số lại từ 1 sau thao tác sắp xếp.
- **Lưu khung** chỉ khả dụng khi có thay đổi và bố cục hợp lệ. Nếu chưa hợp lệ, chỉ đúng ô hoặc giá trị cần sửa. Lỗi lưu giữ nguyên bản nháp. Khi rời màn hình có thay đổi, cho chọn **Lưu / Bỏ thay đổi / Hủy**.

### 2.2. Xem lại và xuất

- Giữa màn hình là ảnh ghép đúng tỷ lệ. Dải dưới chọn ảnh nguồn hoặc ô tương ứng. Inspector có **Lấp đầy / Vừa khung**, zoom, **Căn giữa**, **Đặt lại vị trí**. Kéo ảnh bên trong ô chỉ thay vị trí ảnh, không di chuyển ô của khung.
- Thanh thao tác có **Chụp lại ảnh này**, **Xuất ảnh**, **Về thư viện**. Phiên chưa đủ ảnh hiện số ảnh còn thiếu và **Chụp tiếp**. Người dùng có thể xem phần đã lưu, còn nút xuất giải thích lý do đang bị khóa.
- Sheet xuất có ảnh xem trước, định dạng và chất lượng JPG. Nút **Chọn nơi lưu…** mở hộp thoại lưu tệp của macOS để chọn tên và đích. Khi thành công hiện **Hiện trong Finder**. Nếu lỗi, giữ tùy chọn hiện tại để thử lại.
- Khi đang lưu chỉnh sửa, hiện **Đang lưu…**. Khi lỗi, giữ giá trị chỉnh trong UI, hiện **Thử lưu lại**. Trước khi xuất, chuyển màn hình hay đưa phiên vào Thùng rác, phải lưu xong hoặc cho người dùng chọn bỏ phần chỉnh chưa lưu. Không dùng thông báo tạm thay cho trạng thái lưu.

### 2.3. Trạng thái chung và bàn phím

- Lần đầu mở vào **Chụp ảnh**, chọn khung 3 ảnh có sẵn và hiện **Bật camera** nếu cần xin quyền. Không cần chọn thư mục xuất trước khi chụp.
- Không có camera hoặc bị từ chối quyền thì vẫn mở được Khung ảnh, Thư viện, Thùng rác và Cài đặt. Nếu có phiên dang dở, banner đưa người dùng đến **Xem phiên**. Mở phiên không tự đếm ngược.
- Màn hình rỗng nêu hành động phù hợp như **Chụp phiên đầu**, **Nhập khung** hoặc **Xóa bộ lọc**. Nút bị khóa có lý do. Icon có nhãn VoiceOver và tooltip, thứ tự Tab theo bố cục, giữ focus rõ trong hộp thoại.
- Nếu rời màn hình Chụp khi đang đếm hoặc nghỉ giữa lượt, cho chọn **Tạm dừng và rời màn hình / Ở lại**. Khi rời trong lúc camera đang trả ảnh hoặc app đang lưu, hiển thị tiến độ và xử lý yêu cầu rời ở điểm an toàn. Trong lúc chờ thao tác, không khởi động lượt tiếp theo.
- Space kích hoạt nút chụp khi màn hình Chụp đang sẵn sàng và focus không nằm trong ô nhập. Esc hủy đếm ngược hoặc đóng hộp thoại theo ngữ cảnh. Chế độ Sáng/Tối và Reduce Motion theo khả năng hệ thống.

<a id="capture"></a>
## 3. Camera và luồng chụp

### 3.1. Quyền và chọn nguồn

- Kiểm tra quyền trước khi thiết lập camera. Khi chưa hỏi, chỉ xin quyền camera sau khi người dùng bấm **Bật camera**. Bị từ chối hoặc bị giới hạn thì hiện hướng dẫn vào Cài đặt hệ thống và kiểm tra lại khi quay về. Không xin quyền microphone.
- Một CameraService sở hữu phiên AVFoundation. Bộ chọn chỉ hiển thị thiết bị video mà macOS nhận diện, cập nhật khi thiết bị đến/đi. Continuity Camera dùng kết nối do macOS cung cấp. Nếu iPhone không xuất hiện, hiển thị hướng dẫn kiểm tra nguồn trên Mac và cho chọn camera khác.
- Ưu tiên ảnh tĩnh nếu thiết bị hỗ trợ. Chọn cấu hình theo định dạng camera hiện hành và ghi kích thước ảnh thực tế. Nếu chỉ có thể lấy frame video, báo chất lượng giới hạn trước khi bắt đầu hoặc tiếp tục để người dùng xác nhận. Không lấy ảnh từ ảnh chụp màn hình preview.
- Tự chọn camera khi rảnh. Trong phiên đang chụp, giữ nguồn đến điểm an toàn. Mất nguồn thì tạm dừng và cho chọn lại, sau đó người dùng bấm **Tiếp tục**. Thay nguồn cần cập nhật preview trước khi cho chụp.

### 3.2. Trạng thái và nút chính

| Trạng thái | Hành động chính | Điều kiện chuyển |
|---|---|---|
| Chưa sẵn sàng | **Bật camera / Thử lại / Chọn khung** | Đủ quyền, camera sẵn sàng, khung hợp lệ và kho nội bộ ghi được. |
| Sẵn sàng | **Bắt đầu chụp** | Tạo một phiên cùng bản chụp bố cục khung. Chỉ bắt đầu đếm sau khi tạo thành công. |
| Đếm ngược | **Hủy đếm ngược** | Hết giờ thì phát đúng một yêu cầu. Hủy thì giữ phiên, không ghi ảnh. |
| Đang chụp / Đang lưu | Nút chính khóa | Camera trả dữ liệu, app xác thực và lưu. Nếu thất bại, giữ lượt hiện tại. |
| Nghỉ giữa lượt | **Tạm dừng** | Tự động đếm lượt tiếp theo khi hết thời gian nghỉ, nếu ảnh trước đã lưu. |
| Chờ lượt thủ công | **Chụp tiếp** | Đếm ngược lượt kế khi người dùng bấm. Không khởi động bộ đếm giữa lượt. |
| Tạm dừng / Lỗi | **Tiếp tục / Thử lưu lại / Thử chụp lại lượt** | Khi ảnh còn trong bộ nhớ, thử lưu lại trước. Nếu phải chụp lại, chỉ phát lệnh sau khi người dùng chọn. |
| Đủ ảnh | **Xem lại** | Chuyển sang Xem lại sau khi xác nhận lưu lượt cuối. |
| Chụp lại từ Xem lại | **Chụp lại / Hủy đếm ngược** | Chụp đúng ảnh được chọn rồi quay về Xem lại. Các lượt còn lại không chạy tự động. |

### 3.3. Quy tắc chuyển trạng thái

1. Một phiên được chụp tại một thời điểm. Có thể giữ nhiều phiên chưa đủ ảnh trong Thư viện. Trước mỗi yêu cầu chụp, xác thực phiên, lượt, nguồn camera và khả năng lưu.
2. Mỗi yêu cầu có ID duy nhất. Cú bấm lặp và callback trễ không tạo ảnh trùng. Mỗi phiên có tối đa một bộ đếm có hiệu lực. Đếm bằng đồng hồ đơn điệu; hủy phải vô hiệu hóa callback cũ. Giá trị 0 bỏ qua hiển thị số nhưng vẫn chỉ phát một lệnh.
3. **Chỉ tăng tiến độ sau khi tệp ảnh và bản ghi đã được xác nhận.** Nếu mất camera lúc ghi mà ảnh đã về, hoàn tất ghi rồi tạm dừng. Nếu mất camera, Mac ngủ hoặc app mất trạng thái hoạt động trong lúc đếm/nghỉ, hủy bộ đếm. Khi chụp đang diễn ra, xử lý kết quả đã yêu cầu hoặc timeout rồi tạm dừng trước lượt kế.
4. Đổi khung và thông số chụp trước khi bấm Bắt đầu. Sau khi tạo phiên, bố cục và chế độ chụp cố định đến khi kết thúc. Muốn dùng khung khác thì tạo phiên mới. Khi thoát màn hình hoặc đổi phiên trong lúc đang ghi, đợi đến điểm an toàn và giữ phiên cũ trong Thư viện.
5. Chụp lại tạo tệp mới, xác thực rồi mới đổi ảnh đang dùng trong một giao dịch dữ liệu. Lỗi hoặc hủy giữ nguyên ảnh và crop cũ. Thành công đặt lại crop của đúng ô về mặc định. Phiên bản trước vẫn thuộc phiên, được dọn cùng phiên khi xóa vĩnh viễn.

<a id="render"></a>
## 4. Khung, chỉnh ảnh và kết xuất

### 4.1. Nhập khung và lưu bố cục

- Chọn một PNG/JPG từ Finder. Xác thực định dạng thực tế và kích thước trước khi giải mã toàn bộ. Sao chép vào kho của app, tránh phụ thuộc tệp nguồn. File không đọc được, vượt giới hạn hoặc hết dung lượng phải có thông báo cụ thể. File trùng tên được thêm hậu tố, không ghi đè.
- PNG có alpha mặc định làm lớp phủ, PNG không alpha và JPG mặc định làm nền. Trong Editor có thể đổi vai trò. Nếu lớp phủ kín và che ảnh, hiển thị cảnh báo và yêu cầu chuyển sang nền hoặc chọn ảnh có vùng trong suốt. Canvas bắt đầu theo tỷ lệ ảnh nhập. Lớp ảnh khác tỷ lệ canvas dùng Fit hoặc Fill, không kéo giãn.
- Khung vừa nhập xuất hiện dưới dạng **Chưa thiết lập** và mở Editor. Chỉ sau khi lưu bố cục hợp lệ mới xuất hiện trong bộ chọn chụp. Thoát Editor khi chưa thiết lập giữ bản nháp nhập trong Khung ảnh.
- Giới hạn bản đầu là 1–12 ô chữ nhật, mỗi chiều canvas 256–8192 px và tổng không quá 40 megapixel, file ảnh khung tối đa 100 MB. Ô phải có kích thước dương, số hữu hạn và nằm trọn trong canvas. Nếu ô chồng lên nhau, ô có chỉ số cao hơn nằm trên và Editor hiển thị đúng thứ tự đó.
- Mỗi lần lưu bố cục tạo phiên bản mới. Phiên chụp giữ bản chụp bố cục và tham chiếu tệp khung riêng của phiên. Đổi tên, chỉnh khung, đưa khung vào Thùng rác hoặc xóa khung khỏi thư viện đều không làm phiên cũ đổi ảnh ghép.

### 4.2. Quy tắc hình học và ảnh đầu ra

- Hệ tọa độ chuẩn của ảnh đã định hướng và canvas có gốc ở góc trên trái, X tăng sang phải, Y tăng xuống. Ô lưu `x, y, width, height` chuẩn hóa theo chiều rộng và chiều cao canvas. Chuyển sang pixel ở bước vẽ cuối cùng. Chuẩn hóa hướng ảnh theo metadata một lần khi đọc, không áp lại lần thứ hai ở preview hoặc export.
- `Lấp đầy` lấy mức scale cơ sở lớn hơn giữa tỷ lệ chiều rộng và chiều cao, cắt phần tràn. Giới hạn thao tác kéo/zoom để ô luôn được phủ kín. `Vừa khung` lấy mức scale nhỏ hơn và căn giữa mặc định, vùng trống thấy nền canvas. Vị trí lưu theo hệ tọa độ của từng ô, không phụ thuộc kích thước cửa sổ.
- Thứ tự vẽ là nền canvas → ảnh nền → ảnh theo từng ô và clipping → lớp phủ. Placeholder và số đếm chỉ thuộc UI. Review có thể vẽ ở độ phân giải thấp hơn, dùng cùng bố cục, crop, hướng ảnh và thứ tự lớp với xuất ảnh.
- Nếu khung cần vùng trong suốt, PNG giữ alpha. JPG ghép nền trắng trước khi mã hóa. Xuất dùng canvas gốc và sRGB. Không dựng lại ảnh từ một bản JPG đã xuất. Khi thiếu tệp bắt buộc hoặc không giải mã được ảnh, khóa xuất và chỉ rõ dữ liệu nào thiếu.

<a id="library"></a>
## 5. Thư viện, xuất ảnh và Finder

- Thư viện đọc từ dữ liệu đã lưu. Phiên chưa đủ có thumbnail của ảnh đã lưu đầu tiên nếu có. Phiên đủ ảnh dùng ảnh ghép xem trước, tạo lại được khi cache bị dọn. Mở lại phiên đủ ảnh có thể chỉnh, chụp lại hoặc xuất nhiều lần. Các tệp đã xuất trước đó không bị thay đổi khi chỉnh phiên.
- Nếu một ảnh hiện hành bị mất hoặc hỏng, đánh dấu đúng lượt và khóa xuất. Nếu bố cục còn đầy đủ, cho chụp lại đúng lượt đó. Nếu tệp khung của phiên bị mất, giữ phiên và các ảnh còn đọc được, hiện hướng dẫn khôi phục kho từ bản sao. Không tự gán khung hay ảnh khác.
- Trước khi xuất, lưu phần chỉnh đang chờ, kiểm tra đủ ảnh và ghim một bản dữ liệu render của phiên hiện tại. Trong lúc xuất, khóa sửa/chụp lại/xóa phiên đó. Hủy hoặc lỗi xuất quay về Xem lại. Kết quả của phiên luôn dùng đúng revision tại thời điểm bấm xuất.
- Tên gợi ý là `Photobooth-YYYYMMDD-HHmmss` với phần mở rộng theo định dạng. Hộp thoại hệ thống chọn đích. Tên trùng mặc định dùng hậu tố hoặc người dùng chọn tên khác. Thay thế tệp chỉ khi có xác nhận rõ. Tệp tạm ở đích được kiểm tra trước khi hoàn tất ghi. Khi lỗi hoặc bị hủy, chỉ dọn tệp tạm mà app tạo, giữ phiên và tệp đích cũ.
- Chỉ hiện **Đã xuất ảnh** khi tệp cuối đã ghi thành công. Nếu tệp đã ghi nhưng lịch sử xuất chưa ghi được, thông báo riêng và vẫn cho mở tệp vừa xuất. Lịch sử lưu tham chiếu tới tệp, không sở hữu nó. Nếu tệp bị dời, đổi tên hoặc mất quyền truy cập, báo rõ và cho xuất lại.
- **Hiện trong Finder** chọn tệp vừa xuất. Muốn AirDrop, dùng menu chia sẻ trong Finder. App không theo dõi người nhận hay trạng thái truyền. Lần xuất sau vẫn dùng hộp thoại chọn đích, không cần quyền truy cập dài hạn vào thư mục xuất.

<a id="storage"></a>
## 6. Lưu trữ, khôi phục và Thùng rác

### 6.1. Lưu an toàn

- Kho nội bộ nằm trong Application Support của app. Tách cơ sở dữ liệu, ảnh gốc, tài nguyên khung, tệp tạm và cache. Tên tệp nội bộ do app sinh, đường dẫn tương đối được kiểm tra nằm trong thư mục quản lý. Ảnh gốc bất biến. Bản chỉnh sửa gồm thông số crop, không ghi đè ảnh.
- Ghi ảnh theo thứ tự **lưu ý định ghi vào DB → ghi tệp tạm cùng ổ → kiểm tra tệp → chuyển nguyên tử sang tên cuối mới → giao dịch DB xác nhận ảnh, con trỏ revision và tiến độ → cập nhật UI**. Tên tạm/tên cuối gắn với ID yêu cầu. Nếu đã có tệp cuối của yêu cầu đó, đối chiếu với ý định ghi thay vì ghi đè.
- Khi mở app, xử lý ý định ghi còn dang dở trước khi cho sửa/xóa phiên liên quan. Có tệp cuối hợp lệ và giao dịch chưa hoàn thành thì đối chiếu và hoàn tất đúng một lần nếu trạng thái phiên còn khớp. Tệp bất thường được cách ly và báo rõ. Tệp tạm chưa hoàn chỉnh không được tính là ảnh đã lưu. Phiên đang chụp khi app đóng đột ngột được mở lại ở trạng thái tạm dừng hoặc Xem lại nếu đã đủ ảnh.
- Lưu chỉnh vị trí sau khi kết thúc kéo, zoom hoặc đổi chế độ crop. Giữ draft trong UI nếu DB lỗi, chặn xuất đến khi người dùng lưu lại hoặc bỏ draft. Khi đóng app trong lúc lưu ảnh, chờ thao tác đến điểm an toàn nếu có thể. Recovery xử lý trường hợp hệ điều hành buộc đóng.
- Kiểm tra khả năng ghi và dung lượng trống trước khi tạo phiên, trước lượt kế và trước xuất ảnh. Ước lượng cần chừa chỗ cho một ảnh mới cùng tệp tạm, hoặc bản render và tệp xuất tương ứng. Nếu không đủ, tạm dừng và chỉ rõ ổ cần giải phóng. Dung lượng ước tính chỉ dùng để cảnh báo, mọi lỗi ghi thực tế vẫn phải được xử lý. Cache có thể dọn lại được; không tự xóa ảnh gốc hoặc rút hạn Thùng rác để lấy chỗ.

### 6.2. Sao lưu trên máy cá nhân

- **Hiện thư mục dữ liệu** mở thư mục Application Support của app trong Finder. Nếu muốn giữ bản sao để phòng hỏng ổ hoặc chuyển máy, người dùng thoát app hoàn toàn rồi sao chép **cả thư mục dữ liệu** sang ổ khác. Tệp đã xuất ở ngoài thư mục này cần sao lưu riêng.
- Khi cần khôi phục thủ công, thoát app, giữ một bản sao của thư mục hiện tại, đưa bản sao lưu tương thích về đúng vị trí và mở app để kiểm tra. Đây là khôi phục nguyên kho, không ghép hai thư viện. Giữ bundle identifier và tên kho dữ liệu ổn định qua các bản cập nhật. Nếu cần migration, giữ bản sao trước khi đổi schema và báo lỗi khi không mở được thay vì tạo thư viện rỗng đè lên dữ liệu cũ.

### 6.3. Vòng đời Thùng rác

| Hành động | Xử lý | Ảnh hưởng UI |
|---|---|---|
| Chuyển vào Thùng rác | Giao dịch đổi trạng thái của phiên/khung và ghi thời điểm UTC. Giữ nguyên tệp vật lý và các tham chiếu trong hạn giữ. | Ẩn mục khỏi danh sách sử dụng, hiện ở Thùng rác. |
| Khôi phục | Kiểm tra mục chưa hết hạn và đủ tệp, bỏ trạng thái đã xóa trong một giao dịch. Nếu tên khung trùng, thêm hậu tố. | Mục về danh sách cũ với bố cục, ảnh, phiên bản và chỉnh sửa đã lưu. |
| Đủ 30 × 24 giờ | Đủ điều kiện dọn tại `deletedAt + 2_592_000 giây`. Dọn sau Recovery khi mở app, khi vào Thùng rác và định kỳ khi app chạy. | Hiện **Đang chờ dọn** trong lúc chưa thể dọn. Mục hết hạn không khôi phục được. |
| Xóa vĩnh viễn thủ công | Xác nhận theo mục, đánh dấu đang dọn, xóa tệp thuộc quyền sở hữu của mục và hoàn tất cập nhật DB. | Khi lỗi, giữ mục với trạng thái **Chưa dọn xong** và cho thử lại. |

- Chỉ một thao tác khôi phục hoặc dọn có thể giữ cùng một mục. Không đưa mục đang chụp, lưu, xuất hoặc có bản chỉnh chưa xử lý vào Thùng rác. Với thao tác dọn, ghi trạng thái trước khi xóa bytes để lần mở sau có thể tiếp tục an toàn nếu app đóng giữa chừng. Tệp đã xóa ở lần trước được coi là đã xử lý nếu đường dẫn đúng. Tác vụ dọn nhường luồng chụp và bỏ qua mục đang sử dụng.
- Phiên sở hữu ảnh gốc, các bản chụp lại, bản chụp khung và tài nguyên đã sao chép cho phiên. Khung sở hữu tài nguyên riêng trong thư viện khung. Dọn khung không đụng đến dữ liệu của phiên, kể cả phiên đang trong Thùng rác. Dọn phiên chỉ xóa phần app quản lý, kể cả các bản chỉnh, ảnh gốc và cache của phiên. Tệp xuất ngoài app thuộc người dùng.
- Khi app đóng thì không có tác vụ nền. Dùng UTC để việc đổi múi giờ không ảnh hưởng thời hạn. Nếu chênh lệch giữa thời gian theo đồng hồ máy và thời gian thực trôi qua theo đồng hồ đơn điệu vượt 24 giờ trong cùng lần chạy, tạm dừng tự dọn và báo rõ. Thời điểm dọn sau khi mở lại dựa vào đồng hồ máy. Xóa vĩnh viễn là xóa khỏi kho của app, các bản sao ở Finder hay ổ sao lưu vẫn do người dùng quản lý.

<a id="data"></a>
## 7. Mô hình dữ liệu và liên kết chức năng

### 7.1. Bản ghi và ràng buộc

| Bản ghi | Dữ liệu chính | Quan hệ và vòng đời |
|---|---|---|
| **Frame** | ID, tên, loại có sẵn/đã nhập, trạng thái chưa thiết lập/sẵn sàng, phiên bản hiện tại, thời điểm xóa nếu có | Sở hữu tài nguyên nền/lớp phủ của thư viện khung. Ẩn khung không thay đổi phiên đã tạo. |
| **FrameRevision** | ID khung, số phiên bản, canvas, danh sách ô và vai trò tài nguyên | Bố cục bất biến sau khi lưu. Con trỏ phiên bản hiện tại phải thuộc đúng khung. Có thể giữ bố cục hiện tại và dọn bố cục cũ khi không còn thao tác liên quan, vì phiên đã có bản chụp riêng. |
| **Session** | ID, ngày giờ, tên khung lúc bắt đầu, bản chụp bố cục, chế độ, đếm ngược, khoảng nghỉ, trạng thái, revision, thời điểm xóa nếu có | Sở hữu bản chụp khung và tài nguyên riêng của phiên. Số lượt lấy từ số ô trong bản chụp. |
| **Shot** | ID phiên, số thứ tự, ảnh hiện hành, thông số crop | Khóa duy nhất theo cặp phiên và thứ tự. Chỉ trỏ đến phiên bản ảnh của chính lượt đó. Crop hiện hành đi cùng ảnh hiện hành. |
| **PhotoRevision** | ID lượt, ID yêu cầu duy nhất, đường dẫn, checksum, kích thước thực, định dạng, hướng ảnh, thời điểm chụp | Mỗi lần chụp thành công tạo một bản ghi và tệp riêng. Tệp bất biến, thuộc phiên. |
| **PendingOperation** | ID, loại, đối tượng, đường dẫn tạm/cuối, trạng thái, thông tin đối chiếu | Dùng cho ghi ảnh, tạo phiên có tệp, nhập khung và dọn. Chỉ kết thúc sau khi tệp và DB nhất quán. Có thể chạy lại an toàn. |
| **ExportRecord** | ID phiên, revision đã dựng, định dạng, đường dẫn hoặc tên tệp, thời điểm | Chỉ ghi khi tệp xuất đã hoàn tất. Xóa record không xóa tệp ngoài. |

Trạng thái nghiệp vụ lưu của phiên gồm chưa đủ ảnh, đủ ảnh, trong Thùng rác và đang dọn. Đếm ngược, chụp, ghi, nghỉ và xuất là trạng thái chạy của ứng dụng. Lượt tiếp theo được suy ra từ lượt đầu chưa có ảnh hiện hành hợp lệ. SQLite bật khóa ngoại, dùng giao dịch cho cập nhật liên quan và version hóa schema. Thay đổi dữ liệu dùng ID, không dùng tên hiển thị làm khóa. Phiên đủ ảnh vẫn có thể mở để chỉnh.

### 7.2. Trách nhiệm và thứ tự cập nhật

```text
Khung đã lưu → Bộ chọn khung → Bản chụp khung trong phiên
Camera → Bộ điều phối chụp → Lưu ảnh và tiến độ → Xem lại / Thư viện
Xem lại → Lưu crop theo ô → Renderer dùng chung → Ảnh ghép xem trước / Xuất
Thư viện / Khung ảnh → Thùng rác → Khôi phục hoặc dọn dữ liệu nội bộ
```

| Bộ phận | Trách nhiệm | Điểm bàn giao |
|---|---|---|
| Camera | Quyền, nguồn, preview và trả ảnh theo ID yêu cầu | Bộ điều phối chụp nhận kết quả hoặc lỗi, Camera không sửa DB. |
| Bộ điều phối chụp | Trạng thái, đồng hồ, lượt hiện tại, xử lý ngắt nguồn | Yêu cầu lớp lưu ghi ảnh. Chỉ chạy lượt tiếp khi nhận xác nhận. |
| Kho dữ liệu | Ghi DB/tệp theo thứ tự, snapshot, khôi phục, dọn | Sau giao dịch thành công, UI đọc lại mục đã đổi và cập nhật tiến độ/thư viện. |
| Renderer | Dùng cùng mô hình bố cục và crop cho preview/xuất | Mỗi render gắn revision. Bỏ kết quả preview cũ nếu có chỉnh sửa mới. |
| Xuất ảnh | Ghim dữ liệu render, lưu qua hộp thoại, trả tệp cuối | Trả trạng thái xuất về Xem lại và lịch sử phiên. |

UI cập nhật trên luồng chính. Camera và thao tác kho chạy tuần tự trong phạm vi chúng sở hữu. Thumbnails, kết xuất và dọn rác không chặn nút điều khiển. Các thao tác có thể xung đột trên cùng phiên được kiểm tra tại lớp xử lý, kể cả khi lệnh đến từ phím tắt hoặc callback. Trong lúc lưu, app chỉ cập nhật tiến độ khi giao dịch xác nhận. Xem lại, Thư viện và Thùng rác đọc cùng trạng thái đã lưu.

### 7.3. Xử lý khi các thao tác gặp nhau

| Tình huống | Kết quả |
|---|---|
| Khung vừa bị chỉnh hoặc đưa vào Thùng rác khi chuẩn bị chụp | Kiểm tra phiên bản và trạng thái trước khi tạo phiên. Nếu khung không còn sẵn sàng, dừng và yêu cầu chọn lại. Sau khi tạo phiên thành công, chỉ dùng bản chụp khung của phiên. |
| Bấm xuất ngay khi vừa chỉnh crop | Đợi lưu crop rồi mới dựng từ revision đã xác nhận. Lỗi lưu giữ người dùng ở Xem lại. |
| Dọn rác và khôi phục cùng một mục | Bên giữ khóa mục trước thực hiện. Kiểm tra lại hạn và trạng thái dưới cùng khóa trước khi thay đổi. |
| Callback camera đến sau khi yêu cầu đã kết thúc | Đối chiếu ID yêu cầu và trạng thái. Bỏ callback trùng hoặc đã hết hiệu lực, giữ nguyên lượt hiện hành. |

<a id="acceptance"></a>
## 8. Bàn giao và nghiệm thu

Bàn giao dự án Xcode, ứng dụng `.app` chạy trên Mac cá nhân và hướng dẫn ngắn về cách mở app, cấp quyền camera, dùng khung, xuất ảnh và sao lưu thủ công. Ghi rõ phiên bản macOS/Xcode dùng để build và thiết bị camera thực tế đã dùng. Tài liệu này định nghĩa tiêu chí cần kiểm tra, kết quả nghiệm thu được ghi riêng khi có bản chạy.

| Nhóm | Điều kiện nghiệm thu bản đầu |
|---|---|
| **Mở app và camera** | Cài/mở `.app` trên máy cá nhân. Lần đầu có 3 khung hợp lệ, không xin microphone. Quyền camera bị từ chối vẫn dùng được các màn hình khác. Nếu iPhone là nguồn chụp chính, chọn iPhone thật, chụp đủ một phiên và kiểm tra mất/kết nối lại nguồn. |
| **Chụp và lưu** | Chụp tự động 4 ảnh đúng thứ tự, chụp thủ công không tự chạy lượt sau, đếm 0 giây vẫn không chụp trùng. Esc hoặc sleep trong đếm ngược không phát lệnh muộn. Hết chỗ hoặc lỗi ghi không tăng tiến độ. Đóng đột ngột ở bước trước/sau đổi tên tệp và trước/sau DB commit phải khôi phục nhất quán. Chụp lại lỗi giữ ảnh và crop cũ. |
| **Khung và render** | Nhập PNG alpha/JPG hợp lệ, từ chối file hỏng, khung chưa có ô không dùng để chụp. Ô ra ngoài canvas không lưu được. Chỉnh khung sau khi chụp không làm phiên cũ thay đổi. Ảnh chân dung, ảnh ngang và ảnh có chữ giữ đúng hướng ở Xem lại và khi xuất, dù camera preview bật gương. Crop một ô không đổi ô khác. |
| **Thư viện và xuất** | Mở lại phiên thiếu ảnh để tiếp tục, xuất chỉ khi đủ ảnh, JPG nền trắng và PNG giữ alpha theo canvas. Lỗi ghi hoặc tên trùng không ghi đè tệp ngoài nếu chưa xác nhận. Finder chọn được tệp xuất còn tồn tại và app báo rõ khi tệp bị dời. |
| **Thùng rác và giao diện** | Khôi phục phiên trước mốc hạn giữ đầy đủ ảnh và crop. Kiểm tra đúng ranh giới 30 × 24 giờ, dọn tiếp khi đóng giữa chừng, xóa khung không ảnh hưởng phiên đã dùng khung đó. Xóa vĩnh viễn phiên không đụng tệp xuất. Ở kích thước tối thiểu, Sáng/Tối và điều hướng bàn phím, các thao tác chính đều nhìn thấy và dùng được. |

Các lỗi làm mất ảnh đã xác nhận, bắn thêm lượt ngoài ý muốn, xuất sai bố cục hoặc ghi đè tệp của người dùng là lỗi chặn bàn giao. Phần cứng chưa thử cần được ghi rõ trong kết quả nghiệm thu.
