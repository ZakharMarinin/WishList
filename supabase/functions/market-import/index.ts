// Deploy as market-import. Authentication is checked through Supabase Auth and the admin RPC.
const allowedOrigin = 'https://zakharmarinin.github.io';
const headers = {
  'Access-Control-Allow-Origin': allowedOrigin,
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Content-Type': 'application/json',
};
const sourceUrl = 'https://market.yandex.ru/wishlist/4b584df8-5f48-4462-96d0-6a7f12c19015?publicId=1fjyvgf5tahvr53wau19w3vg44';
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers });

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response(null, { headers });
  if (request.method !== 'POST') return json({ message: 'method_not_allowed' }, 405);
  const authorization = request.headers.get('Authorization');
  if (!authorization?.startsWith('Bearer ')) return json({ message: 'Войдите в аккаунт администратора.' }, 401);
  const apiHeaders = {
    apikey: Deno.env.get('SUPABASE_ANON_KEY')!,
    Authorization: authorization,
    'Content-Type': 'application/json',
  };
  try {
    const auth = await fetch(Deno.env.get('SUPABASE_URL') + '/rest/v1/rpc/wishlist_is_admin', {
      method: 'POST', headers: apiHeaders, body: '{}',
    });
    if (!auth.ok || await auth.json() !== true) return json({ message: 'Доступ разрешён только администратору.' }, 403);
    const response = await fetch(sourceUrl, { signal: AbortSignal.timeout(15000) });
    if (!response.ok) return json({ message: 'Маркет отклонил импорт (HTTP ' + response.status + '). Добавьте товар вручную. Каталог сохранён.' }, 502);
    const html = await response.text();
    if (/showcaptcha|Подтвердите, что вы не робот|Доступ к\s*сервису временно запрещён/i.test(html)) {
      return json({ message: 'Маркет требует проверку в браузере. Добавьте товар вручную. Каталог сохранён.' }, 422);
    }
    // Only accept a complete structured list. Never infer deletions from a partial page.
    const scripts = [...html.matchAll(/<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)];
    const lists = scripts.flatMap((match) => {
      try {
        const data = JSON.parse(match[1]);
        return Array.isArray(data) ? data : [data, ...(data['@graph'] || [])];
      } catch { return []; }
    }).filter((value) => value['@type'] === 'ItemList');
    const list = lists.find((value) => Array.isArray(value.itemListElement)
      && Number(value.numberOfItems) > 0 && Number(value.numberOfItems) === value.itemListElement.length);
    if (!list) return json({ message: 'Маркет не передал полный список товаров для импорта. Добавьте товар вручную. Каталог сохранён.' }, 422);
    const gifts = list.itemListElement.map((entry: Record<string, any>) => {
      const item = entry.item || entry;
      const url = new URL(item.url);
      const id = url.pathname.match(/^\/card\/[^/]+\/(\d+)/)?.[1];
      const image = Array.isArray(item.image) ? item.image[0] : item.image;
      if (url.hostname !== 'market.yandex.ru' || !id || !item.name || typeof image !== 'string'
          || new URL(image).protocol !== 'https:') throw new Error('incomplete_list');
      return { id: 'ym-' + id, name: item.name, description: '', image,
        stores: [{ name: 'Яндекс Маркет', url: url.origin + url.pathname }] };
    });
    if (gifts.length > 200 || new Set(gifts.map((gift: { id: string }) => gift.id)).size !== gifts.length) {
      throw new Error('incomplete_list');
    }
    return json({ gifts });
  } catch {
    return json({ message: 'Не удалось получить полный список Маркета. Повторите позже или добавьте товар вручную. Каталог сохранён.' }, 502);
  }
});
