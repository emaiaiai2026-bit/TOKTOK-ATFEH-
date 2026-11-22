/* مركز إشعارات خدماتنا: ملف مشترك لكل الصفحات
   - جرس بعدّاد غير المقروء (يتحدّث لحظيًا)
   - تنبيه داخل التطبيق عند وصول إشعار جديد
   - تفعيل وإيقاف إشعارات الجهاز (Push) من مكان واحد
   خيارات وسم <script>:
     data-no-bell   لا يعرض الجرس (مثل صفحة الإشعارات نفسها)
     data-no-toast  لا يعرض تنبيه الإشعار الجديد
     data-top="116" بعد الجرس عن أعلى الشاشة بالبكسل (الافتراضي 14)
     data-side="right" يضع الجرس يمين الشاشة (الافتراضي يسار)
     data-push-prompt يعرض بطاقة اقتراح تفعيل الإشعارات (مرة كل 3 أيام لو الإذن لسه مش متحدد)
   لو الصفحة عندها اتصال Supabase جاهز، تشاركه بكتابة: window.__khadamatnaClient = sb  */
(function () {
  'use strict';

  var SUPABASE_URL = 'https://nhxenquczoaxytxskdsa.supabase.co';
  var SUPABASE_KEY = 'sb_publishable_kQuBBDlxf1Z-6PSwbNBgCw_4F_pRUaT';
  var VAPID_PUBLIC_KEY = 'BJ77YksHejiOMhILBjthpjNFfbaVos4jqYrNw31Sks-SKwa1Qfe6jkIYmXZ-zwzufHba_rZ7D6Qw2qYg8SvY288';

  var script = document.currentScript;
  var noBell = !!(script && script.hasAttribute('data-no-bell'));
  var noToast = !!(script && script.hasAttribute('data-no-toast'));
  var bellTop = parseInt((script && script.getAttribute('data-top')) || '14', 10) || 14;
  var bellSide = (script && script.getAttribute('data-side')) === 'right' ? 'right' : 'left';
  var pushPromptOn = !!(script && script.hasAttribute('data-push-prompt'));

  if (window.KhadamatnaNotify && window.KhadamatnaNotify.__loaded) return;
  var api = window.KhadamatnaNotify = { __loaded: true };

  var sb = null;
  var user = null;
  var channel = null;
  var unread = 0;
  var changeCallbacks = [];
  var bellEl = null;
  var badgeEl = null;
  var toastEl = null;
  var toastTimer = null;
  var promptEl = null;
  var audioCtx = null;
  var lastAlertAt = 0;
  var promptCheckedFor = null;
  var healedFor = null;
  var BELL_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9"/><path d="M10 21h4"/></svg>';

  /* ---------- اتصال Supabase ---------- */
  function loadClient(done, fail) {
    if (window.supabase && window.supabase.createClient) return done();
    var sources = [
      'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2',
      'https://unpkg.com/@supabase/supabase-js@2'
    ];
    var i = 0;
    function next() {
      if (i >= sources.length) { if (fail) fail(); return; }
      var s = document.createElement('script');
      s.src = sources[i++];
      s.onload = done;
      s.onerror = function () { s.remove(); next(); };
      document.head.appendChild(s);
    }
    next();
  }

  function getClient(cb) {
    if (sb) return cb(sb);
    loadClient(function () {
      if (!sb) sb = window.__khadamatnaClient || window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY);
      cb(sb);
    });
  }

  function clientReady() {
    return new Promise(function (resolve) { getClient(resolve); });
  }

  api.client = clientReady;

  /* ---------- أدوات ---------- */
  function safeUrl(u) {
    try {
      var t = new URL(u || './', location.href);
      return t.origin === location.origin ? t.href : new URL('./', location.href).href;
    } catch (e) {
      return new URL('./', location.href).href;
    }
  }
  api.safeUrl = safeUrl;

  function emitChange(n) {
    changeCallbacks.forEach(function (fn) { try { fn(n || null); } catch (e) {} });
  }
  api.onChange = function (fn) { if (typeof fn === 'function') changeCallbacks.push(fn); };
  api.getUnread = function () { return unread; };

  /* ---------- العدّاد ---------- */
  function paintBadge() {
    if (!badgeEl || !bellEl) return;
    badgeEl.textContent = unread > 99 ? '99+' : String(unread);
    badgeEl.hidden = unread === 0;
    bellEl.setAttribute('aria-label', unread
      ? 'مركز الإشعارات، ' + unread + ' غير مقروء'
      : 'مركز الإشعارات، لا توجد إشعارات غير مقروءة');
  }

  async function refreshCount() {
    if (!sb || !user) return;
    var r = await sb.from('notifications')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', user.id)
      .is('read_at', null);
    if (r.error) return;
    unread = r.count || 0;
    paintBadge();
  }
  api.refresh = refreshCount;

  /* ---------- تنبيه داخل التطبيق ---------- */
  /* المتصفح بيمنع الصوت لحد أول لمسة على الصفحة، فبنفتح السماعة مرة واحدة عند أول لمسة */
  var UNLOCK_EVENTS = ['pointerdown', 'touchstart', 'click', 'keydown'];
  function removeUnlockListeners() {
    UNLOCK_EVENTS.forEach(function (ev) { window.removeEventListener(ev, unlockAudio, true); });
  }
  function unlockAudio() {
    try {
      var AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) return;
      if (!audioCtx) audioCtx = new AC();
      if (audioCtx.state === 'suspended') {
        audioCtx.resume().then(function () { if (audioCtx.state === 'running') removeUnlockListeners(); });
      } else if (audioCtx.state === 'running') {
        removeUnlockListeners();
      }
    } catch (e) {}
  }
  UNLOCK_EVENTS.forEach(function (ev) { window.addEventListener(ev, unlockAudio, { capture: true, passive: true }); });
  api.audioState = function () { return audioCtx ? audioCtx.state : 'locked'; };

  function chime() {
    try {
      if (!audioCtx) return; /* المستخدم لسه ما لمسش الصفحة: المتصفح بيمنع الصوت */
      if (audioCtx.state === 'suspended') audioCtx.resume();
      var ctx = audioCtx;
      var t = ctx.currentTime;
      [880, 1175].forEach(function (f, i) {
        var o = ctx.createOscillator();
        var g = ctx.createGain();
        var s0 = t + i * 0.16;
        o.type = 'sine';
        o.frequency.value = f;
        g.gain.setValueAtTime(0.0001, s0);
        g.gain.exponentialRampToValueAtTime(0.35, s0 + 0.02);
        g.gain.exponentialRampToValueAtTime(0.0001, s0 + 0.34);
        o.connect(g);
        g.connect(ctx.destination);
        o.start(s0);
        o.stop(s0 + 0.36);
      });
    } catch (e) {}
  }

  /* يشغّل النغمة مرة واحدة حتى لو وصل التنبيه من مسارين (لحظي + عامل الإشعارات) */
  function playAlert() {
    var now = Date.now();
    if (now - lastAlertAt < 4000) return;
    lastAlertAt = now;
    chime();
  }

  function showToast(n) {
    if (noToast || !n || !toastEl) return;
    toastEl.querySelector('.kn-t-title').textContent = n.title || 'إشعار جديد';
    toastEl.querySelector('.kn-t-body').textContent = n.body || '';
    toastEl.onclick = async function () {
      toastEl.classList.remove('show');
      try { if (sb && n.id) await sb.rpc('mark_notification_read', { p_notification_id: n.id }); } catch (e) {}
      var target = n.target_url && n.target_url !== './' ? safeUrl(n.target_url) : safeUrl('./notifications.html');
      location.href = target;
    };
    toastEl.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toastEl.classList.remove('show'); }, 7000);
    if (navigator.vibrate) { try { navigator.vibrate([120, 60, 120]); } catch (e) {} }
    playAlert();
  }

  function handleIncoming(n) {
    refreshCount();
    showToast(n);
    emitChange(n);
  }

  function flashToast(text) {
    if (!toastEl) return;
    toastEl.querySelector('.kn-t-title').textContent = text;
    toastEl.querySelector('.kn-t-body').textContent = '';
    toastEl.onclick = function () { toastEl.classList.remove('show'); };
    toastEl.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toastEl.classList.remove('show'); }, 4500);
  }

  function pushReasonText(r) {
    if (r.reason === 'conflict') return 'الجهاز ده مربوط بحساب تاني. سجّل دخول بالحساب القديم واضغط «خروج» مرة، وبعدها فعّل الإشعارات.';
    if (r.reason === 'denied') return 'الإشعارات متقفلة لهذا الموقع. افتح إعدادات الموقع من أيقونة القفل وفعّلها.';
    if (r.reason === 'dismissed') return 'لم يتم السماح بالإشعارات.';
    if (r.reason === 'unsupported') return 'المتصفح ده مش بيدعم الإشعارات.';
    return 'تعذر تفعيل الإشعارات';
  }

  function showPushPrompt() {
    if (!promptEl) {
      promptEl = document.createElement('div');
      promptEl.id = 'khadamatnaPrompt';
      promptEl.setAttribute('role', 'dialog');
      promptEl.setAttribute('aria-label', 'تفعيل الإشعارات');
      promptEl.innerHTML =
        '<div class="kn-p-row"><span class="kn-t-ico">' + BELL_SVG + '</span><div>' +
        '<div class="kn-t-title">فعّل الإشعارات</div>' +
        '<div class="kn-t-body">عشان توصلك تحديثات رحلاتك وخدماتك حتى والشاشة مقفولة.</div></div></div>' +
        '<div class="kn-p-btns"><button type="button" class="kn-p-yes">فعّل الإشعارات</button>' +
        '<button type="button" class="kn-p-no">لاحقًا</button></div>';
      document.body.appendChild(promptEl);
      promptEl.querySelector('.kn-p-no').onclick = function () {
        try { localStorage.setItem('kn_push_later', String(Date.now())); } catch (e) {}
        promptEl.classList.remove('show');
      };
      promptEl.querySelector('.kn-p-yes').onclick = async function () {
        this.disabled = true;
        var r = await api.enablePush();
        promptEl.classList.remove('show');
        flashToast(r.ok ? 'تم تفعيل الإشعارات على هذا الجهاز' : pushReasonText(r));
        this.disabled = false;
      };
    }
    requestAnimationFrame(function () { promptEl.classList.add('show'); });
  }

  /* علاج ذاتي: لو الخادم مسح اشتراك الجهاز (انتهى عند جوجل)، نعيد تسجيله، ونجدّده مرة كل يوم */
  async function healPush() {
    if (!user || healedFor === user.id) return;
    healedFor = user.id;
    try {
      var st = await api.pushStatus();
      if (st === 'needs-subscribe') { api.enablePush(); return; }
      if (st !== 'enabled') return;
      var last = 0;
      try { last = parseInt(localStorage.getItem('kn_push_fresh') || '0', 10); } catch (e) {}
      var stale = !last || (Date.now() - last) > 86400000;
      var r = await api.enablePush(null, stale);
      if (stale && r && r.ok) { try { localStorage.setItem('kn_push_fresh', String(Date.now())); } catch (e) {} }
    } catch (e) {}
  }

  async function maybePushPrompt() {
    if (!pushPromptOn || !user || promptCheckedFor === user.id) return;
    promptCheckedFor = user.id;
    var st = await api.pushStatus();
    if (st === 'needs-subscribe') { api.enablePush(); return; }
    if (st !== 'default') return;
    try {
      var t = parseInt(localStorage.getItem('kn_push_later') || '0', 10);
      if (t && Date.now() - t < 3 * 86400000) return;
    } catch (e) {}
    setTimeout(showPushPrompt, 1800);
  }

  /* ---------- التحديث اللحظي ---------- */
  function subscribeRealtime() {
    if (!sb || !user) return;
    if (channel && channel.__uid === user.id) return;
    if (channel) { try { sb.removeChannel(channel); } catch (e) {} channel = null; }
    try {
      var ch = sb.channel('notifications-' + user.id)
        .on('postgres_changes', {
          event: 'INSERT', schema: 'public', table: 'notifications', filter: 'user_id=eq.' + user.id
        }, function (payload) { handleIncoming(payload && payload.new); })
        .subscribe();
      ch.__uid = user.id;
      channel = ch;
    } catch (e) {}
  }

  function onSession(session) {
    var next = session && session.user ? session.user : null;
    var changed = (next && next.id) !== (user && user.id);
    user = next;
    if (!user) {
      unread = 0;
      if (bellEl) bellEl.hidden = true;
      if (channel) { try { sb.removeChannel(channel); } catch (e) {} channel = null; }
      return;
    }
    if (bellEl) bellEl.hidden = false;
    if (changed) refreshCount();
    subscribeRealtime();
    maybePushPrompt();
    healPush();
  }

  /* ---------- إشعارات الجهاز (Push) ---------- */
  function pushSupported() {
    return 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
  }

  function b64ToU8(b64) {
    var pad = '='.repeat((4 - b64.length % 4) % 4);
    var raw = atob((b64 + pad).replace(/-/g, '+').replace(/_/g, '/'));
    return Uint8Array.from(raw, function (c) { return c.charCodeAt(0); });
  }

  api.pushStatus = async function () {
    if (!pushSupported()) return 'unsupported';
    if (Notification.permission === 'denied') return 'denied';
    if (Notification.permission !== 'granted') return 'default';
    try {
      var reg = await navigator.serviceWorker.getRegistration();
      var sub = reg ? await reg.pushManager.getSubscription() : null;
      return sub ? 'enabled' : 'needs-subscribe';
    } catch (e) {
      return 'needs-subscribe';
    }
  };

  api.enablePush = async function (pageUrl, forceFresh) {
    if (!pushSupported()) return { ok: false, reason: 'unsupported' };
    var perm = Notification.permission;
    if (perm === 'denied') return { ok: false, reason: 'denied' };
    if (perm !== 'granted') {
      perm = await Notification.requestPermission();
      if (perm !== 'granted') return { ok: false, reason: perm === 'denied' ? 'denied' : 'dismissed' };
    }
    try {
      var c = await clientReady();
      var reg = await navigator.serviceWorker.register('sw.js');
      await navigator.serviceWorker.ready;
      var want = b64ToU8(VAPID_PUBLIC_KEY);
      var sub = await reg.pushManager.getSubscription();
      if (sub && forceFresh) {
        // نمسح الاشتراك القديم من القاعدة قبل ما نلغيه، عشان ما يفضلش صف ميت
        try { await c.rpc('remove_push_subscription', { p_endpoint: sub.endpoint }); } catch (e) {}
        try { await sub.unsubscribe(); } catch (e) {}
        sub = null;
      }
      if (sub) {
        var cur = sub.options && sub.options.applicationServerKey ? new Uint8Array(sub.options.applicationServerKey) : null;
        var same = cur && cur.length === want.length && cur.every(function (v, i) { return v === want[i]; });
        if (!same) { await sub.unsubscribe(); sub = null; }
      }
      if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: want });
      var j = sub.toJSON();
      var r = await c.rpc('save_push_subscription', {
        p_endpoint: j.endpoint,
        p_p256dh: j.keys.p256dh,
        p_auth: j.keys.auth,
        p_page_url: pageUrl || (location.origin + '/')
      });
      if (r.error) {
        return { ok: false, reason: /another user/i.test(r.error.message || '') ? 'conflict' : 'error', message: r.error.message };
      }
      return { ok: true };
    } catch (e) {
      return { ok: false, reason: 'error', message: e && e.message };
    }
  };

  /* يلغي اشتراك هذا الجهاز من الحساب الحالي. نادِه قبل تسجيل الخروج
     عشان إشعارات حساب ما توصلش لحد تاني على نفس الموبايل. */
  api.disablePush = async function () {
    try {
      var reg = await navigator.serviceWorker.getRegistration();
      var sub = reg ? await reg.pushManager.getSubscription() : null;
      if (!sub) return true;
      try {
        var c = await clientReady();
        await c.rpc('remove_push_subscription', { p_endpoint: sub.endpoint });
      } catch (e) {}
      await sub.unsubscribe();
      return true;
    } catch (e) {
      return false;
    }
  };
  api.beforeLogout = api.disablePush;

  /* ---------- الواجهة: الجرس والتنبيه ---------- */
  function mountUI() {
    if (document.getElementById('siteNotificationBell') || document.getElementById('khadamatnaToast')) return;
    var side = bellSide;
    var style = document.createElement('style');
    style.textContent =
      '#siteNotificationBell[hidden]{display:none!important}' +
      '#siteNotificationBell{position:fixed;top:calc(' + bellTop + 'px + env(safe-area-inset-top,0px));' + side + ':14px;z-index:10000;width:50px;height:50px;border-radius:17px;display:flex;align-items:center;justify-content:center;color:#FFC83D;text-decoration:none;' +
        'background:linear-gradient(180deg,#1E4190 0%,#0B1F4B 72%);' +
        'box-shadow:inset 0 1.5px 0 rgba(255,255,255,.28),inset 0 -2px 0 rgba(0,0,0,.28),0 4px 0 #050F2B,0 10px 18px rgba(5,15,43,.35);' +
        'transition:transform .08s ease,box-shadow .08s ease;-webkit-tap-highlight-color:transparent}' +
      '#siteNotificationBell:active{transform:translateY(3px);box-shadow:inset 0 1.5px 0 rgba(255,255,255,.28),inset 0 -2px 0 rgba(0,0,0,.28),0 1px 0 #050F2B,0 4px 8px rgba(5,15,43,.3)}' +
      '#siteNotificationBell:focus-visible{outline:3px solid #FFB400;outline-offset:3px}' +
      '#siteNotificationBell svg{width:25px;height:25px}' +
      '#siteNotificationBell .kn-badge{position:absolute;top:-12px;right:-12px;min-width:23px;height:23px;padding:0 5px;border-radius:12px;color:#2B1D00;border:2px solid #fff;font:800 11px/19px Cairo,Arial,sans-serif;text-align:center;' +
        'background:linear-gradient(180deg,#FFD66B,#FFB400);box-shadow:0 2px 0 #B87400}' +
      '.kn-badge[hidden]{display:none!important}' +
      '#khadamatnaToast{position:fixed;top:calc(12px + env(safe-area-inset-top,0px));left:50%;transform:translate(-50%,-160%);width:min(92vw,420px);z-index:10001;display:flex;gap:11px;align-items:flex-start;cursor:pointer;direction:rtl;' +
        'padding:13px 14px;border-radius:18px;color:#fff;border:1px solid rgba(255,200,61,.55);' +
        'background:linear-gradient(180deg,#17367A,#0B1F4B);box-shadow:0 16px 32px rgba(5,15,43,.42),inset 0 1px 0 rgba(255,255,255,.18);transition:transform .35s cubic-bezier(.2,.9,.3,1.15)}' +
      '#khadamatnaToast.show{transform:translate(-50%,0)}' +
      '.kn-t-ico{flex:none;width:38px;height:38px;border-radius:12px;display:flex;align-items:center;justify-content:center;color:#2B1D00;background:linear-gradient(180deg,#FFD66B,#FFB400);box-shadow:0 3px 0 #B87400}' +
      '.kn-t-ico svg{width:21px;height:21px}' +
      '.kn-t-title{font:800 15px/1.5 Cairo,Arial,sans-serif}' +
      '.kn-t-body{font:500 13px/1.6 Cairo,Arial,sans-serif;color:#C9D6F2;margin-top:1px}' +
      '#khadamatnaPrompt{position:fixed;top:calc(12px + env(safe-area-inset-top,0px));left:50%;transform:translate(-50%,-170%);width:min(92vw,420px);z-index:10002;direction:rtl;visibility:hidden;' +
        'padding:14px;border-radius:20px;color:#fff;border:1px solid rgba(255,200,61,.55);background:linear-gradient(180deg,#17367A,#0B1F4B);' +
        'box-shadow:0 18px 36px rgba(5,15,43,.45),inset 0 1px 0 rgba(255,255,255,.18);transition:transform .4s cubic-bezier(.2,.9,.3,1.15)}' +
      '#khadamatnaPrompt.show{transform:translate(-50%,0);visibility:visible}' +
      '.kn-p-row{display:flex;gap:11px;align-items:flex-start}' +
      '.kn-p-btns{display:flex;gap:10px;margin-top:13px}' +
      '.kn-p-btns button{flex:1;min-height:46px;border:0;border-radius:14px;font:800 14px Cairo,Arial,sans-serif;cursor:pointer;transition:transform .08s ease,box-shadow .08s ease}' +
      '.kn-p-yes{color:#2B1D00;background:linear-gradient(180deg,#FFD66B 0%,#FFB400 52%,#E69A00 100%);box-shadow:inset 0 1.5px 0 rgba(255,255,255,.7),0 4px 0 #B87400}' +
      '.kn-p-yes:active{transform:translateY(3px);box-shadow:inset 0 1.5px 0 rgba(255,255,255,.6),0 1px 0 #B87400}' +
      '.kn-p-no{color:#fff;background:rgba(255,255,255,.12);border:1px solid rgba(255,255,255,.3)!important;box-shadow:inset 0 1px 0 rgba(255,255,255,.3),0 4px 0 rgba(3,10,32,.5)}' +
      '.kn-p-no:active{transform:translateY(3px);box-shadow:inset 0 1px 0 rgba(255,255,255,.3),0 1px 0 rgba(3,10,32,.5)}' +
      '@media (prefers-reduced-motion:reduce){#khadamatnaToast,#khadamatnaPrompt,#siteNotificationBell{transition:none}}';
    document.head.appendChild(style);

    if (!noBell) {
      bellEl = document.createElement('a');
      bellEl.id = 'siteNotificationBell';
      bellEl.href = './notifications.html';
      bellEl.hidden = true;
      bellEl.title = 'مركز الإشعارات';
      bellEl.setAttribute('aria-label', 'مركز الإشعارات');
      bellEl.innerHTML = BELL_SVG + '<span class="kn-badge" id="siteNotificationCount" hidden>0</span>';
      document.body.appendChild(bellEl);
      badgeEl = bellEl.querySelector('.kn-badge');
    }

    {
      toastEl = document.createElement('div');
      toastEl.id = 'khadamatnaToast';
      toastEl.setAttribute('role', 'status');
      toastEl.setAttribute('aria-live', 'polite');
      toastEl.innerHTML = '<span class="kn-t-ico">' + BELL_SVG + '</span><div><div class="kn-t-title"></div><div class="kn-t-body"></div></div>';
      document.body.appendChild(toastEl);
    }
  }

  function listenForPushMessages() {
    if (!('serviceWorker' in navigator) || noToast) return;
    navigator.serviceWorker.addEventListener('message', function (e) {
      var d = e && e.data;
      if (!d || d.type !== 'khadamatna-push') return;
      refreshCount();
      playAlert();
    });
  }

  function boot() {
    mountUI();
    listenForPushMessages();
    getClient(function (c) {
      c.auth.onAuthStateChange(function (event, session) {
        setTimeout(function () { onSession(session); }, 0);
      });
      c.auth.getSession().then(function (r) { onSession(r && r.data ? r.data.session : null); });
      window.addEventListener('focus', refreshCount);
      document.addEventListener('visibilitychange', function () {
        if (document.visibilityState === 'visible') refreshCount();
      });
      window.setInterval(refreshCount, 30000);
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, { once: true });
  else boot();
})();
