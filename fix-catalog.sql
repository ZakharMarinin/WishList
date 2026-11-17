begin;
insert into wishlist_private.gifts (gift_id, category_id) values
  ('ym-103590699384', 'slicers'),
  ('ym-4769356990', 'slicers'),
  ('ym-102038875871', 'spices'),
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
  if selected_category is null then
    raise exception 'wishlist_unknown_gift' using errcode = '22023';
  end if;

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


notify pgrst, 'reload schema';
commit;
