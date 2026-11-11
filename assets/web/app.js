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
  for (let i = 0; i < n; i++) {
    setTimeout(() => { if (link && link.isOpen()) link.sendClock(JSON.stringify({ t: 'ping', c: nowUs() })); }, i * gap);
  }
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
// The page reaches the host one of two ways (transport.js):
//  - 'ws':  served by the host itself over HTTPS (certificate route, offline)
//  - 'rtc': served from GitHub Pages; WebRTC data channels, found through an
//           end-to-end encrypted relay (no certificate, needs internet to join)
let link = null, ended = null, reconnectTimer = null;
const JOIN = SyncLinks.joinParams();
let sessionName = JOIN.session || S.session, slot = 0;
if (JOIN.session) document.getElementById('sessionLabel').textContent = JOIN.session;
function send(t, body) {
  if (link && link.isOpen()) link.send(JSON.stringify({ t, ...body }));
}
let started = false; // set once the user pressed Start camera
function connect() {
  if (ended || link) return;
  setLink('connecting');
  const make = S.mode === 'rtc' ? SyncLinks.rtc : SyncLinks.ws;
  link = make({
    camId: ID,
    join: JOIN,
    onStatus: (text) => { $('pillText').textContent = text; },
    onOpen: () => {
      // A reconnect may reach a restarted host whose clock differs: never
      // reuse samples measured against the previous connection.
      clock.samples = [];
      setLink('connected');
      send('hello', { id: ID, name, platform: 'web', model: deviceModel(), v: S.protocol, app: S.version });
      sendCaps();
      pingBurst(30, 25);
      resumeUploads();
    },
    onText: (text) => onMessage(JSON.parse(text)),
    onClose: (why) => {
      link = null;
      if (ended) return;
      if (why) lastError = why;
      setLink('disconnected');
      clearTimeout(reconnectTimer);
      reconnectTimer = setTimeout(connect, 3000);
    },
  });
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

let opening = Promise.resolve();
function openCamera(s) {
  // One (re)open at a time: settings can arrive while the camera starts.
  const run = opening.then(() => openCameraNow(s));
  opening = run.catch(() => {});
  return run;
}

// Resolves when the <video> shows frames, or fails after [ms].
async function videoReady(ms) {
  // Poll rather than wait for one event, which a backgrounded tab can miss.
  for (let t = 0; t < ms; t += 50) {
    if (video.readyState >= 2 && video.videoWidth) return;
    await sleep(50);
  }
  throw new Error('the camera did not start');
}

async function openCameraNow(s) {
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
  video.play().catch(() => {}); // muted inline video; readiness is checked below
  await videoReady(5000);
  const track = stream.getVideoTracks()[0];
  caps = (track.getCapabilities && track.getCapabilities()) || {};
  cameraReady = true;
  await applyLive(s);
  sendCaps();
  render();
}

// Only these need a new camera stream. Compare loosely: the host sends
// null for "auto" where this page starts with undefined, and restarting the
// camera on every join would flicker and delay the first shot.
const needsReopen = (a, b) => (a.lens || 'back') !== (b.lens || 'back') ||
  (a.resolution || 'veryHigh') !== (b.resolution || 'veryHigh') ||
  (a.fps || 0) !== (b.fps || 0) || (a.enableAudio !== false) !== (b.enableAudio !== false);

// Applies settings and returns notes on anything this browser couldn't match.
async function applySettings(next) {
  const prev = settings;
  settings = next;
  if (next.showGrid) $('grid').style.display = 'block';
  const notes = [];
  if (recorder) {
    if (needsReopen(prev, next)) notes.push('Format changes after recording');
    return notes.concat(await applyLive(next)); // never cut a recording
  }
  if (!stream || needsReopen(prev, next)) {
    try {
      await openCamera(next);
    } catch (e) {
      cameraError(e);
      return ["Camera didn't start"];
    }
    return notes.concat(lastMissing, formatNotes(next));
  }
  return notes.concat(await applyLive(next));
}

// What the camera actually delivered, when it's less than asked for.
function formatNotes(s) {
  const track = stream && stream.getVideoTracks()[0];
  const got = track && track.getSettings ? track.getSettings() : {};
  const out = [];
  const want = RES[s.resolution] || RES.veryHigh;
  const short = Math.min(got.width || 0, got.height || 0);
  if (short && short < Math.min(want[0], want[1]) * 0.9) out.push(`Used ${short}p`);
  if (s.fps && got.frameRate && got.frameRate < s.fps - 1) {
    out.push(`This iPhone can't do ${s.fps} fps in the browser; using ${Math.round(got.frameRate)}`);
  }
  return out;
}

// Browsers expose only some controls; anything unsupported is reported, not fatal.
let lastMissing = [];
async function applyLive(s) {
  const track = stream && stream.getVideoTracks()[0];
  if (!track || !track.applyConstraints) return [];
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
    lastError = null;
  } catch (e) {
    lastError = 'Camera control: ' + e.message;
  }
  renderErr();
  lastMissing = missing.map((m) => `Can't use ${m} in the browser`);
  return lastMissing;
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
  if (!preview.on || preview.busy || !cameraReady || !link || !link.isOpen() || !video.videoWidth) return;
  if (link.previewBacklog() > 512 * 1024) return; // network is behind: skip a frame
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
      if (b && link && link.isOpen()) {
        const jpeg = new Uint8Array(await b.arrayBuffer());
        const out = new Uint8Array(jpeg.length + 2);
        out[0] = 0x53; out[1] = 1; out.set(jpeg, 2);
        link.sendPreview(out);
      }
    } finally { preview.busy = false; }
  }, 'image/jpeg', preview.q);
}

// ------------------------------------------------------------- capture
let captures = 0, pendingUploads = 0, countdownLocal = null;

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

// A trigger that fires more than a frame late is not in sync: say so, so
// the host can flag this camera instead of silently mixing it in.
function reportIfLate(take, lateUs) {
  if (lateUs > 40000) send('error', { take, msg: `fired ${(lateUs / 1000).toFixed(0)} ms late (camera was busy)`, lateMs: lateUs / 1000 });
}

// Settings may be reopening the camera when a trigger arrives; wait briefly.
async function whenCameraReady(ms = 2500) {
  for (let t = 0; !cameraReady && t < ms; t += 50) await sleep(50);
  return cameraReady;
}

async function capturePhotos(m) {
  await whenCameraReady();
  if (!cameraReady || recorder) return send('error', { take: m.take, msg: recorder ? 'busy recording' : 'camera not ready' });
  countdown(m.at);
  const results = [];
  for (let k = 0; k < (m.count || 1); k++) {
    const due = m.at + k * (m.interval || 0) * 1000;
    await waitUntilHost(due);
    const called = hostNow();
    reportIfLate(m.take, called - due);
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
  await whenCameraReady();
  if (!cameraReady || recorder) {
    if (!recorder) send('error', { take: m.take, msg: 'camera not ready' });
    return;
  }
  countdown(m.at);
  recMime = pickMime();
  recChunks = [];
  // Build the recorder before the trigger so only start() happens at the instant.
  const r = new MediaRecorder(stream, recMime ? { mimeType: recMime, videoBitsPerSecond: 10e6 } : undefined);
  r.ondataavailable = (e) => { if (e.data && e.data.size) recChunks.push(e.data); };
  const started = new Promise((res) => { r.onstart = () => { recStartReturned = hostNow(); res(); }; });
  await waitUntilHost(m.at);
  recStartCalled = hostNow();
  reportIfLate(m.take, recStartCalled - m.at);
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

// ------------------------------------------------- keeping and uploading
// Every capture is written to this iPhone's storage first (the backup),
// then sent to the controlling phone. Anything not yet sent is retried
// whenever the connection comes back, even after a reload.
let autoUpload = true;
let stored = []; // what's kept on this iPhone, newest first
const uploading = new Set();

async function refreshStored() {
  stored = await Store.list();
  pendingUploads = stored.filter((r) => !r.uploaded && r.session === sessionKey()).length;
  render();
}
const sessionKey = () => (JOIN.session || S.session || '') + '|' + (JOIN.room || location.host);

async function deliver(blob, take, shot, kind, ext) {
  const rec = {
    id: `${take}_${shot}_${kind}`, take, shot, kind, ext, blob, size: blob.size, created: Date.now(),
    name: `SyncCam_${(sessionName || 'rig').replace(/[^\w-]+/g, '_')}_${take}_${shot + 1}.${ext}`,
    session: sessionKey(), uploaded: false, saved: false,
  };
  const durable = await Store.put(rec);
  if (!durable) {
    lastError = 'This browser is not keeping files after the tab closes (private browsing?). Save clips to Photos before leaving.';
    renderErr();
  }
  await refreshStored();
  if (kind === 'video') showSavePrompt();
  if (autoUpload) upload(rec);
}

async function upload(rec) {
  if (uploading.has(rec.id) || rec.uploaded) return;
  uploading.add(rec.id);
  try {
    for (let a = 0; a < 3; a++) {
      try {
        if (link && link.isOpen() && await link.upload(rec.blob, { device: ID, take: rec.take, shot: rec.shot, kind: rec.kind, ext: rec.ext })) {
          rec.uploaded = true;
          await Store.update(rec.id, { uploaded: true });
          break;
        }
      } catch (e) { lastError = 'Sending: ' + e.message; }
      await sleep(2000 << a);
    }
  } finally {
    uploading.delete(rec.id);
    refreshStored();
  }
}

// Called when the connection opens: send anything this rig hasn't received.
async function resumeUploads() {
  if (!autoUpload) return;
  for (const r of await Store.list()) {
    if (!r.uploaded && r.session === sessionKey()) upload(r);
  }
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
    case 'welcome': {
      const first = !joined;
      joined = true;
      sessionName = m.session || sessionName;
      slot = m.slot || 0;
      render();
      if (first) flashColour();
      return;
    }
    case 'settings':
      return applySettings(m.s).then((notes) => {
        if (m.seq != null) send('applied', notes && notes.length ? { seq: m.seq, note: notes.join(' · ') } : { seq: m.seq });
      });
    case 'capturePhoto': return capturePhotos(m);
    case 'startVideo': return startVideo(m);
    case 'stopVideo': return stopVideo(m);
    case 'focusAt': return focusAt(m.x, m.y);
    case 'identify': return identify();
    case 'preview':
      Object.assign(preview, { on: m.on !== false, fps: m.fps || preview.fps, max: m.max || preview.max, q: (m.q || 55) / 100 });
      return restartPreview();
    case 'rename': name = m.name; localStorage.setItem('synccam.name', name); return render();
    case 'policy': autoUpload = m.autoUpload !== false; return;
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
// Each camera keeps one number and colour everywhere (same list as the app).
const COLOURS = ['#5EEAD4', '#8B9CFF', '#FFC53D', '#FF7AB6', '#4FC3F7', '#B5E853', '#FF8A65', '#B388FF'];
const colour = () => COLOURS[slot % COLOURS.length];
let joined = false, linkState = 'connecting';

function setLink(state) {
  linkState = state;
  render();
}

function status() {
  if (linkState !== 'connected') return ['lost', 'Lost: reconnecting'];
  if (recorder) {
    const s = Math.max(0, Math.floor((hostNow() - recStartReturned) / 1e6));
    const hh = String(Math.floor(s / 3600)).padStart(2, '0');
    const mm = String(Math.floor(s / 60) % 60).padStart(2, '0');
    return ['rec', `Recording ${hh}:${mm}:${String(s % 60).padStart(2, '0')}`];
  }
  if (!synced() || !cameraReady) return ['sync', 'Syncing…'];
  return ['ready', 'Ready'];
}

function render() {
  const c = colour();
  document.documentElement.style.setProperty('--cam', c);
  const badge = $('badge');
  badge.textContent = String(slot + 1);
  badge.style.color = lum(c) > 0.4 ? '#000' : '#fff';
  $('camName').textContent = name;
  $('rigName').textContent = sessionName || '';
  const [kind, text] = status();
  const pill = $('pill');
  pill.className = 'pill ' + kind;
  $('pillText').textContent = text;
  document.body.classList.toggle('recording', !!recorder);
  const unsaved = stored.filter((r) => !r.saved).length;
  $('keptCount').textContent = stored.length ? String(stored.length) : '';
  $('keptCount').style.display = stored.length ? 'grid' : 'none';
  $('keptBtn').classList.toggle('attention', unsaved > 0);
  $('sending').textContent = pendingUploads ? `Sending ${pendingUploads}…` : '';
  $('dimRec').textContent = recorder ? 'Recording' : 'Standby';
  renderErr();
}
function renderSync() { render(); }
function renderErr() { $('err').textContent = lastError || ''; }
function lum(hex) {
  const n = parseInt(hex.slice(1), 16);
  const ch = [n >> 16, (n >> 8) & 255, n & 255].map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; });
  return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2];
}

setInterval(() => {
  if (recorder || linkState !== 'connected') render();
  const c = $('count');
  if (countdownLocal) {
    const rem = (countdownLocal - nowUs()) / 1e6;
    c.textContent = Math.ceil(rem);
    c.classList.toggle('show', rem >= 0.9);
  } else c.classList.remove('show');
}, 250);
function countdown(hostAt) { countdownLocal = hostAt ? hostToLocal(hostAt) : null; }

const reduceMotion = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
function flashColour(ms = 450) {
  if (reduceMotion) return;
  const o = $('identify');
  o.textContent = String(slot + 1);
  o.style.color = lum(colour()) > 0.4 ? '#000' : '#fff';
  o.classList.add('show');
  if (navigator.vibrate) navigator.vibrate(30);
  setTimeout(() => o.classList.remove('show'), ms);
}
function identify() { flashColour(1500); }

function end(by) {
  if (ended) return;
  ended = by;
  if (recorder) stopVideo({ at: hostNow() });
  $('endedTitle').textContent = by === 'host' ? 'The shoot has ended' : 'You left the rig';
  $('endedText').textContent = stored.some((r) => !r.saved)
    ? 'Your photos and videos are kept on this iPhone. Save them to Photos now.'
    : 'Your photos and videos were sent to the controlling phone.';
  $('endedSave').style.display = stored.some((r) => !r.saved) ? 'block' : 'none';
  $('ended').classList.add('show');
  setTimeout(() => link && link.close(), 300);
}

$('leave').onclick = () => {
  if (!confirm(recorder ? 'This camera is recording. Leave and keep the clip?' : 'Leave the rig?')) return;
  send('bye');
  end('left');
};
$('dimBtn').onclick = () => $('dim').classList.add('show');
$('dim').onclick = () => $('dim').classList.remove('show');
$('gridBtn').onclick = () => {
  const on = $('grid').style.display !== 'block';
  $('grid').style.display = on ? 'block' : 'none';
  $('gridBtn').classList.toggle('on', on);
};

// --------------------------------------------------- saving to Photos
// Safari only lets a page hand files to Photos through the share sheet
// ("Save Video" / "Save Image"), which needs a tap, so the page offers it
// after each clip and keeps everything until it's saved.
function fileOf(r) { return new File([r.blob], r.name, { type: r.blob.type || (r.kind === 'video' ? 'video/mp4' : 'image/jpeg') }); }

async function saveToPhotos(recs) {
  if (!recs.length) return;
  const files = recs.map(fileOf);
  if (navigator.canShare && navigator.canShare({ files })) {
    try {
      await navigator.share({ files });
      for (const r of recs) { r.saved = true; await Store.update(r.id, { saved: true }); }
    } catch (e) {
      if (e && e.name !== 'AbortError' && recs.length > 1) {
        // Too many at once for the share sheet: offer them one by one.
        lastError = 'Save them one at a time from the list.';
        renderErr();
      }
    }
  } else {
    for (const [i, r] of recs.entries()) {
      const a = document.createElement('a');
      a.href = URL.createObjectURL(files[i]);
      a.download = r.name;
      a.click();
      r.saved = true;
      await Store.update(r.id, { saved: true });
    }
  }
  await refreshStored();
  renderKept();
}

let promptTimer = null;
function showSavePrompt() {
  const p = $('savePrompt');
  p.classList.add('show');
  clearTimeout(promptTimer);
  promptTimer = setTimeout(() => p.classList.remove('show'), 12000);
}
$('savePromptBtn').onclick = () => { $('savePrompt').classList.remove('show'); saveToPhotos(stored.filter((r) => !r.saved).slice(0, 1)); };
$('savePromptClose').onclick = () => $('savePrompt').classList.remove('show');

function fmtSize(b) { return b > 1e9 ? (b / 1e9).toFixed(1) + ' GB' : b > 1e6 ? (b / 1e6).toFixed(1) + ' MB' : Math.round(b / 1e3) + ' KB'; }

async function renderKept() {
  const list = $('keptList');
  list.textContent = '';
  if (!stored.length) {
    list.innerHTML = '<p class="muted">Nothing yet. Every photo and video this iPhone takes is kept here too.</p>';
  }
  for (const r of stored) {
    const row = document.createElement('div');
    row.className = 'kept';
    const thumb = document.createElement(r.kind === 'video' ? 'video' : 'img');
    thumb.className = 'thumb';
    thumb.src = URL.createObjectURL(r.blob);
    if (r.kind === 'video') { thumb.muted = true; thumb.playsInline = true; thumb.preload = 'metadata'; }
    const info = document.createElement('div');
    info.className = 'info';
    info.innerHTML = `<b>${r.kind === 'video' ? 'Video' : 'Photo'}</b><span class="mono">${fmtSize(r.size)}</span>` +
      `<span class="tag ${r.saved ? 'ok' : ''}">${r.saved ? 'Saved to Photos' : 'Only here'}</span>` +
      (r.uploaded ? '' : '<span class="tag warn">Not sent yet</span>');
    const save = document.createElement('button');
    save.textContent = 'Save';
    save.onclick = () => saveToPhotos([r]);
    const del = document.createElement('button');
    del.textContent = 'Delete';
    del.className = 'ghost';
    del.onclick = async () => {
      if (!r.saved && !confirm('This file isn\'t saved to Photos yet. Delete it from this iPhone?')) return;
      await Store.remove(r.id);
      await refreshStored();
      renderKept();
    };
    row.append(thumb, info, save, del);
    list.append(row);
  }
  const u = await Store.usage();
  $('keptUsage').textContent = u.quota ? `Using ${fmtSize(u.used)} of this iPhone's browser storage` : '';
  $('keptSaveAll').disabled = !stored.some((r) => !r.saved);
}
$('keptBtn').onclick = async () => { await refreshStored(); await renderKept(); $('keptSheet').classList.add('show'); };
$('keptClose').onclick = () => $('keptSheet').classList.remove('show');
$('keptSaveAll').onclick = () => saveToPhotos(stored.filter((r) => !r.saved));
$('endedSave').onclick = async () => { await refreshStored(); await renderKept(); $('keptSheet').classList.add('show'); };

// ------------------------------------------------------- staying awake
let wakeLock = null;
async function keepAwake() {
  try { wakeLock = await navigator.wakeLock.request('screen'); } catch (_) {}
}
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') {
    keepAwake();
    if (started && !ended && !link) connect();
    // iOS may have stopped the camera while the screen was locked.
    if (started && !ended && (!stream || stream.getVideoTracks().every((t) => t.readyState === 'ended'))) {
      openCamera(settings).catch(cameraError);
    }
  }
});

// One-time tip: Add to Home Screen gives a full-screen camera that's less
// likely to be closed by accident.
const standalone = window.navigator.standalone || (window.matchMedia && matchMedia('(display-mode: standalone)').matches);
if (!standalone && /iPhone|iPad/.test(navigator.userAgent) && !localStorage.getItem('synccam.a2hs')) {
  $('a2hs').style.display = 'block';
}
$('a2hsClose').onclick = () => { localStorage.setItem('synccam.a2hs', '1'); $('a2hs').style.display = 'none'; };

if (S.mode === 'rtc') {
  $('privateText').textContent = 'This page only talks to the phone running SyncCam. Internet is used just for an encrypted hello; photos and videos go phone to phone.';
}
$('name').value = name;
$('startBtn').onclick = async () => {
  name = $('name').value.trim() || name;
  localStorage.setItem('synccam.name', name);
  if (!navigator.mediaDevices || !window.isSecureContext) {
    $('startErr').textContent = 'The camera needs the secure page. Scan the code on the controlling phone again.';
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
  started = true;
  connect();
  render();
};
$('startKept').onclick = async () => { await refreshStored(); await renderKept(); $('keptSheet').classList.add('show'); };

refreshStored().then(() => {
  const unsaved = stored.filter((r) => !r.saved).length;
  if (unsaved) {
    $('startKept').style.display = 'block';
    $('startKept').textContent = `${unsaved} file${unsaved === 1 ? '' : 's'} on this iPhone not saved to Photos`;
  }
});
render();
