// SyncCam browser camera: the same protocol as the app's camera node
// (lib/node/camera_node.dart), for iPhones that don't have the app.
// Clock sync runs over the WebSocket (browsers have no UDP); captures fire
// at a host-clock instant via a coarse timer plus a short busy-wait.
'use strict';

const $ = (id) => document.getElementById(id);
const S = window.SYNCCAM;
const video = $('video');

// ------------------------------------------------------------ identity
function loadId() {
  let id = localStorage.getItem('synccam.id');
  if (!id) {
    const b = new Uint8Array(8);
    crypto.getRandomValues(b);
    id = 'web' + [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
    localStorage.setItem('synccam.id', id);
  }
  return id;
}
const ID = loadId();
let name = localStorage.getItem('synccam.name') || (/iPad/.test(navigator.userAgent) ? 'iPad (web)' : 'iPhone (web)');

// --------------------------------------------------------------- clock
// Microseconds on a monotonic clock anchored to wall time, like MonoClock.
const nowUs = () => Math.round((performance.timeOrigin + performance.now()) * 1000);
const clock = { offset: 0, bestRtt: 0, samples: [], seq: 0 };
const hostNow = () => nowUs() + clock.offset;
const hostToLocal = (h) => h - clock.offset;
const synced = () => clock.samples.length >= 8;

function onPong(m) {
  const t3 = nowUs();
  const rtt = t3 - m.c - (m.h2 - m.h1);
  if (rtt < 0 || rtt > 500000) return;
  clock.samples.push({ off: Math.round((m.h1 - m.c + (m.h2 - t3)) / 2), rtt, at: t3 });
  const cutoff = t3 - 30e6;
  clock.samples = clock.samples.filter((s) => s.at > cutoff).slice(-200);
  const best = [...clock.samples].sort((a, b) => a.rtt - b.rtt);
  const top = best.slice(0, 5).sort((a, b) => a.off - b.off);
  clock.offset = top[Math.floor(top.length / 2)].off;
  clock.bestRtt = best[0].rtt;
  renderSync();
}
function pingBurst(n, gap) {
  for (let i = 0; i < n; i++) setTimeout(() => send('ping', { c: nowUs() }), i * gap);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// Coarse sleep, then spin the last ~12 ms for sub-millisecond firing.
async function waitUntilHost(hostUs) {
  const target = hostToLocal(hostUs);
  for (;;) {
    const rem = target - nowUs();
    if (rem <= 0) return;
    if (rem <= 12000) break;
    await sleep((rem - 12000) / 1000);
  }
  while (nowUs() < target) { /* spin */ }
}

// ---------------------------------------------------------------- link
let ws = null, ended = null, reconnectTimer = null;
let sessionName = S.session, slot = 0;
function send(t, body) {
  if (ws && ws.readyState === 1) ws.send(JSON.stringify({ t, ...body }));
}
function connect() {
  if (ended) return;
  setLink('connecting');
  // wss on the real (HTTPS) page; ws only for local testing on http://localhost.
  ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws');
  ws.binaryType = 'arraybuffer';
  ws.onopen = () => {
    // A reconnect may reach a restarted host whose clock differs: never
    // reuse samples measured against the previous connection.
    clock.samples = [];
    setLink('connected');
    send('hello', { id: ID, name, platform: 'web', model: deviceModel(), v: S.protocol, app: S.version });
    sendCaps();
    pingBurst(30, 25);
  };
  ws.onmessage = (e) => { if (typeof e.data === 'string') onMessage(JSON.parse(e.data)); };
  ws.onclose = () => {
    ws = null;
    if (ended) return;
    setLink('disconnected');
    clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(connect, 2000);
  };
}
setInterval(() => pingBurst(8, 30), 2000);
setInterval(sendStatus, 2000);

function deviceModel() {
  const ua = navigator.userAgent;
  const ios = ua.match(/OS (\d+)_(\d+)/);
  const kind = /iPad/.test(ua) ? 'iPad' : /iPhone/.test(ua) ? 'iPhone' : /Android/.test(ua) ? 'Android' : 'Browser';
  return kind + ' Safari' + (ios ? ` (iOS ${ios[1]}.${ios[2]})` : '');
}

// -------------------------------------------------------------- camera
const RES = { low: [320, 240], medium: [640, 480], high: [1280, 720], veryHigh: [1920, 1080], ultraHigh: [3840, 2160], max: [3840, 2160] };
let stream = null, settings = { lens: 'back', resolution: 'veryHigh', enableAudio: true, zoom: 1, flash: 'off', exposureOffset: 0 };
let caps = {}, lastError = null, cameraReady = false;

async function openCamera(s) {
  cameraReady = false;
  if (stream) stream.getTracks().forEach((t) => t.stop());
  const [w, h] = RES[s.resolution] || RES.veryHigh;
  const video_ = { facingMode: s.lens === 'front' ? 'user' : 'environment', width: { ideal: w }, height: { ideal: h } };
  if (s.fps) video_.frameRate = { ideal: s.fps };
  try {
    stream = await navigator.mediaDevices.getUserMedia({ video: video_, audio: !!s.enableAudio });
  } catch (e) {
    // Retry without audio if the microphone was refused.
    if (s.enableAudio) stream = await navigator.mediaDevices.getUserMedia({ video: video_, audio: false });
    else throw e;
  }
  video.srcObject = stream;
  video.style.transform = s.lens === 'front' ? 'scaleX(-1)' : '';
  await video.play();
  const track = stream.getVideoTracks()[0];
  caps = (track.getCapabilities && track.getCapabilities()) || {};
  cameraReady = true;
  await applyLive(s);
  sendCaps();
}

const needsReopen = (a, b) => a.lens !== b.lens || a.resolution !== b.resolution || a.fps !== b.fps || a.enableAudio !== b.enableAudio;

async function applySettings(next) {
  const prev = settings;
  settings = next;
  $('grid').style.display = next.showGrid ? 'block' : 'none';
  if (recorder) return applyLive(next); // never cut a recording
  if (!stream || needsReopen(prev, next)) return openCamera(next).catch(cameraError);
  return applyLive(next);
}

// Browsers expose only some controls; anything unsupported is reported, not fatal.
async function applyLive(s) {
  const track = stream && stream.getVideoTracks()[0];
  if (!track || !track.applyConstraints) return;
  const adv = {}, missing = [];
  if (caps.zoom) adv.zoom = Math.min(caps.zoom.max, Math.max(caps.zoom.min, s.zoom || 1));
  else if ((s.zoom || 1) !== 1) missing.push('zoom');
  if (caps.torch) adv.torch = s.flash === 'torch';
  else if (s.flash === 'torch') missing.push('torch');
  if (caps.exposureCompensation) adv.exposureCompensation = s.exposureOffset || 0;
  else if (s.exposureOffset) missing.push('exposure');
  if (caps.focusMode) adv.focusMode = s.focusLocked ? 'manual' : 'continuous';
  if (caps.exposureMode) adv.exposureMode = s.exposureLocked ? 'manual' : 'continuous';
  try {
    if (Object.keys(adv).length) await track.applyConstraints({ advanced: [adv] });
    lastError = missing.length ? 'This browser can\'t control: ' + missing.join(', ') : null;
  } catch (e) {
    lastError = 'camera control: ' + e.message;
  }
  renderErr();
}

function cameraError(e) {
  lastError = 'Camera unavailable: ' + (e && e.message ? e.message : e) +
    '. Allow camera access for this site (Settings → Safari → Camera).';
  renderErr();
}

function sendCaps() {
  send('caps', {
    lenses: ['back', 'front'],
    minZoom: caps.zoom ? caps.zoom.min : 1, maxZoom: caps.zoom ? caps.zoom.max : 1,
    minEv: caps.exposureCompensation ? caps.exposureCompensation.min : 0,
    maxEv: caps.exposureCompensation ? caps.exposureCompensation.max : 0,
    evStep: caps.exposureCompensation ? caps.exposureCompensation.step : 0,
  });
}

// ----------------------------------------------------------- live view
// Unlike the app, a browser can keep live view going while recording:
// grabbing a small frame from the <video> element is cheap.
const preview = { on: true, fps: 6, max: 360, q: 0.55, busy: false };
const small = document.createElement('canvas');
let previewTimer = null;
function restartPreview() {
  clearInterval(previewTimer);
  previewTimer = setInterval(grabPreview, 1000 / Math.max(1, preview.fps));
}
function grabPreview() {
  if (!preview.on || preview.busy || !cameraReady || !ws || ws.readyState !== 1 || !video.videoWidth) return;
  if (ws.bufferedAmount > 512 * 1024) return; // network is behind: skip a frame
  const k = preview.max / Math.max(video.videoWidth, video.videoHeight);
  small.width = Math.round(video.videoWidth * k);
  small.height = Math.round(video.videoHeight * k);
  const g = small.getContext('2d');
  if (settings.lens === 'front') { g.setTransform(-1, 0, 0, 1, small.width, 0); }
  g.drawImage(video, 0, 0, small.width, small.height);
  g.setTransform(1, 0, 0, 1, 0, 0);
  preview.busy = true;
  small.toBlob(async (b) => {
    try {
      if (b && ws && ws.readyState === 1) {
        const jpeg = new Uint8Array(await b.arrayBuffer());
        const out = new Uint8Array(jpeg.length + 2);
        out[0] = 0x53; out[1] = 1; out.set(jpeg, 2);
        ws.send(out);
      }
    } finally { preview.busy = false; }
  }, 'image/jpeg', preview.q);
}

// ------------------------------------------------------------- capture
let captures = 0, pendingUploads = 0, countdownLocal = null;
const copies = []; // recent captures the user can save from this page

// Grab the frame at the trigger instant and encode in the background, so a
// slow JPEG encode never delays the next shot of a burst. Saved photos are
// not mirrored (like the recorded video); only the on-screen views are.
function snapshotBlob(quality) {
  const c = document.createElement('canvas');
  c.width = video.videoWidth;
  c.height = video.videoHeight;
  c.getContext('2d').drawImage(video, 0, 0);
  return new Promise((r) => c.toBlob(r, 'image/jpeg', quality));
}

async function capturePhotos(m) {
  if (!cameraReady || recorder) return send('error', { take: m.take, msg: recorder ? 'busy recording' : 'camera not ready' });
  countdown(m.at);
  const results = [];
  for (let k = 0; k < (m.count || 1); k++) {
    await waitUntilHost(m.at + k * (m.interval || 0) * 1000);
    const called = hostNow();
    const blob = snapshotBlob((settings.jpegQuality || 95) / 100);
    results.push({ blob, shot: (m.shot || 0) + k, called, returned: hostNow() });
    if (k === 0) countdown(null);
  }
  for (const r of results) {
    r.blob = await r.blob;
    captures++;
    send('captured', {
      take: m.take, shot: r.shot, kind: 'photo',
      scheduledHostUs: m.at + (r.shot - (m.shot || 0)) * (m.interval || 0) * 1000,
      calledHostUs: r.called, returnedHostUs: r.returned, size: r.blob.size,
    });
    deliver(r.blob, m.take, r.shot, 'photo', 'jpg');
  }
  render();
}

let recorder = null, recTake = null, recScheduled = 0, recStartCalled = 0, recStartReturned = 0, recChunks = [], recMime = '';
function pickMime() {
  for (const t of ['video/mp4;codecs=avc1', 'video/mp4', 'video/webm;codecs=vp9', 'video/webm']) {
    if (window.MediaRecorder && MediaRecorder.isTypeSupported(t)) return t;
  }
  return '';
}

async function startVideo(m) {
  if (!cameraReady || recorder) return;
  countdown(m.at);
  recMime = pickMime();
  recChunks = [];
  // Build the recorder before the trigger so only start() happens at the instant.
  const r = new MediaRecorder(stream, recMime ? { mimeType: recMime, videoBitsPerSecond: 10e6 } : undefined);
  r.ondataavailable = (e) => { if (e.data && e.data.size) recChunks.push(e.data); };
  const started = new Promise((res) => { r.onstart = () => { recStartReturned = hostNow(); res(); }; });
  await waitUntilHost(m.at);
  recStartCalled = hostNow();
  try {
    r.start(1000);
    recorder = r;
    recTake = m.take;
    recScheduled = m.at;
    await started;
  } catch (e) {
    send('error', { take: m.take, msg: 'record failed: ' + e.message });
  }
  countdown(null);
  sendStatus();
  render();
}

async function stopVideo(m) {
  if (!recorder) return;
  await waitUntilHost(m.at);
  const stopCalled = hostNow();
  const r = recorder;
  const done = new Promise((res) => { r.onstop = res; });
  r.stop();
  await done;
  const stopReturned = hostNow();
  recorder = null;
  const blob = new Blob(recChunks, { type: recMime || 'video/mp4' });
  recChunks = [];
  captures++;
  send('captured', {
    take: recTake, shot: 0, kind: 'video', scheduledHostUs: recScheduled, stopScheduledHostUs: m.at,
    startCalledHostUs: recStartCalled, startReturnedHostUs: recStartReturned,
    stopCalledHostUs: stopCalled, stopReturnedHostUs: stopReturned, size: blob.size,
  });
  deliver(blob, recTake, 0, 'video', (recMime || 'video/mp4').includes('webm') ? 'webm' : 'mp4');
  sendStatus();
  render();
}

let autoUpload = true, keepCopy = true;
async function deliver(blob, take, shot, kind, ext) {
  if (keepCopy) {
    copies.unshift({ blob, name: `SyncCam_${take}_${shot}.${ext}`, kind });
    copies.splice(12); // keep memory bounded
  }
  if (!autoUpload) return;
  pendingUploads++;
  render();
  for (let a = 0; a < 3; a++) {
    try {
      const r = await fetch('/upload', {
        method: 'POST', body: blob,
        headers: { 'x-device': ID, 'x-take': take, 'x-shot': String(shot), 'x-kind': kind, 'x-ext': ext },
      });
      if (r.ok) break;
    } catch (e) { lastError = 'upload: ' + e.message; }
    await sleep(2000 << a);
  }
  pendingUploads--;
  render();
}

function sendStatus() {
  send('status', {
    battery: null, charging: false, synced: synced(), offsetMs: clock.offset / 1000, errMs: clock.bestRtt / 2000,
    recording: !!recorder, recStartHostUs: recorder ? recStartReturned : null, pendingUploads, captures,
    cameraReady, lens: settings.lens, err: lastError,
  });
}

// ------------------------------------------------------------ messages
function onMessage(m) {
  switch (m.t) {
    case 'pong': return onPong(m);
    case 'welcome': sessionName = m.session || sessionName; slot = m.slot || 0; return render();
    case 'settings': return applySettings(m.s);
    case 'capturePhoto': return capturePhotos(m);
    case 'startVideo': return startVideo(m);
    case 'stopVideo': return stopVideo(m);
    case 'focusAt': return focusAt(m.x, m.y);
    case 'identify': return identify();
    case 'preview':
      Object.assign(preview, { on: m.on !== false, fps: m.fps || preview.fps, max: m.max || preview.max, q: (m.q || 55) / 100 });
      return restartPreview();
    case 'rename': name = m.name; localStorage.setItem('synccam.name', name); return render();
    case 'policy': autoUpload = m.autoUpload !== false; keepCopy = m.keepCopy !== false; return;
    case 'countdown': return countdown(m.at);
    case 'endSession': return end('host');
  }
}

async function focusAt(x, y) {
  const track = stream && stream.getVideoTracks()[0];
  if (!track || !caps.pointsOfInterest) return;
  try { await track.applyConstraints({ advanced: [{ pointsOfInterest: [{ x, y }] }] }); } catch (_) {}
}

// ------------------------------------------------------------------ UI
function setLink(state) {
  $('linkDot').style.background = state === 'connected' ? 'var(--green)' : state === 'connecting' ? 'var(--amber)' : 'var(--red)';
  render();
}
function render() {
  $('linkText').textContent = `#${slot + 1} ${name}${sessionName ? ' · ' + sessionName : ''}`;
  $('captures').textContent = `${captures} captured${pendingUploads ? ' · ↑' + pendingUploads : ''}${copies.length ? ' · save' : ''}`;
  $('rec').style.display = recorder ? 'block' : 'none';
  $('dimRec').textContent = recorder ? '● REC' : '';
  renderErr();
}
function renderSync() {
  $('syncDot').style.background = synced() ? 'var(--green)' : 'var(--amber)';
  $('syncText').textContent = synced() ? `Synced ±${(clock.bestRtt / 2000).toFixed(1)} ms` : 'Syncing clock…';
}
function renderErr() { $('err').textContent = lastError || ''; }
setInterval(() => {
  if (recorder) {
    const s = Math.floor((hostNow() - recStartReturned) / 1e6);
    $('rec').textContent = `● REC ${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
  }
  const c = $('count');
  if (countdownLocal) {
    const rem = (countdownLocal - nowUs()) / 1e6;
    c.textContent = Math.ceil(rem);
    c.classList.toggle('show', rem >= 0.9);
  } else c.classList.remove('show');
}, 100);
function countdown(hostAt) { countdownLocal = hostAt ? hostToLocal(hostAt) : null; }
function identify() {
  const o = $('identify');
  o.textContent = `#${slot + 1} ${name}`;
  o.classList.add('show');
  setTimeout(() => o.classList.remove('show'), 1500);
}
function end(by) {
  if (ended) return;
  ended = by;
  if (recorder) stopVideo({ at: hostNow() });
  $('endedTitle').textContent = by === 'host' ? 'Session ended by host' : 'You left the session';
  $('endedText').textContent = copies.length ? 'Tap "save" below the camera to keep copies on this iPhone.' : '';
  $('ended').classList.add('show');
  setTimeout(() => ws && ws.close(), 300);
}

$('leave').onclick = () => {
  if (!confirm(recorder ? 'This camera is recording. Leave and save the clip?' : 'Leave this session?')) return;
  send('bye');
  end('left');
};
$('dimBtn').onclick = () => $('dim').classList.add('show');
$('dim').onclick = () => $('dim').classList.remove('show');
$('captures').onclick = async () => {
  if (!copies.length) return;
  const c = copies[0];
  const file = new File([c.blob], c.name, { type: c.blob.type });
  if (navigator.canShare && navigator.canShare({ files: [file] })) {
    try { await navigator.share({ files: [file] }); copies.shift(); render(); } catch (_) {}
  } else {
    const a = document.createElement('a');
    a.href = URL.createObjectURL(c.blob);
    a.download = c.name;
    a.click();
  }
};

let wakeLock = null;
async function keepAwake() {
  try { wakeLock = await navigator.wakeLock.request('screen'); } catch (_) {}
}
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') {
    keepAwake();
    if (!ended && (!ws || ws.readyState > 1)) connect();
  }
});

$('name').value = name;
$('startBtn').onclick = async () => {
  name = $('name').value.trim() || name;
  localStorage.setItem('synccam.name', name);
  if (!navigator.mediaDevices || !window.isSecureContext) {
    $('startErr').textContent = 'Camera needs the secure page. Open the setup link from the host again.';
    return;
  }
  try {
    await openCamera(settings);
  } catch (e) {
    $('startErr').textContent = 'Camera unavailable: ' + e.message + '. Allow camera and microphone for this site.';
    return;
  }
  $('start').classList.remove('show');
  $('start').style.display = 'none';
  keepAwake();
  restartPreview();
  connect();
  render();
};
render();
renderSync();
