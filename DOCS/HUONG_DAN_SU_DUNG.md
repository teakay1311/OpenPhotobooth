# Hướng dẫn sử dụng Open Photobooth v1.2

Open Photobooth là ứng dụng Photobooth bản địa (native) dành riêng cho hệ điều hành macOS, hỗ trợ chụp ảnh theo khung tùy chỉnh, chỉnh sửa vị trí ảnh, áp dụng preset màu và xuất file chất lượng cao.

---

## 1. Yêu cầu hệ thống và cài đặt
- **Hệ điều hành**: macOS 14.0 (Sonoma) trở lên (khuyến nghị macOS 14 hoặc macOS 15+).
- **Phần cứng**: Tương thích cả Apple Silicon (M1/M2/M3/M4) và vi xử lý Intel (Universal Binary).
- **Quyền truy cập**: Quyền sử dụng **Camera** (ứng dụng tuyệt đối không yêu cầu quyền Microphone).
- **Cài đặt**: Kéo thả tệp `Open Photobooth.app` vào thư mục `/Applications` hoặc mở trực tiếp từ Finder.

---

## 2. Các màn hình và luồng chức năng chính

### 2.1. Màn hình Chụp ảnh (Capture)
1. Chọn **Số ảnh của phiên** ở đầu màn Chụp ảnh. Phiên mới dùng luồng **chụp trước, chọn khung sau**: chụp đủ ảnh, bấm **Chọn khung**, chọn ảnh vào các ô và bấm **Dùng khung này**. Ứng dụng có 9 khung dựng sẵn gồm *Dải 3 ảnh*, *Lưới 4 ảnh*, *Một ảnh lớn*, *Cặp ảnh dọc*, *Cặp ảnh ngang*, *Collage 5 ảnh*, *Lưới 6 ảnh*, *Lưới 8 ảnh* và *Lưới 9 ảnh*.
2. **Cài đặt nhanh** nằm ở cột bên màn Chụp ảnh. Chọn **Tự động** hoặc **Thủ công**, đặt đếm ngược 0, 3, 5, 10 giây hoặc tùy chỉnh từ 1 đến 30 giây, và đặt thời gian nghỉ giữa lượt từ 0 đến 15 giây.
3. Nếu chụp nhiều ảnh hơn số ô của khung, chọn các ảnh theo thứ tự muốn đưa vào các ô và bấm lại để bỏ chọn. Các phiên cũ đã gắn khung vẫn có thể tiếp tục theo cấu hình được lưu của phiên đó.
4. Chọn **Preset màu**, **Lật ngang ảnh thành phẩm** và **Âm thanh** ở cùng cột. Các thông số chụp và hướng ảnh thành phẩm được chốt khi bắt đầu phiên. Lật ảnh xem trước được chỉnh riêng trong Cài đặt camera.
5. Bấm **Chụp** hoặc phím `Space` để bắt đầu. Dùng `Esc` để hủy đếm ngược. Nếu ảnh đã lưu, ứng dụng giữ ảnh để tiếp tục hoặc xem lại.

### 2.2. Chế độ Toàn màn hình (Fullscreen Kiosk)
- Bật từ nút **Toàn màn hình** ở góc trên thanh công cụ màn Chụp ảnh.
- Chế độ kiosk tối ưu cho sự kiện / tiệc cưới, tự động quay về màn hình chờ sau khi hoàn tất.

### 2.3. Màn hình Xem lại & Chỉnh sửa (Review)
- **Căn chỉnh ảnh trong ô**: Kéo di chuyển hoặc cuộn chuột để phóng to/thu nhỏ ảnh trong từng ô của khung.
- **Chế độ cắt (Crop Mode)**:
  - **Fill (Lấp đầy)**: Cắt tràn ô ảnh mà không méo tỉ lệ.
  - **Fit (Vừa khung)**: Hiển thị trọn vẹn toàn bộ ảnh trong ô.
  - **Auto Face (Nhận diện mặt)** căn theo khuôn mặt. Nếu không tìm thấy mặt, ảnh được căn giữa. Bạn có thể yêu cầu căn lại từ Review.
- **Chụp lại (Retake)**: Chọn một ô ảnh bất kỳ trên dải ảnh và bấm "Chụp lại" để chụp lại đúng ô đó (áp dụng cho cả phiên vừa chụp lẫn bất kỳ phiên nào mở lại từ Thư viện); các ô ảnh khác được giữ nguyên. Sau khi chụp lại thành công, ứng dụng tự động quay về đúng phiên trong màn hình Xem và chỉnh ảnh.
- **Đổi khung trong Review**: Có thể đổi sang khung khác khi đang xem lại; các ảnh đã chụp sẽ được tự động giữ nguyên và gán vào các ô tương ứng.
- **Phiên từ phiên bản cũ** tiếp tục dùng màu, crop và góc xoay đã lưu. Bộ dựng ảnh bỏ qua tham số làm mịn da cũ.

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
