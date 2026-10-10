-- MIGRATION: SIÊU QUẢN TRỊ + GHI CHÚ CHUNG + NHẬT KÝ CÔNG KHAI THỐNG KÊ
-- Chạy 1 lần trong Supabase SQL Editor SAU migration_tong_hop. Chạy lại nhiều lần vẫn an toàn.
-- Nội dung:
--  1) Thêm vai trò 'superadmin' (is_admin() vẫn đúng cho cả admin lẫn superadmin).
--  2) Chỉ superadmin: nhập Excel, đổi quyền người dùng. Admin không sửa/khóa/đặt lại mật khẩu được tài khoản superadmin.
--  3) Ghi chú thành ghi chú CHUNG: mọi tài khoản xem được, chỉ quản trị (admin/superadmin) thêm/sửa/xóa.
--  4) Bảng thống kê theo cán bộ (có tổng số người + tổng số thay đổi) cho MỌI tài khoản xem; chi tiết nhật ký vẫn chỉ xem của mình (RLS k_sel giữ nguyên).
--  5) Bỏ chức năng hoàn tác từ nhật ký.

-- ===== 1) Vai trò =====
do $$ declare c text; begin
  for c in select conname from pg_constraint where conrelid='public.nguoi_dung'::regclass and contype='c' and pg_get_constraintdef(oid) ilike '%vai_tro%' loop
    execute format('alter table nguoi_dung drop constraint %I',c);
  end loop;
  alter table nguoi_dung add constraint nguoi_dung_vai_tro_check check (vai_tro in ('superadmin','admin','can_bo'));
end $$;

create or replace function is_admin() returns boolean language sql stable security definer set search_path=public as
$$ select exists(select 1 from nguoi_dung where id=auth.uid() and hoat_dong and vai_tro in ('admin','superadmin')) $$;
create or replace function is_superadmin() returns boolean language sql stable security definer set search_path=public as
$$ select exists(select 1 from nguoi_dung where id=auth.uid() and hoat_dong and vai_tro='superadmin') $$;

-- Chặn ở tầng CSDL: chỉ superadmin được đổi quyền / cấp quyền quản trị / đụng vào tài khoản superadmin
create or replace function nguoi_dung_sk() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null or is_superadmin() or is_sys() then   -- SQL Editor / hệ thống / superadmin: cho phép
    if tg_op='DELETE' then return old; end if; return new;
  end if;
  if tg_op='INSERT' then
    if new.vai_tro<>'can_bo' then raise exception 'Chỉ siêu quản trị được cấp quyền quản trị' using errcode='42501'; end if;
    return new;
  elsif tg_op='DELETE' then
    if old.vai_tro='superadmin' then raise exception 'Chỉ siêu quản trị được xóa tài khoản siêu quản trị' using errcode='42501'; end if;
    return old;
  else
    if old.vai_tro='superadmin' then raise exception 'Chỉ siêu quản trị được sửa tài khoản siêu quản trị' using errcode='42501'; end if;
    if new.vai_tro is distinct from old.vai_tro then raise exception 'Chỉ siêu quản trị được đổi quyền người dùng' using errcode='42501'; end if;
    return new;
  end if;
end $$;
drop trigger if exists trg_nguoi_dung_sk on nguoi_dung;
create trigger trg_nguoi_dung_sk before insert or update or delete on nguoi_dung for each row execute function nguoi_dung_sk();

create or replace function ds_nguoi_dung() returns table(id uuid,email text,ho_ten text,vai_tro text,hoat_dong boolean)
language plpgsql stable security definer set search_path=public as $$
begin
  if not (is_admin() or is_sys()) then raise exception 'Chỉ quản trị viên' using errcode='42501'; end if;
  return query select n.id,u.email::text,n.ho_ten,n.vai_tro,n.hoat_dong from nguoi_dung n left join auth.users u on u.id=n.id
    order by case n.vai_tro when 'superadmin' then 0 when 'admin' then 1 else 2 end, n.ho_ten;
end $$;

create or replace function them_nguoi_dung(p_email text,p_ten text,p_vai_tro text default 'can_bo') returns text
language plpgsql security definer set search_path=public as $$
declare v uuid;
begin
  if not (is_admin() or is_sys()) then raise exception 'Chỉ quản trị viên' using errcode='42501'; end if;
  if p_vai_tro not in ('superadmin','admin','can_bo') then raise exception 'Vai trò không hợp lệ'; end if;
  if p_vai_tro<>'can_bo' and not (is_superadmin() or is_sys()) then raise exception 'Chỉ siêu quản trị được cấp quyền quản trị' using errcode='42501'; end if;
  select id into v from auth.users where lower(email)=lower(trim(p_email));
  if v is null then return 'Chưa có tài khoản này: hãy tạo trong Supabase → Authentication → Users trước'; end if;
  insert into nguoi_dung(id,ho_ten,vai_tro,hoat_dong) values(v,trim(p_ten),p_vai_tro,true)
    on conflict (id) do update set ho_ten=excluded.ho_ten, hoat_dong=true,
      vai_tro=case when is_superadmin() or is_sys() then excluded.vai_tro else nguoi_dung.vai_tro end;   -- admin thêm lại email đã có thì KHÔNG đổi quyền
  return 'ok';
end $$;

create or replace function dat_lai_mat_khau(p_id uuid,p_mk text) returns text
language plpgsql security definer set search_path=public,extensions as $$
declare who text; ten text; n int;
begin
  if not (is_admin() or is_sys()) then raise exception 'Chỉ quản trị viên' using errcode='42501'; end if;
  if exists(select 1 from nguoi_dung where id=p_id and vai_tro='superadmin') and not (is_superadmin() or is_sys()) then
    raise exception 'Chỉ siêu quản trị được đặt lại mật khẩu của siêu quản trị' using errcode='42501'; end if;
  if length(coalesce(p_mk,''))<6 then raise exception 'Mật khẩu ít nhất 6 ký tự'; end if;
  update auth.users set encrypted_password=crypt(p_mk,gen_salt('bf')), updated_at=now() where id=p_id;
  get diagnostics n=row_count;
  if n=0 then raise exception 'Không tìm thấy tài khoản'; end if;
  begin delete from auth.sessions where user_id=p_id; exception when others then null; end;   -- buộc thiết bị cũ đăng nhập lại
  select ho_ten into who from nguoi_dung where id=auth.uid();
  select ho_ten into ten from nguoi_dung where id=p_id;
  insert into nhat_ky(nguoi,ten_nguoi,hanh_dong,truong,moi)
    values(auth.uid(),coalesce(who,'Hệ thống'),'mat_khau','mat_khau','Đặt lại mật khẩu cho '||coalesce(ten,'?'));   -- không ghi mật khẩu
  return 'ok';
end $$;

-- ===== 2) Nhập Excel: chỉ superadmin =====
create or replace function bulk_upsert(rows jsonb, add_new boolean default false) returns int
language plpgsql set search_path=public as $$
declare n int;
begin
  if not (is_superadmin() or is_sys()) then raise exception 'Chỉ siêu quản trị được nhập Excel' using errcode='42501'; end if;
  insert into workplaces(name)
    select distinct trim(x->>'noi_cong_tac') from jsonb_array_elements(rows) x
    where coalesce(trim(x->>'noi_cong_tac'),'')<>'' on conflict do nothing;
  if add_new then
    insert into people(stt,ho_ten,ngay_sinh,gioi_tinh,cccd,chu_ho,so_hsct,thon)
    select r.stt,r.ho_ten,r.ngay_sinh,r.gioi_tinh,r.cccd,r.chu_ho,r.so_hsct,r.thon
    from jsonb_to_recordset(rows) as r(stt int,ho_ten text,ngay_sinh date,gioi_tinh text,cccd text,chu_ho text,so_hsct text,thon text)
    where r.cccd is not null and r.ho_ten is not null
    on conflict (cccd) do update set ho_ten=excluded.ho_ten, ngay_sinh=excluded.ngay_sinh,
      gioi_tinh=excluded.gioi_tinh, chu_ho=excluded.chu_ho, so_hsct=excluded.so_hsct, thon=excluded.thon;
  end if;
  update people p set
    nhom_doi_tuong=coalesce(r.nhom_doi_tuong,p.nhom_doi_tuong),
    trang_thai_ra_soat=coalesce(r.trang_thai_ra_soat,p.trang_thai_ra_soat),
    da_kham=coalesce(r.da_kham,p.da_kham), noi_kham=coalesce(r.noi_kham,p.noi_kham),
    dang_lam_cty=coalesce(r.dang_lam_cty,p.dang_lam_cty), noi_cong_tac=coalesce(r.noi_cong_tac,p.noi_cong_tac),
    di_vang=coalesce(r.di_vang,p.di_vang), sinh_vien=coalesce(r.sinh_vien,p.sinh_vien)
  from jsonb_to_recordset(rows) as r(cccd text,nhom_doi_tuong text,trang_thai_ra_soat text,da_kham boolean,noi_kham text,dang_lam_cty boolean,noi_cong_tac text,di_vang boolean,sinh_vien boolean)
  where p.cccd=r.cccd;
  get diagnostics n = row_count; return n;
end $$;

-- ===== 3) Ghi chú chung: ai cũng xem, chỉ quản trị sửa =====
drop policy if exists gc_all on ghi_chu; drop policy if exists gc_sel on ghi_chu; drop policy if exists gc_ins on ghi_chu;
drop policy if exists gc_upd on ghi_chu; drop policy if exists gc_del on ghi_chu;
create policy gc_sel on ghi_chu for select to authenticated using ((select is_active()));
create policy gc_ins on ghi_chu for insert to authenticated with check ((select is_admin()) and nguoi=auth.uid());
create policy gc_upd on ghi_chu for update to authenticated using ((select is_admin())) with check ((select is_admin()));
create policy gc_del on ghi_chu for delete to authenticated using ((select is_admin()));

-- ===== 4) Thống kê theo cán bộ cho trang Nhật ký (mọi tài khoản đang hoạt động đều xem được) =====
-- Các cột Rà soát..Chết: số NGƯỜI mà cán bộ đã đánh dấu trong khoảng thời gian và hiện vẫn đang ở trạng thái đó.
-- n_nguoi = tổng số người khác nhau cán bộ đã tác động; n_thay_doi = tổng số lần thay đổi.
drop function if exists thong_ke_can_bo(text,timestamptz,timestamptz);
create or replace function thong_ke_can_bo(p_t1 timestamptz default null, p_t2 timestamptz default null)
returns table(uid uuid,ten text,n_rs bigint,n_kham bigint,n_cty bigint,n_sv bigint,n_dv bigint,n_chet bigint,n_nguoi bigint,n_thay_doi bigint)
language plpgsql stable security definer set search_path=public as $$
begin
  if not is_active() then raise exception 'Tài khoản chưa được cấp quyền' using errcode='42501'; end if;
  return query
  select k.nguoi,
    coalesce((select n.ho_ten from nguoi_dung n where n.id=k.nguoi), max(k.ten_nguoi)),
    count(distinct k.person_id) filter (where k.hanh_dong='sua' and k.truong='trang_thai_ra_soat' and k.moi='Đã rà soát' and p.trang_thai_ra_soat='Đã rà soát'),
    count(distinct k.person_id) filter (where k.hanh_dong='sua' and k.truong='da_kham' and k.moi='true' and p.da_kham),
    count(distinct k.person_id) filter (where k.hanh_dong='sua' and k.truong='dang_lam_cty' and k.moi='true' and p.dang_lam_cty),
    count(distinct k.person_id) filter (where k.hanh_dong='sua' and k.truong='sinh_vien' and k.moi='true' and p.sinh_vien),
    count(distinct k.person_id) filter (where k.hanh_dong='sua' and k.truong='di_vang' and k.moi='true' and p.di_vang),
    count(distinct k.person_id) filter (where k.hanh_dong='sua' and k.truong='da_chet' and k.moi='true' and p.da_chet),
    count(distinct k.person_id),
    count(*)
  from nhat_ky k left join people p on p.id=k.person_id
  where k.hanh_dong in ('them','sua','xoa') and k.nguoi is not null
    and k.luc>=coalesce(p_t1,'-infinity'::timestamptz) and k.luc<=coalesce(p_t2,'infinity'::timestamptz)
  group by k.nguoi
  order by 10 desc, 2;
end $$;

-- ===== 5) Bỏ hoàn tác từ nhật ký =====
drop function if exists hoan_tac_nhat_ky(bigint);

-- ===== BƯỚC CUỐI: chỉ định siêu quản trị (đổi email cho đúng), chạy trong SQL Editor =====
-- Chưa có siêu quản trị thì chưa ai nhập Excel / đổi quyền được.
-- update nguoi_dung set vai_tro='superadmin' where id=(select id from auth.users where lower(email)=lower('email-cua-ban@example.com'));
