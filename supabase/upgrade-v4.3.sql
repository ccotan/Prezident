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
