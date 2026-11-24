// Sennit Web relay: lets a browser reach a phone that is not on its network.
//
// The phone dials out to /phone with its relay secret; the relay files it
// under an id derived from that secret, so nobody without the secret can
// stand in for it. A browser then opens https://<relay>/<id>/ and everything
// it asks for is passed to the phone and back:
//
//   - files: the Sennit Web bundle, which is public (it is on the release
//     page), so the relay sees it in the clear;
//   - /<id>/ws: the app's own WebSocket, which is end-to-end encrypted between
//     the browser and the phone. The relay sees only ciphertext and sizes.
//
// Between relay and phone, one WebSocket carries everything:
//
//   text   {"t":"get","r":7,"p":"/main.dart.js","e":"<etag>"}   relay → phone
//   text   {"t":"res","r":7,"s":200,"h":{...}}                  phone → relay
//   binary [2][r:u32][bytes]  body chunk                         phone → relay
//   text   {"t":"end","r":7}                                     phone → relay
//   text   {"t":"open","c":3} / {"t":"close","c":3}              both ways
//   text   {"t":"text","c":3,"d":"..."}                          both ways
//   binary [1][c:u32][bytes]  a browser socket's binary frame    both ways
//
// Nothing is stored; a Durable Object per phone only holds the open sockets.

const KIND_DATA = 1;
const KIND_BODY = 2;
const REQUEST_TIMEOUT_MS = 30_000;

/** base64url(SHA-256(secret)), first 22 characters (132 bits). */
async function phoneId(secret) {
  const digest = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(secret),
  );
  let s = btoa(String.fromCharCode(...new Uint8Array(digest)));
  s = s.replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
  return s.slice(0, 22);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/phone') {
      const auth = request.headers.get('Authorization') ?? '';
      const secret = auth.startsWith('Bearer ') ? auth.slice(7) : '';
      if (secret.length < 32) return new Response('unauthorized', { status: 401 });
      if (request.headers.get('Upgrade') !== 'websocket') {
        return new Response('expected a WebSocket', { status: 426 });
      }
      const id = await phoneId(secret);
      const stub = env.PHONES.get(env.PHONES.idFromName(id));
      const forwarded = new Request(request);
      forwarded.headers.set('X-Sennit-Phone', id);
      return stub.fetch(forwarded);
    }
    const match = url.pathname.match(/^\/([A-Za-z0-9_-]{22})(\/.*)?$/);
    if (!match) return new Response('Sennit relay', { status: 404 });
    const [, id, rest] = match;
    if (rest === undefined) return Response.redirect(`${url.origin}/${id}/`, 308);
    const stub = env.PHONES.get(env.PHONES.idFromName(id));
    const forwarded = new Request(request);
    forwarded.headers.set('X-Sennit-Path', rest);
    return stub.fetch(forwarded);
  },
};

export class Phone {
  constructor(ctx) {
    this.ctx = ctx;
    this.pending = new Map();
    this.nextRequest = 1;
    // The phone pings to keep its socket open; answered without waking us.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping', 'pong'));
  }

  phone() {
    return this.ctx.getWebSockets('phone')[0];
  }

  browser(channel) {
    return this.ctx.getWebSockets(`b:${channel}`)[0];
  }

  async fetch(request) {
    if (request.headers.has('X-Sennit-Phone')) {
      // A phone that reconnects replaces its old socket and its browsers.
      for (const ws of this.ctx.getWebSockets()) ws.close(1012, 'phone reconnected');
      const [client, server] = Object.values(new WebSocketPair());
      this.ctx.acceptWebSocket(server, ['phone']);
      return new Response(null, { status: 101, webSocket: client });
    }
    const phone = this.phone();
    if (!phone) return new Response('This phone is not connected.', { status: 502 });
    const path = request.headers.get('X-Sennit-Path');

    if (path === '/ws' && request.headers.get('Upgrade') === 'websocket') {
      const channel = crypto.getRandomValues(new Uint32Array(1))[0];
      const [client, server] = Object.values(new WebSocketPair());
      this.ctx.acceptWebSocket(server, [`b:${channel}`]);
      server.serializeAttachment({ channel });
      phone.send(JSON.stringify({ t: 'open', c: channel }));
      return new Response(null, { status: 101, webSocket: client });
    }
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response('method not allowed', { status: 405 });
    }
    return this.forwardGet(phone, path, request);
  }

  forwardGet(phone, path, request) {
    const r = this.nextRequest++;
    const { readable, writable } = new TransformStream();
    const writer = writable.getWriter();
    const head = request.method === 'HEAD';
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(r);
        resolve(new Response('The phone did not answer.', { status: 504 }));
      }, REQUEST_TIMEOUT_MS);
      this.pending.set(r, {
        head(status, headers) {
          clearTimeout(timer);
          resolve(new Response(head || status === 304 ? null : readable, { status, headers }));
        },
        chunk: (bytes) => writer.write(bytes).catch(() => {}),
        end: () => writer.close().catch(() => {}),
      });
      phone.send(
        JSON.stringify({ t: 'get', r, p: path, e: request.headers.get('If-None-Match') ?? undefined }),
      );
    });
  }

  async webSocketMessage(ws, message) {
    const tags = this.ctx.getTags(ws);
    if (tags.includes('phone')) return this.fromPhone(message);
    const { channel } = ws.deserializeAttachment();
    const phone = this.phone();
    if (!phone) return ws.close(1011, 'phone gone');
    if (typeof message === 'string') {
      phone.send(JSON.stringify({ t: 'text', c: channel, d: message }));
    } else {
      phone.send(frame(KIND_DATA, channel, message));
    }
  }

  fromPhone(message) {
    if (typeof message !== 'string') {
      const view = new DataView(message);
      const kind = view.getUint8(0);
      const id = view.getUint32(1);
      const body = new Uint8Array(message, 5);
      if (kind === KIND_DATA) this.browser(id)?.send(body);
      if (kind === KIND_BODY) this.pending.get(id)?.chunk(body);
      return;
    }
    let m;
    try {
      m = JSON.parse(message);
    } catch {
      return;
    }
    switch (m.t) {
      case 'res':
        this.pending.get(m.r)?.head(m.s, m.h ?? {});
        break;
      case 'end':
        this.pending.get(m.r)?.end();
        this.pending.delete(m.r);
        break;
      case 'text':
        this.browser(m.c)?.send(m.d);
        break;
      case 'close':
        this.browser(m.c)?.close(1000, 'closed by phone');
        break;
    }
  }

  async webSocketClose(ws) {
    const tags = this.ctx.getTags(ws);
    if (tags.includes('phone')) {
      if (this.phone()) return;
      for (const b of this.ctx.getWebSockets()) b.close(1001, 'phone gone');
      for (const p of this.pending.values()) {
        p.head(502, {});
        p.end();
      }
      this.pending.clear();
      return;
    }
    const { channel } = ws.deserializeAttachment();
    this.phone()?.send(JSON.stringify({ t: 'close', c: channel }));
  }

  async webSocketError(ws) {
    return this.webSocketClose(ws);
  }
}

function frame(kind, id, payload) {
  const bytes = new Uint8Array(payload);
  const out = new Uint8Array(5 + bytes.length);
  const view = new DataView(out.buffer);
  view.setUint8(0, kind);
  view.setUint32(1, id);
  out.set(bytes, 5);
  return out;
}
