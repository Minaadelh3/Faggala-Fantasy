-- Append-only finance, idempotent provider events, atomic wallets and scoped
-- Supabase Storage policies.

begin;

set local search_path = public, extensions;

-- Financial history blocks church deletion instead of disappearing silently.
alter table public.subscriptions drop constraint if exists subscriptions_church_id_fkey;
alter table public.subscriptions add constraint subscriptions_church_id_fkey
  foreign key(church_id) references public.churches(id) on delete restrict;
alter table public.payments drop constraint if exists payments_church_id_fkey;
alter table public.payments add constraint payments_church_id_fkey
  foreign key(church_id) references public.churches(id) on delete restrict;
alter table public.payments drop constraint if exists payments_subscription_id_fkey;
alter table public.payments add constraint payments_subscription_id_fkey
  foreign key(subscription_id) references public.subscriptions(id) on delete restrict;
alter table public.invoices drop constraint if exists invoices_church_id_fkey;
alter table public.invoices add constraint invoices_church_id_fkey
  foreign key(church_id) references public.churches(id) on delete restrict;
alter table public.invoices drop constraint if exists invoices_payment_id_fkey;
alter table public.invoices add constraint invoices_payment_id_fkey
  foreign key(payment_id) references public.payments(id) on delete restrict;
alter table public.church_wallet drop constraint if exists church_wallet_church_id_fkey;
alter table public.church_wallet add constraint church_wallet_church_id_fkey
  foreign key(church_id) references public.churches(id) on delete restrict;
alter table public.church_wallet_transactions drop constraint if exists church_wallet_transactions_church_id_fkey;
alter table public.church_wallet_transactions add constraint church_wallet_transactions_church_id_fkey
  foreign key(church_id) references public.churches(id) on delete restrict;

-- Preserve any legacy duplicate provider references for investigation while
-- enforcing uniqueness for every unambiguous legacy row and all new rows.
alter table public.payments
  add column if not exists provider_reference_enforced boolean not null default false;
with unambiguous as (
  select provider,provider_payment_id
  from public.payments
  where provider is not null and provider_payment_id is not null
  group by provider,provider_payment_id having count(*)=1
)
update public.payments p set provider_reference_enforced=true
from unambiguous u
where p.provider=u.provider and p.provider_payment_id=u.provider_payment_id;
alter table public.payments alter column provider_reference_enforced set default true;
create unique index if not exists uq_payments_provider_reference
  on public.payments(provider,provider_payment_id)
  where provider_reference_enforced and provider is not null and provider_payment_id is not null;

create or replace function public.validate_payment_subscription_scope()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.subscription_id is not null and not exists(
    select 1 from public.subscriptions s
    where s.id=new.subscription_id and s.church_id=new.church_id
  ) then raise exception 'Payment subscription belongs to another church'; end if;
  return new;
end;
$$;
drop trigger if exists trg_validate_payment_subscription_scope on public.payments;
create trigger trg_validate_payment_subscription_scope
before insert or update of church_id,subscription_id on public.payments
for each row execute function public.validate_payment_subscription_scope();

create or replace function public.validate_invoice_payment_scope()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.payment_id is not null and not exists(
    select 1 from public.payments p where p.id=new.payment_id and p.church_id=new.church_id
  ) then raise exception 'Invoice payment belongs to another church'; end if;
  return new;
end;
$$;
drop trigger if exists trg_validate_invoice_payment_scope on public.invoices;
create trigger trg_validate_invoice_payment_scope
before insert or update of church_id,payment_id on public.invoices
for each row execute function public.validate_invoice_payment_scope();

create table public.payment_events (
  id uuid primary key default uuid_generate_v4(),
  provider text not null,
  provider_event_id text not null,
  payment_id uuid references public.payments(id) on delete restrict,
  payload_sha256 text not null check(payload_sha256 ~ '^[a-f0-9]{64}$'),
  event_type text,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  processing_error text,
  unique(provider,provider_event_id)
);
create index idx_payment_events_payment on public.payment_events(payment_id) where payment_id is not null;
alter table public.payment_events enable row level security;
create policy "payment_events_super_admin_select" on public.payment_events for select
using(public.is_super_admin());
revoke insert,update,delete on public.payment_events from anon,authenticated;

create or replace function public.record_payment_event(
  p_provider text,
  p_provider_event_id text,
  p_payload_sha256 text,
  p_event_type text,
  p_church_id uuid,
  p_subscription_id uuid,
  p_amount numeric,
  p_currency text,
  p_provider_payment_id text,
  p_status public.payment_status
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare event_id uuid; v_payment_id uuid; existing_payment public.payments;
begin
  if auth.role()<>'service_role' then raise exception 'Service role only' using errcode='42501'; end if;
  if p_provider is null or btrim(p_provider)='' or p_provider_event_id is null or btrim(p_provider_event_id)='' then
    raise exception 'Provider and event ID are required';
  end if;
  if p_payload_sha256 !~ '^[a-f0-9]{64}$' then raise exception 'Invalid payload hash'; end if;
  if p_amount<=0 or upper(p_currency) !~ '^[A-Z]{3}$' then raise exception 'Invalid payment amount or currency'; end if;
  if p_subscription_id is not null and not exists(
    select 1 from public.subscriptions where id=p_subscription_id and church_id=p_church_id
  ) then raise exception 'Subscription belongs to another church'; end if;

  insert into public.payment_events(provider,provider_event_id,payload_sha256,event_type)
  values(lower(btrim(p_provider)),btrim(p_provider_event_id),p_payload_sha256,p_event_type)
  on conflict(provider,provider_event_id) do nothing returning id into event_id;
  if event_id is null then
    select pe.id,pe.payment_id into event_id,v_payment_id from public.payment_events pe
    where pe.provider=lower(btrim(p_provider)) and pe.provider_event_id=btrim(p_provider_event_id);
    return jsonb_build_object('duplicate',true,'event_id',event_id,'payment_id',v_payment_id);
  end if;

  if p_provider_payment_id is not null then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
      lower(btrim(p_provider))||':'||p_provider_payment_id,0
    ));
    select * into existing_payment from public.payments
    where provider=lower(btrim(p_provider)) and provider_payment_id=p_provider_payment_id
    order by created_at,id limit 1 for update;
  end if;
  if existing_payment.id is not null then
    if existing_payment.church_id<>p_church_id
       or existing_payment.amount<>p_amount
       or existing_payment.currency<>upper(p_currency)
       or existing_payment.subscription_id is distinct from p_subscription_id then
      raise exception 'Provider payment reference conflicts with different immutable payment data';
    end if;
    update public.payments set status=p_status where id=existing_payment.id returning id into v_payment_id;
  else
    insert into public.payments(
      church_id,subscription_id,amount,currency,status,provider,provider_payment_id,provider_reference_enforced
    ) values(
      p_church_id,p_subscription_id,p_amount,upper(p_currency),p_status,
      lower(btrim(p_provider)),p_provider_payment_id,true
    ) returning id into v_payment_id;
  end if;
  update public.payment_events set payment_id=v_payment_id,processed_at=now()
  where id=event_id;
  insert into public.audit_logs(church_id,action,entity_type,entity_id,metadata)
  values(p_church_id,'payment.event_processed','payment',v_payment_id,
         jsonb_build_object('provider',lower(btrim(p_provider)),'event_id',btrim(p_provider_event_id),'status',p_status));
  return jsonb_build_object('duplicate',false,'event_id',event_id,'payment_id',v_payment_id);
end;
$$;
revoke all on function public.record_payment_event(text,text,text,text,uuid,uuid,numeric,text,text,public.payment_status)
  from public,anon,authenticated;
grant execute on function public.record_payment_event(text,text,text,text,uuid,uuid,numeric,text,text,public.payment_status)
  to service_role;

alter table public.church_wallet_transactions
  add column if not exists currency text,
  add column if not exists idempotency_key text,
  add column if not exists balance_after numeric(10,2),
  add column if not exists created_by uuid references public.profiles(id) on delete set null;
update public.church_wallet_transactions tx set currency=w.currency
from public.church_wallet w where w.church_id=tx.church_id and tx.currency is null;
alter table public.church_wallet_transactions alter column currency set not null;
alter table public.church_wallet_transactions
  add constraint wallet_transactions_currency_check check(currency ~ '^[A-Z]{3}$') not valid,
  add constraint wallet_transactions_balance_after_check check(balance_after is null or balance_after>=0) not valid;
create unique index if not exists uq_wallet_transaction_idempotency
  on public.church_wallet_transactions(church_id,idempotency_key)
  where idempotency_key is not null;

drop trigger if exists trg_apply_wallet_transaction on public.church_wallet_transactions;
create or replace function public.apply_wallet_transaction()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare current_balance numeric; wallet_currency text; next_balance numeric;
begin
  if new.amount<=0 then raise exception 'Wallet transaction amount must be positive'; end if;
  select balance,currency into current_balance,wallet_currency
  from public.church_wallet where church_id=new.church_id for update;
  if not found then raise exception 'Wallet not found'; end if;
  if new.currency<>wallet_currency then raise exception 'Wallet currency mismatch'; end if;
  next_balance := case new.type when 'credit' then current_balance+new.amount else current_balance-new.amount end;
  if next_balance<0 then raise exception 'Insufficient wallet balance'; end if;
  update public.church_wallet set balance=next_balance,updated_at=now() where church_id=new.church_id;
  new.balance_after := next_balance;
  return new;
end;
$$;
create trigger trg_apply_wallet_transaction
before insert on public.church_wallet_transactions
for each row execute function public.apply_wallet_transaction();

create or replace function public.protect_wallet_ledger()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Wallet transactions are immutable';
end;
$$;
drop trigger if exists trg_protect_wallet_ledger on public.church_wallet_transactions;
create trigger trg_protect_wallet_ledger before update or delete on public.church_wallet_transactions
for each row execute function public.protect_wallet_ledger();

create or replace function public.post_wallet_transaction(
  p_church_id uuid,
  p_type public.wallet_tx_type,
  p_amount numeric,
  p_reason text,
  p_reference_id uuid,
  p_idempotency_key text
)
returns public.church_wallet_transactions
language plpgsql
security definer
set search_path = ''
as $$
declare existing public.church_wallet_transactions; wallet_currency text;
begin
  if auth.role()<>'service_role' then raise exception 'Service role only' using errcode='42501'; end if;
  if p_amount<=0 or p_idempotency_key is null or btrim(p_idempotency_key)='' then
    raise exception 'Positive amount and idempotency key are required';
  end if;
  -- The wallet row serializes all credits/debits for one church. Checking the
  -- idempotency key after this lock also makes concurrent retries harmless.
  select currency into wallet_currency from public.church_wallet where church_id=p_church_id for update;
  if wallet_currency is null then raise exception 'Wallet not found'; end if;
  select * into existing from public.church_wallet_transactions
  where church_id=p_church_id and idempotency_key=btrim(p_idempotency_key);
  if existing.id is not null then return existing; end if;
  insert into public.church_wallet_transactions(
    church_id,type,amount,currency,reason,reference_id,idempotency_key,created_by
  ) values(
    p_church_id,p_type,p_amount,wallet_currency,p_reason,p_reference_id,btrim(p_idempotency_key),auth.uid()
  ) returning * into existing;
  insert into public.audit_logs(church_id,action,entity_type,entity_id,metadata)
  values(p_church_id,'wallet.transaction_posted','wallet_transaction',existing.id,
         jsonb_build_object('type',p_type,'amount',p_amount,'currency',wallet_currency,'reason',p_reason));
  return existing;
end;
$$;
revoke all on function public.apply_wallet_transaction() from public,anon,authenticated;
revoke all on function public.protect_wallet_ledger() from public,anon,authenticated;
revoke all on function public.post_wallet_transaction(uuid,public.wallet_tx_type,numeric,text,uuid,text)
  from public,anon,authenticated;
grant execute on function public.post_wallet_transaction(uuid,public.wallet_tx_type,numeric,text,uuid,text)
  to service_role;
revoke insert,update,delete on public.church_wallet_transactions from anon,authenticated;
revoke insert,update,delete on public.church_wallet from anon,authenticated;

-- Public image buckets use tenant/user-prefixed paths and constrained MIME/size.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values
  ('avatars','avatars',true,5242880,array['image/jpeg','image/png','image/webp']),
  ('church-media','church-media',true,10485760,array['image/jpeg','image/png','image/webp']),
  ('player-media','player-media',true,5242880,array['image/jpeg','image/png','image/webp']),
  ('ad-media','ad-media',true,10485760,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set
  public=excluded.public,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "public_media_read" on storage.objects;
create policy "public_media_read" on storage.objects for select using(
  bucket_id in ('avatars','church-media','player-media','ad-media')
);
drop policy if exists "avatar_owner_insert" on storage.objects;
create policy "avatar_owner_insert" on storage.objects for insert to authenticated with check(
  bucket_id='avatars' and (storage.foldername(name))[1]=auth.uid()::text
);
drop policy if exists "avatar_owner_update" on storage.objects;
create policy "avatar_owner_update" on storage.objects for update to authenticated
using(bucket_id='avatars' and (storage.foldername(name))[1]=auth.uid()::text)
with check(bucket_id='avatars' and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists "avatar_owner_delete" on storage.objects;
create policy "avatar_owner_delete" on storage.objects for delete to authenticated
using(bucket_id='avatars' and (storage.foldername(name))[1]=auth.uid()::text);

drop policy if exists "church_media_admin_insert" on storage.objects;
create policy "church_media_admin_insert" on storage.objects for insert to authenticated with check(
  bucket_id='church-media' and exists(
    select 1 from public.churches c where c.id::text=(storage.foldername(name))[1] and public.is_church_admin(c.id)
  )
);
drop policy if exists "church_media_admin_update" on storage.objects;
create policy "church_media_admin_update" on storage.objects for update to authenticated using(
  bucket_id='church-media' and exists(
    select 1 from public.churches c where c.id::text=(storage.foldername(name))[1] and public.is_church_admin(c.id)
  )
) with check(
  bucket_id='church-media' and exists(
    select 1 from public.churches c where c.id::text=(storage.foldername(name))[1] and public.is_church_admin(c.id)
  )
);
drop policy if exists "church_media_admin_delete" on storage.objects;
create policy "church_media_admin_delete" on storage.objects for delete to authenticated using(
  bucket_id='church-media' and exists(
    select 1 from public.churches c where c.id::text=(storage.foldername(name))[1] and public.is_church_admin(c.id)
  )
);

drop policy if exists "player_media_super_admin_write" on storage.objects;
create policy "player_media_super_admin_write" on storage.objects for all to authenticated
using(bucket_id='player-media' and public.is_super_admin())
with check(bucket_id='player-media' and public.is_super_admin());

drop policy if exists "ad_media_admin_write" on storage.objects;
create policy "ad_media_admin_write" on storage.objects for all to authenticated
using(bucket_id='ad-media' and exists(
  select 1 from public.churches c where c.id::text=(storage.foldername(name))[1] and public.is_church_admin(c.id)
)) with check(bucket_id='ad-media' and exists(
  select 1 from public.churches c where c.id::text=(storage.foldername(name))[1] and public.is_church_admin(c.id)
));

commit;
