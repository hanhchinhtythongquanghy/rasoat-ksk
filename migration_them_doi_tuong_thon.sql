-- MIGRATION: THÊM ĐỐI TƯỢNG MỚI (tự sinh mã hộ) + THỐNG KÊ THEO THÔN
-- Chạy 1 lần trong Supabase SQL Editor SAU migration_tong_hop và migration_superadmin. Chạy lại nhiều lần vẫn an toàn.
-- Nội dung:
--  1) Mã hộ tự sinh dạng MAHO0001, MAHO0002, ... (không trùng: dùng sequence + kiểm tra chưa có trong people.so_hsct).
--  2) Hàm them_doi_tuong_moi(): tạo 1 hộ mới + người đầu tiên của hộ, mọi tài khoản đang hoạt động dùng được. Có ghi nhật ký như thường lệ.
--  3) Hàm thong_ke_thon(): bảng thống kê theo thôn cho trang Nhật ký, CHỈ admin / superadmin xem được.

-- ===== 1) Mã hộ không trùng =====
create sequence if not exists ma_ho_seq;

create or replace function tao_ma_ho() returns text
language plpgsql volatile security definer set search_path=public as $$
declare n bigint; v text;
begin
  loop
    n:=nextval('ma_ho_seq');                                              -- mỗi lần gọi ra một số khác nhau, kể cả khi nhiều người bấm cùng lúc
    v:='MAHO'||lpad(n::text,greatest(4,length(n::text)),'0');            -- MAHO0001 ... MAHO9999, MAHO10000 ...
    exit when not exists(select 1 from people where so_hsct=v);          -- bỏ qua nếu mã này đã có sẵn (vd. nạp từ Excel)
  end loop;
  return v;
end $$;
revoke all on function tao_ma_ho() from public, anon, authenticated;     -- chỉ được gọi bên trong them_doi_tuong_moi

-- ===== 2) Thêm đối tượng mới (hộ mới) =====
create or replace function them_doi_tuong_moi(p_ho_ten text,p_ngay_sinh date,p_gioi_tinh text,p_cccd text,p_thon text,p_chu_ho text default null)
returns people language plpgsql security definer set search_path=public as $$
declare ten text:=regexp_replace(btrim(coalesce(p_ho_ten,'')),'\s+',' ','g');
        th text:=btrim(coalesce(p_thon,''));
        cc text:=nullif(btrim(coalesce(p_cccd,'')),'');
        ch text:=regexp_replace(btrim(coalesce(p_chu_ho,'')),'\s+',' ','g');
        r people;
begin
  if not is_active() then raise exception 'Tài khoản chưa được cấp quyền' using errcode='42501'; end if;
  if ten='' then raise exception 'Nhập họ tên'; end if;
  if th='' then raise exception 'Chọn thôn'; end if;
  if cc is not null and cc !~ '^\d{12}$' then raise exception 'CCCD gồm đúng 12 chữ số'; end if;
  insert into people(ho_ten,ngay_sinh,gioi_tinh,cccd,so_hsct,chu_ho,thon)
  values(ten,p_ngay_sinh,nullif(btrim(coalesce(p_gioi_tinh,'')),''),cc,tao_ma_ho(),coalesce(nullif(ch,''),ten),th)   -- để trống chủ hộ = chính người này là chủ hộ
  returning * into r;
  return r;
end $$;
revoke all on function them_doi_tuong_moi(text,date,text,text,text,text) from public, anon;
grant execute on function them_doi_tuong_moi(text,date,text,text,text,text) to authenticated;

-- ===== 3) Thống kê theo thôn (chỉ admin / superadmin) =====
-- Cùng cách tính với bảng theo cán bộ (thong_ke_can_bo): các cột Rà soát..Chết = số NGƯỜI được thao tác trong khoảng thời gian
-- và hiện vẫn đang ở trạng thái đó; n_nguoi = số người khác nhau bị tác động; n_thay_doi = số lần thay đổi.
create or replace function thong_ke_thon(p_t1 timestamptz default null, p_t2 timestamptz default null)
returns table(thon text,n_rs bigint,n_kham bigint,n_cty bigint,n_sv bigint,n_dv bigint,n_chet bigint,n_nguoi bigint,n_thay_doi bigint)
language plpgsql stable security definer set search_path=public as $$
begin
  if not is_admin() then raise exception 'Chỉ quản trị viên' using errcode='42501'; end if;
  return query
  select coalesce(p.thon,'(Không rõ thôn)'),
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
  group by coalesce(p.thon,'(Không rõ thôn)')
  order by 9 desc, 1;
end $$;
revoke all on function thong_ke_thon(timestamptz,timestamptz) from public, anon;
grant execute on function thong_ke_thon(timestamptz,timestamptz) to authenticated;
