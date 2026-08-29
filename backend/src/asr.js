const { WebSocket } = require('ws');
const crypto = require('crypto');
const zlib = require('zlib');

const DEFAULT_RESOURCE_ID = 'volc.bigasr.sauc.duration';
const ASR_WS_URL = 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream';
const ASR_STREAM_WS_URL = 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async';

const MT_FULL_CLIENT_REQUEST = 1;
const MT_AUDIO_ONLY = 2;
const MT_SERVER_RESPONSE = 9;
const MT_ACK = 11;
const MT_ERROR = 15;

const GZIP = 1;
const NO_COMPRESSION = 0;
const JSON_SER = 1;

// 请求 flags
const NO_SEQUENCE = 0;
const NEG_SEQUENCE = 2; // LAST 包：不带 sequence 的结束包

function buildHeader(messageType, flags, serialization, compression) {
  const buf = Buffer.alloc(4);
  buf[0] = 0x11; // protocol_version=1, header_size=1(4字节)
  buf[1] = (messageType << 4) | flags;
  buf[2] = (serialization << 4) | compression;
  buf[3] = 0;
  return buf;
}

function buildFrame(header, payload) {
  const size = Buffer.alloc(4);
  size.writeUInt32BE(payload.length, 0);
  return Buffer.concat([header, size, payload]);
}

/**
 * 服务端响应帧解析（对齐官方 volcengine-asr-sdk 的 parse_response）：
 * payload = [sequence 4B（flags&1 时有）][size 4B][JSON]
 * - FULL_SERVER_RESPONSE(9):   size 在 payload[0:4]，JSON 在 [4:]
 * - SERVER_ACK(11):            sequence[0:4], size[4:8], JSON[8:]
 * - SERVER_ERROR_RESPONSE(15): code[0:4], size[4:8], JSON[8:]
 * 每帧的 JSON 是完整快照（无需跨帧拼接），LAST 帧（flags&2）即最终结果。
 */
function parseFrame(buf) {
  const headerSize = buf[0] & 0x0f;
  const messageType = (buf[1] >> 4) & 0x0f;
  const flags = buf[1] & 0x0f;
  const serialization = (buf[2] >> 4) & 0x0f;
  const compression = buf[2] & 0x0f;
  // 每个协议帧都在消息头后带一个 4 字节的外层 payload 长度。
  // 服务端响应的 payload 内部还会再带业务 JSON 长度；必须先跳过外层长度，
  // 否则外层长度会被误当成业务长度，合法响应最终会变成“响应为空”。
  const payloadOffset = headerSize * 4;
  if (buf.length < payloadOffset + 4) {
    return { messageType, flags, isLast: (flags & 2) !== 0 };
  }
  const framePayloadSize = buf.readUInt32BE(payloadOffset);
  const payloadStart = payloadOffset + 4;
  const payloadEnd = payloadStart + framePayloadSize;
  if (payloadEnd > buf.length) {
    return { messageType, flags, isLast: (flags & 2) !== 0, truncated: true };
  }
  let payload = buf.subarray(payloadStart, payloadEnd);
  const out = { messageType, flags, isLast: (flags & 2) !== 0 };
  if (flags & 0x01) {
    out.sequence = payload.length >= 4 ? payload.readInt32BE(0) : undefined;
    payload = payload.subarray(4);
  }
  let jsonBytes = null;
  if (messageType === MT_SERVER_RESPONSE && payload.length >= 4) {
    out.size = payload.readInt32BE(0);
    jsonBytes = payload.subarray(4);
  } else if (messageType === MT_ACK && payload.length >= 8) {
    out.sequence = payload.readInt32BE(0);
    out.size = payload.readUInt32BE(4);
    jsonBytes = payload.subarray(8);
  } else if (messageType === MT_ERROR && payload.length >= 8) {
    out.code = payload.readUInt32BE(0);
    out.size = payload.readUInt32BE(4);
    jsonBytes = payload.subarray(8);
  }
  if (jsonBytes && jsonBytes.length > 0) {
    if (compression === GZIP) {
      try { jsonBytes = zlib.gunzipSync(jsonBytes); } catch (e) { jsonBytes = null; }
    }
    if (jsonBytes && serialization === JSON_SER) {
      try { out.json = JSON.parse(jsonBytes.toString('utf8')); } catch (e) { out.json = null; }
    }
  }
  return out;
}

function buildFullClientRequest({ appId, accessToken, uid, format, rate, bits, channel, hotwords }) {
  const request = {
    user: {
      uid: uid || 'watchdog',
    },
    audio: {
      format,
      codec: 'raw',
      rate,
      bits,
      channel,
      language: 'zh-CN',
    },
    request: {
      model_name: 'bigmodel',
      enable_itn: true,
      enable_punc: true,
      enable_ddc: true,
      enable_nostream: true,
      vad_segment_duration: 3000,
      end_window_size: 800,
      force_to_speech_time: 10000,
      result_type: 'full',
      show_utterances: false,
    },
  };
  if (hotwords && hotwords.length > 0) {
    const words = hotwords.slice(0, 5000).map((w) => ({ word: String(w).trim() })).filter((w) => w.word);
    if (words.length > 0) {
      request.request.corpus = {
        context: JSON.stringify({ hotwords: words }),
      };
    }
  }
  return request;
}

function buildStreamingClientRequest({ appId, accessToken, uid, format, rate, bits, channel, hotwords }) {
  const request = buildFullClientRequest({ appId, accessToken, uid, format, rate, bits, channel, hotwords });
  request.audio.format = format || 'pcm';
  request.request.enable_nostream = false;
  request.request.model_name = 'bigmodel';
  // async 是双向流式优化版本：服务端仅在识别结果变化时返回新快照。
  request.request.result_type = 'full';
  request.request.show_utterances = true;
  return request;
}

/**
 * 打开一条双向流式 ASR 会话。调用方按实时节奏传入 PCM，结果通过 onResult
 * 回调返回；回调中的 text 是当前完整识别快照，不是增量字符串。
 */
function openStreamingSession({
  appId,
  accessToken,
  resourceId,
  format = 'pcm',
  rate = 16000,
  bits = 16,
  channel = 1,
  hotwords = [],
  timeoutMs = 70000,
  wsFactory = defaultWebSocketFactory,
  wsUrl = ASR_STREAM_WS_URL,
  onResult = () => {},
  onReady = () => {},
  onError = () => {},
  onClose = () => {},
}) {
  const reqid = crypto.randomUUID();
  const connectId = crypto.randomUUID();
  const headers = {
    'X-Api-Key': appId,
    'X-Api-Resource-Id': resourceId || DEFAULT_RESOURCE_ID,
    'X-Api-Request-Id': reqid,
    'X-Api-Sequence': '-1',
    'X-Api-Connect-Id': connectId,
  };
  if (accessToken) headers['X-Api-Access-Key'] = accessToken;

  let ws;
  let ended = false;
  let initialized = false;
  let lastJson = null;
  let timer;
  const ready = new Promise((resolve, reject) => {
    const fail = (error) => {
      if (ended) return;
      ended = true;
      clearTimeout(timer);
      try { ws?.close(); } catch {}
      try { onError(error); } catch {}
      reject(error);
    };
    try {
      ws = wsFactory(wsUrl, { headers, handshakeTimeout: 10000 });
    } catch (error) {
      fail(error);
      return;
    }
    timer = setTimeout(() => fail(new Error('ASR 实时会话超时')), timeoutMs);
    ws.on('open', () => {
      const payload = Buffer.from(JSON.stringify(buildStreamingClientRequest({
        appId, accessToken, uid: 'watchdog', format, rate, bits, channel, hotwords,
      })), 'utf8');
      ws.send(buildFrame(buildHeader(MT_FULL_CLIENT_REQUEST, NO_SEQUENCE, JSON_SER, GZIP), zlib.gzipSync(payload)), (error) => {
        if (error) fail(error);
      });
      initialized = true;
      try { onReady(); } catch {}
      resolve(session);
    });
    ws.on('message', (data) => {
      try {
        const frame = parseFrame(Buffer.from(data));
        if (frame.messageType === MT_ERROR) throw new Error('ASR 服务端错误');
        if (frame.messageType !== MT_SERVER_RESPONSE || !frame.json) return;
        lastJson = frame.json;
        const code = frame.json.code ?? frame.json.message?.code;
        if (code !== undefined && code !== 1000) throw new Error(`ASR 错误码 ${code}`);
        const result = frame.json.result;
        const utterances = Array.isArray(result?.utterances) ? result.utterances : [];
        const text = typeof result?.text === 'string'
          ? result.text
          : utterances.map((item) => item.text || '').join('');
        if (text) onResult({
          text: text.trim(),
          sequence: frame.sequence,
          final: Boolean(frame.isLast || utterances.some((item) => item.definite === true)),
          raw: frame.json,
        });
        if (frame.isLast) end();
      } catch (error) {
        fail(error);
      }
    });
    ws.on('error', fail);
    ws.on('close', () => {
      if (!ended) {
        ended = true;
        clearTimeout(timer);
        try { onClose(); } catch {}
      }
    });
  });

  const session = {
    ready,
    get initialized() { return initialized; },
    sendAudio(audio) {
      if (ended || !ws || ws.readyState !== ws.OPEN) throw new Error('ASR 实时会话未连接');
      const bytes = Buffer.from(audio);
      if (bytes.length === 0) return;
      ws.send(buildFrame(buildHeader(MT_AUDIO_ONLY, NO_SEQUENCE, JSON_SER, GZIP), zlib.gzipSync(bytes)));
    },
    end() {
      if (ended || !ws || ws.readyState !== ws.OPEN) return;
      ws.send(buildFrame(buildHeader(MT_AUDIO_ONLY, NEG_SEQUENCE, JSON_SER, NO_COMPRESSION), Buffer.alloc(0)));
    },
    close() {
      if (ended) return;
      ended = true;
      clearTimeout(timer);
      try { ws?.close(); } catch {}
    },
  };
  return session;
}

/**
 * 一句话转写：上传完整音频，等待 nostream 流式识别结果。
 * 音频格式支持 wav/pcm/mp3/ogg（不支持 m4a/aac，App 端录音需为 wav/pcm）。
 * 分包规则：音频按 100~200ms 分包发送（带正 sequence），最后发一个空 LAST 包
 * （flags=NEG_WITH_SEQUENCE + sequence 取负 + 不压缩）。
 */
const defaultWebSocketFactory = (url, options) => new WebSocket(url, options);

function transcribe({
  appId,
  accessToken,
  resourceId,
  audioBuffer,
  format = 'wav',
  rate = 16000,
  bits = 16,
  channel = 1,
  hotwords = [],
  timeoutMs = 25000,
  wsFactory = defaultWebSocketFactory,
  wsUrl = ASR_WS_URL,
}) {
  return new Promise((resolve, reject) => {
    const reqid = crypto.randomUUID();
    const connectId = crypto.randomUUID();
    const headers = {
      'X-Api-Key': appId,
      'X-Api-Resource-Id': resourceId || DEFAULT_RESOURCE_ID,
      'X-Api-Request-Id': reqid,
      'X-Api-Sequence': '-1',
      'X-Api-Connect-Id': connectId,
    };
    if (accessToken) headers['X-Api-Access-Key'] = accessToken;

    let ws;
    let settled = false;
    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        try { ws.close(); } catch {}
        reject(new Error('ASR 识别超时'));
      }
    }, timeoutMs);

    const finish = (err, text) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { ws.close(); } catch {}
      if (err) reject(err);
      else resolve(text);
    };

    try {
      ws = wsFactory(wsUrl, { headers, handshakeTimeout: 10000 });
    } catch (e) {
      return finish(e);
    }

    ws.on('open', () => {
      const clientReq = buildFullClientRequest({
        appId,
        accessToken,
        uid: 'watchdog',
        format,
        rate,
        bits,
        channel,
        hotwords,
      });
      const jsonPayload = Buffer.from(JSON.stringify(clientReq), 'utf8');
      const gzPayload = zlib.gzipSync(jsonPayload);
      const header = buildHeader(MT_FULL_CLIENT_REQUEST, NO_SEQUENCE, JSON_SER, GZIP);
      ws.send(buildFrame(header, gzPayload));

      // 音频分包发送（每包 200ms），最后发空 LAST 包（flags=NEG_SEQUENCE）
      // 不再人为限速（旧实现每 100ms 发一包，3 秒语音要 1.5 秒纯发送），
      // 改为连续发送；仅当 ws 缓冲过大（大文件/弱网）时才让出事件循环。
      const chunkBytes = Math.max(1, Math.round((rate * bits / 8) * channel * 0.2));
      const frames = [];
      for (let offset = 0; offset < audioBuffer.length; offset += chunkBytes) {
        const end = Math.min(offset + chunkBytes, audioBuffer.length);
        frames.push(buildFrame(buildHeader(MT_AUDIO_ONLY, NO_SEQUENCE, JSON_SER, GZIP), zlib.gzipSync(audioBuffer.subarray(offset, end))));
      }
      frames.push(buildFrame(buildHeader(MT_AUDIO_ONLY, NEG_SEQUENCE, JSON_SER, NO_COMPRESSION), Buffer.alloc(0)));
      const sendAll = (i) => {
        if (settled) return;
        if (i >= frames.length) return;
        ws.send(frames[i], (err) => {
          if (err) { finish(err); return; }
          if (ws.bufferedAmount > 512 * 1024) setTimeout(() => sendAll(i + 1), 10);
          else sendAll(i + 1);
        });
      };
      sendAll(0);
    });

    let lastJson = null;
    let lastError = null;
    ws.on('message', (data) => {
      try {
        const frame = parseFrame(Buffer.from(data));
        if (frame.messageType === MT_ERROR) {
          const msg = frame.json ? JSON.stringify(frame.json) : `code=${frame.code}`;
          finish(new Error('ASR 服务端错误: ' + msg));
          return;
        }
        if (frame.messageType !== MT_SERVER_RESPONSE) return;
        if (frame.json) lastJson = frame.json;
        if (!frame.isLast) return;
        const obj = lastJson;
        if (!obj) {
          finish(new Error('ASR 响应为空'));
          return;
        }
        const code = obj.code ?? obj.message?.code;
        if (code !== undefined && code !== 1000) {
          finish(new Error(`ASR 错误码 ${code}: ${obj.message?.message || obj.message || ''}`));
          return;
        }
        // v3 nostream 响应结构：{audio_info:{duration}, result:{text}}
        // 兜底兼容 message.result[].text 结构
        const directText = typeof obj.result === 'object' && obj.result !== null ? obj.result.text : '';
        const results = Array.isArray(obj.message?.result) ? obj.message.result : Array.isArray(obj.result) ? obj.result : [];
        const texts = [directText, ...results.map((r) => r.text || '')].filter(Boolean).join('');
        if (texts) finish(null, texts.trim());
        else finish(Object.assign(new Error('未听清，请再说一遍'), { status: 422 }));
      } catch (e) {
        finish(e);
      }
    });

    ws.on('error', (e) => finish(new Error('ASR 连接失败: ' + e.message)));
    ws.on('close', () => {
      if (!settled) finish(new Error('ASR 连接意外关闭'));
    });
  });
}

module.exports = {
  transcribe,
  openStreamingSession,
  // 仅供本地协议回归使用；业务调用仍只依赖 transcribe。
  __test: { buildHeader, buildFrame, parseFrame },
};
