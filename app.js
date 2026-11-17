const filters = document.querySelector('#filters');
const grid = document.querySelector('#gifts');
const notice = document.querySelector('#notice');
const retry = document.querySelector('#retry');
const feedback = document.querySelector('#feedback');
const { supabaseUrl, publishableKey } = bookingConfig;
const demo = !supabaseUrl && !publishableKey;
const configured = Boolean(supabaseUrl && publishableKey);

const cards = new Map();
const demoBookings = new Set();
let activeCategory = '';
let bookings = new Map();
let categoryBookings = new Map();
let catalogRevision = null;
let ready = demo;
let reading = false;
let pendingGift = '';
let feedbackTimer;
let issue = '';
let version = 0;

function tokenForBrowser() {
  const key = 'housewarming-wishlist-owner-v1';
  const saved = localStorage.getItem(key);
  if (saved && /^[0-9a-f]{64}$/.test(saved)) return saved;
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const token = Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
  localStorage.setItem(key, token);
  return token;
}

async function rpc(name, args) {
  const response = await fetch(`${supabaseUrl.replace(/\/$/, '')}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: { apikey: publishableKey, 'Content-Type': 'application/json' },
    body: JSON.stringify(args),
    signal: AbortSignal.timeout(8000),
  });
  if (!response.ok) {
    const details = await response.json().catch(() => ({}));
    throw new Error(details.message || `Supabase HTTP ${response.status}`);
  }
  return response.json();
}

function element(tag, content, className) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (content) node.textContent = content;
  return node;
}

function enableFilterScrolling() {
  let drag = null;
  let suppressClick = false;

  filters.addEventListener('wheel', (event) => {
    if (event.ctrlKey || filters.scrollWidth <= filters.clientWidth) return;
    const delta = Math.abs(event.deltaX) > Math.abs(event.deltaY) ? event.deltaX : event.deltaY;
    const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? filters.clientWidth : 1;
    const previous = filters.scrollLeft;
    filters.scrollLeft += delta * unit;
    if (filters.scrollLeft !== previous) event.preventDefault();
  }, { passive: false });

  filters.addEventListener('click', (event) => {
    if (!suppressClick || event.detail === 0) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    suppressClick = false;
  }, { capture: true });
  filters.addEventListener('pointerdown', (event) => {
    suppressClick = false;
    if (event.pointerType !== 'mouse' || event.button !== 0) return;
    drag = { pointerId: event.pointerId, x: event.clientX, scrollLeft: filters.scrollLeft };
  });
  filters.addEventListener('pointermove', (event) => {
    if (!drag || event.pointerId !== drag.pointerId) return;
    if (!suppressClick && Math.abs(drag.x - event.clientX) < 5) return;
    if (!suppressClick) {
      suppressClick = true;
      filters.setPointerCapture(event.pointerId);
      filters.classList.add('is-dragging');
    }
    event.preventDefault();
    filters.scrollLeft = drag.scrollLeft + drag.x - event.clientX;
  });
  const stopDragging = (event) => {
    if (!drag || event.pointerId !== drag.pointerId) return;
    const pointerId = drag.pointerId;
    drag = null;
    if (filters.hasPointerCapture(pointerId)) filters.releasePointerCapture(pointerId);
    filters.classList.remove('is-dragging');
  };
  filters.addEventListener('pointerup', stopDragging);
  filters.addEventListener('pointercancel', stopDragging);
  filters.addEventListener('lostpointercapture', stopDragging);
}

function buildCatalog() {
  filters.replaceChildren();
  grid.replaceChildren();
  cards.clear();
  const categories = [{ id: '', label: 'Все' }, ...catalog.categories];
  for (const { id, label } of categories) {
    const button = element('button', label, 'filter');
    button.type = 'button';
    button.dataset.category = id;
    button.addEventListener('click', () => {
      if (activeCategory === id) return;
      activeCategory = id;
      render();
      if (!matchMedia('(prefers-reduced-motion: reduce)').matches) {
        grid.animate(
          [{ opacity: .35, transform: 'translateY(6px)' }, { opacity: 1, transform: 'translateY(0)' }],
          { duration: 220, easing: 'ease-out' },
        );
      }
    });
    filters.append(button);
  }

  for (const gift of catalog.gifts) {
    const card = element('article', '', 'gift');
    card.dataset.category = gift.category;
    const header = element('div', '', 'gift-header');
    const icon = element('span', gift.icon, 'gift-icon');
    icon.setAttribute('aria-hidden', 'true');
    const status = element('span', '', 'gift-status');
    header.append(icon, status);
    if (gift.image) {
      const photo = element('img', '', 'gift-photo');
      photo.alt = gift.name;
      photo.loading = 'lazy';
      photo.decoding = 'async';
      photo.addEventListener('load', () => {
        photo.classList.add('is-loaded');
        icon.hidden = true;
      });
      const original = gift.image.replace(
        /^(https:\/\/avatars\.mds\.yandex\.net\/get-mpic\/.+)\/180x240_multiply$/,
        '$1/orig',
      );
      photo.addEventListener('error', () => {
        if (photo.getAttribute('src') !== gift.image) photo.src = gift.image;
      });
      photo.src = original;
      header.append(photo);
    }

    const text = element('div', '', 'gift-copy');
    const title = element('h3', gift.name);
    title.id = `gift-${gift.id}`;
    card.setAttribute('aria-labelledby', title.id);
    text.append(title, element('p', gift.description, 'gift-description'));

    const stores = element('div', '', 'gift-stores');
    for (const store of gift.stores) {
      const url = new URL(store.url, location.href);
      if (!['https:', 'http:'].includes(url.protocol)) continue;
      const link = element('a', store.name);
      link.href = url.href;
      link.target = '_blank';
      link.rel = 'noopener noreferrer';
      link.setAttribute('aria-label', `${gift.name} в магазине «${store.name}» (новая вкладка)`);
      stores.append(link);
    }

    const button = element('button', '', 'gift-action');
    button.type = 'button';
    button.addEventListener('click', () => changeBooking(gift));
    const body = element('div', '', 'gift-body');
    body.append(text, stores, button);
    card.append(header, body);
    grid.append(card);
    cards.set(gift.id, { gift, card, status, button });
  }
}

function render() {
  for (const filter of filters.children) {
    filter.setAttribute('aria-pressed', String(filter.dataset.category === activeCategory));
  }
  notice.textContent = demo
    ? 'Демо · можно попробовать бронь. Изменения видны только в этой вкладке и сбросятся при перезагрузке.'
    : issue;
  notice.hidden = !notice.textContent;
  retry.hidden = !configured || !issue;
  retry.disabled = reading || Boolean(pendingGift);
  grid.setAttribute('aria-busy', String(!ready && reading));

  for (const [id, { gift, card, status, button }] of cards) {
    const selected = categoryBookings.get(gift.category);
    const taken = Boolean(selected);
    const alternative = taken && selected !== id;
    const mine = bookings.get(id) === true;
    const pending = pendingGift === id;
    card.hidden = Boolean(activeCategory && gift.category !== activeCategory);
    card.dataset.owner = String(ready && mine);
    status.hidden = !ready || !taken;
    status.textContent = mine ? 'Ваша бронь' : alternative ? 'Выбран другой вариант' : 'Занято';
    const action = pending ? 'Сохраняем…'
      : !ready ? (issue ? 'Бронь недоступна' : 'Проверяем статус…')
      : mine ? 'Снять бронь' : taken ? 'Категория занята' : 'Занять';
    button.textContent = action;
    button.setAttribute('aria-label', `${action} · ${gift.name}`);
    button.setAttribute('aria-disabled', String(!ready || Boolean(pendingGift) || (taken && !mine)));
    button.dataset.release = String(ready && mine && !pending);
  }
}

async function refresh({ afterChange = false } = {}) {
  if (demo || !configured || (pendingGift && !afterChange) || (reading && !afterChange)) return;

  const requestVersion = ++version;
  reading = true;
  render();
  try {
    const updatedCatalog = await rpc('wishlist_catalog', {});
    const rows = await rpc('wishlist_status_v2', { p_token: tokenForBrowser() });
    if (requestVersion !== version) return;
    if (updatedCatalog.revision !== catalogRevision) {
      catalog.categories = updatedCatalog.categories;
      catalog.gifts = updatedCatalog.gifts;
      catalogRevision = updatedCatalog.revision;
      if (!catalog.categories.some((category) => category.id === activeCategory)) activeCategory = '';
      buildCatalog();
    }
    bookings = new Map(rows.map(({ gift_id, mine }) => [gift_id, mine]));
    categoryBookings = new Map(rows.map(({ gift_id, category_id }) => [category_id, gift_id]));
    ready = true;
    issue = '';
  } catch {
    if (requestVersion !== version) return;
    ready = false;
    issue = 'Не удалось проверить брони. Обновите статусы, чтобы выбрать подарок.';
  } finally {
    if (requestVersion === version) {
      reading = false;
      render();
    }
  }
}

async function changeBooking(gift) {
  if (cards.get(gift.id).button.getAttribute('aria-disabled') === 'true') return;
  const release = bookings.get(gift.id) === true;
  clearTimeout(feedbackTimer);
  feedback.textContent = '';
  pendingGift = gift.id;
  let claimRejected = false;
  version++;
  render();

  try {
    if (demo) {
      if (release) demoBookings.delete(gift.id);
      else demoBookings.add(gift.id);
      bookings = new Map(Array.from(demoBookings, (id) => [id, true]));
      categoryBookings = new Map(catalog.gifts.filter((item) => bookings.has(item.id)).map((item) => [item.category, item.id]));
    } else {
      const ok = await rpc(release ? 'wishlist_release' : 'wishlist_claim', {
        p_gift_id: gift.id,
        p_token: tokenForBrowser(),
      });
      if (!ok) {
        claimRejected = !release;
        feedback.textContent = release ? 'Эта бронь уже изменилась.' : '';
        return;
      }
      if (release) bookings.delete(gift.id);
      else bookings.set(gift.id, true);
    }
    feedback.textContent = release ? 'Бронь снята.' : `«${gift.name}» теперь за вами.`;
  } catch (error) {
    feedback.textContent = error.message === 'wishlist_unknown_gift'
      ? 'Товар ещё не подключён к бронированию. Владельцу нужно обновить каталог в Supabase.'
      : 'Не удалось подтвердить действие. Проверяем текущий статус.';
  } finally {
    if (!demo) await refresh({ afterChange: true });
    if (claimRejected) {
      const selected = categoryBookings.get(gift.category);
      feedback.textContent = ready && selected
        ? 'В этой категории уже выбрали подарок.'
        : 'Не удалось занять подарок. Владельцу нужно проверить каталог и брони категории в Supabase.';
    }
    pendingGift = '';
    render();
    feedbackTimer = setTimeout(() => { feedback.textContent = ''; }, 5000);
  }
}

if (!demo && !configured) issue = 'Для бронирования необходимо завершить настройку страницы.';
buildCatalog();
enableFilterScrolling();
render();
retry.addEventListener('click', () => refresh());
if (configured) {
  refresh();
  setInterval(() => {
    if (!document.hidden) refresh();
  }, 12000);
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) refresh();
  });
}
