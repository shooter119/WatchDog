const { test } = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');

const { transcribe, __test } = require('../src/asr');

const MT_SERVER_RESPONSE = 9;
const MT_ERROR = 15;
const JSON_SER = 1;
const NO_COMPRESSION = 0;

function serverFrame(messageType, body, flags = 2) {
  const json = Buffer.from(JSON.stringify(body), 'utf8');
  const size = Buffer.alloc(4);
  size.writeUInt32BE(json.length, 0);
  let payload = Buffer.concat([size, json]);
  if (messageType === MT_ERROR) {
    const code = Buffer.alloc(4);
    code.writeUInt32BE(401, 0);
    payload = Buffer.concat([code, payload]);
  }
  return __test.buildFrame(
    __test.buildHeader(messageType, flags, JSON_SER, NO_COMPRESSION),
    payload,
  );
}

class FakeWebSocket extends EventEmitter {
  constructor(url, options, behavior) {
    super();
    this.url = url;
    this.options = options;
    this.behavior = behavior;
    this.sent = [];
    this.closed = false;
    queueMicrotask(() => {
      if (this.behavior.openError) {
        this.emit('error', new Error(this.behavior.openError));
        return;
      }
      if (!this.behavior.neverOpen) this.emit('open');
      if (this.behavior.response) {
        setTimeout(() => this.emit('message', this.behavior.response), 0);
      }
    });
  }

  send(payload, callback) {
    this.sent.push(Buffer.from(payload));
    if (callback) callback(this.behavior.sendError ? new Error(this.behavior.sendError) : undefined);
  }

  close() {
    this.closed = true;
    this.emit('close');
  }
}

function socketFactory(behavior, instances) {
  return (url, options) => {
    const socket = new FakeWebSocket(url, options, behavior);
    instances.push(socket);
    return socket;
  };
}

test('ASR 成功链路发送初始化帧、音频帧和最终结束帧', async () => {
  const instances = [];
  const response = serverFrame(MT_SERVER_RESPONSE, { code: 1000, result: { text: '张伟，20兆帕' } });
  const text = await transcribe({
    appId: 'app-id',
    accessToken: 'access-token',
    audioBuffer: Buffer.alloc(1600),
    timeoutMs: 1000,
    wsUrl: 'wss://fake.example.test/asr',
    wsFactory: socketFactory({ response }, instances),
  });

  assert.equal(text, '张伟，20兆帕');
  assert.equal(instances.length, 1);
  const socket = instances[0];
  assert.equal(socket.url, 'wss://fake.example.test/asr');
  assert.equal(socket.options.headers['X-Api-Key'], 'app-id');
  assert.equal(socket.options.headers['X-Api-Access-Key'], 'access-token');
  assert.equal(__test.parseFrame(socket.sent[0]).messageType, 1);
  assert.ok(socket.sent.length >= 3, '应至少包含初始化帧、音频帧和结束帧');
  const last = __test.parseFrame(socket.sent.at(-1));
  assert.equal(last.messageType, 2);
  assert.equal(last.isLast, true);
  assert.equal(socket.closed, true);
});

test('ASR 服务端错误帧转换为可识别错误', async () => {
  const instances = [];
  await assert.rejects(
    transcribe({
      appId: 'app-id',
      audioBuffer: Buffer.alloc(100),
      timeoutMs: 1000,
      wsFactory: socketFactory({ response: serverFrame(MT_ERROR, { message: 'invalid audio' }) }, instances),
    }),
    /ASR 服务端错误/,
  );
  assert.equal(instances[0].closed, true);
});

test('ASR 最终响应没有文本时返回 422 业务错误', async () => {
  await assert.rejects(
    transcribe({
      appId: 'app-id',
      audioBuffer: Buffer.alloc(100),
      timeoutMs: 1000,
      wsFactory: socketFactory({ response: serverFrame(MT_SERVER_RESPONSE, { code: 1000, result: { text: '' } }) }, []),
    }),
    (error) => error.status === 422 && /未听清/.test(error.message),
  );
});

test('ASR WebSocket 连接错误不会挂起请求', async () => {
  await assert.rejects(
    transcribe({
      appId: 'app-id',
      audioBuffer: Buffer.alloc(100),
      timeoutMs: 1000,
      wsFactory: socketFactory({ openError: 'socket unavailable' }, []),
    }),
    /ASR 连接失败: socket unavailable/,
  );
});

test('ASR 连接迟迟未建立时按超时失败并关闭连接', async () => {
  const instances = [];
  await assert.rejects(
    transcribe({
      appId: 'app-id',
      audioBuffer: Buffer.alloc(100),
      timeoutMs: 5,
      wsFactory: socketFactory({ neverOpen: true }, instances),
    }),
    /ASR 识别超时/,
  );
  assert.equal(instances[0].closed, true);
});

test('ASR WebSocket 工厂同步抛错时仍返回失败 Promise', async () => {
  await assert.rejects(
    transcribe({
      appId: 'app-id',
      audioBuffer: Buffer.alloc(100),
      wsFactory: () => { throw new Error('factory failed'); },
    }),
    /factory failed/,
  );
});
