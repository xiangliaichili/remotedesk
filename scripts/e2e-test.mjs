// 服务器端到端集成测试：账号 / 设备 / 信令 / 会话 / 中继转发 / 取消
// 用法： node scripts/e2e-test.mjs http://127.0.0.1:18443
const BASE = process.argv[2] || 'http://127.0.0.1:18443';
const WS = BASE.replace(/^http/, 'ws') + '/ws';

let failures = 0;
function ok(name, cond, extra = '') {
  if (cond) {
    console.log(`  ✓ ${name}`);
  } else {
    failures++;
    console.log(`  ✗ ${name}${extra ? ' — ' + extra : ''}`);
  }
}

async function post(path, body, token) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = 'Bearer ' + token;
  const res = await fetch(BASE + path, {
    method: 'POST',
    headers,
    body: JSON.stringify(body || {}),
  });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* not json */ }
  return { status: res.status, json, text };
}

async function get(path, token) {
  const res = await fetch(BASE + path, { headers: { Authorization: 'Bearer ' + token } });
  return { status: res.status, json: await res.json().catch(() => null) };
}

/** 带消息队列的信令客户端，便于 await 期待的类型。 */
class Client {
  constructor(name) {
    this.name = name;
    this.queue = [];
    this.waiters = [];
    this.ws = null;
    this.authed = false;
  }

  connect(token) {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(WS);
      this.ws = ws;
      const timer = setTimeout(() => reject(new Error(this.name + ' 鉴权超时')), 8000);
      ws.onopen = () => ws.send(JSON.stringify({ type: 'auth', data: token }));
      ws.onmessage = (ev) => {
        const msg = JSON.parse(ev.data);
        if (msg.type === 'auth_ok') {
          this.authed = true;
          clearTimeout(timer);
          resolve();
          return;
        }
        this.push(msg);
      };
      ws.onerror = () => reject(new Error(this.name + ' WebSocket 错误'));
    });
  }

  push(msg) {
    const idx = this.waiters.findIndex((w) => w.type === msg.type);
    if (idx >= 0) {
      const w = this.waiters.splice(idx, 1)[0];
      clearTimeout(w.timer);
      w.resolve(msg);
    } else {
      this.queue.push(msg);
    }
  }

  /** 等待某类型消息，超时返回 null。 */
  wait(type, ms = 5000) {
    const idx = this.queue.findIndex((m) => m.type === type);
    if (idx >= 0) {
      return Promise.resolve(this.queue.splice(idx, 1)[0]);
    }
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        const i = this.waiters.findIndex((w) => w.timer === timer);
        if (i >= 0) this.waiters.splice(i, 1);
        resolve(null);
      }, ms);
      this.waiters.push({ type, resolve, timer });
    });
  }

  send(obj) {
    this.ws.send(JSON.stringify(obj));
  }

  close() {
    try { this.ws.close(); } catch { /* ignore */ }
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const suffix = Math.random().toString(36).slice(2, 8);
  const userA = 'e2e_a_' + suffix;
  const userB = 'e2e_b_' + suffix;
  const pass = 'secret123';

  console.log('\n[1] 注册与设备登录');
  const ra = await post('/api/register', {
    username: userA, password: pass, device_name: '控制端PC', os: 'windows', device_id: 'devA-' + suffix,
  });
  ok('注册控制端账号', ra.status === 200 && !!ra.json.token, ra.text);
  const rb = await post('/api/register', {
    username: userB, password: pass, device_name: '被控端手机', os: 'android', device_id: 'devB-' + suffix,
  });
  ok('注册被控端账号', rb.status === 200 && !!rb.json.token, rb.text);
  const tokenA = ra.json.token;
  const tokenB = rb.json.token;

  // 同一账号第二台设备
  const ra2 = await post('/api/login', {
    username: userA, password: pass, device_name: '控制端手机', os: 'harmonyos', device_id: 'devA2-' + suffix,
  });
  ok('同账号登录第二台设备', ra2.status === 200 && ra2.json.device_id === 'devA2-' + suffix, ra2.text);

  const devsA = await get('/api/devices', tokenA);
  ok('同账号可见两台设备', devsA.json.devices.length === 2,
    JSON.stringify(devsA.json.devices.map((d) => d.name)));

  console.log('\n[2] 密码错误与离线拒绝');
  const bad = await post('/api/login', { username: userA, password: 'wrongpass', device_id: 'x-' + suffix });
  ok('错误密码被拒 401', bad.status === 401);
  const off = await post('/api/session/request', {
    target_device_id: 'devB-' + suffix, auth: { mode: 'same_account' },
  }, tokenB);
  ok('目标离线返回 409', off.status === 409, off.text);

  console.log('\n[3] 建立信令连接');
  const cA = new Client('A');
  const cB = new Client('B');
  await cA.connect(tokenA);
  await cB.connect(tokenB);
  ok('两端信令鉴权通过', cA.authed && cB.authed);
  await sleep(200);

  console.log('\n[4] 账号密码连接（pending → 被控端同意）');
  // A 用自己的 token 用 B 的账号密码控制 B 的设备
  const req1 = await post('/api/session/request', {
    target_device_id: 'devB-' + suffix,
    auth: { mode: 'account', username: userB, password: pass },
  }, tokenA);
  ok('发起账号密码会话 → pending', req1.status === 200 && req1.json.status === 'pending', req1.text);
  const sess1 = req1.json.session_id;

  const reqMsg = await cB.wait('session_req');
  ok('被控端收到 session_req 弹窗消息', !!reqMsg && reqMsg.data.auth_mode === 'account',
    JSON.stringify(reqMsg));
  ok('session_req 携带控制端名称', !!reqMsg && reqMsg.data.controller_name === '控制端PC',
    JSON.stringify(reqMsg && reqMsg.data));

  const acc = await post('/api/session/accept', { session_id: sess1, accept: true }, tokenB);
  ok('被控端同意 → active + turn', acc.status === 200 && acc.json.status === 'active' &&
    Array.isArray(acc.json.turn.urls) && acc.json.turn.urls.length >= 2, acc.text);

  const cstart = await cB.wait('control_start');
  ok('被控端收到 control_start（含 turn，用于弹提示窗）',
    !!cstart && !!cstart.data.turn && cstart.data.controller_name === '控制端PC',
    JSON.stringify(cstart));

  const sok = await cA.wait('session_ok');
  ok('控制端收到 session_ok + turn', !!sok && !!sok.data.turn, JSON.stringify(sok));

  console.log('\n[5] SDP / ICE 中继转发');
  cA.send({ type: 'offer', to: 'devB-' + suffix, session_id: sess1, sdp: 'v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\n' });
  const offer = await cB.wait('offer');
  ok('offer 转发到被控端', !!offer && offer.sdp.startsWith('v=0') && offer.from === 'devA-' + suffix,
    JSON.stringify(offer));

  cB.send({ type: 'answer', to: 'devA-' + suffix, session_id: sess1, sdp: 'v=0\r\nanswer' });
  const ans = await cA.wait('answer');
  ok('answer 转发回控制端', !!ans && ans.sdp === 'v=0\r\nanswer', JSON.stringify(ans));

  cA.send({
    type: 'ice', to: 'devB-' + suffix, session_id: sess1,
    candidate: JSON.stringify({ candidate: 'candidate:1 1 udp 1 10.0.0.1 5000 typ host', sdpMid: '0', sdpMLineIndex: 0 }),
  });
  const ice = await cB.wait('ice');
  ok('ICE 候选转发（JSON 字符串）', !!ice && ice.candidate.includes('candidate:1'), JSON.stringify(ice));

  console.log('\n[6] 任一端取消控制');
  const cancel = await post('/api/session/cancel', { session_id: sess1 }, tokenA);
  ok('控制端取消 → ended', cancel.status === 200 && cancel.json.status === 'ended', cancel.text);
  const endMsg = await cB.wait('control_end');
  ok('被控端收到 control_end', !!endMsg && endMsg.session_id === sess1, JSON.stringify(endMsg));

  console.log('\n[7] 统一连接码（免同意直连）');
  const link = await post('/api/link/create', {}, tokenB);
  ok('被控端生成 8 位连接码', link.status === 200 && /^[A-Z2-9]{8}$/.test(link.json.code), link.text);
  const code = link.json.code;

  const req2 = await post('/api/session/request', { auth: { mode: 'link', link_code: code } }, tokenA);
  ok('用连接码发起 → 直接 active', req2.status === 200 && req2.json.status === 'active', req2.text);
  const sess2 = req2.json.session_id;
  const cstart2 = await cB.wait('control_start');
  ok('被控端仍收到控制提示（免同意也要弹窗）', !!cstart2 && cstart2.session_id === sess2,
    JSON.stringify(cstart2));

  const reuse = await post('/api/session/request', { auth: { mode: 'link', link_code: code } }, tokenA);
  ok('连接码一次性，复用被拒 400', reuse.status === 400, reuse.text);

  console.log('\n[8] 同账号免同意开关（A 账号的 PC 与手机互控）');
  const tokenA2 = ra2.json.token;
  const devA1 = 'devA-' + suffix;
  const devA2 = 'devA2-' + suffix;
  const cA2 = new Client('A2');
  await cA2.connect(tokenA2);
  ok('同账号第二台设备接入信令', cA2.authed);

  const setting = (token, patch) => fetch(BASE + '/api/settings', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token },
    body: JSON.stringify(patch),
  });
  const putRes = await setting(tokenA, {
    auto_accept_same_account: false, mic_enabled: true, camera_enabled: false,
  });
  ok('保存设置 PUT 成功', putRes.status === 200, String(putRes.status));
  const st = await get('/api/settings', tokenA);
  ok('设置已持久化', st.json.auto_accept_same_account === false && st.json.mic_enabled === true,
    JSON.stringify(st.json));

  // 被控端是 devA（PC），控制端是 devA2（手机），同属 A 账号
  const req3 = await post('/api/session/request', {
    target_device_id: devA1, auth: { mode: 'same_account' },
  }, tokenA2);
  ok('同账号免同意关闭 → 需 pending', req3.status === 200 && req3.json.status === 'pending', req3.text);
  const req3msg = await cA.wait('session_req');
  ok('同账号也弹窗请求', !!req3msg && req3msg.data.auth_mode === 'same_account', JSON.stringify(req3msg));
  const deny = await post('/api/session/accept', { session_id: req3.json.session_id, accept: false }, tokenA);
  ok('拒绝 → denied', deny.status === 200 && deny.json.status === 'denied', deny.text);
  const denyMsg = await cA2.wait('session_deny');
  ok('控制端收到 session_deny', !!denyMsg, JSON.stringify(denyMsg));
  const denyEnd = await cA.wait('control_end', 1200);
  ok('拒绝时被控端不会进入控制态（无从 control_start）', denyEnd === null, JSON.stringify(denyEnd));

  console.log('\n[9] 关闭免同意后再开启，免同意即时连接');
  await setting(tokenA, { auto_accept_same_account: true });
  const req4 = await post('/api/session/request', {
    target_device_id: devA1, auth: { mode: 'same_account' },
  }, tokenA2);
  ok('免同意开启 → 直接 active', req4.status === 200 && req4.json.status === 'active', req4.text);
  const cstart4 = await cA.wait('control_start');
  ok('免同意时被控端仍有控制提示', !!cstart4, JSON.stringify(cstart4));
  // 免同意路径下控制器从 HTTP 响应拿到 turn（不额外推送 session_ok，避免与响应重复触发）
  ok('免同意时控制端从响应拿到同一份 turn',
    !!req4.json.turn && !!cstart4 && JSON.stringify(req4.json.turn) === JSON.stringify(cstart4.data.turn),
    JSON.stringify({ resp: req4.json.turn, push: cstart4 && cstart4.data.turn }));
  const dupOk = await cA2.wait('session_ok', 800);
  ok('免同意路径不重复推送 session_ok', dupOk === null, JSON.stringify(dupOk));
  // 被控端随时取消
  const cancel4 = await post('/api/session/cancel', { session_id: req4.json.session_id }, tokenA);
  ok('被控端可随时取消控制', cancel4.status === 200 && cancel4.json.status === 'ended', cancel4.text);
  const end4 = await cA2.wait('control_end');
  ok('取消后控制端收到 control_end', !!end4, JSON.stringify(end4));
  cA2.close();

  console.log('\n[10] 越权与参数校验');
  const notMine = await post('/api/session/request', {
    target_device_id: 'devB-' + suffix, auth: { mode: 'same_account' },
  }, tokenA);
  ok('非同账号设备 → 404/403', notMine.status === 404 || notMine.status === 403, String(notMine.status));
  const shortPw = await post('/api/register', { username: 'abc' + suffix, password: '123' });
  ok('密码过短 → 400', shortPw.status === 400, String(shortPw.status));
  const dup = await post('/api/register', { username: userA, password: pass });
  ok('重复用户名 → 409', dup.status === 409, String(dup.status));

  cA.close();
  cB.close();

  console.log('');
  if (failures === 0) {
    console.log('全部用例通过 ✅');
    process.exit(0);
  } else {
    console.log(`${failures} 个用例失败 ❌`);
    process.exit(1);
  }
}

main().catch((e) => {
  console.error('测试异常：', e);
  process.exit(1);
});