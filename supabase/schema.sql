-- Выполнять один раз в НОВОМ проекте Supabase, SQL Editor, от postgres.
-- Не применять поверх чужих таблиц. Схема намеренно не удаляет старые данные.
begin;
create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 nick text not null check (nick ~ '^[A-Za-z0-9_]{2,16}$'),
 min text check (min in ('inf','eco','bez')),
 head boolean not null default false,
 check (not head or min is not null)
);
create unique index profiles_nick_unique on public.profiles(lower(nick));
create unique index one_head_per_ministry on public.profiles(min) where head;
create table public.portal_settings (
 id integer primary key default 1 check (id=1),
 name text not null default 'Портал' check(length(name) between 1 and 40),
 ip text not null default '' check(length(ip)<=200),
 president_id uuid references public.profiles(id) on delete restrict,
 term timestamptz
);
insert into public.portal_settings(id) values (1);
create table public.news (
 id uuid primary key default gen_random_uuid(), title text not null check(length(title) between 1 and 180),
 text text not null check(length(text) between 1 and 20000), pin boolean not null default false,
 author_id uuid references public.profiles(id) on delete set null, author text not null,
 created_at timestamptz not null default now()
);
create table public.reports (
 id uuid primary key default gen_random_uuid(), channel text not null check(channel in ('inf','eco','bez')),
 title text not null check(length(title) between 1 and 180), text text not null check(length(text) between 1 and 20000),
 author_id uuid references public.profiles(id) on delete set null, author text not null,
 created_at timestamptz not null default now()
);
create table public.complaints (
 id uuid primary key default gen_random_uuid(), n bigint generated always as identity unique,
 type text not null check(type in ('player','ministry','territory')),
 target text not null check(length(target) between 1 and 200), text text not null check(length(text) between 1 and 12000),
 proof text not null default '' check(length(proof)<=2000 and (proof='' or proof ~ '^https?://')),
 author_id uuid references public.profiles(id) on delete set null, author text not null,
 st text not null default 'new' check(st in ('new','work','ok','no')),
 reply text not null default '' check(length(reply)<=12000), judge text,
 created_at timestamptz not null default now()
);
create index complaints_author on public.complaints(author_id);
create index complaints_created on public.complaints(created_at);
create table public.taxes (
 id uuid primary key default gen_random_uuid(), nick text not null check(nick ~ '^[A-Za-z0-9_]{2,16}$'),
 num text not null unique check(length(num) between 1 and 32), upd date not null,
 paid boolean not null default false, note text not null default '' check(length(note)<=2000)
);
create function public.portal_is_president() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.portal_settings where id=1 and president_id=auth.uid());
$$;
create function public.portal_in_ministry(m text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.profiles where id=auth.uid() and min=m);
$$;
create function public.portal_can_judge() returns boolean language sql stable security definer set search_path='' as $$
 select public.portal_is_president() or public.portal_in_ministry('bez');
$$;
create function public.portal_new_user() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.profiles(id,nick) values(new.id,new.raw_user_meta_data->>'nick');
 return new;
end;
$$;
create trigger portal_user_created after insert on auth.users for each row execute function public.portal_new_user();
alter table public.profiles enable row level security;
alter table public.portal_settings enable row level security;
alter table public.news enable row level security;
alter table public.reports enable row level security;
alter table public.complaints enable row level security;
alter table public.taxes enable row level security;
create policy profiles_read on public.profiles for select to anon, authenticated using(true);
create policy settings_read on public.portal_settings for select to anon, authenticated using(true);
create policy news_read on public.news for select to anon, authenticated using(true);
create policy taxes_read on public.taxes for select to anon, authenticated using(true);
create policy complaints_private on public.complaints for select to authenticated using(author_id=auth.uid() or public.portal_can_judge());
-- Доступ к изменениям только через RPC; прямые INSERT/UPDATE/DELETE запрещены.
revoke all on public.profiles,public.portal_settings,public.news,public.reports,public.complaints,public.taxes from anon,authenticated;
grant usage on schema public to anon,authenticated;
grant select on public.profiles,public.portal_settings,public.news,public.reports,public.complaints,public.taxes to anon,authenticated;
revoke all on function public.portal_new_user() from public,anon,authenticated;
revoke all on function public.portal_is_president(),public.portal_in_ministry(text),public.portal_can_judge() from public;
grant execute on function public.portal_is_president(),public.portal_in_ministry(text),public.portal_can_judge() to anon,authenticated;

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
-- V3: применить один раз ПОСЛЕ V2 (или upgrade-v2.sql для версии 1).
-- Ничего не удаляет. Сделайте резервную копию перед обновлением.

alter table public.news add column kind text not null default 'news' check(kind in ('news','decree'));
alter table public.news add column decree_no text check(length(decree_no) between 1 and 40);
alter table public.news add column decree_status text not null default 'active' check(decree_status in ('active','repealed'));
alter table public.news add column repeal_reason text not null default '' check(length(repeal_reason)<=4000);
alter table public.news add constraint decree_number_required check(kind<>'decree' or nullif(trim(decree_no),'') is not null);
create unique index decree_number_unique on public.news(lower(decree_no)) where kind='decree';
alter table public.reports add column images jsonb not null default '[]'::jsonb check(public.portal_valid_images(images));
alter table public.reports add column accent text not null default '#a5a8b8' check(accent ~ '^#[0-9a-fA-F]{6}$');
alter table public.reports add column footer text not null default '' check(length(footer)<=200);
alter table public.reports add column updated_at timestamptz;
drop policy if exists reports_read on public.reports;
create policy reports_read on public.reports for select to authenticated using(public.portal_is_president() or public.portal_in_ministry(channel));
create table public.ministry_tasks(
 id uuid primary key default gen_random_uuid(),channel text not null check(channel in ('inf','eco','bez')),
 title text not null check(length(trim(title)) between 1 and 180),text text not null check(length(trim(text)) between 1 and 12000),due date,
 status text not null default 'todo' check(status in ('todo','work','review','done','cancelled')),
 note text not null default '' check(length(note)<=12000),report_id uuid references public.reports(id) on delete set null,
 author_id uuid references public.profiles(id) on delete set null,author text not null,
 created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table public.complaint_messages(
 id uuid primary key default gen_random_uuid(),complaint_id uuid not null references public.complaints(id) on delete cascade,
 author_id uuid references public.profiles(id) on delete set null,author text not null,kind text not null default 'message' check(kind in ('message','system')),
 text text not null check(length(trim(text)) between 1 and 12500),proof text not null default '' check(length(proof)<=2000 and (proof='' or proof ~ '^https?://')),
 created_at timestamptz not null default now()
);
create table public.notifications(
 id uuid primary key default gen_random_uuid(),user_id uuid not null references public.profiles(id) on delete cascade,
 title text not null,body text not null default '',target text not null default 'cabinet',dedupe_key text not null,
 channel text check(channel in ('inf','eco','bez')),read_at timestamptz,created_at timestamptz not null default now(),unique(user_id,dedupe_key)
);
create table public.action_log(
 id uuid primary key default gen_random_uuid(),actor_id uuid references public.profiles(id) on delete set null,
 actor text not null,action text not null,summary text not null,target_id uuid,channel text,created_at timestamptz not null default now()
);
create index tasks_channel on public.ministry_tasks(channel);
create index messages_case on public.complaint_messages(complaint_id,created_at);
create index notices_owner on public.notifications(user_id,created_at desc);
create index log_created on public.action_log(created_at desc);
alter table public.ministry_tasks enable row level security;
alter table public.complaint_messages enable row level security;
alter table public.notifications enable row level security;
alter table public.action_log enable row level security;
revoke all on public.ministry_tasks,public.complaint_messages,public.notifications,public.action_log from anon,authenticated;
grant select on public.ministry_tasks,public.complaint_messages,public.notifications,public.action_log to anon,authenticated;
create policy tasks_private on public.ministry_tasks for select to authenticated using(public.portal_is_president() or public.portal_in_ministry(channel));
create policy messages_private on public.complaint_messages for select to authenticated using(exists(select 1 from public.complaints c where c.id=complaint_id and (c.author_id=auth.uid() or public.portal_can_judge())));
create policy notices_private on public.notifications for select to authenticated using(user_id=auth.uid() and (channel is null or public.portal_is_president() or public.portal_in_ministry(channel)));
create policy log_president on public.action_log for select to authenticated using(public.portal_is_president());
-- V4: применить один раз после V3. Не удаляет существующие данные.

alter table public.ministry_tasks add column images jsonb not null default '[]'::jsonb check(public.portal_valid_images(images));
alter table public.ministry_tasks add column result_images jsonb not null default '[]'::jsonb check(public.portal_valid_images(result_images));
alter table public.complaints add column images jsonb not null default '[]'::jsonb check(public.portal_valid_images(images));
alter table public.complaints add column reply_images jsonb not null default '[]'::jsonb check(public.portal_valid_images(reply_images));
alter table public.complaint_messages add column images jsonb not null default '[]'::jsonb check(public.portal_valid_images(images));
alter table public.taxes add column images jsonb not null default '[]'::jsonb check(public.portal_valid_images(images));
create or replace function public.portal_action(action text,payload jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 u uuid:=auth.uid(); who text; pres boolean; m text; r jsonb; target_id uuid; task public.ministry_tasks%rowtype; report public.reports%rowtype; complaint public.complaints%rowtype; person public.profiles%rowtype; event_id uuid:=gen_random_uuid(); dest text:='cabinet'; summary text;
begin
 if u is null then raise exception 'Нужен вход в аккаунт'; end if;
 if not exists(select 1 from auth.users where id=u and email_confirmed_at is not null) then raise exception 'Подтвердите почту'; end if;
 select nick into who from public.profiles where id=u;
 if who is null then raise exception 'Профиль не найден'; end if;
 -- Сериализует изменения ролей, передачу поста и импорт. Все проверки — актуальные из базы.
 perform pg_advisory_xact_lock(7142026);
 pres:=public.portal_is_president();
 case action
 when 'sync_notifications' then
  insert into public.notifications(user_id,title,body,target,dedupe_key)
  select u,case when t.paid and t.upd+7>(now() at time zone 'Europe/Moscow')::date then 'Скоро истекает оплата' else 'Нужна оплата бочки' end,
   'Проверьте бочку № '||t.num,'taxes','tax:'||t.id||':'||t.upd||':'||case when t.paid and t.upd+7>(now() at time zone 'Europe/Moscow')::date then 'soon' else 'exp' end
  from public.taxes t where lower(t.nick)=lower(who) and (not t.paid or t.upd+7<=(now() at time zone 'Europe/Moscow')::date+2)
  on conflict(user_id,dedupe_key) do nothing;
  return jsonb_build_object('ok',true);
 when 'notification_read' then
  update public.notifications set read_at=coalesce(read_at,now()) where id=(payload->>'id')::uuid and user_id=u;
  if not found then raise exception 'Уведомление недоступно'; end if;
  return jsonb_build_object('ok',true);
 when 'notifications_read_all' then
  update public.notifications set read_at=now() where user_id=u and read_at is null;
  return jsonb_build_object('ok',true);
 when 'team_add','team_remove' then
  if not pres and not exists(select 1 from public.profiles where id=u and head and min is not null) then raise exception 'Нужны полномочия главы'; end if;
  target_id:=(payload->>'id')::uuid;
  select * into person from public.profiles where id=target_id;
  if not found or person.head or target_id=(select president_id from public.portal_settings where id=1) then raise exception 'Игрок не найден или роль защищена'; end if;
  if pres then m:=coalesce(payload->>'channel',person.min); else select min into m from public.profiles where id=u; end if;
  if m is null or m not in ('inf','eco','bez') then raise exception 'Неизвестное министерство'; end if;
  if action='team_add' then
   if person.min is not null then raise exception 'Игрок уже состоит в министерстве'; end if;
   update public.profiles set min=m,head=false where id=target_id;
  else
   if person.min is distinct from m then raise exception 'Нельзя исключить из чужого министерства'; end if;
   update public.profiles set min=null,head=false where id=target_id;
  end if;
 when 'task_save' then
  if not pres then raise exception 'Задачи ставит Президент'; end if;
  m:=payload->>'channel';
  if nullif(payload->>'id','') is null then
   insert into public.ministry_tasks(channel,title,text,due,author_id,author,images)
   values(m,payload->>'title',payload->>'text',nullif(payload->>'due','')::date,u,who,coalesce(payload->'images','[]'::jsonb)) returning id into target_id;
  else
   target_id:=(payload->>'id')::uuid;
   update public.ministry_tasks set images=coalesce(payload->'images',images),result_images=case when channel<>m then '[]'::jsonb else result_images end,title=payload->>'title',text=payload->>'text',due=nullif(payload->>'due','')::date,
    status=case when channel<>m then 'todo' else status end,note=case when channel<>m then '' else note end,
    report_id=case when channel<>m then null else report_id end,channel=m,updated_at=now() where id=target_id;
   if not found then raise exception 'Задача не найдена'; end if;
  end if;
 when 'task_update' then
  target_id:=(payload->>'id')::uuid;
  select * into task from public.ministry_tasks where id=target_id;
  if not found or not (pres or public.portal_in_ministry(task.channel)) then raise exception 'Задача недоступна'; end if;
  m:=task.channel;
  if not pres and (task.status in ('done','cancelled') or coalesce(payload->>'status','') not in ('todo','work','review')) then raise exception 'Принимает или отменяет задачу Президент'; end if;
  if nullif(payload->>'report_id','') is not null and not exists(select 1 from public.reports where id=(payload->>'report_id')::uuid and channel=m) then raise exception 'Отчёт должен быть из канала задачи'; end if;
  update public.ministry_tasks set result_images=coalesce(payload->'result_images',result_images),status=payload->>'status',note=coalesce(payload->>'note',''),report_id=nullif(payload->>'report_id','')::uuid,updated_at=now() where id=target_id;
 when 'complaint_message' then
  target_id:=(payload->>'id')::uuid;
  select * into complaint from public.complaints where id=target_id;
  if not found or not (public.portal_can_judge() or complaint.author_id=u) then raise exception 'Обращение недоступно'; end if;
  if (select count(*) from public.complaint_messages where author_id=u and created_at>now()-interval '1 hour')>=60 then raise exception 'Лимит: 60 сообщений в час'; end if;
  insert into public.complaint_messages(complaint_id,author_id,author,text,proof,images) values(target_id,u,who,payload->>'text',coalesce(payload->>'proof',''),coalesce(payload->'images','[]'::jsonb));
 when 'decree_status' then
  if not pres then raise exception 'Только Президент'; end if;
  target_id:=(payload->>'id')::uuid;
  if coalesce(payload->>'status','') not in ('active','repealed') or (payload->>'status'='repealed' and nullif(trim(payload->>'reason'),'') is null) then raise exception 'Укажите статус и причину отмены'; end if;
  update public.news set decree_status=payload->>'status',repeal_reason=case when payload->>'status'='repealed' then payload->>'reason' else '' end,updated_at=now() where id=target_id and kind='decree';
  if not found then raise exception 'Указ не найден'; end if;
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
  update public.news set kind=coalesce(payload->>'kind','news'),decree_no=nullif(payload->>'decree_no',''),title=payload->>'title',text=payload->>'text',pin=coalesce((payload->>'pin')::boolean,false),
   images=coalesce(payload->'images','[]'::jsonb),accent=coalesce(payload->>'accent','#a5a8b8'),footer=coalesce(payload->>'footer',''),updated_at=now()
   where id=(payload->>'id')::uuid;
  if not found then raise exception 'Новость не найдена'; end if;
 when 'news_add' then
  if not pres then raise exception 'Публиковать новости может только Президент'; end if;
  insert into public.news(title,text,pin,author_id,author,images,accent,footer,kind,decree_no) values(payload->>'title',payload->>'text',coalesce((payload->>'pin')::boolean,false),u,who,coalesce(payload->'images','[]'::jsonb),coalesce(payload->>'accent','#a5a8b8'),coalesce(payload->>'footer',''),coalesce(payload->>'kind','news'),nullif(payload->>'decree_no','')) returning id into target_id;
 when 'news_pin' then
  if not pres then raise exception 'Нет доступа'; end if;
  update public.news set pin=(payload->>'pin')::boolean where id=(payload->>'id')::uuid;
 when 'news_delete' then
  if not pres then raise exception 'Нет доступа'; end if;
  delete from public.news where id=(payload->>'id')::uuid;
 when 'report_add','report_update','report_delete' then
  if action='report_add' then m:=payload->>'channel'; else
   target_id:=(payload->>'id')::uuid;
   select * into report from public.reports where id=target_id;
   if not found then raise exception 'Отчёт не найден'; end if;
   m:=report.channel;
   if not pres and report.author_id is distinct from u then raise exception 'Можно менять только собственный отчёт'; end if;
  end if;
  if not (pres or public.portal_in_ministry(m)) then raise exception 'Чужой канал недоступен'; end if;
  if action='report_add' then
   insert into public.reports(channel,title,text,author_id,author,images,accent,footer) values(m,payload->>'title',payload->>'text',u,who,coalesce(payload->'images','[]'::jsonb),coalesce(payload->>'accent','#a5a8b8'),coalesce(payload->>'footer','')) returning id into target_id;
  elsif action='report_update' then
   if payload ? 'channel' and payload->>'channel' is distinct from m then raise exception 'Перенос отчётов запрещён'; end if;
   update public.reports set title=payload->>'title',text=payload->>'text',images=coalesce(payload->'images','[]'::jsonb),accent=coalesce(payload->>'accent','#a5a8b8'),footer=coalesce(payload->>'footer',''),updated_at=now() where id=target_id;
  else delete from public.reports where id=target_id;
  end if;
 when 'complaint_add' then
  if (select count(*) from public.complaints where author_id=u and created_at>now()-interval '1 hour')>=10 then raise exception 'Лимит: 10 жалоб в час'; end if;
  insert into public.complaints(type,target,text,proof,author_id,author,images) values(payload->>'type',payload->>'target',payload->>'text',coalesce(payload->>'proof',''),u,who,coalesce(payload->'images','[]'::jsonb)) returning id into target_id;
 when 'complaint_update' then
  if payload->>'st' in ('ok','no') and nullif(trim(payload->>'reply'),'') is null then raise exception 'Укажите решение или причину отклонения'; end if;
  if not public.portal_can_judge() then raise exception 'Только Президент и Мин. Без.'; end if;
  update public.complaints set reply_images=coalesce(payload->'reply_images',reply_images),st=coalesce(payload->>'st',st),reply=coalesce(payload->>'reply',reply),judge=who where id=(payload->>'id')::uuid;
  if not found then raise exception 'Жалоба не найдена'; end if;
  insert into public.complaint_messages(complaint_id,author_id,author,kind,text,images) values((payload->>'id')::uuid,u,who,'system','Статус: '||coalesce(payload->>'st','без изменения')||' · '||coalesce(payload->>'reply',''),coalesce(payload->'reply_images','[]'::jsonb));
 when 'complaint_delete' then
  if not pres then raise exception 'Нет доступа'; end if;
  delete from public.complaints where id=(payload->>'id')::uuid;
 when 'tax_save' then
  if not (pres or public.portal_in_ministry('eco')) then raise exception 'Только Президент и Мин. Эко.'; end if;
  if nullif(payload->>'id','') is not null then
   update public.taxes set images=coalesce(payload->'images',images),nick=payload->>'nick',num=payload->>'num',upd=(payload->>'upd')::date,paid=(payload->>'paid')::boolean,note=coalesce(payload->>'note','') where id=(payload->>'id')::uuid;
   if not found then raise exception 'Запись уже удалена. Обновите реестр'; end if;
  else
   insert into public.taxes(nick,num,upd,paid,note,images) values(payload->>'nick',payload->>'num',(payload->>'upd')::date,(payload->>'paid')::boolean,coalesce(payload->>'note',''),coalesce(payload->'images','[]'::jsonb));
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
  if target_id=(select president_id from public.portal_settings where id=1) then raise exception 'Президент не может входить в состав министерства'; end if;
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
  update public.profiles set min=null,head=false where id=target_id;
  update public.portal_settings set president_id=target_id where id=1;
 else raise exception 'Неизвестная операция';
 end case;
 target_id:=coalesce(target_id,nullif(payload->>'id','')::uuid);
 summary:=case action
 when 'news_add' then 'Опубликована новость / указ' when 'news_update' then 'Обновлена публикация'
 when 'news_delete' then 'Удалена публикация' when 'news_pin' then 'Изменено закрепление'
 when 'report_add' then 'Опубликован отчёт' when 'report_update' then 'Обновлён отчёт' when 'report_delete' then 'Удалён отчёт'
 when 'task_save' then 'Создана / изменена задача' when 'task_update' then 'Обновлён результат задачи'
 when 'complaint_add' then 'Поступило обращение' when 'complaint_update' then 'Изменено решение по обращению'
 when 'complaint_message' then 'Новое сообщение по обращению' when 'complaint_delete' then 'Удалено обращение'
 when 'team_add' then 'Игрок принят в министерство' when 'team_remove' then 'Игрок исключён из состава'
 when 'role_set' then 'Изменена роль игрока' when 'transfer' then 'Переданы полномочия Президента'
 when 'tax_save' then 'Изменена запись налога' when 'tax_import' then 'Импортирован налоговый реестр' when 'tax_delete' then 'Удалена запись налога'
 when 'settings_save' then 'Изменены настройки' when 'law_draft' then 'Сохранён черновик закона'
 when 'law_publish' then 'Опубликована конституция' when 'decree_status' then 'Изменён статус указа' else action end;
 insert into public.action_log(actor_id,actor,action,summary,target_id,channel)
 values(u,who,action,summary||coalesce(' · '||coalesce(payload->>'title',payload->>'nick',target_id::text),''),target_id,m);
 if action in ('news_add','news_update','decree_status','law_publish','transfer') then
  dest:=case when action='law_publish' then 'law' when action='transfer' then 'cabinet' when action='decree_status' or payload->>'kind'='decree' then 'decrees' else 'news' end;
  insert into public.notifications(user_id,title,body,target,dedupe_key)
  select id,summary,'Изменения на портале',dest,'event:'||event_id from public.profiles where id<>u;
 elsif action like 'report_%' or action like 'task_%' then
  dest:=case when action like 'report_%' then 'report:'||m else 'task:'||target_id end;
  insert into public.notifications(user_id,title,body,target,dedupe_key,channel)
  select id,summary,'Министерство: '||m,dest,'event:'||event_id,m from public.profiles where id<>u and (min=m or id=(select president_id from public.portal_settings where id=1));
 elsif action in ('complaint_add','complaint_update','complaint_message') then
  select * into complaint from public.complaints where id=target_id;
  insert into public.notifications(user_id,title,body,target,dedupe_key)
  select id,summary,'Обращение № '||complaint.n,'case:'||target_id,'event:'||event_id from public.profiles where id<>u and (id=complaint.author_id or min='bez' or id=(select president_id from public.portal_settings where id=1));
 elsif action in ('team_add','team_remove','role_set') then
  insert into public.notifications(user_id,title,body,target,dedupe_key) select target_id,summary,'Ваша роль на портале изменилась','cabinet','event:'||event_id where target_id<>u;
 end if;
 return jsonb_build_object('ok',true);
end;
$$;

revoke all on function public.portal_action(text,jsonb) from public,anon;
grant execute on function public.portal_action(text,jsonb) to authenticated;
commit;
-- Apply after V4 schema/upgrade-v4.sql. Never contains service keys.
-- A Discord username is self-entered, private and NOT verified with Discord.
begin;
create table if not exists public.profile_contacts (
 user_id uuid primary key references public.profiles(id) on delete cascade,
 discord_username text not null check(discord_username ~ '^[a-z0-9_.]{2,32}$' and position('..' in discord_username)=0),
 updated_at timestamptz not null default now()
);
alter table public.profile_contacts enable row level security;
drop policy if exists profile_contacts_own_read on public.profile_contacts;
create policy profile_contacts_own_read on public.profile_contacts for select to authenticated using(user_id=auth.uid());
revoke all on public.profile_contacts from public,anon,authenticated;
grant select on public.profile_contacts to authenticated;
create or replace function public.portal_set_discord(username text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); desired text:=lower(trim(coalesce(username,'')));
begin
 if u is null then raise exception 'Нужен вход'; end if;
 if not exists(select 1 from public.profiles where id=u) then raise exception 'Профиль не найден'; end if;
 if left(desired,1)='@' then desired:=substring(desired from 2); end if;
 if desired='' then delete from public.profile_contacts where user_id=u;
 else
  if desired !~ '^[a-z0-9_.]{2,32}$' or position('..' in desired)>0 then raise exception 'Некорректное имя Discord'; end if;
  insert into public.profile_contacts(user_id,discord_username) values(u,desired)
  on conflict(user_id) do update set discord_username=excluded.discord_username,updated_at=now();
 end if;
 return jsonb_build_object('ok',true,'discord_username',nullif(desired,''));
end;
$$;
revoke all on function public.portal_set_discord(text) from public,anon;
grant execute on function public.portal_set_discord(text) to authenticated;
commit;
-- Discord is now verified by native Supabase Auth identity linking.
-- Legacy self-entered contacts stay private, but their old write RPC is disabled.
-- OAuth itself needs Discord provider + Manual Linking in Auth settings, not a new public table.
begin;
do $$
begin
 if to_regprocedure('public.portal_set_discord(text)') is not null then
  execute 'revoke all on function public.portal_set_discord(text) from public,anon,authenticated';
 end if;
end;
$$;
commit;
