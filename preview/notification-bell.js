(function () {
  var SUPABASE_URL = 'https://nhxenquczoaxytxskdsa.supabase.co';
  var SUPABASE_KEY = 'sb_publishable_kQuBBDlxf1Z-6PSwbNBgCw_4F_pRUaT';
  function loadClient(done) {
    if (window.supabase && window.supabase.createClient) return done();
    var sources = ['https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2', 'https://unpkg.com/@supabase/supabase-js@2'];
    var i = 0;
    function next() {
      if (i >= sources.length) return;
      var s = document.createElement('script');
      s.src = sources[i++];
      s.onload = done;
      s.onerror = function () { s.remove(); next(); };
      document.head.appendChild(s);
    }
    next();
  }
  function mount() {
    if (document.getElementById('siteNotificationBell')) return;
    var style = document.createElement('style');
    style.textContent = '#siteNotificationBell[hidden]{display:none!important}#siteNotificationBell{position:fixed;top:14px;left:14px;z-index:10000;width:48px;height:48px;border-radius:16px;background:#fff;color:#0B1F4B;display:flex;align-items:center;justify-content:center;text-decoration:none;box-shadow:0 5px 18px rgba(5,20,55,.22);border:1px solid #dce3f0}#siteNotificationBell svg{width:24px;height:24px}#siteNotificationBell .notificationBadge{position:absolute;top:-6px;right:-6px;min-width:21px;height:21px;padding:0 5px;border-radius:12px;background:#e53935;color:#fff;border:2px solid #fff;font:800 11px/17px Cairo,Arial,sans-serif;text-align:center}#siteNotificationBell:focus-visible{outline:3px solid #FFB400;outline-offset:3px}';
    document.head.appendChild(style);
    var a = document.createElement('a');
    a.id = 'siteNotificationBell';
    a.href = './notifications.html';
    a.setAttribute('aria-label', 'مركز الإشعارات');
    a.title = 'مركز الإشعارات';
    a.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9"/><path d="M10 21h4"/></svg><span class="notificationBadge" id="siteNotificationCount" hidden>0</span>';
    document.body.appendChild(a);
    loadClient(function () {
      var sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
      var badge = document.getElementById('siteNotificationCount');
      async function refreshCount() {
        var result = await sb.auth.getUser();
        var user = result.data && result.data.user;
        if (result.error || !user) { a.hidden = true; return; }
        a.hidden = false;
        var countResult = await sb.from('notifications').select('id', { count: 'exact', head: true }).eq('user_id', user.id).is('read_at', null);
        if (countResult.error) { badge.hidden = true; return; }
        var count = countResult.count || 0;
        badge.textContent = count > 99 ? '99+' : String(count);
        badge.hidden = count === 0;
        a.setAttribute('aria-label', count ? 'مركز الإشعارات، ' + count + ' غير مقروء' : 'مركز الإشعارات، لا توجد إشعارات غير مقروءة');
      }
      refreshCount();
      sb.auth.onAuthStateChange(function () { refreshCount(); });
      window.addEventListener('focus', refreshCount);
      window.setInterval(refreshCount, 30000);
    });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', mount, { once: true });
  else mount();
})();