# Hướng dẫn sử dụng Open Photobooth v1.2

Open Photobooth là ứng dụng Photobooth bản địa (native) dành riêng cho hệ điều hành macOS, hỗ trợ chụp ảnh theo khung tùy chỉnh, chỉnh sửa vị trí ảnh, áp dụng bộ lọc màu/làm mịn da và xuất file chất lượng cao.

---

## 1. Yêu cầu hệ thống và cài đặt
- **Hệ điều hành**: macOS 14.0 (Sonoma) trở lên (khuyến nghị macOS 14 hoặc macOS 15+).
- **Phần cứng**: Tương thích cả Apple Silicon (M1/M2/M3/M4) và vi xử lý Intel (Universal Binary).
- **Quyền truy cập**: Quyền sử dụng **Camera** (ứng dụng tuyệt đối không yêu cầu quyền Microphone).
- **Cài đặt**: Kéo thả tệp `Open Photobooth.app` vào thư mục `/Applications` hoặc mở trực tiếp từ Finder.

---

## 2. Các màn hình và luồng chức năng chính

### 2.1. Màn hình Chụp ảnh (Capture)
1. **Chọn khung ảnh**: Danh sách các khung hiển thị ở thanh trượt bên dưới. Mặc định ứng dụng cung cấp 3 khung: *Dải 3 ảnh*, *Lưới 4 ảnh*, và *Một ảnh lớn*.
2. **Cấu hình thông số**:
   - **Chế độ**: Tự động (Auto) hoặc Thủ công (Manual).
   - **Đếm ngược**: 0s, 3s, 5s hoặc 10s.
   - **Nghỉ giữa lượt**: Thời gian nghỉ để tạo dáng cho lượt chụp kế tiếp.
   - **Bộ lọc màu & Làm mịn**: Chọn preset màu sắc (Tự nhiên, Vintage, Trắng đen,...) và thanh trượt làm mịn da.
   - **Lật ảnh (Mirror)**: Xem gương tự nhiên lúc chụp.
3. **Bắt đầu chụp**: Bấm nút **Chụp** hoặc phím `Space`. Có thể hủy bất kỳ lúc nào bằng phím `Esc`.

### 2.2. Chế độ Toàn màn hình (Fullscreen Kiosk)
- Bật từ nút **Toàn màn hình** ở góc trên thanh công cụ màn Chụp ảnh.
- Chế độ kiosk tối ưu cho sự kiện / tiệc cưới, tự động quay về màn hình chờ sau khi hoàn tất.

### 2.3. Màn hình Xem lại & Chỉnh sửa (Review)
- **Căn chỉnh ảnh trong ô**: Kéo di chuyển hoặc cuộn chuột để phóng to/thu nhỏ ảnh trong từng ô của khung.
- **Chế độ cắt (Crop Mode)**:
  - **Fill (Lấp đầy)**: Cắt tràn ô ảnh mà không méo tỉ lệ.
  - **Fit (Vừa khung)**: Hiển thị trọn vẹn toàn bộ ảnh trong ô.
  - **Auto Face (Nhận diện mặt)**: Tự động căn giữa khuôn mặt vào tâm ô ảnh.
- **Chụp lại (Retake)**: Chọn một ô ảnh bất kỳ trên dải ảnh và bấm "Chụp lại" để chụp lại đúng ô đó (áp dụng cho cả phiên vừa chụp lẫn bất kỳ phiên nào mở lại từ Thư viện); các ô ảnh khác được giữ nguyên. Sau khi chụp lại thành công, ứng dụng tự động quay về đúng phiên trong màn hình Xem và chỉnh ảnh.
- **Đổi khung trong Review**: Có thể đổi sang khung khác khi đang xem lại; các ảnh đã chụp sẽ được tự động giữ nguyên và gán vào các ô tương ứng.

### 2.4. Xuất ảnh (Export) và Chia sẻ (Share)
- **Xuất thủ công**: Hộp thoại chọn thư mục xuất, định dạng JPG (chất lượng 1–100%) hoặc PNG (trong suốt).
  - Tên tệp xuất theo cú pháp an toàn: `Photobooth-YYYYMMDD-HHmmss`.
  - Nếu trùng tên, hệ thống tự động thêm hậu tố `(1)`, `(2)`. Nếu chọn ghi đè, hệ thống thay thế tệp nguyên tử sau khi đã xác thực SHA-256 an toàn.
- **Tự động xuất (Auto Export)**: Tùy chọn trong Cài đặt, tự động lưu ảnh ra thư mục đã cấp quyền ngay khi bấm Hoàn thành.
- **Chia sẻ (Share Sheet)**: Chia sẻ nhanh qua AirDrop, Tin nhắn (Messages), Mail hoặc mạng xã hội.

### 2.5. Quản lý Khung ảnh & Trình sửa khung (Frame Editor)
- **Nhập khung mới**: Hỗ trợ tệp PNG (có kênh alpha làm lớp phủ) và JPG/PNG không alpha (làm nền).
- **Gói khung (Frame Pack)**: Xuất hoặc nhập tệp `.photoframepack` để chia sẻ bộ sưu tập khung.
- **Trình sửa khung (Frame Editor)**:
  - Cột quản lý ô ảnh (1 đến 12 ô).
  - Kéo thả, thay đổi kích thước, thứ tự hiển thị (Z-order), bo góc.
  - Tích hợp kiểm tra hợp lệ: Chặn lưu nếu lớp phủ kín che mất ô ảnh.
  - Hỗ trợ Undo (`Cmd + Z`) và Redo (`Cmd + Shift + Z`).

### 2.6. Thư viện & Thùng rác (Library & Trash)
- **Thư viện**: Xem lại toàn bộ các phiên đã chụp, hiển thị ảnh xem trước, tên khung lúc chụp, ngày giờ và số lượng ảnh.
- **Thùng rác an toàn**:
  - Xóa phiên/khung/danh mục/preset sẽ được chuyển vào Thùng rác và lưu trữ an toàn trong 30 ngày.
  - Khôi phục (Restore): Đưa mục về vị trí ban đầu. Nếu trùng tên, tự động thêm hậu tố an toàn.
  - Dọn sạch (Purge): Xóa vĩnh viễn và dọn dẹp các tệp ảnh không còn tham chiếu.
