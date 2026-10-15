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
