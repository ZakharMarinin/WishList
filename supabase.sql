-- Run in the Supabase SQL Editor as the project owner.
begin;

create schema if not exists wishlist_private;
revoke all on schema wishlist_private from public, anon, authenticated;

create table if not exists wishlist_private.bookings (
  gift_id text primary key check (gift_id ~ '^[a-z0-9][a-z0-9-]{0,63}$'),
  owner_hash bytea not null check (octet_length(owner_hash) = 32),
  booked_at timestamptz not null default now()
);

alter table wishlist_private.bookings enable row level security;
revoke all on table wishlist_private.bookings from public, anon, authenticated;
create table if not exists wishlist_private.gifts (
  gift_id text primary key,
  category_id text not null
);
revoke all on table wishlist_private.gifts from public, anon, authenticated;
-- Remove the original sample products and their test bookings.
delete from wishlist_private.bookings
where gift_id in ('kettle', 'glasses', 'glasses-tall', 'basket', 'plant', 'blanket', 'candle');
delete from wishlist_private.gifts
where gift_id in ('kettle', 'glasses', 'glasses-tall', 'basket', 'plant', 'blanket', 'candle');
insert into wishlist_private.gifts (gift_id, category_id) values
  ('ym-6118927806', 'basket'),
  ('ym-5129769206', 'sugar'),
  ('ym-5433285505', 'sugar'),
  ('ym-102063661312', 'sugar'),
  ('ym-5195898705', 'towels'),
  ('ym-5035585282', 'plates'),
  ('ym-4774857243', 'bakeware'),
  ('ym-5035585283', 'plates'),
  ('ym-103828554182', 'towels'),
  ('ym-5743942985', 'bakeware'),
  ('ym-5743847453', 'bakeware'),
  ('ym-103678950575', 'glasses'),
  ('ym-4345281729', 'hanging-storage'),
  ('ym-4675374415', 'shelves'),
  ('ym-5683814989', 'butter'),
  ('ym-103186726114', 'seasoning')
on conflict (gift_id) do update set category_id = excluded.category_id;
alter table wishlist_private.bookings add column if not exists category_id text;
update wishlist_private.bookings b
set category_id = coalesce((select g.category_id from wishlist_private.gifts g where g.gift_id = b.gift_id), b.gift_id);
alter table wishlist_private.bookings alter column category_id set not null;
-- Conflicting existing bookings cause rollback rather than data loss.
create unique index if not exists bookings_one_per_category on wishlist_private.bookings (category_id);


create or replace function public.wishlist_status(p_token text)
returns table (gift_id text, mine boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select booking.gift_id,
         case when p_token ~ '^[0-9a-f]{64}$'
              then booking.owner_hash = sha256(decode(p_token, 'hex'))
              else false
         end
  from wishlist_private.bookings as booking;
$$;

create or replace function public.wishlist_claim(p_gift_id text, p_token text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  token_hash bytea;
  selected_category text;
begin
  if not coalesce(p_gift_id ~ '^[a-z0-9][a-z0-9-]{0,63}$', false)
      or not coalesce(p_token ~ '^[0-9a-f]{64}$', false) then
    return false;
  end if;

  token_hash := sha256(decode(p_token, 'hex'));
  select category_id into selected_category from wishlist_private.gifts where gift_id = p_gift_id;
  if selected_category is null then return false; end if;

  insert into wishlist_private.bookings (gift_id, owner_hash, category_id)
  values (p_gift_id, token_hash, selected_category)
  on conflict do nothing;

  if found then
    return true;
  end if;

  -- A retry from the same browser can follow a lost response.
  return exists (
    select 1 from wishlist_private.bookings
    where gift_id = p_gift_id and owner_hash = token_hash
  );
end;
$$;

create or replace function public.wishlist_release(p_gift_id text, p_token text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not coalesce(p_token ~ '^[0-9a-f]{64}$', false) then
    return false;
  end if;

  delete from wishlist_private.bookings
  where gift_id = p_gift_id and owner_hash = sha256(decode(p_token, 'hex'));

  return found;
end;
$$;

revoke all on function public.wishlist_status(text) from public, anon, authenticated;
revoke all on function public.wishlist_claim(text, text) from public, anon, authenticated;
revoke all on function public.wishlist_release(text, text) from public, anon, authenticated;
grant execute on function public.wishlist_status(text) to anon;
grant execute on function public.wishlist_claim(text, text) to anon;
grant execute on function public.wishlist_release(text, text) to anon;

notify pgrst, 'reload schema';
commit;
