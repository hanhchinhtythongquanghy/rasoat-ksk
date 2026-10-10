-- TẠO TÀI KHOẢN QUẢN TRỊ (admin)
-- Bước 1: Supabase → Authentication → Users → Add user → Create new user
--         nhập email + mật khẩu mạnh, TICK "Auto Confirm User".
-- Bước 2: sửa email và tên hiển thị bên dưới cho đúng, rồi chạy trong SQL Editor.
select them_nguoi_dung('admin@example.com', 'Quản trị viên', 'admin');
-- Kết quả 'ok' là xong. Nếu báo "Chưa có tài khoản này" thì làm lại Bước 1.
-- Sau đó đăng nhập vào phần mềm bằng tài khoản này: sẽ thấy thêm các tab Nhập Excel / Nhật ký / Cán bộ.
