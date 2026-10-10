-- Chạy toàn bộ file này trong Supabase > SQL Editor
create extension if not exists pg_trgm;
create extension if not exists unaccent; create extension if not exists pgcrypto;

create table people(
  id bigint generated always as identity primary key,
  stt int, ho_ten text not null, ngay_sinh date,
  nam_sinh int generated always as (extract(year from ngay_sinh)::int) stored,
  gioi_tinh text, cccd text unique, chu_ho text, so_hsct text, thon text,
  nhom_doi_tuong text,
  trang_thai_ra_soat text not null default 'Chưa rà soát',
  da_kham boolean not null default false,
  noi_kham text,                      -- chỉ hiển thị, không nhập ở giao diện
  dang_lam_cty boolean not null default false,
  noi_cong_tac text,
  da_chet boolean not null default false,
  di_vang boolean not null default false, sinh_vien boolean not null default false,
  kham_at timestamptz, ra_soat_at timestamptz, cong_tac_at timestamptz, chet_at timestamptz, di_vang_at timestamptz, sinh_vien_at timestamptz,  -- thời điểm đổi từng trường
  sua_boi uuid, sua_boi_ten text,                    -- người sửa lần cuối
  search_key text, ten_dau text, updated_at timestamptz default now()
);
create table workplaces(id bigint generated always as identity primary key, name text unique not null);

-- ===== Tài khoản & phân quyền =====
create table if not exists nguoi_dung(
  id uuid primary key references auth.users(id) on delete cascade,
  ho_ten text not null,                                   -- tên hiển thị, dùng để gắn trách nhiệm
  vai_tro text not null default 'can_bo' check (vai_tro in ('admin','can_bo')),
  hoat_dong boolean not null default true                 -- false = đã khóa
);
create table if not exists nhat_ky(
  id bigint generated always as identity primary key,
  luc timestamptz not null default now(),
  nguoi uuid, ten_nguoi text,                             -- ai sửa (lưu cả tên để không mất khi đổi/xóa tài khoản)
  person_id bigint, ten_doi_tuong text, cccd text,        -- sửa ai
  hanh_dong text not null,                                -- them | sua | xoa
  truong text, cu text, moi text                          -- trường nào, giá trị cũ -> mới
);
create index if not exists nhat_ky_luc_idx on nhat_ky(luc desc);
create index if not exists nhat_ky_person_idx on nhat_ky(person_id, luc desc);
create index if not exists nhat_ky_nguoi_idx on nhat_ky(nguoi, luc desc);

create or replace function is_active() returns boolean language sql stable security definer set search_path=public as
$$ select exists(select 1 from nguoi_dung where id=auth.uid() and hoat_dong) $$;
create or replace function is_admin() returns boolean language sql stable security definer set search_path=public as
$$ select exists(select 1 from nguoi_dung where id=auth.uid() and hoat_dong and vai_tro='admin') $$;
-- chạy từ SQL Editor / quản trị hệ thống (không phải từ ứng dụng)
create or replace function is_sys() returns boolean language sql stable as
$$ select session_user in ('postgres','supabase_admin') or coalesce((select rolsuper from pg_roles where rolname=session_user),false) $$;

create or replace function vn_canon(t text) returns text language sql immutable as $$
  select replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(t,'oà','òa'),'oá','óa'),'oả','ỏa'),'oã','õa'),'oạ','ọa'),'oè','òe'),'oé','óe'),'oẻ','ỏe'),'oẽ','õe'),'oẹ','ọe'),'uỳ','ùy'),'uý','úy'),'uỷ','ủy'),'uỹ','ũy'),'uỵ','ụy')
$$;

create function people_sk() returns trigger language plpgsql set search_path=public,extensions as $$
declare uid uuid:=auth.uid();
begin
  new.cccd:=nullif(trim(new.cccd),'');                                        -- CCCD rỗng => null (để lọc "thiếu CCCD")
  new.search_key:=lower(unaccent(new.ho_ten)); new.ten_dau:=vn_canon(lower(normalize(new.ho_ten,NFC)));
  if new.da_kham then new.trang_thai_ra_soat:='Đã rà soát'; end if;          -- đã khám => đã rà soát
  if tg_op='INSERT' then                                                      -- ghi thời điểm thay đổi từng trường
    if new.dang_lam_cty or new.di_vang or new.sinh_vien then new.trang_thai_ra_soat:='Đã rà soát'; end if;
    if new.da_kham then new.kham_at:=now(); end if;
    if new.trang_thai_ra_soat='Đã rà soát' then new.ra_soat_at:=now(); end if;
    if new.dang_lam_cty or new.noi_cong_tac is not null then new.cong_tac_at:=now(); end if;
    if new.da_chet then new.chet_at:=now(); end if;
    if new.di_vang then new.di_vang_at:=now(); end if;
    if new.sinh_vien then new.sinh_vien_at:=now(); end if;
    new.updated_at:=now();
  else
    if (new.dang_lam_cty and not old.dang_lam_cty) or (new.di_vang and not old.di_vang) or (new.sinh_vien and not old.sinh_vien)
      then new.trang_thai_ra_soat:='Đã rà soát'; end if;                      -- vừa tích => đã rà soát
    if new.da_kham is distinct from old.da_kham then new.kham_at:=now(); end if;
    if new.trang_thai_ra_soat is distinct from old.trang_thai_ra_soat then new.ra_soat_at:=now(); end if;
    if new.dang_lam_cty is distinct from old.dang_lam_cty or new.noi_cong_tac is distinct from old.noi_cong_tac then new.cong_tac_at:=now(); end if;
    if new.da_chet is distinct from old.da_chet then new.chet_at:=now(); end if;
    if new.di_vang is distinct from old.di_vang then new.di_vang_at:=now(); end if;
    if new.sinh_vien is distinct from old.sinh_vien then new.sinh_vien_at:=now(); end if;
    -- cán bộ chỉ được sửa các ô trạng thái và ĐIỀN CCCD còn thiếu; sửa thông tin hành chính / đổi CCCD đã có chỉ quản trị viên
    if uid is not null
       and ( (new.ho_ten,new.ngay_sinh,new.gioi_tinh,new.chu_ho,new.so_hsct,new.thon,new.stt,new.nhom_doi_tuong,new.noi_kham)
             is distinct from (old.ho_ten,old.ngay_sinh,old.gioi_tinh,old.chu_ho,old.so_hsct,old.thon,old.stt,old.nhom_doi_tuong,old.noi_kham)
             or (old.cccd is not null and new.cccd is distinct from old.cccd) )
       and not is_admin() then
      raise exception 'Chỉ quản trị viên được sửa thông tin hành chính' using errcode='42501';
    end if;
    if (to_jsonb(new)-'updated_at'-'search_key'-'ten_dau'-'sua_boi'-'sua_boi_ten') is distinct from (to_jsonb(old)-'updated_at'-'search_key'-'ten_dau'-'sua_boi'-'sua_boi_ten')
      then new.updated_at:=now(); new.sua_boi:=uid; new.sua_boi_ten:=(select ho_ten from nguoi_dung where id=uid);
      else new.updated_at:=old.updated_at; end if;                            -- không đổi gì thật thì giữ nguyên
  end if;
  return new; end $$;
create trigger trg_people_sk before insert or update on people for each row execute function people_sk();

create index on people using gin (search_key gin_trgm_ops);
create index on people using gin (cccd gin_trgm_ops);
create index on people(nam_sinh); create index on people(thon);
create index on people(so_hsct); create index on people(da_kham); create index on people(trang_thai_ra_soat);
create index if not exists people_kham_at_idx on people(kham_at) where kham_at is not null;
create index if not exists people_rs_at_idx on people(ra_soat_at) where ra_soat_at is not null;
create index if not exists people_ct_at_idx on people(cong_tac_at) where cong_tac_at is not null;
create index if not exists people_chet_at_idx on people(chet_at) where chet_at is not null;
create index if not exists people_dv_at_idx on people(di_vang_at) where di_vang_at is not null;
create index if not exists people_sv_at_idx on people(sinh_vien_at) where sinh_vien_at is not null;
create index if not exists people_nocccd_idx on people(id) where cccd is null;
create index if not exists people_upd_at_idx on people(updated_at);

create function list_thons() returns setof text language sql stable as
$$ select distinct thon from people where thon is not null order by 1 $$;

-- Cập nhật hàng loạt theo CCCD (ô trống trong Excel = giữ nguyên dữ liệu cũ)
create function bulk_upsert(rows jsonb, add_new boolean default false) returns int
language plpgsql set search_path=public as $$
declare n int;
begin
  if not (is_admin() or is_sys()) then raise exception 'Chỉ quản trị viên được nhập Excel' using errcode='42501'; end if;
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

-- ===== Tìm kiếm: SECURITY DEFINER để dùng được chỉ mục (RLS theo dòng làm mất chỉ mục), tự kiểm tra tài khoản ở đầu hàm =====
create or replace function ra_where(p_q text,p_yr int,p_th text,p_kh boolean,p_rs text,p_flags text[],p_all boolean,p_thieu boolean,p_ev text,p_who uuid,p_t1 timestamptz,p_t2 timestamptz)
returns text language plpgsql stable set search_path=public as $$
declare w text:='true'; f text; parts text[]:='{}'; col text; val text; evs text; cur text:='';
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

-- Tìm có dấu: kết quả khớp dấu xếp lên đầu; tìm kiếm nâng cao thì xếp người mới cập nhật lên đầu
create or replace function search_people(p_q text default '', p_qa text default '', p_yr int default null, p_th text default null,
  p_kh boolean default null, p_rs text default null, p_flags text[] default null, p_all boolean default false, p_thieu boolean default null,
  p_ev text default null, p_who uuid default null, p_t1 timestamptz default null, p_t2 timestamptz default null, p_off int default 0, p_lim int default 30)
returns setof people language plpgsql stable security definer set search_path=public,extensions as $$
declare o text:='p.ho_ten, p.id'; adv boolean:=(p_ev is not null or p_who is not null or p_t1 is not null or p_t2 is not null);
begin
  if not is_active() then raise exception 'Tài khoản chưa được cấp quyền' using errcode='42501'; end if;
  if adv and not is_admin() then raise exception 'Chỉ quản trị viên được dùng tìm kiếm nâng cao' using errcode='42501'; end if;
  p_lim:=least(coalesce(p_lim,30),case when is_admin() then 1000 else 100 end);   -- chống tải hàng loạt: cán bộ tối đa 100 dòng/lần
  if adv then o:='p.updated_at desc, p.id';
  elsif p_qa<>'' then o:='(p.ten_dau ilike $2) desc, '||o; end if;
  return query execute 'select p.* from people p where '||ra_where(p_q,p_yr,p_th,p_kh,p_rs,p_flags,p_all,p_thieu,p_ev,p_who,p_t1,p_t2)||' order by '||o||' offset $7 limit $8'
    using '%'||p_q||'%','%'||p_qa||'%',p_yr,p_th,p_kh,p_rs,p_off,p_lim,p_t1,p_t2,p_who;
end $$;

-- Đếm số người theo cùng bộ lọc
create or replace function dem_people(p_q text default '', p_yr int default null, p_th text default null,
  p_kh boolean default null, p_rs text default null, p_flags text[] default null, p_all boolean default false, p_thieu boolean default null,
  p_ev text default null, p_who uuid default null, p_t1 timestamptz default null, p_t2 timestamptz default null)
returns bigint language plpgsql stable security definer set search_path=public,extensions as $$
declare n bigint;
begin
  if not is_active() then raise exception 'Tài khoản chưa được cấp quyền' using errcode='42501'; end if;
  if (p_ev is not null or p_who is not null or p_t1 is not null or p_t2 is not null) and not is_admin() then
    raise exception 'Chỉ quản trị viên được dùng tìm kiếm nâng cao' using errcode='42501'; end if;
  execute 'select count(*) from people p where '||ra_where(p_q,p_yr,p_th,p_kh,p_rs,p_flags,p_all,p_thieu,p_ev,p_who,p_t1,p_t2) into n
    using '%'||p_q||'%','',p_yr,p_th,p_kh,p_rs,0,0,p_t1,p_t2,p_who;
  return n;
end $$;

-- Những người cùng hộ (cùng số HSCT)
create or replace function ho_cung(p_hsct text) returns setof people language plpgsql stable security definer set search_path=public as $$
begin
  if not is_active() then raise exception 'Tài khoản chưa được cấp quyền' using errcode='42501'; end if;
  return query select * from people where so_hsct=p_hsct order by ngay_sinh,id limit 40;
end $$;
-- /Tìm kiếm

-- ===== Nhật ký thay đổi (tự ghi, người dùng không sửa/xóa được) =====
create or replace function nhat_ky_ghi() returns trigger language plpgsql security definer set search_path=public as $$
declare k text; o jsonb; n jsonb; uid uuid:=auth.uid(); who text;
begin
  select ho_ten into who from nguoi_dung where id=uid;
  who:=coalesce(who, case when uid is null then 'Hệ thống' else 'Không rõ' end);
  if tg_op='INSERT' then
    insert into nhat_ky(nguoi,ten_nguoi,person_id,ten_doi_tuong,cccd,hanh_dong) values(uid,who,new.id,new.ho_ten,new.cccd,'them');
  elsif tg_op='DELETE' then
    insert into nhat_ky(nguoi,ten_nguoi,person_id,ten_doi_tuong,cccd,hanh_dong) values(uid,who,old.id,old.ho_ten,old.cccd,'xoa');
  else
    o:=to_jsonb(old); n:=to_jsonb(new);
    for k in select jsonb_object_keys(n) loop
      if k not in ('updated_at','search_key','ten_dau','nam_sinh','sua_boi','sua_boi_ten') and k not like '%\_at' and n->k is distinct from o->k then
        insert into nhat_ky(nguoi,ten_nguoi,person_id,ten_doi_tuong,cccd,hanh_dong,truong,cu,moi)
        values(uid,who,new.id,new.ho_ten,new.cccd,'sua',k,o->>k,n->>k);
      end if;
    end loop;
  end if;
  return null; end $$;
drop trigger if exists trg_nhat_ky on people;
create trigger trg_nhat_ky after insert or update or delete on people for each row execute function nhat_ky_ghi();

-- ===== Hàm cho màn hình quản trị =====
create or replace function ds_nguoi_dung() returns table(id uuid,email text,ho_ten text,vai_tro text,hoat_dong boolean)
language plpgsql stable security definer set search_path=public as $$
begin
  if not (is_admin() or is_sys()) then raise exception 'Chỉ quản trị viên' using errcode='42501'; end if;
  return query select n.id,u.email::text,n.ho_ten,n.vai_tro,n.hoat_dong from nguoi_dung n left join auth.users u on u.id=n.id order by n.vai_tro,n.ho_ten;
end $$;
create or replace function them_nguoi_dung(p_email text,p_ten text,p_vai_tro text default 'can_bo') returns text
language plpgsql security definer set search_path=public as $$
declare v uuid;
begin
  if not (is_admin() or is_sys()) then raise exception 'Chỉ quản trị viên' using errcode='42501'; end if;
  select id into v from auth.users where lower(email)=lower(trim(p_email));
  if v is null then return 'Chưa có tài khoản này: hãy tạo trong Supabase → Authentication → Users trước'; end if;
  insert into nguoi_dung(id,ho_ten,vai_tro,hoat_dong) values(v,trim(p_ten),p_vai_tro,true)
    on conflict (id) do update set ho_ten=excluded.ho_ten, vai_tro=excluded.vai_tro, hoat_dong=true;
  return 'ok';
end $$;
create or replace function thong_ke_nhat_ky(p_from timestamptz,p_to timestamptz)
returns table(ten_nguoi text,so_thay_doi bigint,so_doi_tuong bigint) language sql stable as
$$ select ten_nguoi, count(*), count(distinct person_id) from nhat_ky
   where luc between p_from and p_to and hanh_dong in ('them','sua','xoa') group by ten_nguoi order by 2 desc $$;
create or replace function hoan_tac_nhat_ky(p_id bigint) returns text
language plpgsql security definer set search_path=public as $$
declare r nhat_ky%rowtype;
begin
  if not (is_admin() or is_sys()) then raise exception 'Chỉ quản trị viên' using errcode='42501'; end if;
  select * into r from nhat_ky where id=p_id;
  if r.id is null or r.hanh_dong<>'sua' then raise exception 'Chỉ hoàn tác được thao tác sửa'; end if;
  execute format('update people set %I=(jsonb_populate_record(null::people, jsonb_build_object(%L, %L::text))).%I where id=$1',r.truong,r.truong,r.cu,r.truong) using r.person_id;
  return 'ok';
end $$;

create or replace function ghi_xuat(p_mo_ta text,p_so int) returns void language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); who text;
begin
  if not is_admin() then raise exception 'Chỉ quản trị viên' using errcode='42501'; end if;
  select ho_ten into who from nguoi_dung where id=uid;
  insert into nhat_ky(nguoi,ten_nguoi,hanh_dong,truong,moi) values(uid,coalesce(who,'Không rõ'),'xuat','xuat_excel',left(coalesce(p_mo_ta,'')||' — '||p_so||' người',500));
end $$;

create or replace function dat_lai_mat_khau(p_id uuid,p_mk text) returns text
language plpgsql security definer set search_path=public,extensions as $$
declare who text; ten text; n int;
begin
  if not (is_admin() or is_sys()) then raise exception 'Chỉ quản trị viên' using errcode='42501'; end if;
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

-- ===== Phân quyền theo dòng (RLS) =====
alter table people enable row level security; alter table workplaces enable row level security;
alter table nguoi_dung enable row level security; alter table nhat_ky enable row level security;
drop policy if exists "auth all" on people; drop policy if exists "auth all" on workplaces;
drop policy if exists p_sel on people; drop policy if exists p_ins on people; drop policy if exists p_upd on people; drop policy if exists p_del on people;
create policy p_sel on people for select to authenticated using ((select is_active()));
create policy p_ins on people for insert to authenticated with check ((select is_active()));
create policy p_upd on people for update to authenticated using ((select is_active())) with check ((select is_active()));
create policy p_del on people for delete to authenticated using ((select is_admin()));
drop policy if exists w_sel on workplaces; drop policy if exists w_ins on workplaces; drop policy if exists w_adm on workplaces;
create policy w_sel on workplaces for select to authenticated using ((select is_active()));
create policy w_ins on workplaces for insert to authenticated with check ((select is_active()));
create policy w_adm on workplaces for all to authenticated using ((select is_admin())) with check ((select is_admin()));
drop policy if exists n_sel on nguoi_dung; drop policy if exists n_adm on nguoi_dung;
create policy n_sel on nguoi_dung for select to authenticated using (id=auth.uid() or (select is_active()));
create policy n_adm on nguoi_dung for all to authenticated using ((select is_admin())) with check ((select is_admin()));
drop policy if exists k_sel on nhat_ky;

-- ===== Nhật ký: cán bộ thường chỉ xem được nhật ký CỦA MÌNH; quản trị xem tất cả =====
drop policy if exists k_sel on nhat_ky;
create policy k_sel on nhat_ky for select to authenticated
  using ((select is_admin()) or (nguoi=auth.uid() and (select is_active())));
create index if not exists nhat_ky_truong_idx on nhat_ky(truong, luc desc) where hanh_dong='sua';

-- ===== Thống kê cho TÌM KIẾM NÂNG CAO (chỉ quản trị viên) =====
-- Trong khoảng thời gian (và cán bộ / thôn đã chọn): bao nhiêu người được rà soát, trong đó bao nhiêu đã khám, là sinh viên, làm cty...
-- (đếm theo trạng thái HIỆN TẠI của những người đã được rà soát trong khoảng đó)
create or replace function thong_ke_ra_soat(p_who uuid default null, p_th text default null, p_t1 timestamptz default null, p_t2 timestamptz default null)
returns table(n_tong bigint,n_kham bigint,n_sv bigint,n_cty bigint,n_dv bigint,n_chet bigint)
language plpgsql stable security definer set search_path=public,extensions as $$
begin
  if not is_admin() then raise exception 'Chỉ quản trị viên' using errcode='42501'; end if;
  return query execute 'select count(*), count(*) filter (where p.da_kham), count(*) filter (where p.sinh_vien), count(*) filter (where p.dang_lam_cty),
      count(*) filter (where p.di_vang), count(*) filter (where p.da_chet) from people p where '
    ||ra_where('',null,p_th,null,null,null,false,null,'ra_soat',p_who,p_t1,p_t2)
    using '%%','',null::int,p_th,null::boolean,null::text,0,0,p_t1,p_t2,p_who;
end $$;

-- Thống kê theo từng cán bộ: mỗi người đã rà soát / khám / đánh dấu cty / sinh viên / đi vắng / chết bao nhiêu NGƯỜI trong khoảng thời gian
create or replace function thong_ke_can_bo(p_th text default null, p_t1 timestamptz default null, p_t2 timestamptz default null)
returns table(uid uuid,ten text,n_rs bigint,n_kham bigint,n_cty bigint,n_sv bigint,n_dv bigint,n_chet bigint)
language plpgsql stable security definer set search_path=public as $$
begin
  if not is_admin() then raise exception 'Chỉ quản trị viên' using errcode='42501'; end if;
  return query
  select k.nguoi,
    coalesce((select n.ho_ten from nguoi_dung n where n.id=k.nguoi), max(k.ten_nguoi)),
    count(distinct k.person_id) filter (where k.truong='trang_thai_ra_soat' and k.moi='Đã rà soát' and p.trang_thai_ra_soat='Đã rà soát'),
    count(distinct k.person_id) filter (where k.truong='da_kham' and k.moi='true' and p.da_kham),
    count(distinct k.person_id) filter (where k.truong='dang_lam_cty' and k.moi='true' and p.dang_lam_cty),
    count(distinct k.person_id) filter (where k.truong='sinh_vien' and k.moi='true' and p.sinh_vien),
    count(distinct k.person_id) filter (where k.truong='di_vang' and k.moi='true' and p.di_vang),
    count(distinct k.person_id) filter (where k.truong='da_chet' and k.moi='true' and p.da_chet)
  from nhat_ky k join people p on p.id=k.person_id
  where k.hanh_dong='sua' and k.nguoi is not null
    and k.luc>=coalesce(p_t1,'-infinity'::timestamptz) and k.luc<=coalesce(p_t2,'infinity'::timestamptz)
    and (p_th is null or p.thon=p_th)
  group by k.nguoi
  order by 3 desc, 2;
end $$;

-- ===== Ghi chú cá nhân (mỗi tài khoản chỉ thấy ghi chú của chính mình) =====
create table if not exists ghi_chu(
  id bigint generated always as identity primary key,
  nguoi uuid not null default auth.uid() references nguoi_dung(id) on delete cascade,
  noi_dung text not null check (length(btrim(noi_dung)) between 1 and 5000),
  tao_luc timestamptz not null default now(),
  sua_luc timestamptz not null default now()
);
create index if not exists ghi_chu_nguoi_idx on ghi_chu(nguoi, sua_luc desc);
create or replace function ghi_chu_sk() returns trigger language plpgsql as $$
begin new.sua_luc:=now(); new.nguoi:=old.nguoi; return new; end $$;
drop trigger if exists trg_ghi_chu on ghi_chu;
create trigger trg_ghi_chu before update on ghi_chu for each row execute function ghi_chu_sk();
alter table ghi_chu enable row level security;
drop policy if exists gc_all on ghi_chu;
create policy gc_all on ghi_chu for all to authenticated
  using (nguoi=auth.uid() and (select is_active())) with check (nguoi=auth.uid() and (select is_active()));
grant select,insert,update,delete on ghi_chu to authenticated;

-- ===== BƯỚC CUỐI (làm sau khi chạy xong file này) =====
-- Tạo tài khoản quản trị: (1) Supabase → Authentication → Users → Add user (tick Auto Confirm User),
-- (2) chạy lệnh sau với đúng email đó (xem thêm tao_admin.sql):
-- select them_nguoi_dung('admin@example.com', 'Quản trị viên', 'admin');
