// How a browser camera reaches the SyncCam host.
//
//  ws  - the host serves this page over HTTPS from its own local CA (works
//        offline, but each iPhone must trust the certificate once).
//  rtc - this page is served from GitHub Pages (a normal trusted HTTPS
//        site), and talks to the host directly over WebRTC data channels.
//        To find each other, phone and host exchange one offer/answer
//        through a public MQTT relay. Those messages are end-to-end encrypted
//        (AES-256-GCM) with a key that exists only in the QR code's #fragment,
//        which browsers never send to any server.
//
// Must stay in step with lib/host/rtc_link.dart.
'use strict';

const SyncLinks = (() => {
  const BROKERS = ['wss://broker.hivemq.com:8884/mqtt', 'wss://broker.emqx.io:8084/mqtt'];
  const TOPIC = (room) => 'synccam/v1/' + room;
  const enc = new TextEncoder(), dec = new TextDecoder();

  function joinParams() {
    const p = new URLSearchParams(location.hash.slice(1));
    return { room: p.get('r'), key: p.get('k'), session: p.get('s'), broker: Number(p.get('b') || 0) };
  }

  // ------------------------------------------------------------ crypto
  const b64url = {
    decode: (s) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4)), (c) => c.charCodeAt(0)),
    encode: (u8) => btoa(String.fromCharCode(...u8)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''),
  };
  async function importKey(k) {
    return crypto.subtle.importKey('raw', b64url.decode(k), 'AES-GCM', false, ['encrypt', 'decrypt']);
  }
  // Envelope: base64url(iv[12] || ciphertext+tag)
  async function seal(key, obj) {
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, enc.encode(JSON.stringify(obj))));
    const out = new Uint8Array(12 + ct.length);
    out.set(iv); out.set(ct, 12);
    return b64url.encode(out);
  }
  async function open(key, text) {
    const b = b64url.decode(text);
    const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: b.slice(0, 12) }, key, b.slice(12));
    return JSON.parse(dec.decode(pt));
  }

  // -------------------------------------------- minimal MQTT 3.1.1 client
  // QoS 0 publish/subscribe over WebSocket: all signaling needs.
  function mqtt(url, onMessage) {
    const ws = new WebSocket(url, 'mqtt');
    ws.binaryType = 'arraybuffer';
    let ping, buf = new Uint8Array(0);
    const ready = new Promise((resolve, reject) => {
      ws.onerror = () => reject(new Error('relay unreachable'));
      ws.onopen = () => {
        const id = 'sc' + Math.random().toString(36).slice(2, 12);
        ws.send(packet(0x10, [...str('MQTT'), 4, 0x02, 0, 60], str(id)));
        ping = setInterval(() => ws.readyState === 1 && ws.send(new Uint8Array([0xc0, 0])), 25000);
      };
      ws.onmessage = (e) => {
        buf = concat(buf, new Uint8Array(e.data));
        for (;;) {
          const p = parse(buf);
          if (!p) break;
          buf = buf.slice(p.size);
          const type = p.head >> 4;
          if (type === 2) resolve(); // CONNACK
          if (type === 3) { // PUBLISH
            const tlen = (p.body[0] << 8) | p.body[1];
            const topic = dec.decode(p.body.slice(2, 2 + tlen));
            let off = 2 + tlen;
            if ((p.head >> 1) & 3) off += 2; // packet id for QoS > 0
            onMessage(topic, dec.decode(p.body.slice(off)));
          }
        }
      };
    });
    ws.onclose = () => clearInterval(ping);
    let pid = 1;
    return {
      ready,
      subscribe: (topic) => ws.send(packet(0x82, [(pid >> 8) & 255, pid++ & 255], [...str(topic), 0])),
      publish: (topic, text) => ws.send(packet(0x30, str(topic), [...enc.encode(text)])),
      close: () => { clearInterval(ping); try { ws.send(new Uint8Array([0xe0, 0])); ws.close(); } catch (_) {} },
    };
  }
  function str(s) { const b = enc.encode(s); return [b.length >> 8, b.length & 255, ...b]; }
  function packet(head, varHeader, payload) {
    const body = [...varHeader, ...payload];
    const len = [];
    let n = body.length;
    do { let d = n % 128; n = Math.floor(n / 128); if (n > 0) d |= 128; len.push(d); } while (n > 0);
    return new Uint8Array([head, ...len, ...body]);
  }
  function parse(b) {
    if (b.length < 2) return null;
    let mult = 1, len = 0, i = 1, d;
    do { if (i >= b.length) return null; d = b[i++]; len += (d & 127) * mult; mult *= 128; } while (d & 128);
    if (b.length < i + len) return null;
    return { head: b[0], body: b.slice(i, i + len), size: i + len };
  }
  function concat(a, b) { const o = new Uint8Array(a.length + b.length); o.set(a); o.set(b, a.length); return o; }

  // ------------------------------------------------------------- ws link
  function ws(o) {
    const sock = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws');
    sock.binaryType = 'arraybuffer';
    sock.onopen = () => o.onOpen();
    sock.onmessage = (e) => { if (typeof e.data === 'string') o.onText(e.data); };
    sock.onclose = () => o.onClose();
    const isOpen = () => sock.readyState === 1;
    return {
      isOpen,
      send: (t) => sock.send(t),
      sendClock: (t) => sock.send(t),
      sendPreview: (u8) => sock.send(u8),
      previewBacklog: () => sock.bufferedAmount,
      upload: async (blob, m) => {
        const r = await fetch('/upload', {
          method: 'POST', body: blob,
          headers: { 'x-device': m.device, 'x-take': m.take, 'x-shot': String(m.shot), 'x-kind': m.kind, 'x-ext': m.ext },
        });
        return r.ok;
      },
      close: () => sock.close(),
    };
  }

  // ------------------------------------------------------------ rtc link
  function rtc(o) {
    let closed = false, relay = null, pc = null, ctl, clk, prev;
    const fail = (why) => {
      if (closed) return;
      closed = true;
      try { relay && relay.close(); } catch (_) {}
      try { pc && pc.close(); } catch (_) {}
      o.onClose(why);
    };

    (async () => {
      const j = o.join;
      if (!j.room || !j.key) return fail('This link is incomplete. Scan the QR code on the host again.');
      const key = await importKey(j.key);
      const camTopic = TOPIC(j.room) + '/cam/' + o.camId;
      let answered;
      const gotAnswer = new Promise((r) => { answered = r; });
      o.onStatus && o.onStatus('Finding the host…');
      relay = mqtt(BROKERS[j.broker] || BROKERS[0], async (topic, text) => {
        if (topic !== camTopic) return;
        try {
          const m = await open(key, text);
          if (m.type === 'answer') answered(m);
        } catch (_) { /* not for us / wrong key */ }
      });
      await relay.ready;
      relay.subscribe(camTopic);

      pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] });
      ctl = pc.createDataChannel('ctl');
      clk = pc.createDataChannel('clk', { ordered: false, maxRetransmits: 0 });
      prev = pc.createDataChannel('prev', { ordered: false, maxRetransmits: 0 });
      for (const ch of [ctl, clk]) ch.onmessage = (e) => { if (typeof e.data === 'string') o.onText(e.data); };
      ctl.onopen = () => {
        relay.close(); // signaling done: everything else is phone-to-phone
        o.onOpen();
      };
      ctl.onclose = () => fail();
      pc.onconnectionstatechange = () => {
        if (pc.connectionState === 'failed') fail('Lost the direct connection to the host.');
      };

      await pc.setLocalDescription(await pc.createOffer());
      // Send one complete offer instead of trickling candidates.
      await Promise.race([
        new Promise((r) => { pc.onicegatheringstatechange = () => pc.iceGatheringState === 'complete' && r(); }),
        new Promise((r) => setTimeout(r, 2500)),
      ]);
      relay.publish(TOPIC(j.room) + '/host', await seal(key, { type: 'offer', cam: o.camId, sdp: pc.localDescription.sdp }));
      const answer = await Promise.race([gotAnswer, new Promise((r) => setTimeout(() => r(null), 15000))]);
      if (!answer) return fail('The host did not answer. Is SyncCam hosting, and do both phones have internet?');
      o.onStatus && o.onStatus('Connecting directly…');
      await pc.setRemoteDescription({ type: 'answer', sdp: answer.sdp });
    })().catch((e) => fail('Could not reach the host: ' + e.message));

    const isOpen = () => !closed && ctl && ctl.readyState === 'open';
    return {
      isOpen,
      send: (t) => ctl.send(t),
      sendClock: (t) => (clk.readyState === 'open' ? clk : ctl).send(t),
      sendPreview: (u8) => prev.readyState === 'open' && prev.send(u8),
      previewBacklog: () => (prev ? prev.bufferedAmount : 0),
      // One data channel per file: label carries the metadata, chunks follow,
      // the host answers "ok" once every byte is stored.
      upload: (blob, m) => new Promise((resolve, reject) => {
        const ch = pc.createDataChannel('file:' + JSON.stringify({ ...m, size: blob.size }));
        ch.binaryType = 'arraybuffer';
        ch.bufferedAmountLowThreshold = 256 * 1024;
        const timer = setTimeout(() => { ch.close(); reject(new Error('upload timed out')); }, 60000 + blob.size / 50);
        ch.onmessage = (e) => { if (e.data === 'ok') { clearTimeout(timer); ch.close(); resolve(true); } };
        ch.onerror = () => { clearTimeout(timer); reject(new Error('upload channel failed')); };
        ch.onopen = async () => {
          const CHUNK = 16 * 1024;
          for (let off = 0; off < blob.size; off += CHUNK) {
            if (ch.bufferedAmount > 1024 * 1024) {
              await new Promise((r) => { ch.onbufferedamountlow = r; });
            }
            ch.send(await blob.slice(off, off + CHUNK).arrayBuffer());
          }
        };
      }),
      close: () => { try { ctl && ctl.close(); } catch (_) {} fail(); },
    };
  }

  return { joinParams, ws, rtc, seal, open, importKey, mqtt };
})();
