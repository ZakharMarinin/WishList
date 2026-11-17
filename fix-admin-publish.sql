begin;
create or replace function public.wishlist_admin_publish(p_catalog jsonb, p_revision bigint)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  current_revision bigint;
  gift jsonb;
  category jsonb;
  item_position integer := 0;
begin
  if not public.wishlist_is_admin() then raise insufficient_privilege using message = 'admin_required'; end if;
  perform pg_advisory_xact_lock(1701126);
  select revision into current_revision from wishlist_private.catalog_state for update;
  if p_revision is distinct from current_revision then raise exception 'catalog_changed'; end if;
  if jsonb_typeof(p_catalog->'gifts') is distinct from 'array'
     or jsonb_typeof(p_catalog->'categories') is distinct from 'array'
     or jsonb_array_length(p_catalog->'gifts') > 200 then
    raise exception 'invalid_catalog';
  end if;
  if (select count(*) <> count(distinct value->>'id') from jsonb_array_elements(p_catalog->'gifts'))
     or (select count(*) <> count(distinct value->>'id') from jsonb_array_elements(p_catalog->'categories')) then
    raise exception 'duplicate_id';
  end if;
  for category in select value from jsonb_array_elements(p_catalog->'categories') loop
    if not coalesce(category->>'id' ~ '^[a-z0-9][a-z0-9-]{0,63}$', false)
       or not coalesce(length(trim(category->>'label')) between 1 and 80, false) then
      raise exception 'invalid_category';
    end if;
  end loop;
  for gift in select value from jsonb_array_elements(p_catalog->'gifts') loop
    if not coalesce(gift->>'id' ~ '^[a-z0-9][a-z0-9-]{0,63}$', false)
       or not coalesce(length(trim(gift->>'name')) between 1 and 200, false)
       or length(coalesce(gift->>'description', '')) > 2000
       or not coalesce(gift->>'image' ~ '^https://[^[:space:]]+$', false)
       or not exists(select 1 from jsonb_array_elements(p_catalog->'categories') c where c->>'id' = gift->>'category')
       or jsonb_typeof(gift->'stores') is distinct from 'array' then
      raise exception 'invalid_gift';
    end if;
    if jsonb_array_length(gift->'stores') < 1 or jsonb_array_length(gift->'stores') > 5
       or exists(select 1 from jsonb_array_elements(gift->'stores') store
         where not coalesce(store->>'url' ~ '^https://[^[:space:]]+$', false)
           or not coalesce(length(trim(store->>'name')) between 1 and 100, false)) then
      raise exception 'invalid_store';
    end if;
    if exists(select 1 from wishlist_private.bookings b
      where b.gift_id = gift->>'id' and b.category_id <> gift->>'category') then
      raise exception 'booked_category_change';
    end if;
  end loop;
  update wishlist_private.gifts set active = false where active;
  for gift in select value from jsonb_array_elements(p_catalog->'gifts') loop
    insert into wishlist_private.gifts (gift_id, category_id, details, active, position)
    values (gift->>'id', gift->>'category', gift, true, item_position)
    on conflict (gift_id) do update set category_id = excluded.category_id,
      details = excluded.details, active = true, position = excluded.position;
    item_position := item_position + 1;
  end loop;
  update wishlist_private.catalog_state set categories = p_catalog->'categories', revision = revision + 1
  where singleton = true;
  return current_revision + 1;
end;
$$;


notify pgrst, 'reload schema';
commit;
