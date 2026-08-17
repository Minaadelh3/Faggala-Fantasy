-- Users may have signed up while the public schema was not yet deployed.
-- Create only missing profile rows; preserve every existing profile unchanged.
begin;

insert into public.profiles(id,full_name,avatar_url)
select
  users.id,
  coalesce(users.raw_user_meta_data->>'full_name',users.email),
  users.raw_user_meta_data->>'avatar_url'
from auth.users
where not exists(
  select 1 from public.profiles where profiles.id=users.id
)
on conflict(id) do nothing;

commit;
