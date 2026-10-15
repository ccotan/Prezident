-- V4: применить один раз после V3. Не удаляет существующие данные.
begin;
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
