#!/usr/bin/env node
'use strict';
// Lightweight AMQP 1.0 broker for local DocumentServer development on macOS.
// Uses the rhea package already installed in server/Common/node_modules.
const path = require('path');
const rhea = require(path.join(__dirname, '..', 'server', 'Common', 'node_modules', 'rhea'));

const PORT = Number(process.env.EO_AMQP_PORT || 5672);
const HOST = process.env.EO_AMQP_HOST || '127.0.0.1';

const queues = new Map(); // address -> { messages: [], receivers: Set<Sender> }
const topics = new Map(); // address -> Set<Sender>

function getQueue(addr) {
  if (!queues.has(addr)) queues.set(addr, { messages: [], receivers: new Set(), rr: 0 });
  return queues.get(addr);
}

function getTopic(addr) {
  if (!topics.has(addr)) topics.set(addr, new Set());
  return topics.get(addr);
}

function isTopic(addr, caps) {
  if (typeof addr === 'string' && addr.startsWith('topic://')) return true;
  if (Array.isArray(caps) && caps.includes('topic')) return true;
  return false;
}

function dispatchQueue(addr) {
  const q = getQueue(addr);
  if (q.messages.length === 0 || q.receivers.size === 0) return;
  const list = Array.from(q.receivers);
  while (q.messages.length > 0) {
    let sent = false;
    for (let i = 0; i < list.length; i++) {
      const idx = (q.rr + i) % list.length;
      const s = list[idx];
      if (s.is_open() && s.sendable()) {
        const msg = q.messages.shift();
        s.send({ durable: true, body: msg.body });
        q.rr = (idx + 1) % list.length;
        sent = true;
        break;
      }
    }
    if (!sent) break;
  }
}

const container = rhea.create_container({ id: 'eo-local-amqp-broker' });

container.on('receiver_open', (context) => {
  const recv = context.receiver;
  const addr = (recv.remote && recv.remote.attach && recv.remote.attach.target && recv.remote.attach.target.address) || '';
  const caps = recv.remote && recv.remote.attach && recv.remote.attach.target && recv.remote.attach.target.capabilities;
  recv._eo_addr = addr;
  recv._eo_is_topic = isTopic(addr, caps);
});

container.on('message', (context) => {
  const recv = context.receiver;
  const addr = recv._eo_addr || '';
  const msg = context.message;
  context.delivery.accept();

  if (recv._eo_is_topic) {
    for (const s of getTopic(addr)) {
      if (s.is_open() && s.sendable()) {
        s.send({ durable: true, body: msg.body });
      }
    }
    return;
  }

  if (addr.includes('ds.delayed') && msg.ttl > 0) {
    setTimeout(() => {
      const dlqAddr = 'queue://ActiveMQ.DLQ';
      getQueue(dlqAddr).messages.push({ body: msg.body });
      dispatchQueue(dlqAddr);
    }, msg.ttl);
    return;
  }

  getQueue(addr).messages.push({ body: msg.body });
  dispatchQueue(addr);
});

container.on('sender_open', (context) => {
  const sender = context.sender;
  const src = sender.remote && sender.remote.attach && sender.remote.attach.source;
  const addr = (src && src.address) || '';
  const caps = src && src.capabilities;
  sender._eo_addr = addr;
  sender._eo_is_topic = isTopic(addr, caps);
  if (sender._eo_is_topic) {
    getTopic(addr).add(sender);
  } else {
    getQueue(addr).receivers.add(sender);
  }
});

container.on('sendable', (context) => {
  const sender = context.sender;
  if (!sender._eo_is_topic && sender._eo_addr) {
    dispatchQueue(sender._eo_addr);
  }
});

function cleanupSender(sender) {
  if (!sender || !sender._eo_addr) return;
  if (sender._eo_is_topic) {
    getTopic(sender._eo_addr).delete(sender);
  } else {
    getQueue(sender._eo_addr).receivers.delete(sender);
  }
}

container.on('sender_close', (ctx) => cleanupSender(ctx.sender));
container.on('connection_close', (ctx) => {
  for (const [, q] of queues) {
    for (const s of q.receivers) if (s.connection === ctx.connection) q.receivers.delete(s);
  }
  for (const [, set] of topics) {
    for (const s of set) if (s.connection === ctx.connection) set.delete(s);
  }
});
container.on('disconnected', (ctx) => {
  for (const [, q] of queues) {
    for (const s of q.receivers) if (s.connection === ctx.connection) q.receivers.delete(s);
  }
  for (const [, set] of topics) {
    for (const s of set) if (s.connection === ctx.connection) set.delete(s);
  }
});

const server = container.listen({ port: PORT, host: HOST });
server.on('listening', () => {
  console.log(`[amqp-broker] listening on amqp://${HOST}:${PORT}`);
});
process.on('SIGTERM', () => { server.close(); process.exit(0); });
process.on('SIGINT', () => { server.close(); process.exit(0); });
