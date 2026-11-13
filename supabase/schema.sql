-- ADSBETA Supabase schema
-- Run in Supabase SQL Editor. Review policies before production launch.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  phone text,
  role text not null default 'user' check (role in ('user','admin')),
  balance numeric(12,2) not null default 0 check (balance >= 0),
  total_earned numeric(12,2) not null default 0 check (total_earned >= 0),
  total_withdrawn numeric(12,2) not null default 0 check (total_withdrawn >= 0),
  referral_code text unique,
  created_at timestamptz not null default now()
);

create table if not exists public.ad_tasks (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  reward numeric(12,2) not null default 0 check (reward >= 0),
  target_url text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.ad_completions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  task_id uuid not null references public.ad_tasks(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  unique(user_id, task_id)
);

create table if not exists public.deposits (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  amount numeric(12,2) not null check (amount > 0),
  mpesa_receipt text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.withdrawals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  amount numeric(12,2) not null check (amount > 0),
  phone_number text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.site_settings (
  id integer primary key default 1 check (id=1),
  mpesa_number text not null default 'Set by administrator',
  mpesa_name text not null default 'ADSBETA',
  maintenance_notice text not null default 'M-Pesa integration is currently under maintenance.',
  manual_payments_enabled boolean not null default false,
  min_withdrawal numeric(12,2) not null default 100 check (min_withdrawal > 0)
);
insert into public.site_settings(id) values (1) on conflict do nothing;

create unique index if not exists deposits_receipt_unique on public.deposits (upper(mpesa_receipt));

create table if not exists public.wallet_ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  amount numeric(12,2) not null,
  entry_type text not null,
  reference_id uuid,
  note text,
  created_at timestamptz not null default now()
);

create table if not exists public.admin_audit_log (
  id uuid primary key default gen_random_uuid(),
  admin_id uuid not null references public.profiles(id),
  action text not null,
  table_name text not null,
  record_id uuid not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.profiles where id=auth.uid() and role='admin'); $$;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path=public
as $$
declare new_code text;
begin
  new_code := upper(substr(encode(gen_random_bytes(6),'hex'),1,8));
  insert into public.profiles(id,full_name,phone,referral_code)
  values(new.id,coalesce(new.raw_user_meta_data->>'full_name',''),new.raw_user_meta_data->>'phone',new_code)
  on conflict(id) do nothing;
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute procedure public.handle_new_user();

alter table public.profiles enable row level security;
alter table public.ad_tasks enable row level security;
alter table public.ad_completions enable row level security;
alter table public.deposits enable row level security;
alter table public.withdrawals enable row level security;
alter table public.site_settings enable row level security;
alter table public.wallet_ledger enable row level security;
alter table public.admin_audit_log enable row level security;

create policy "profiles read own or admin" on public.profiles for select to authenticated using (id=auth.uid() or public.is_admin());
-- No direct client UPDATE policy on profiles: balances and roles must only change through trusted database functions.
create policy "ads visible when active" on public.ad_tasks for select to authenticated using (active or public.is_admin());
create policy "admins manage ads" on public.ad_tasks for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "users read own completions" on public.ad_completions for select to authenticated using (user_id=auth.uid() or public.is_admin());
create policy "users read own deposits" on public.deposits for select to authenticated using (user_id=auth.uid() or public.is_admin());
create policy "users submit deposits" on public.deposits for insert to authenticated with check (user_id=auth.uid() and status='pending');
create policy "users read own withdrawals" on public.withdrawals for select to authenticated using (user_id=auth.uid() or public.is_admin());
create policy "users read settings" on public.site_settings for select to authenticated using (true);
create policy "admins update settings" on public.site_settings for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "users read own ledger" on public.wallet_ledger for select to authenticated using (user_id=auth.uid() or public.is_admin());
create policy "admins read audit" on public.admin_audit_log for select to authenticated using (public.is_admin());

create or replace function public.complete_ad_task(task_id uuid)
returns void language plpgsql security definer set search_path=public
as $$
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  if not exists(select 1 from public.ad_tasks where id=task_id and active=true) then raise exception 'Task is unavailable'; end if;
  insert into public.ad_completions(user_id,task_id,status) values(auth.uid(),task_id,'pending');
  -- Rewards are credited only after an admin approves the task.
end; $$;

create or replace function public.request_withdrawal(requested_amount numeric, phone_number text)
returns void language plpgsql security definer set search_path=public
as $$
declare current_balance numeric; minimum numeric;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  select balance into current_balance from public.profiles where id=auth.uid() for update;
  select min_withdrawal into minimum from public.site_settings where id=1;
  if requested_amount < minimum then raise exception 'Amount is below the minimum withdrawal'; end if;
  if requested_amount > current_balance then raise exception 'Insufficient available balance'; end if;
  insert into public.withdrawals(user_id,amount,phone_number) values(auth.uid(),requested_amount,phone_number);
end; $$;

create or replace function public.admin_review_request(request_table text, request_id uuid, new_status text)
returns void language plpgsql security definer set search_path=public
as $$
declare rec record;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if new_status not in ('approved','rejected') then raise exception 'Invalid status'; end if;
  if request_table='deposits' then
    select * into rec from public.deposits where id=request_id for update;
    if not found or rec.status <> 'pending' then raise exception 'Request not found or already reviewed'; end if;
    update public.deposits set status=new_status,reviewed_by=auth.uid(),reviewed_at=now() where id=request_id;
    if new_status='approved' then
      update public.profiles set balance=balance+rec.amount where id=rec.user_id;
      insert into public.wallet_ledger(user_id,amount,entry_type,reference_id,note) values(rec.user_id,rec.amount,'deposit',request_id,'Admin-approved manual deposit');
    end if;
  elsif request_table='ad_completions' then
    select c.*, t.reward into rec from public.ad_completions c
      join public.ad_tasks t on t.id=c.task_id where c.id=request_id for update of c;
    if not found or rec.status <> 'pending' then raise exception 'Task submission not found or already reviewed'; end if;
    update public.ad_completions set status=new_status where id=request_id;
    if new_status='approved' then
      update public.profiles set balance=balance+rec.reward,total_earned=total_earned+rec.reward where id=rec.user_id;
      insert into public.wallet_ledger(user_id,amount,entry_type,reference_id,note)
      values(rec.user_id,rec.reward,'ad_reward',request_id,'Admin-approved advertising task reward');
    end if;
  elsif request_table='withdrawals' then
    select * into rec from public.withdrawals where id=request_id for update;
    if not found or rec.status <> 'pending' then raise exception 'Request not found or already reviewed'; end if;
    if new_status='approved' then
      update public.profiles set balance=balance-rec.amount,total_withdrawn=total_withdrawn+rec.amount where id=rec.user_id and balance>=rec.amount;
      if not found then raise exception 'Insufficient balance at approval time'; end if;
      insert into public.wallet_ledger(user_id,amount,entry_type,reference_id,note) values(rec.user_id,-rec.amount,'withdrawal',request_id,'Admin-approved withdrawal');
    end if;
    update public.withdrawals set status=new_status,reviewed_by=auth.uid(),reviewed_at=now() where id=request_id;
  else
    raise exception 'Unsupported request type';
  end if;
  insert into public.admin_audit_log(admin_id,action,table_name,record_id,details)
  values(auth.uid(),new_status,request_table,request_id,jsonb_build_object('reviewed_at',now()));
end; $$;

-- Promote the intended admin only after that person has registered:
-- update public.profiles set role='admin' where id=(select id from auth.users where email='YOUR_ADMIN_EMAIL');
-- Run the statement above manually in SQL Editor, replacing the email. Never expose admin role editing in the client.
