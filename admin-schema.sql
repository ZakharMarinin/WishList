-- Run once after supabase.sql. Existing bookings are preserved.
begin;
alter table wishlist_private.gifts add column if not exists details jsonb;
alter table wishlist_private.gifts add column if not exists active boolean not null default false;
alter table wishlist_private.gifts add column if not exists position integer not null default 0;
create table if not exists wishlist_private.catalog_state (
  singleton boolean primary key default true check (singleton),
  categories jsonb not null default '[]',
  revision bigint not null default 0
);
insert into wishlist_private.catalog_state (singleton) values (true) on conflict do nothing;
create table if not exists wishlist_private.admins (email text primary key);
insert into wishlist_private.admins values ('marinin.vsyakoe@gmail.com') on conflict do nothing;
alter table wishlist_private.admins enable row level security;
alter table wishlist_private.catalog_state enable row level security;
revoke all on all tables in schema wishlist_private from public, anon, authenticated;

create or replace function public.wishlist_is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from auth.users u join wishlist_private.admins a on a.email = lower(u.email)
    where u.id = auth.uid() and u.email_confirmed_at is not null
  );
$$;

create or replace function public.wishlist_catalog()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'revision', s.revision, 'categories', s.categories,
    'gifts', coalesce((select jsonb_agg(g.details order by g.position, g.gift_id)
      from wishlist_private.gifts g where g.active and g.details is not null), '[]'::jsonb))
  from wishlist_private.catalog_state s;
$$;

create or replace function public.wishlist_admin_catalog()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.wishlist_is_admin() then raise insufficient_privilege using message = 'admin_required'; end if;
  return public.wishlist_catalog() || jsonb_build_object('bookings',
    coalesce((select jsonb_agg(jsonb_build_object('gift_id', b.gift_id, 'category', b.category_id))
      from wishlist_private.bookings b), '[]'::jsonb));
end;
$$;

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
  update wishlist_private.catalog_state set categories = p_catalog->'categories', revision = revision + 1;
  return current_revision + 1;
end;
$$;

create or replace function public.wishlist_status_v2(p_token text)
returns table (gift_id text, category_id text, mine boolean)
language sql stable security definer set search_path = '' as $$
  select b.gift_id, b.category_id,
    case when p_token ~ '^[0-9a-f]{64}$' then b.owner_hash = sha256(decode(p_token, 'hex')) else false end
  from wishlist_private.bookings b;
$$;

create or replace function public.wishlist_claim(p_gift_id text, p_token text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare selected_category text; token_hash bytea;
begin
  if not coalesce(p_token ~ '^[0-9a-f]{64}$', false) then return false; end if;
  perform pg_advisory_xact_lock(1701126);
  select category_id into selected_category from wishlist_private.gifts where gift_id = p_gift_id and active;
  if selected_category is null then raise exception 'wishlist_unknown_gift' using errcode = '22023'; end if;
  token_hash := sha256(decode(p_token, 'hex'));
  insert into wishlist_private.bookings(gift_id, category_id, owner_hash)
    values(p_gift_id, selected_category, token_hash) on conflict do nothing;
  return exists(select 1 from wishlist_private.bookings where gift_id = p_gift_id and owner_hash = token_hash);
end;
$$;

revoke all on function public.wishlist_is_admin() from public, anon, authenticated;
revoke all on function public.wishlist_catalog() from public, anon, authenticated;
revoke all on function public.wishlist_admin_catalog() from public, anon, authenticated;
revoke all on function public.wishlist_admin_publish(jsonb, bigint) from public, anon, authenticated;
revoke all on function public.wishlist_status_v2(text) from public, anon, authenticated;
grant execute on function public.wishlist_is_admin() to authenticated;
grant execute on function public.wishlist_catalog() to anon, authenticated;
grant execute on function public.wishlist_admin_catalog() to authenticated;
grant execute on function public.wishlist_admin_publish(jsonb, bigint) to authenticated;
grant execute on function public.wishlist_status_v2(text) to anon;

-- Bootstrap only on the first migration, before any admin publishes.
insert into wishlist_private.gifts (gift_id,category_id,details,active,position)
select seed.* from (values
('"ym-103590699384"'::jsonb #>> '{}', '"slicers"'::jsonb #>> '{}', '{"id":"ym-103590699384","category":"slicers","name":"Овощерезка Veggie Slicer","description":"Многофункциональный слайсер 14 в 1 с контейнером.","image":"https://avatars.mds.yandex.net/get-mpic/20308035/2a0000019fdc7cdc5867925b283e3f0254cb/180x240_multiply","stores":[{"name":"Яндекс Маркет","url":"https://market.yandex.ru/card/ovoshcherezka-veggie-slicer-slayser-s-konteynerom-14-v-1/103590699384"}]}'::jsonb, true, 0),
('"ym-4769356990"'::jsonb #>> '{}', '"slicers"'::jsonb #>> '{}', '{"id":"ym-4769356990","category":"slicers","name":"Овощерезка Nicer Dicer Plus","description":"Второй вариант овощерезки — достаточно одной из двух.","image":"https://avatars.mds.yandex.net/get-mpic/21131268/picecd31a3869b26e368eb52e4a83a5aaa2/180x240_multiply","stores":[{"name":"Яндекс Маркет","url":"https://market.yandex.ru/card/ovoshcherezka-nicer-dicer-plus/4769356990"}]}'::jsonb, true, 1),
('"ym-102038875871"'::jsonb #>> '{}', '"spices"'::jsonb #>> '{}', '{"id":"ym-102038875871","category":"spices","name":"Набор специй Kooh","description":"16 видов специй на подставке.","image":"https://avatars.mds.yandex.net/get-mpic/20793833/pic23e1729fc3a59915a7ef8f2d4a5e1833/180x240_multiply","stores":[{"name":"Яндекс Маркет","url":"https://market.yandex.ru/card/pripravy-i-spetsii-kooh-podarochnyy-nabor-na-podstavke-iz-16-vidov--podarok-muzhchine-i-zhenshchine-mame-podruge-i-babushke-na-den-rozhdeniya/102038875871"}]}'::jsonb, true, 2),
('"ym-6118927806"'::jsonb #>> '{}', '"basket"'::jsonb #>> '{}', '{"id":"ym-6118927806","category":"basket","name":"Бамбуковые корзины","description":"Набор корзин цвета светлого дерева.","image":"https://avatars.mds.yandex.net/get-mpic/20275872/picf6c77964515328b09a16555501a4337f/180x240_multiply","stores":[{"name":"Яндекс Маркет","url":"https://market.yandex.ru/card/nabor-bambukovykh-korzin-svetloye-derevo/6118927806"}]}'::jsonb, true, 3),
('"ym-5129769206"'::jsonb #>> '{}', '"sugar"'::jsonb #>> '{}', '{"id":"ym-5129769206","category":"sugar","name":"Белая сахарница","description":"Из пищевого пластика, с крышкой и ложкой.","image":"https://avatars.mds.yandex.net/get-mpic/16466315/2a0000019c480913504de0687774d5be2e92/180x240_multiply","stores":[{"name":"Яндекс Маркет","url":"https://market.yandex.ru/card/sakharnitsa-s-lozhkoy-i-kryshkoy/5129769206"}]}'::jsonb, true, 4),
('"ym-5433285505"'::jsonb #>> '{}', '"sugar"'::jsonb #>> '{}', '{"id":"ym-5433285505","category":"sugar","name":"Бежевая сахарница","description":"С крышкой и ложкой.","image":"https://avatars.mds.yandex.net/get-mpic/15237895/2a0000019d30e7aac9c939cdd1906e45049e/180x240_multiply","stores":[{"name":"Яндекс Маркет","url":"https://market.yandex.ru/card/sakharnitsa-s-lozhkoy-i-kryshkoy-bezhevaya/5433285505"}]}'::jsonb, true, 5),
('"ym-102063661312"'::jsonb #>> '{}', '"sugar"'::jsonb #>> '{}', '{"id":"ym-102063661312","category":"sugar","name":"Сахарница BellaTenero","description":"Фарфор, 250 мл, с ложкой и деревянной подставкой.","image":"https://avatars.mds.yandex.net/get-mpic/18104832/2a0000019c51a7da196ab530db1a03ff2f6c/180x240_multiply","stores":[{"name":"Яндекс Маркет","url":"https://market.yandex.ru/card/sakharnitsa-bellatenero-250-ml/102063661312"}]}'::jsonb, true, 6),
('"ym-5195898705"'::jsonb #>> '{}', '"towels"'::jsonb #>> '{}', '{"id":"ym-5195898705","category":"towels","name":"Синие полотенца Pragma","description":"Три кухонных полотенца, 60 × 40 см.","image":"https://avatars.mds.yandex.net/get-mpic/21319520/2a0000019f0559b760af7c7cd67a7130fdc3/180x240_multiply","stores":[{"name":"Яндекс Маркет","url":"https://market.yandex.ru/card/komplekt-kukhonnykh-polotenets-3-sht-60kh40-sm-pragma-boopla-dog/5195898705"}]}'::jsonb, true, 7),
('"ym-5035585282"'::jsonb #>> '{}', '"plates"'::jsonb #>> '{}', '{"id":"ym-5035585282","category":"plates","name":"Тарелки Pragma Boopla","description":"Две фарфоровые тарелки диаметром 23,8 см.","image":"https://avatars.mds.yandex.net/get-mpic/19784087/2a0000019f13bafd13894daff4553fd9f917/180x240_multiply","stores":[{"name":"Яндекс Маркет","url":"https://market.yandex.ru/card/nabor-iz-2kh-farforovykh-tarelok-pragma-boopla-238-sm/5035585282"}]}'::jsonb, true, 8),
('"ym-4774857243"'::jsonb #>> '{}', '"bakeware"'::jsonb #>> '{}', '{"id":"ym-4774857243","category":"bakeware","name":"Круглая форма Pragma Boopla","description":"Керамика, 26 × 23 × 6,5 см.","image":"https://avatars.mds.yandex.net/get-mpic/17708257/2a0000019dba9c161963a1ad6f890ea597dc/180x240_multiply","stores":[{"name":"Яндекс Маркет","url":"https://market.yandex.ru/card/kruglaya-forma-keramicheskaya-dlya-zapekaniya-pragma-boopla-258x235x65-sm/4774857243"}]}'::jsonb, true, 9),
('"ym-5035585283"'::jsonb #>> '{}', '"plates"'::jsonb #>> '{}', '{"id":"ym-5035585283","category":"plates","name":"Тарелки Pragma Boopla — второй вариант","description":"Две фарфоровые тарелки диаметром 23,8 см.","image":"https://avatars.mds.yandex.net/get-mpic/20342011/2a0000019f148998ce00d65694a5cc132f86/180x240_multiply","stores":[{"name":"Яндекс Маркет","url":"https://market.yandex.ru/card/nabor-iz-2kh-farforovykh-tarelok-pragma-boopla-238-sm/5035585283"}]}'::jsonb, true, 10),
('"ym-103828554182"'::jsonb #>> '{}', '"towels"'::jsonb #>> '{}', '{"id":"ym-103828554182","category":"towels","name":"Белые полотенца Pragma Rumlup","description":"Четыре хлопковых кухонных полотенца.","image":"https://avatars.mds.yandex.net/get-mpic/19751797/2a0000019c9a84db48cea5558977883f5135/180x240_multiply","stores":[{"name":"Яндекс Маркет","url":"https://market.yandex.ru/card/komplekt-khlopkovykh-kukhonnykh-polotenets-4-sht-pragma-ralum-peremenchivyy-belyy/103828554182"}]}'::jsonb, true, 11),
('"ym-5743942985"'::jsonb #>> '{}', '"bakeware"'::jsonb #>> '{}', '{"id":"ym-5743942985","category":"bakeware","name":"Голубая форма Pragma","description":"Керамическая форма для запекания, 1,1 л.","image":"https://avatars.mds.yandex.net/get-mpic/20923513/picfe070e4b76744f8e27580412ad02b98b/180x240_multiply","stores":[{"name":"Яндекс Маркет","url":"https://market.yandex.ru/card/kvadratnaya-keramicheskaya-forma-dlya-zapekaniya-pragma-27-golubaya/5743942985"}]}'::jsonb, true, 12),
('"ym-5743847453"'::jsonb #>> '{}', '"bakeware"'::jsonb #>> '{}', '{"id":"ym-5743847453","category":"bakeware","name":"Бежевая форма Pragma","description":"Керамическая форма для запекания, 2,15 л.","image":"https://avatars.mds.yandex.net/get-mpic/21939413/pic1646c62dcde0aa1dc7dd5aaaf7f1181c/180x240_multiply","stores":[{"name":"Яндекс Маркет","url":"https://market.yandex.ru/card/keramicheskaya-forma-dlya-zapekaniya-pragma-27-bezhevaya/5743847453"}]}'::jsonb, true, 13),
('"ym-103678950575"'::jsonb #>> '{}', '"glasses"'::jsonb #>> '{}', '{"id":"ym-103678950575","category":"glasses","name":"Стаканы Pragma Baltam","description":"Два прозрачных стеклянных стакана, 380 мл.","image":"https://avatars.mds.yandex.net/get-mpic/17762302/2a0000019f036828f4a8f3e4d7fa34363a67/180x240_multiply","stores":[{"name":"Яндекс Маркет","url":"https://market.yandex.ru/card/nabor-stakanov-pragma-baltam-2-sht-380ml/103678950575"}]}'::jsonb, true, 14),
('"ym-4345281729"'::jsonb #>> '{}', '"hanging-storage"'::jsonb #>> '{}', '{"id":"ym-4345281729","category":"hanging-storage","name":"Подвесной ящик Pragma Ralva","description":"Белый, 40 × 26 × 14 см.","image":"https://avatars.mds.yandex.net/get-mpic/19895571/pic77881038bc26429d4b0a9c914025184b/180x240_multiply","stores":[{"name":"Яндекс Маркет","url":"https://market.yandex.ru/card/podvesnoy-yashchik-dlya-khraneniya-40kh26kh14-sm-chernyy/4345281729"}]}'::jsonb, true, 15),
('"ym-4675374415"'::jsonb #>> '{}', '"shelves"'::jsonb #>> '{}', '{"id":"ym-4675374415","category":"shelves","name":"Этажерка Pragma Gramut","description":"Кремовая складная этажерка на колёсиках.","image":"https://avatars.mds.yandex.net/get-mpic/20170061/2a0000019db485511678c59fb85bd6792034/180x240_multiply","stores":[{"name":"Яндекс Маркет","url":"https://market.yandex.ru/card/etazherka-pragma-skladnaya-seraya/4675374415"}]}'::jsonb, true, 16),
('"ym-5683814989"'::jsonb #>> '{}', '"butter"'::jsonb #>> '{}', '{"id":"ym-5683814989","category":"butter","name":"Маслёнка Pragma Boopla","description":"Белая фарфоровая маслёнка.","image":"https://avatars.mds.yandex.net/get-mpic/22106218/pic13597ae45f1eefb0103f83ee5e5c18be/180x240_multiply","stores":[{"name":"Яндекс Маркет","url":"https://market.yandex.ru/card/maslenka-farforovaya-pragma-boopla/5683814989"}]}'::jsonb, true, 17),
('"ym-103186726114"'::jsonb #>> '{}', '"seasoning"'::jsonb #>> '{}', '{"id":"ym-103186726114","category":"seasoning","name":"Солонка и перечница BellaTenero «Котики»","description":"Две ёмкости на подставке.","image":"https://avatars.mds.yandex.net/get-mpic/17710693/2a0000019e8ce6cbf682fbce23ccaedcee3c/180x240_multiply","stores":[{"name":"Яндекс Маркет","url":"https://market.yandex.ru/card/solonka-i-perechnitsa-bellatenero/103186726114"}]}'::jsonb, true, 18)
) as seed(gift_id,category_id,details,active,position)
where (select revision=0 from wishlist_private.catalog_state)
on conflict(gift_id) do update set details=excluded.details,active=true,position=excluded.position;
update wishlist_private.catalog_state set categories='[{"id":"slicers","label":"Овощерезки"},{"id":"spices","label":"Наборы специй"},{"id":"glasses","label":"Стаканы"},{"id":"basket","label":"Корзины"},{"id":"sugar","label":"Сахарницы"},{"id":"towels","label":"Кухонные полотенца"},{"id":"plates","label":"Тарелки"},{"id":"bakeware","label":"Формы для запекания"},{"id":"hanging-storage","label":"Подвесные ящики"},{"id":"shelves","label":"Этажерки"},{"id":"butter","label":"Маслёнки"},{"id":"seasoning","label":"Солонки и перечницы"}]'::jsonb, revision=1 where revision=0;

notify pgrst, 'reload schema';
commit;
