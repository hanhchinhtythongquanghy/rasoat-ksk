-- ĐẶT LẠI MẬT KHẨU cho một tài khoản (quản trị viên chạy trong Supabase → SQL Editor)
-- Sửa EMAIL và MẬT KHẨU MỚI bên dưới (mật khẩu từ 6 ký tự trở lên), rồi chạy.
-- Kết quả hiện ra 1 dòng (email) là thành công; 0 dòng nghĩa là sai email.
update auth.users
set encrypted_password = crypt('MAT-KHAU-MOI-O-DAY', gen_salt('bf')), updated_at = now()
where lower(email) = lower('cb01@example.com')
returning email;

-- (Tuỳ chọn) Buộc thiết bị cũ phải đăng nhập lại bằng mật khẩu mới:
-- delete from auth.sessions where user_id = (select id from auth.users where lower(email)=lower('cb01@example.com'));
