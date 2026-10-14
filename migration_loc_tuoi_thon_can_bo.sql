-- MIGRATION: LỌC THEO NHÓM TUỔI / NGÀY SINH (tìm kiếm nâng cao) + THỐNG KÊ "THÔN × CÁN BỘ" (nhật ký)
-- Chạy 1 lần trong Supabase SQL Editor SAU migration_tong_hop, migration_superadmin và migration_them_doi_tuong_thon.
-- Chạy lại nhiều lần vẫn an toàn. Chạy xong mới thay index.html mới.
-- Lưu ý: file này ghi đè các hàm ra_where / search_people / dem_people / thong_ke_ra_soat của migration_tong_hop,
--        nên KHÔNG chạy lại migration_tong_hop sau file này (nếu lỡ chạy thì chạy lại file này).
-- Nội dung:
--  1) Tìm kiếm nâng cao thêm: p_age (nhóm tuổi '0-6' | '6-18' | '18+'), p_b1 / p_b2 (ngày sinh từ / đến). Chỉ admin / superadmin.
--     Tuổi tính theo ngày hôm nay (giờ Việt Nam):  0-6 = dưới 6 tuổi;  6-18 = từ đủ 6 đến dưới 18 tuổi;  18+ = từ đủ 18 tuổi trở lên.
--  2) Hàm thong_ke_thon_can_bo(): mỗi thôn có bao nhiêu cán bộ rà soát và mỗi người rà soát được bao nhiêu. Chỉ admin / superadmin.

create index if not exists people_ngay_sinh_idx on people(ngay_sinh);

-- bỏ bản cũ (khác số tham số) để không bị trùng tên hàm
drop function if exists search_people(text,text,int,text,boolean,text,text[],boolean,boolean,text,uuid,timestamptz,timestamptz,int,int);
drop function if exists dem_people(text,int,text,boolean,text,text[],boolean,boolean,text,uuid,timestamptz,timestamptz);
drop function if exists ra_where(text,int,text,boolean,text,text[],boolean,boolean,text,uuid,timestamptz,timestamptz);
drop function if exists thong_ke_ra_soat(uuid,text,timestamptz,timestamptz);

-- ===== 1) Điều kiện lọc =====
create or replace function ra_where(p_q text,p_yr int,p_th text,p_kh boolean,p_rs text,p_flags text[],p_all boolean,p_thieu boolean,p_ev text,p_who uuid,p_t1 timestamptz,p_t2 timestamptz,
  p_age text default null,p_b1 date default null,p_b2 date default null)
returns text language plpgsql stable set search_path=public as $$
declare w text:='true'; f text; parts text[]:='{}'; col text; val text; evs text; cur text:='';
        td text:='(now() at time zone ''Asia/Ho_Chi_Minh'')::date';   -- hôm nay theo giờ Việt Nam
begin
  if p_q<>'' then w:=w||case when p_q ~ '^[0-9]+$' then ' and p.cccd ilike $1' else ' and p.search_key ilike $1' end; end if;
  if p_yr is not null then w:=w||' and p.nam_sinh=$3'; end if;
  if p_th is not null then w:=w||' and p.thon=$4'; end if;
  if p_kh is not null then w:=w||' and p.da_kham=$5'; if not p_kh then w:=w||' and not p.da_chet'; end if; end if;
  if p_rs is not null then w:=w||' and p.trang_thai_ra_soat=$6'; end if;
  if p_flags is not null and cardinality(p_flags)>0 then   -- chọn nhiều tình trạng: mặc định "có ít nhất một", p_all = "phải có đủ tất cả"
    foreach f in array p_flags loop
      if f not in ('da_chet','di_vang','sinh_vien','dang_lam_cty') then raise exception 'Bộ lọc không hợp lệ'; end if;
      parts:=parts||format('p.%I',f);
    end loop;
    w:=w||' and ('||array_to_string(parts,case when coalesce(p_all,false) then ' and ' else ' or ' end)||')';
  end if;
  if coalesce(p_thieu,false) then w:=w||' and p.cccd is null'; end if;   -- thiếu CCCD
  -- LỌC THEO TUỔI / NGÀY SINH (quản trị). Người chưa có ngày sinh sẽ không nằm trong kết quả khi đang lọc tuổi / ngày sinh.
  if p_age is not null then
    if p_age not in ('0-6','6-18','18+') then raise exception 'Bộ lọc không hợp lệ'; end if;
    w:=w||case p_age
      when '0-6'  then ' and p.ngay_sinh>('||td||' - interval ''6 years'')'
      when '6-18' then ' and p.ngay_sinh<=('||td||' - interval ''6 years'') and p.ngay_sinh>('||td||' - interval ''18 years'')'
      else             ' and p.ngay_sinh<=('||td||' - interval ''18 years'')' end;
  end if;
  if p_b1 is not null then w:=w||' and p.ngay_sinh>=$12'; end if;
  if p_b2 is not null then w:=w||' and p.ngay_sinh<=$13'; end if;
  -- TÌM KIẾM NÂNG CAO (quản trị): dựa trên nhật ký thao tác -> biết AI đã làm GÌ, KHI NÀO.
  -- p_ev: ra_soat | kham | cty | sinh_vien | di_vang | chet (NULL = bất kỳ thay đổi nào); p_who: cán bộ; p_t1..p_t2: khoảng thời gian thao tác
  if p_ev is not null or p_who is not null or p_t1 is not null or p_t2 is not null then
    if p_ev is null then evs:='k.hanh_dong in (''sua'',''them'')';
    else
      col:=case p_ev when 'ra_soat' then 'trang_thai_ra_soat' when 'kham' then 'da_kham' when 'cty' then 'dang_lam_cty'
                     when 'sinh_vien' then 'sinh_vien' when 'di_vang' then 'di_vang' when 'chet' then 'da_chet' end;
      if col is null then raise exception 'Bộ lọc không hợp lệ'; end if;
      val:=case when p_ev='ra_soat' then 'Đã rà soát' else 'true' end;
      evs:=format('k.hanh_dong=''sua'' and k.truong=%L and k.moi=%L',col,val);
      cur:=case when p_ev='ra_soat' then ' and p.trang_thai_ra_soat=''Đã rà soát''' else format(' and p.%I',col) end;   -- và hiện vẫn đang ở trạng thái đó
    end if;
    w:=w||' and exists(select 1 from nhat_ky k where k.person_id=p.id and '||evs
      ||case when p_who is not null then ' and k.nguoi=$11' else '' end
      ||case when p_t1 is not null then ' and k.luc>=$9' else '' end
      ||case when p_t2 is not null then ' and k.luc<=$10' else '' end||')'||cur;
  end if;
  return w;
end $$;

create or replace function search_people(p_q text default '', p_qa text default '', p_yr int default null, p_th text default null,
  p_kh boolean default null, p_rs text default null, p_flags text[] default null, p_all boolean default false, p_thieu boolean default null,
  p_ev text default null, p_who uuid default null, p_t1 timestamptz default null, p_t2 timestamptz default null,
  p_age text default null, p_b1 date default null, p_b2 date default null, p_off int default 0, p_lim int default 30)
returns setof people language plpgsql stable security definer set search_path=public,extensions as $$
declare o text:='p.ho_ten, p.id'; adv boolean:=(p_ev is not null or p_who is not null or p_t1 is not null or p_t2 is not null);
        advx boolean:=(p_ev is not null or p_who is not null or p_t1 is not null or p_t2 is not null or p_age is not null or p_b1 is not null or p_b2 is not null);
begin
  if not is_active() then raise exception 'Tài khoản chưa được cấp quyền' using errcode='42501'; end if;
  if advx and not is_admin() then raise exception 'Chỉ quản trị viên được dùng tìm kiếm nâng cao' using errcode='42501'; end if;
  p_lim:=least(coalesce(p_lim,30),case when is_admin() then 1000 else 100 end);   -- chống tải hàng loạt: cán bộ tối đa 100 dòng/lần
  if adv then o:='p.updated_at desc, p.id';
  elsif p_qa<>'' then o:='(p.ten_dau ilike $2) desc, '||o; end if;
  return query execute 'select p.* from people p where '||ra_where(p_q,p_yr,p_th,p_kh,p_rs,p_flags,p_all,p_thieu,p_ev,p_who,p_t1,p_t2,p_age,p_b1,p_b2)||' order by '||o||' offset $7 limit $8'
    using '%'||p_q||'%','%'||p_qa||'%',p_yr,p_th,p_kh,p_rs,p_off,p_lim,p_t1,p_t2,p_who,p_b1,p_b2;
end $$;

create or replace function dem_people(p_q text default '', p_yr int default null, p_th text default null,
  p_kh boolean default null, p_rs text default null, p_flags text[] default null, p_all boolean default false, p_thieu boolean default null,
  p_ev text default null, p_who uuid default null, p_t1 timestamptz default null, p_t2 timestamptz default null,
  p_age text default null, p_b1 date default null, p_b2 date default null)
returns bigint language plpgsql stable security definer set search_path=public,extensions as $$
declare n bigint;
begin
  if not is_active() then raise exception 'Tài khoản chưa được cấp quyền' using errcode='42501'; end if;
  if (p_ev is not null or p_who is not null or p_t1 is not null or p_t2 is not null or p_age is not null or p_b1 is not null or p_b2 is not null) and not is_admin() then
    raise exception 'Chỉ quản trị viên được dùng tìm kiếm nâng cao' using errcode='42501'; end if;
  execute 'select count(*) from people p where '||ra_where(p_q,p_yr,p_th,p_kh,p_rs,p_flags,p_all,p_thieu,p_ev,p_who,p_t1,p_t2,p_age,p_b1,p_b2) into n
    using '%'||p_q||'%','',p_yr,p_th,p_kh,p_rs,0,0,p_t1,p_t2,p_who,p_b1,p_b2;
  return n;
end $$;

-- Thống kê của tìm kiếm nâng cao: áp dụng cả bộ lọc tuổi / ngày sinh
create or replace function thong_ke_ra_soat(p_who uuid default null, p_th text default null, p_t1 timestamptz default null, p_t2 timestamptz default null,
  p_age text default null, p_b1 date default null, p_b2 date default null)
returns table(n_tong bigint,n_kham bigint,n_sv bigint,n_cty bigint,n_dv bigint,n_chet bigint)
language plpgsql stable security definer set search_path=public,extensions as $$
begin
  if not is_admin() then raise exception 'Chỉ quản trị viên' using errcode='42501'; end if;
  return query execute 'select count(*), count(*) filter (where p.da_kham), count(*) filter (where p.sinh_vien), count(*) filter (where p.dang_lam_cty),
      count(*) filter (where p.di_vang), count(*) filter (where p.da_chet) from people p where '
    ||ra_where('',null,p_th,null,null,null,false,null,'ra_soat',p_who,p_t1,p_t2,p_age,p_b1,p_b2)
    using '%%','',null::int,p_th,null::boolean,null::text,0,0,p_t1,p_t2,p_who,p_b1,p_b2;
end $$;

-- ===== 2) Thống kê thôn × cán bộ (chỉ admin / superadmin) =====
-- Với mỗi thôn: những cán bộ đã rà soát ở thôn đó (có ít nhất 1 người được rà soát trong khoảng thời gian) và mỗi người rà soát được bao nhiêu NGƯỜI.
-- Cách tính từng cột giống thong_ke_thon / thong_ke_can_bo. n_rs_thon = số người khác nhau được rà soát trong thôn (không cộng trùng khi 2 cán bộ cùng đánh dấu 1 người);
-- n_cb_thon = số cán bộ đã rà soát trong thôn.
create or replace function thong_ke_thon_can_bo(p_t1 timestamptz default null, p_t2 timestamptz default null)
returns table(thon text,uid uuid,ten text,n_rs bigint,n_kham bigint,n_cty bigint,n_sv bigint,n_dv bigint,n_chet bigint,n_nguoi bigint,n_thay_doi bigint,n_rs_thon bigint,n_cb_thon bigint)
language plpgsql stable security definer set search_path=public as $$
begin
  if not is_admin() then raise exception 'Chỉ quản trị viên' using errcode='42501'; end if;
  return query
  with a as (
    select coalesce(p.thon,'(Không rõ thôn)') as c_th, k.nguoi as c_u,
      coalesce((select n.ho_ten from nguoi_dung n where n.id=k.nguoi), max(k.ten_nguoi)) as c_ten,
      count(distinct k.person_id) filter (where k.hanh_dong='sua' and k.truong='trang_thai_ra_soat' and k.moi='Đã rà soát' and p.trang_thai_ra_soat='Đã rà soát') as c_rs,
      count(distinct k.person_id) filter (where k.hanh_dong='sua' and k.truong='da_kham' and k.moi='true' and p.da_kham) as c_kham,
      count(distinct k.person_id) filter (where k.hanh_dong='sua' and k.truong='dang_lam_cty' and k.moi='true' and p.dang_lam_cty) as c_cty,
      count(distinct k.person_id) filter (where k.hanh_dong='sua' and k.truong='sinh_vien' and k.moi='true' and p.sinh_vien) as c_sv,
      count(distinct k.person_id) filter (where k.hanh_dong='sua' and k.truong='di_vang' and k.moi='true' and p.di_vang) as c_dv,
      count(distinct k.person_id) filter (where k.hanh_dong='sua' and k.truong='da_chet' and k.moi='true' and p.da_chet) as c_chet,
      count(distinct k.person_id) as c_ng, count(*) as c_td
    from nhat_ky k left join people p on p.id=k.person_id
    where k.hanh_dong in ('them','sua','xoa') and k.nguoi is not null
      and k.luc>=coalesce(p_t1,'-infinity'::timestamptz) and k.luc<=coalesce(p_t2,'infinity'::timestamptz)
    group by coalesce(p.thon,'(Không rõ thôn)'), k.nguoi
  ), t as (
    select coalesce(p.thon,'(Không rõ thôn)') as t_th, count(distinct k.person_id) as t_rs
    from nhat_ky k left join people p on p.id=k.person_id
    where k.hanh_dong='sua' and k.truong='trang_thai_ra_soat' and k.moi='Đã rà soát' and p.trang_thai_ra_soat='Đã rà soát' and k.nguoi is not null
      and k.luc>=coalesce(p_t1,'-infinity'::timestamptz) and k.luc<=coalesce(p_t2,'infinity'::timestamptz)
    group by coalesce(p.thon,'(Không rõ thôn)')
  )
  select a.c_th, a.c_u, a.c_ten, a.c_rs, a.c_kham, a.c_cty, a.c_sv, a.c_dv, a.c_chet, a.c_ng, a.c_td,
         t.t_rs, (count(*) over (partition by a.c_th))
  from a join t on t.t_th=a.c_th
  where a.c_rs>0
  order by t.t_rs desc, a.c_th, a.c_rs desc, a.c_ten;
end $$;
revoke all on function thong_ke_thon_can_bo(timestamptz,timestamptz) from public, anon;
grant execute on function thong_ke_thon_can_bo(timestamptz,timestamptz) to authenticated;
