const $ = (selector) => document.querySelector(selector);
const status = $('#admin-status');
const { supabaseUrl, publishableKey } = bookingConfig;
const sessionKey = 'wishlist-admin-session';
let session = JSON.parse(sessionStorage.getItem(sessionKey) || 'null');
let draft = null;
let revision = null;
let bookings = [];
let editingId = null;
let dirty = false;
let importCandidates = [];

function node(tag, text, className) {
  const result = document.createElement(tag);
  result.textContent = text || '';
  if (className) result.className = className;
  return result;
}

const errors = {
  admin_required: 'У этого аккаунта нет доступа администратора.',
  catalog_changed: 'Каталог изменился в другой вкладке. Перезагрузите страницу и повторите изменения.',
  booked_category_change: 'У забронированного товара нельзя менять категорию.',
  invalid_catalog: 'Проверьте данные каталога.',
  duplicate_id: 'В каталоге есть товары или категории с одинаковыми ID.',
  invalid_gift: 'Проверьте название, фото и категорию товара.',
  invalid_store: 'Проверьте название магазина и HTTPS-ссылку на товар.',
};

async function request(path, body, authenticated = false) {
  if (authenticated && session && session.expires_at < Date.now() / 1000 + 60) {
    saveSession(await request('/auth/v1/token?grant_type=refresh_token', { refresh_token: session.refresh_token }));
  }
  const headers = { apikey: publishableKey, 'Content-Type': 'application/json' };
  if (authenticated) {
    if (!session) throw new Error('Войдите в аккаунт.');
    headers.Authorization = 'Bearer ' + session.access_token;
  }
  const response = await fetch(supabaseUrl + path, {
    method: 'POST', headers, body: JSON.stringify(body), signal: AbortSignal.timeout(25000),
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok) {
    const message = result.message || result.msg || result.error_description || result.error || 'Не удалось выполнить запрос.';
    throw new Error(errors[message] || message);
  }
  return result;
}

function saveSession(value) {
  session = { ...value, expires_at: value.expires_at || Date.now() / 1000 + value.expires_in };
  sessionStorage.setItem(sessionKey, JSON.stringify(session));
}

async function action(callback) {
  status.textContent = '';
  document.querySelectorAll('button').forEach((button) => { button.disabled = true; });
  try {
    await callback();
  } catch (error) {
    status.textContent = error.message;
  } finally {
    document.querySelectorAll('button').forEach((button) => { button.disabled = false; });
  }
}

function updateDraftStatus() {
  $('#draft-status').textContent = dirty
    ? 'Есть изменения в черновике. Нажмите «Опубликовать изменения», чтобы гости их увидели.'
    : 'Изменения появятся у гостей после публикации.';
}

function renderProducts() {
  $('#admin-products').replaceChildren();
  for (const gift of draft.gifts) {
    const row = node('article', '', 'admin-product');
    const image = node('img');
    image.src = gift.image;
    image.alt = '';
    image.loading = 'lazy';
    const text = node('div', '', 'product-copy');
    text.append(node('strong', gift.name));
    const category = draft.categories.find((item) => item.id === gift.category);
    const reserved = bookings.some((item) => item.gift_id === gift.id);
    text.append(node('p', (category?.label || gift.category) + (reserved ? ' · Забронирован' : '')));
    const controls = node('div', '', 'admin-toolbar');
    const edit = node('button', 'Изменить');
    edit.addEventListener('click', () => openEditor(gift));
    const remove = node('button', 'Убрать');
    remove.addEventListener('click', () => {
      if (reserved && !confirm('Товар забронирован. Скрыть его из каталога? Бронь категории сохранится.')) return;
      draft.gifts = draft.gifts.filter((item) => item.id !== gift.id);
      dirty = true;
      renderProducts();
    });
    controls.append(edit, remove);
    row.append(image, text, controls);
    $('#admin-products').append(row);
  }
  updateDraftStatus();
}

async function loadWorkspace() {
  const result = await request('/rest/v1/rpc/wishlist_admin_catalog', {}, true);
  draft = { categories: result.categories, gifts: result.gifts };
  revision = result.revision;
  bookings = result.bookings;
  dirty = false;
  $('#login-panel').hidden = true;
  $('#workspace').hidden = false;
  $('#logout').hidden = false;
  renderProducts();
}

function openEditor(gift = null) {
  editingId = gift?.id || null;
  $('#gift-form').reset();
  $('#form-title').textContent = gift ? 'Изменить товар' : 'Новый товар';
  $('#gift-name').value = gift?.name || '';
  $('#gift-description').value = gift?.description || '';
  $('#gift-image').value = gift?.image || '';
  $('#gift-url').value = gift?.stores[0]?.url || '';
  $('#gift-store').value = gift?.stores[0]?.name || 'Яндекс Маркет';
  $('#gift-category').replaceChildren();
  for (const category of draft.categories) {
    const option = node('option', category.label);
    option.value = category.id;
    $('#gift-category').append(option);
  }
  if (gift) $('#gift-category').value = gift.category;
  $('#gift-form').hidden = false;
  $('#gift-name').focus();
}

$('#login-form').addEventListener('submit', (event) => {
  event.preventDefault();
  action(async () => {
    await request('/auth/v1/otp?redirect_to=' + encodeURIComponent(location.origin + location.pathname), {
      email: $('#email').value.trim(), create_user: true,
    });
    $('#code-form').hidden = false;
    status.textContent = 'Письмо отправлено. Откройте ссылку из письма в этом браузере или введите код, если он есть в письме.';
  });
});
$('#code-form').addEventListener('submit', (event) => {
  event.preventDefault();
  action(async () => {
    saveSession(await request('/auth/v1/verify', {
      email: $('#email').value.trim(), token: $('#otp').value.trim(), type: 'email',
    }));
    await loadWorkspace();
  });
});
$('#logout').addEventListener('click', () => action(async () => {
  try { await request('/auth/v1/logout', {}, true); }
  finally { sessionStorage.removeItem(sessionKey); session = null; location.reload(); }
}));
$('#new-gift').addEventListener('click', () => openEditor());
$('#cancel-edit').addEventListener('click', () => { $('#gift-form').hidden = true; });
$('#gift-form').addEventListener('submit', (event) => {
  event.preventDefault();
  status.textContent = '';
  const image = $('#gift-image').value.trim();
  const url = $('#gift-url').value.trim();
  if (![image, url].every((value) => { try { return new URL(value).protocol === 'https:'; } catch { return false; } })) {
    status.textContent = 'Фото и ссылка на товар должны начинаться с https://.';
    return;
  }
  const existing = draft.gifts.find((gift) => gift.id === editingId);
  const newCategory = $('#new-category').value.trim();
  let categoryId = $('#gift-category').value;
  if (newCategory) {
    const sameCategory = draft.categories.find((item) => item.label.toLowerCase() === newCategory.toLowerCase());
    categoryId = sameCategory?.id || 'cat-' + crypto.randomUUID();
    if (!sameCategory) draft.categories.push({ id: categoryId, label: newCategory });
  }
  const marketId = new URL(url).hostname === 'market.yandex.ru' && new URL(url).pathname.match(/\/card\/[^/]+\/(\d+)/)?.[1];
  const gift = {
    ...existing,
    id: editingId || (marketId ? 'ym-' + marketId : 'gift-' + crypto.randomUUID()),
    category: categoryId,
    name: $('#gift-name').value.trim(),
    description: $('#gift-description').value.trim(),
    image,
    stores: [{ name: $('#gift-store').value.trim(), url }, ...(existing?.stores.slice(1) || [])],
  };
  if (!editingId && draft.gifts.some((item) => item.id === gift.id)) {
    status.textContent = 'Этот товар уже есть. Найдите его в списке и нажмите «Изменить».';
    return;
  }
  draft.gifts = existing ? draft.gifts.map((item) => item.id === editingId ? gift : item) : [...draft.gifts, gift];
  dirty = true;
  $('#gift-form').hidden = true;
  renderProducts();
});
$('#publish').addEventListener('click', () => action(async () => {
  const used = new Set(draft.gifts.map((gift) => gift.category));
  const payload = { ...draft, categories: draft.categories.filter((category) => used.has(category.id)) };
  await request('/rest/v1/rpc/wishlist_admin_publish', { p_catalog: payload, p_revision: revision }, true);
  await loadWorkspace();
  status.textContent = 'Опубликовано. Гости увидят изменения при обновлении каталога.';
}));
$('#import-market').addEventListener('click', () => action(async () => {
  const result = await request('/functions/v1/market-import', {}, true);
  importCandidates = result.gifts;
  const incoming = new Set(importCandidates.map((gift) => gift.id));
  const added = importCandidates.filter((gift) => !draft.gifts.some((item) => item.id === gift.id));
  const removed = draft.gifts.filter((gift) => gift.id.startsWith('ym-') && !incoming.has(gift.id));
  const panel = $('#import-preview');
  panel.replaceChildren(node('h2', 'Изменения в подборке'),
    node('p', 'Новых товаров: ' + added.length + '. Удалённых из подборки: ' + removed.length + '.'));
  for (const gift of added) {
    const button = node('button', 'Добавить в черновик — ' + gift.name);
    button.addEventListener('click', () => {
      openEditor({ ...gift, category: draft.categories[0]?.id || '', stores: gift.stores });
      editingId = null;
      button.disabled = true;
    });
    panel.append(button);
  }
  for (const gift of removed) {
    const button = node('button', 'Убрать из черновика — ' + gift.name);
    button.addEventListener('click', () => {
      if (bookings.some((booking) => booking.gift_id === gift.id)
          && !confirm('Этот товар забронирован. Скрыть его, сохранив бронь категории?')) return;
      draft.gifts = draft.gifts.filter((item) => item.id !== gift.id);
      dirty = true;
      renderProducts();
      button.disabled = true;
    });
    panel.append(button);
  }
  panel.hidden = false;
}));
window.addEventListener('beforeunload', (event) => {
  if (dirty) { event.preventDefault(); event.returnValue = ''; }
});

action(async () => {
  const fragment = new URLSearchParams(location.hash.slice(1));
  if (fragment.has('access_token')) {
    saveSession({
      access_token: fragment.get('access_token'), refresh_token: fragment.get('refresh_token'),
      expires_in: Number(fragment.get('expires_in')),
    });
    history.replaceState(null, '', location.pathname);
  }
  if (fragment.has('error_description')) {
    const message = fragment.get('error_description');
    history.replaceState(null, '', location.pathname);
    throw new Error(message);
  }
  if (session) await loadWorkspace();
});
