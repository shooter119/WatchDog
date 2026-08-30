const { test } = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const zlib = require('node:zlib');

const { transcribe, openStreamingSession, __test } = require('../src/asr');

const MT_SERVER_RESPONSE = 9;
const MT_ERROR = 15;
const JSON_SER = 1;
const NO_COMPRESSION = 0;

function serverFrame(messageType, body, flags = 2) {
  const json = Buffer.from(JSON.stringify(body), 'utf8');
  const size = Buffer.alloc(4);
  size.writeUInt32BE(json.length, 0);
  const sequence = Buffer.alloc(4);
  sequence.writeInt32BE(1, 0);
  const payload = Buffer.concat([
    flags & 0x01 ? sequence : Buffer.alloc(0),
    size,
    json,
  ]);
  return Buffer.concat([
    __test.buildHeader(messageType, flags, JSON_SER, NO_COMPRESSION),
    payload,
  ]);
}

class FakeWebSocket extends EventEmitter {
  constructor(url, options, behavior) {
    super();
    this.url = url;
    this.options = options;
    this.behavior = behavior;
    this.sent = [];
    this.closed = false;
    this.readyState = 1;
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
    this.readyState = 3;
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
  assert.equal(socket.options.headers['X-Api-App-Key'], 'app-id');
  assert.equal(socket.options.headers['X-Api-Access-Key'], 'access-token');
  assert.equal(socket.options.headers['X-Api-Key'], undefined);
  assert.equal(__test.parseFrame(socket.sent[0]).messageType, 1);
  assert.ok(socket.sent.length >= 3, '应至少包含初始化帧、音频帧和结束帧');
  const last = __test.parseFrame(socket.sent.at(-1));
  assert.equal(last.messageType, 2);
  assert.equal(last.isLast, true);
  assert.equal(socket.closed, true);
});

test('ASR 新版控制台无 Access Token 时使用 X-Api-Key', async () => {
  const instances = [];
  const response = serverFrame(MT_SERVER_RESPONSE, { code: 1000, result: { text: '测试' } });
  await transcribe({
    appId: 'app-key',
    audioBuffer: Buffer.alloc(100),
    timeoutMs: 1000,
    wsFactory: socketFactory({ response }, instances),
  });
  const headers = instances[0].options.headers;
  assert.equal(headers['X-Api-Key'], 'app-key');
  assert.equal(headers['X-Api-App-Key'], undefined);
  assert.equal(headers['X-Api-Access-Key'], undefined);
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

test('ASR 双向流式会话转发初始化、PCM，并交付 partial/final', async () => {
  const instances = [];
  const partial = serverFrame(MT_SERVER_RESPONSE, {
    code: 1000,
    result: { text: '张伟', utterances: [{ text: '张伟', definite: false }] },
  }, 0);
  const final = serverFrame(MT_SERVER_RESPONSE, {
    code: 1000,
    result: { text: '张伟进场', utterances: [{ text: '张伟进场', definite: true }] },
  }, 3);
  const events = [];
  const wsFactory = (url, options) => {
    const socket = new FakeWebSocket(url, options, {});
    instances.push(socket);
    queueMicrotask(() => socket.emit('message', partial));
    setTimeout(() => socket.emit('message', final), 2);
    return socket;
  };
  const session = openStreamingSession({
    appId: 'app-id',
    audioBuffer: Buffer.alloc(0),
    hotwords: ['张伟', '气瓶'],
    wsFactory,
    wsUrl: 'wss://fake.example.test/async',
    onResult: (result) => events.push(result),
  });
  await session.ready;
  session.sendAudio(Buffer.alloc(3200));
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.deepEqual(events.map((item) => [item.text, item.final]), [['张伟', false], ['张伟进场', true]]);
  const init = __test.parseFrame(instances[0].sent[0]);
  assert.equal(init.messageType, 1);
  const initJson = JSON.parse(zlib.gunzipSync(instances[0].sent[0].subarray(8)).toString('utf8'));
  assert.equal(initJson.request.enable_nostream, undefined);
  assert.equal(initJson.request.enable_nonstream, true);
  assert.equal(initJson.request.corpus.context.includes('张伟'), true);
  // 音频是二进制序列，serialization 必须为 0；只对音频内容做 gzip。
  assert.equal(instances[0].sent[1][2], 0x01);
  assert.equal(instances[0].sent[1][1], 0x20);
});
