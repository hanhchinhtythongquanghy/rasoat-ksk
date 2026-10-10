# Triển khai
1. Supabase → New project → SQL Editor → dán & chạy `schema.sql`.
2. Authentication → Users → Add user (tạo tài khoản cho từng người dùng). Tắt "Allow new users to sign up" để người ngoài không tự đăng ký.
3. Settings → API: lấy Project URL và anon key → dán vào 2 hằng số đầu phần `<script>` trong `index.html`.
4. Đẩy thư mục này lên GitHub → Vercel → Import (Framework: Other) → Deploy. (Hoặc `npx vercel`.)
5. Mở web → tab "Nhập Excel" → tick "Thêm người mới" → chọn file danh sách gốc 50.000 người (lần đầu).

# Cập nhật
- CSDL mới hoàn toàn: chạy `schema.sql`.
- CSDL đã có (đã chạy bản cũ): chạy `migration_tong_hop.sql` (chạy lại nhiều lần vẫn an toàn), rồi thay `index.html`.
  Các tài khoản đang có sẽ tự thành "cán bộ".

# Tài khoản quản trị (admin)
1. Supabase → Authentication → Users → Add user: nhập email + mật khẩu mạnh, tick "Auto Confirm User".
2. Mở `tao_admin.sql`, sửa email/tên cho đúng, chạy trong SQL Editor (kết quả `ok`).
3. Đăng nhập bằng tài khoản đó: sẽ thấy thêm 3 tab Nhập Excel / Nhật ký / Cán bộ.
Thêm cán bộ sau này: tạo tài khoản ở bước 1, rồi vào tab "Cán bộ" nhập email + tên.

# Phân quyền
- Cán bộ: tra cứu, tích các ô trạng thái, thêm người vào hộ, điền CCCD còn thiếu (đổi CCCD đã có thì chỉ quản trị viên); mọi thay đổi đều được ghi nhật ký.
- Quản trị: thêm Nhập Excel, xem nhật ký + hoàn tác, quản lý/khóa cán bộ, xóa dữ liệu.
- Tài khoản chưa có hồ sơ hoặc đã khóa không đọc/sửa được dữ liệu (kể cả khi mở đăng ký Supabase).

# Mật khẩu
- Mỗi người tự đổi ở nút "Đổi mật khẩu" (cạnh nút Thoát). Không bắt buộc đổi ở lần đăng nhập đầu.
- Quên mật khẩu: quản trị viên vào tab "Cán bộ" → nút "Đặt lại mật khẩu" (việc này được ghi vào Nhật ký). Cách dự phòng: `dat_lai_mat_khau.sql` chạy trong SQL Editor.
- Độ dài tối thiểu 6 ký tự (khớp mặc định của Supabase). Muốn chặt hơn: Supabase → Authentication → Sign In / Providers → Password.

# Xuất Excel
Chỉ quản trị viên thấy nút xuất. Không lọc = toàn xã; đang lọc = xuất đúng danh sách lọc. Mỗi lần xuất được ghi vào tab Nhật ký.
