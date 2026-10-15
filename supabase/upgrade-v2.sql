-- Обновление предыдущей версии без удаления новостей, ролей и налогов.
-- Выполнить один раз, если schema.sql версии 1 уже применялась.
begin;
create or replace function public.portal_valid_images(items jsonb) returns boolean
language sql immutable set search_path='' as $$
 select case when jsonb_typeof(items)='array' then
 jsonb_array_length(items)<=4 and not exists (
  select 1 from jsonb_array_elements_text(items) item
  where item is null or length(item)>2000 or item !~ '^https://[^[:space:]]+$'
 ) else false end;
$$;
revoke all on function public.portal_valid_images(jsonb) from public,anon,authenticated;
alter table public.news add column if not exists images jsonb not null default '[]'::jsonb check(public.portal_valid_images(images));
alter table public.news add column if not exists accent text not null default '#a5a8b8' check(accent ~ '^#[0-9a-fA-F]{6}$');
alter table public.news add column if not exists footer text not null default '' check(length(footer)<=200);
alter table public.news add column if not exists updated_at timestamptz;
create table if not exists public.constitution (
 id integer primary key default 1 check(id=1),
 title text not null check(length(title) between 1 and 180),
 text text not null check(length(text) between 1 and 50000),
 images jsonb not null default '[]'::jsonb check(public.portal_valid_images(images)),
 accent text not null default '#a5a8b8' check(accent ~ '^#[0-9a-fA-F]{6}$'),
 footer text not null default '' check(length(footer)<=200),
 author_id uuid references public.profiles(id) on delete set null,
 author text not null, published_at timestamptz not null default now(), updated_at timestamptz
);
create table if not exists public.law_drafts (
 id integer primary key default 1 check(id=1),
 title text not null check(length(title) between 1 and 180),
 text text not null check(length(text) between 1 and 50000),
 images jsonb not null default '[]'::jsonb check(public.portal_valid_images(images)),
 accent text not null default '#a5a8b8' check(accent ~ '^#[0-9a-fA-F]{6}$'),
 footer text not null default '' check(length(footer)<=200),
 updated_at timestamptz not null default now()
);
alter table public.constitution enable row level security;
alter table public.law_drafts enable row level security;
revoke all on public.constitution,public.law_drafts from anon,authenticated;
grant select on public.constitution,public.law_drafts to anon,authenticated;
drop policy if exists constitution_read on public.constitution;
create policy constitution_read on public.constitution for select to anon,authenticated using(true);
drop policy if exists drafts_private on public.law_drafts;
create policy drafts_private on public.law_drafts for select to authenticated using(public.portal_is_president());
drop policy if exists reports_read on public.reports;
create policy reports_read on public.reports for select to authenticated using(
 public.portal_is_president() or public.portal_in_ministry('inf') or public.portal_in_ministry('eco') or public.portal_in_ministry('bez')
);
create or replace function public.portal_action(action text,payload jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 u uuid:=auth.uid(); who text; pres boolean; m text; r jsonb; target_id uuid;
begin
 if u is null then raise exception 'Нужен вход в аккаунт'; end if;
 if not exists(select 1 from auth.users where id=u and email_confirmed_at is not null) then raise exception 'Подтвердите почту'; end if;
 select nick into who from public.profiles where id=u;
 if who is null then raise exception 'Профиль не найден'; end if;
 -- Сериализует изменения ролей, передачу поста и импорт. Все проверки — актуальные из базы.
 perform pg_advisory_xact_lock(7142026);
 pres:=public.portal_is_president();
 case action
 when 'law_draft' then
  if not pres then raise exception 'Редактировать закон может только Президент'; end if;
  insert into public.law_drafts(id,title,text,images,accent,footer)
  values(1,payload->>'title',payload->>'text',coalesce(payload->'images','[]'::jsonb),coalesce(payload->>'accent','#a5a8b8'),coalesce(payload->>'footer',''))
  on conflict(id) do update set title=excluded.title,text=excluded.text,images=excluded.images,accent=excluded.accent,footer=excluded.footer,updated_at=now();
 when 'law_publish' then
  if not pres then raise exception 'Публиковать закон может только Президент'; end if;
  insert into public.constitution(id,title,text,images,accent,footer,author_id,author)
  values(1,payload->>'title',payload->>'text',coalesce(payload->'images','[]'::jsonb),coalesce(payload->>'accent','#a5a8b8'),coalesce(payload->>'footer',''),u,who)
  on conflict(id) do update set title=excluded.title,text=excluded.text,images=excluded.images,accent=excluded.accent,footer=excluded.footer,author_id=u,author=who,published_at=now(),updated_at=now();
  insert into public.law_drafts(id,title,text,images,accent,footer)
  values(1,payload->>'title',payload->>'text',coalesce(payload->'images','[]'::jsonb),coalesce(payload->>'accent','#a5a8b8'),coalesce(payload->>'footer',''))
  on conflict(id) do update set title=excluded.title,text=excluded.text,images=excluded.images,accent=excluded.accent,footer=excluded.footer,updated_at=now();
 when 'news_update' then
  if not pres then raise exception 'Редактировать новости может только Президент'; end if;
  update public.news set title=payload->>'title',text=payload->>'text',pin=coalesce((payload->>'pin')::boolean,false),
   images=coalesce(payload->'images','[]'::jsonb),accent=coalesce(payload->>'accent','#a5a8b8'),footer=coalesce(payload->>'footer',''),updated_at=now()
   where id=(payload->>'id')::uuid;
  if not found then raise exception 'Новость не найдена'; end if;
 when 'news_add' then
  if not pres then raise exception 'Публиковать новости может только Президент'; end if;
  insert into public.news(title,text,pin,author_id,author,images,accent,footer) values(payload->>'title',payload->>'text',coalesce((payload->>'pin')::boolean,false),u,who,coalesce(payload->'images','[]'::jsonb),coalesce(payload->>'accent','#a5a8b8'),coalesce(payload->>'footer',''));
 when 'news_pin' then
  if not pres then raise exception 'Нет доступа'; end if;
  update public.news set pin=(payload->>'pin')::boolean where id=(payload->>'id')::uuid;
 when 'news_delete' then
  if not pres then raise exception 'Нет доступа'; end if;
  delete from public.news where id=(payload->>'id')::uuid;
 when 'report_add' then
  m:=payload->>'channel';
  if not (pres or public.portal_in_ministry(m)) then raise exception 'Нет доступа к этому каналу'; end if;
  insert into public.reports(channel,title,text,author_id,author) values(m,payload->>'title',payload->>'text',u,who);
 when 'report_delete' then
  delete from public.reports where id=(payload->>'id')::uuid and (pres or (author_id=u and (public.portal_in_ministry('inf') or public.portal_in_ministry('eco') or public.portal_in_ministry('bez'))));
  if not found then raise exception 'Нет доступа или отчёт удалён'; end if;
 when 'complaint_add' then
  if (select count(*) from public.complaints where author_id=u and created_at>now()-interval '1 hour')>=10 then raise exception 'Лимит: 10 жалоб в час'; end if;
  insert into public.complaints(type,target,text,proof,author_id,author) values(payload->>'type',payload->>'target',payload->>'text',coalesce(payload->>'proof',''),u,who);
 when 'complaint_update' then
  if not public.portal_can_judge() then raise exception 'Только Президент и Мин. Без.'; end if;
  update public.complaints set st=coalesce(payload->>'st',st),reply=coalesce(payload->>'reply',reply),judge=who where id=(payload->>'id')::uuid;
  if not found then raise exception 'Жалоба не найдена'; end if;
 when 'complaint_delete' then
  if not pres then raise exception 'Нет доступа'; end if;
  delete from public.complaints where id=(payload->>'id')::uuid;
 when 'tax_save' then
  if not (pres or public.portal_in_ministry('eco')) then raise exception 'Только Президент и Мин. Эко.'; end if;
  if nullif(payload->>'id','') is not null then
   update public.taxes set nick=payload->>'nick',num=payload->>'num',upd=(payload->>'upd')::date,paid=(payload->>'paid')::boolean,note=coalesce(payload->>'note','') where id=(payload->>'id')::uuid;
   if not found then raise exception 'Запись уже удалена. Обновите реестр'; end if;
  else
   insert into public.taxes(nick,num,upd,paid,note) values(payload->>'nick',payload->>'num',(payload->>'upd')::date,(payload->>'paid')::boolean,coalesce(payload->>'note',''));
  end if;
 when 'tax_import' then
  if not (pres or public.portal_in_ministry('eco')) then raise exception 'Только Президент и Мин. Эко.'; end if;
  if jsonb_typeof(payload->'rows') is distinct from 'array' then raise exception 'Нужен массив записей'; end if;
  if jsonb_array_length(payload->'rows') not between 1 and 500 then raise exception 'От 1 до 500 записей за импорт'; end if;
  for r in select value from jsonb_array_elements(payload->'rows') loop
   insert into public.taxes(nick,num,upd,paid,note) values(r->>'nick',r->>'num',(r->>'upd')::date,(r->>'paid')::boolean,coalesce(r->>'note',''))
   on conflict(num) do update set nick=excluded.nick,upd=excluded.upd,paid=excluded.paid,note=excluded.note;
  end loop;
 when 'tax_delete' then
  if not (pres or public.portal_in_ministry('eco')) then raise exception 'Нет доступа'; end if;
  delete from public.taxes where id=(payload->>'id')::uuid;
 when 'role_set' then
  if not pres then raise exception 'Назначать роли может только Президент'; end if;
  target_id:=(payload->>'id')::uuid; m:=nullif(payload->>'min','');
  if m is not null and m not in ('inf','eco','bez') then raise exception 'Неизвестное министерство'; end if;
  if coalesce((payload->>'head')::boolean,false) and m is null then raise exception 'Сначала выберите министерство'; end if;
  if coalesce((payload->>'head')::boolean,false) then update public.profiles set head=false where min=m and head; end if;
  update public.profiles set min=m,head=coalesce((payload->>'head')::boolean,false) where id=target_id;
  if not found then raise exception 'Игрок не найден'; end if;
 when 'settings_save' then
  if not pres then raise exception 'Нет доступа'; end if;
  update public.portal_settings set name=payload->>'name',ip=coalesce(payload->>'ip',''),term=(payload->>'term')::timestamptz where id=1;
 when 'transfer' then
  if not pres then raise exception 'Нет доступа'; end if;
  target_id:=(payload->>'id')::uuid;
  if not exists(select 1 from auth.users where id=target_id and email_confirmed_at is not null) then raise exception 'Новый Президент должен подтвердить почту'; end if;
  update public.portal_settings set president_id=target_id where id=1;
 else raise exception 'Неизвестная операция';
 end case;
 return jsonb_build_object('ok',true);
end;
$$;

revoke all on function public.portal_action(text,jsonb) from public,anon;
grant execute on function public.portal_action(text,jsonb) to authenticated;
-- Изображения новостей/закона публичны. Запись только у Президента.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('portal-media','portal-media',true,5242880,array['image/png','image/jpeg','image/webp','image/gif'])
on conflict(id) do update set public=true,file_size_limit=5242880,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists portal_media_read on storage.objects;
create policy portal_media_read on storage.objects for select to anon,authenticated using(bucket_id='portal-media');
drop policy if exists portal_media_insert on storage.objects;
create policy portal_media_insert on storage.objects for insert to authenticated with check(bucket_id='portal-media' and public.portal_is_president());
drop policy if exists portal_media_delete on storage.objects;
create policy portal_media_delete on storage.objects for delete to authenticated using(bucket_id='portal-media' and public.portal_is_president());
commit;
