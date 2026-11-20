/* عامل إشعارات خدماتنا: الرحلات والخدمات الطبية وطلبات الإدارة */
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));

self.addEventListener('push', event => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (_) {}
  const target = data.url || data.target_url || './';
  const show = self.registration.showNotification(data.title || 'خدماتنا', {
    body: data.body || '',
    tag: data.tag || data.event_type || 'khadamatna-notification',
    renotify: true,
    requireInteraction: true,
    vibrate: [300, 100, 300],
    icon: 'logo-192.png',
    lang: 'ar',
    dir: 'rtl',
    data: { url: target }
  });
  // لو التطبيق مفتوح في الخلفية، نبلّغه يشغّل النغمة (محاولة، المتصفح ممكن يمنعها لو الصفحة متجمّدة)
  const tell = self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(windows => {
    windows.forEach(client => {
      try { client.postMessage({ type: 'khadamatna-push', title: data.title || '', body: data.body || '', event_type: data.event_type || '' }); } catch (_) {}
    });
  }).catch(() => {});
  event.waitUntil(Promise.all([show, tell]));
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  const rawUrl = event.notification.data && event.notification.data.url || './';
  let target;
  try {
    target = new URL(rawUrl, self.location.origin);
    if (target.origin !== self.location.origin) target = new URL('./', self.location.origin);
  } catch (_) {
    target = new URL('./', self.location.origin);
  }
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of windows) {
      if (!('focus' in client)) continue;
      if ('navigate' in client) {
        try { await client.navigate(target.href); } catch (_) {}
      }
      return client.focus();
    }
    return self.clients.openWindow(target.href);
  })());
});
