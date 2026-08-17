-- Run with: supabase db test
-- The test is transactional and leaves no fixtures behind.

begin;
create extension if not exists pgtap with schema extensions;
select plan(28);

-- Stable fixture identities.
insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at
) values
('00000000-0000-0000-0000-000000000000','10000000-0000-0000-0000-000000000001','authenticated','authenticated','user1@test.invalid','',now(),'{}','{"full_name":"User One"}',now(),now()),
('00000000-0000-0000-0000-000000000000','10000000-0000-0000-0000-000000000002','authenticated','authenticated','admin-a@test.invalid','',now(),'{}','{"full_name":"Admin A"}',now(),now()),
('00000000-0000-0000-0000-000000000000','10000000-0000-0000-0000-000000000003','authenticated','authenticated','admin-b@test.invalid','',now(),'{}','{"full_name":"Admin B"}',now(),now()),
('00000000-0000-0000-0000-000000000000','10000000-0000-0000-0000-000000000004','authenticated','authenticated','super@test.invalid','',now(),'{}','{"full_name":"Super"}',now(),now());
set local request.jwt.claims='{"role":"service_role"}';
update public.profiles set platform_role='super_admin' where id='10000000-0000-0000-0000-000000000004';

insert into public.churches(id,owner_id,name,slug,status) values
('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002','Church A','test-church-a','active'),
('20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000003','Church B','test-church-b','active');
insert into public.seasons(id,name,start_date,end_date,is_current)
values('30000000-0000-0000-0000-000000000001','Test Season',current_date-30,current_date+300,true);
insert into public.gameweeks(id,season_id,number,name,start_date,end_date,transfer_deadline,status) values
('31000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001',1,'Past Week',now()-interval '8 days',now()-interval '1 day',now()-interval '8 days','locked'),
('31000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000001',2,'Future Week',now()+interval '1 day',now()+interval '8 days',now()+interval '1 day','upcoming');
insert into public.fantasy_rules(season_id,rules) values(
  '30000000-0000-0000-0000-000000000001',
  '{"starting_budget":100,"squad_size":15,"lineup_size":11,"bench_size":4,"position_counts":{"GK":2,"DEF":5,"MID":5,"FWD":3},"lineup_min":{"GK":1,"DEF":3,"MID":2,"FWD":1},"lineup_max":{"GK":1,"DEF":5,"MID":5,"FWD":3},"max_players_per_club":3,"free_transfers_per_gameweek":1,"max_free_transfers":2,"additional_transfer_cost":4,"captain_multiplier":2,"vice_captain_fallback":true,"selling_price_basis":"current","goal_gk_def":6,"goal_mid":5,"goal_fwd":4,"assist":3,"clean_sheet_gk_def":4,"clean_sheet_mid":1,"yellow_card":-1,"red_card":-3,"own_goal":-2,"penalty_miss":-2,"penalty_save":5,"save_every_3":1,"minutes_60_plus":2,"minutes_under_60":1}'::jsonb
);

insert into public.teams(id,name) select ('40000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,'Club '||i
from generate_series(1,6) i;
with player_data(position,ordinal) as (
  select 'GK'::public.player_position,i from generate_series(1,2)i union all
  select 'DEF',i from generate_series(1,5)i union all
  select 'MID',i from generate_series(1,5)i union all
  select 'FWD',i from generate_series(1,3)i
), numbered as (
  select position,ordinal,row_number() over(order by position,ordinal) n from player_data
)
insert into public.players(id,team_id,name,position,price)
select ('50000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,
       ('40000000-0000-0000-0000-'||lpad((((n-1)%6)+1)::text,12,'0'))::uuid,
       position::text||' '||ordinal,position,4 from numbered;
insert into public.players(id,team_id,name,position,price) values
('50000000-0000-0000-0000-000000000099','40000000-0000-0000-0000-000000000006','Expensive DEF','DEF',50);

insert into public.fantasy_leagues(id,season_id,created_by,name,is_private,max_members,status) values
('60000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002','Public Test',false,20,'active'),
('60000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000003','Private Test',true,20,'active');
insert into public.fantasy_league_secrets(league_id,invite_code)
values('60000000-0000-0000-0000-000000000002','FAG-ABCDEF1234');

-- Attack 1: a normal user cannot self-promote platform_role.
set local role authenticated;
set local request.jwt.claims='{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
select throws_ok($$update public.profiles set platform_role='super_admin' where id='10000000-0000-0000-0000-000000000001'$$);
select is((select platform_role::text from public.profiles where id=auth.uid()),'user','profile role remained user');

-- Attacks 2/3: direct privileged membership creation/promotion is denied.
select throws_ok($$insert into public.church_members(church_id,user_id,role,status) values('20000000-0000-0000-0000-000000000001',auth.uid(),'church_admin','active')$$);
select lives_ok($$select public.join_church('20000000-0000-0000-0000-000000000001')$$,'safe self-join succeeds');
select is((select role::text from public.church_members where church_id='20000000-0000-0000-0000-000000000001' and user_id=auth.uid()),'member','self-join is member only');
select throws_ok($$update public.church_members set role='church_admin' where church_id='20000000-0000-0000-0000-000000000001' and user_id=auth.uid()$$);

-- Attack 4: Admin A cannot change Church B settings.
reset role;
set local role authenticated;
set local request.jwt.claims='{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
update public.church_settings set primary_color='#BADBAD' where church_id='20000000-0000-0000-0000-000000000002';
select isnt((select primary_color from public.church_settings where church_id='20000000-0000-0000-0000-000000000002'),'#BADBAD','cross-tenant settings update changed no row');

-- Create one legal squad through the real authenticated RPC.
reset role;
set local role authenticated;
set local request.jwt.claims='{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
select lives_ok($sql$
  select public.create_fantasy_team_with_squad(
    '60000000-0000-0000-0000-000000000001','Legal XI',(
      select jsonb_agg(jsonb_build_object(
        'player_id',id,
        'is_bench',not is_starter,
        'bench_order',bench_order,
        'is_captain',is_starter and position='DEF' and pos_n=1,
        'is_vice_captain',is_starter and position='MID' and pos_n=1
      ) order by id)
      from (
        select classified.*,
          case when is_starter then null else row_number() over(
            partition by is_starter order by (position='GK') desc,position,id
          ) end bench_order
        from (
          select id,position,row_number() over(partition by position order by id) pos_n,
            case position when 'GK' then row_number() over(partition by position order by id)<=1
                          when 'DEF' then row_number() over(partition by position order by id)<=4
                          when 'MID' then row_number() over(partition by position order by id)<=4
                          else row_number() over(partition by position order by id)<=2 end is_starter
          from public.players where id<>'50000000-0000-0000-0000-000000000099'
        ) classified
      ) squad
    )
  )
$sql$,'valid team creation succeeds');

-- Attack 5: knowing a private league UUID is insufficient.
select throws_ok($sql$
  select public.create_fantasy_team_with_squad('60000000-0000-0000-0000-000000000002','No Access','[]'::jsonb)
$sql$);
-- Attack 6: one user cannot create a second team in the league.
select throws_ok($sql$
  select public.create_fantasy_team_with_squad('60000000-0000-0000-0000-000000000001','Duplicate','[]'::jsonb)
$sql$);
-- Attacks 7/8: direct squad duplication/captain tampering is denied.
select throws_ok($$insert into public.fantasy_team_players(fantasy_team_id,player_id,purchase_price) select id,'50000000-0000-0000-0000-000000000001',4 from public.fantasy_teams where user_id=auth.uid()$$);
select throws_ok($$update public.fantasy_team_players set is_captain=true where fantasy_team_id=(select id from public.fantasy_teams where user_id=auth.uid())$$);

-- Attacks 9/10: deadline and budget are checked in the transfer transaction.
select throws_ok($$select public.execute_transfer((select id from public.fantasy_teams where user_id=auth.uid()),'50000000-0000-0000-0000-000000000003','50000000-0000-0000-0000-000000000099','31000000-0000-0000-0000-000000000001')$$);
select throws_ok($$select public.execute_transfer((select id from public.fantasy_teams where user_id=auth.uid()),'50000000-0000-0000-0000-000000000003','50000000-0000-0000-0000-000000000099','31000000-0000-0000-0000-000000000002')$$);

-- Attack 11: finalized snapshots are not client-writable.
reset role;
set local request.jwt.claims='{"role":"service_role"}';
insert into public.fantasy_team_gameweek_players(
  fantasy_team_id,gameweek_id,player_id,position_at_lock,player_price_at_lock,purchase_price,
  is_starting,is_bench,is_captain,is_vice_captain,rule_id,rule_version,rules_snapshot,finalized_at
)
select ft.id,'31000000-0000-0000-0000-000000000001',ftp.player_id,p.position,p.price,ftp.purchase_price,
       true,false,false,false,r.id,r.version,r.rules,now()
from public.fantasy_teams ft
join public.fantasy_team_players ftp on ftp.fantasy_team_id=ft.id
join public.players p on p.id=ftp.player_id
join public.fantasy_rules r on r.season_id='30000000-0000-0000-0000-000000000001' and r.is_active
where ft.user_id='10000000-0000-0000-0000-000000000001'
order by ftp.id limit 1;
set local role authenticated;
set local request.jwt.claims='{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
select throws_ok($$update public.fantasy_team_gameweek_players set counted_points=999 where fantasy_team_id=(select id from public.fantasy_teams where user_id=auth.uid())$$);

-- Attack 12: Church Admin A cannot self-approve an ad.
reset role;
insert into public.advertisements(id,church_id,title,placement,start_date,end_date,status)
values('70000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','Draft','home_banner',now(),now()+interval '1 day','draft');
set local role authenticated;
set local request.jwt.claims='{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
select throws_ok($$update public.advertisements set status='active' where id='70000000-0000-0000-0000-000000000001'$$);

-- Attack 13: Church Admin A cannot read Church B finance.
reset role;
insert into public.payments(id,church_id,amount,currency,status)
values('80000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000002',10,'EGP','pending');
set local role authenticated;
set local request.jwt.claims='{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
select is((select count(*)::integer from public.payments where church_id='20000000-0000-0000-0000-000000000002'),0,'cross-tenant payments are invisible');

-- Attack 14: duplicate provider events produce one payment effect.
reset role;
set local role service_role;
set local request.jwt.claims='{"role":"service_role"}';
select lives_ok($$select public.record_payment_event('testpay','evt-1',repeat('a',64),'paid','20000000-0000-0000-0000-000000000002',null,25,'EGP','pay-1','succeeded')$$);
select lives_ok($$select public.record_payment_event('testpay','evt-1',repeat('a',64),'paid','20000000-0000-0000-0000-000000000002',null,25,'EGP','pay-1','succeeded')$$);
select is((select count(*)::integer from public.payment_events where provider='testpay' and provider_event_id='evt-1'),1,'provider event is idempotent');
select is((select count(*)::integer from public.payments where provider='testpay' and provider_payment_id='pay-1'),1,'duplicate event creates one payment');

-- Attack 15: wallet postings serialize on the wallet row, retry keys are
-- idempotent, and an overdraft is rejected.
select lives_ok($$select public.post_wallet_transaction('20000000-0000-0000-0000-000000000002','credit',100,'test',null,'credit-1')$$);
select lives_ok($$select public.post_wallet_transaction('20000000-0000-0000-0000-000000000002','debit',30,'test',null,'debit-1')$$);
select lives_ok($$select public.post_wallet_transaction('20000000-0000-0000-0000-000000000002','debit',30,'retry',null,'debit-1')$$);
select is((select balance from public.church_wallet where church_id='20000000-0000-0000-0000-000000000002'),70.00::numeric,'idempotent debit changes balance once');
select throws_ok($$select public.post_wallet_transaction('20000000-0000-0000-0000-000000000002','debit',100,'overdraft',null,'debit-2')$$);

-- Functional checks: legitimate profile and notification operations survive.
reset role;
insert into public.notifications(id,user_id,title) values('90000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','Test');
set local role authenticated;
set local request.jwt.claims='{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
select lives_ok($$update public.profiles set full_name='Updated User' where id=auth.uid()$$,'normal profile edit succeeds');
select lives_ok($$select public.mark_notifications_read('90000000-0000-0000-0000-000000000001')$$,'notification owner can mark read');

select * from finish();
rollback;
