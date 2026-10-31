// media.js 纯逻辑单测（不依赖浏览器 / Tauri）
// 用法：node scripts/media-policy.test.mjs
import assert from 'node:assert/strict';
import {
  describeMediaState,
  emptyMediaState,
  guessTrackKind,
  makeMediaReq,
  makeMediaState,
  makeTrackAnnounce,
  mediaErrorReason,
  mergeTrack,
  normalizeMediaPolicy,
  parseMediaState,
  permissionHint,
  reasonText,
  trackKindMap,
} from '../windows/src/media.js';

let pass = 0;
function ok(name, fn) {
  try {
    fn();
    pass++;
    console.log(`  ✓ ${name}`);
  } catch (e) {
    console.log(`  ✗ ${name} — ${e.message}`);
    process.exitCode = 1;
  }
}

console.log('\n[1] 政策归一化');
ok('null → 全关', () => assert.deepEqual(normalizeMediaPolicy(null), { mic: false, camera: false }));
ok('会话格式 {mic,camera}', () =>
  assert.deepEqual(normalizeMediaPolicy({ mic: true, camera: false }), { mic: true, camera: false }));
ok('设备列表格式 {mic_enabled,camera_enabled}', () =>
  assert.deepEqual(normalizeMediaPolicy({ mic_enabled: true, camera_enabled: true }), {
    mic: true,
    camera: true,
  }));
ok('脏值只认 true', () =>
  assert.deepEqual(normalizeMediaPolicy({ mic: 'true', camera: 1 }), { mic: false, camera: false }));

console.log('\n[2] 状态解析');
ok('初始状态只带政策位', () =>
  assert.deepEqual(emptyMediaState({ mic: true }), {
    mic: true,
    camera: false,
    micOn: false,
    camOn: false,
    reason: '',
  }));
ok('media_state 解析下划线字段', () => {
  const s = parseMediaState({ t: 'media_state', mic: true, camera: false, mic_on: true, cam_on: false, reason: '' });
  assert.equal(s.micOn, true);
  assert.equal(s.camOn, false);
});
ok('非法消息保留上次状态', () => {
  const prev = { mic: true, camera: true, micOn: true, camOn: true, reason: '' };
  assert.deepEqual(parseMediaState({ t: 'screen' }, prev), prev);
});
ok('失败原因透传', () => {
  const s = parseMediaState({ t: 'media_state', mic: false, camera: false, mic_on: false, cam_on: false, reason: 'busy' });
  assert.equal(s.reason, 'busy');
});

console.log('\n[3] 消息构造');
ok('media_req 字段名正确', () =>
  assert.deepEqual(makeMediaReq({ mic: true, camera: false }), { t: 'media_req', mic: true, camera: false }));
ok('media_state 输出 snake_case', () =>
  assert.deepEqual(makeMediaState({ mic: true, camera: true, micOn: true, camOn: false, reason: 'no_device' }), {
    t: 'media_state',
    mic: true,
    camera: true,
    mic_on: true,
    cam_on: false,
    reason: 'no_device',
  }));
ok('track 通告只允许 mic/camera', () =>
  assert.deepEqual(makeTrackAnnounce('weird', 12), { t: 'media_track', kind: 'mic', id: '12' }));

console.log('\n[4] 错误映射');
ok('NotAllowedError → permission_denied', () =>
  assert.equal(mediaErrorReason({ name: 'NotAllowedError' }), 'permission_denied'));
ok('NotFoundError → no_device', () => assert.equal(mediaErrorReason({ name: 'NotFoundError' }), 'no_device'));
ok('NotReadableError → busy', () => assert.equal(mediaErrorReason({ name: 'NotReadableError' }), 'busy'));
ok('未知错误 → unsupported', () => assert.equal(mediaErrorReason(new Error('boom')), 'unsupported'));
ok('permission_denied 提示可跳设置', () => {
  const h = permissionHint('mic', { name: 'NotAllowedError' });
  assert.equal(h.canOpenSettings, true);
  assert.equal(h.what, '麦克风');
  assert.ok(h.text.includes('麦克风'));
});
ok('no_device 不需要跳设置', () => {
  const h = permissionHint('camera', { name: 'NotFoundError' });
  assert.equal(h.canOpenSettings, false);
  assert.ok(h.text.includes('摄像头'));
});

console.log('\n[5] 文案');
ok('reason 文案', () => assert.equal(reasonText('policy_off'), '被控端已在设置里关闭该权限'));
ok('未知 reason 仍可读', () => assert.ok(reasonText('something').includes('something')));
ok('空 reason 返回空串', () => assert.equal(reasonText(''), ''));
ok('状态摘要含三要素', () => {
  const t = describeMediaState({ mic: true, camera: false, micOn: true, camOn: false, reason: '' });
  assert.ok(t.includes('麦克风 已开'));
  assert.ok(t.includes('摄像头 已关闭权限'));
});

console.log('\n[6] 轨道管理');
ok('mergeTrack 去重', () => {
  const added = [];
  const stream = { getTracks: () => added.slice(), addTrack: (t) => added.push(t) };
  const track = { id: 'a' };
  mergeTrack(stream, track);
  mergeTrack(stream, track);
  assert.equal(added.length, 1);
});
ok('media_track 映射 camera', () => {
  const map = trackKindMap({}, { t: 'media_track', kind: 'camera', id: 'tid-1' });
  assert.equal(map['tid-1'], 'camera');
});
ok('缺通告时按 id 前缀兜底', () => {
  assert.equal(guessTrackKind('camera0', 'video'), 'camera');
  assert.equal(guessTrackKind('abc', 'audio'), 'mic');
  assert.equal(guessTrackKind('abc', 'video'), 'screen');
});

console.log(pass > 0 ? `\n全部通过，共 ${pass} 项 ✅` : '');
