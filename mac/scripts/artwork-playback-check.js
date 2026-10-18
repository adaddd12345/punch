const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const scripts = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
let checks = 0;
function test(name, fn) { fn(); checks++; console.log('PASS ' + name); }
function run(op, overrides = {}) {
  const ranges = overrides.ranges || [[0, 200]];
  const media = {readyState: 4, currentSrc: 'https://example.invalid/media', duration: 200, currentTime: 80,
    paused: false, ended: false, playbackRate: 1, srcObject: null,
    classList: {contains: () => true},
    seekable: {length: ranges.length, start: i => ranges[i][0], end: i => ranges[i][1]},
    pause() { this.paused = true; }, play() { this.paused = false; return Promise.resolve(); },
    ...overrides.media};
  const context = {URL, location: {href: overrides.url || 'https://www.youtube.com/watch?v=abcdefghijk'},
    document: {querySelector: selector => selector === '#movie_player' ? overrides.player || null : overrides.ad || null,
      querySelectorAll: () => overrides.videos || [media]}};
  return {reply: JSON.parse(vm.runInNewContext(scripts[op], context, {timeout: 100})), media};
}
test('Read real position and duration', () => { let {reply} = run('read'); assert.equal(reply.snapshot.position,80); assert.equal(reply.snapshot.duration,200); });
test('Read does not mutate', () => { let {media} = run('read'); assert.equal(media.currentTime,80); assert.equal(media.paused,false); });
test('Pause selected media', () => assert.equal(run('toggle').media.paused,true));
test('Play selected media', () => assert.equal(run('toggle',{media:{paused:true}}).media.paused,false));
test('Back exactly ten seconds', () => assert.equal(run('previous').media.currentTime,70));
test('Forward exactly ten seconds', () => assert.equal(run('next').media.currentTime,90));
test('Seek clamps duration', () => assert.equal(run('seek').media.currentTime,200));
test('Back clamps start', () => assert.equal(run('previous',{media:{currentTime:3}}).media.currentTime,0));
test('Forward clamps end', () => assert.equal(run('next',{media:{currentTime:198}}).media.currentTime,200));
test('Gap chooses nearest valid edge', () => assert.equal(run('previous',{ranges:[[0,50],[100,200]],media:{currentTime:80}}).media.currentTime,50));
test('DVR start respected', () => assert.equal(run('previous',{ranges:[[70,200]],media:{currentTime:75}}).media.currentTime,70));
test('Changed video never mutates', () => { let r=run('toggle',{url:'https://www.youtube.com/watch?v=xxxxxxxxxxx'}); assert.equal(r.reply.error,'changed'); assert.equal(r.media.paused,false); });
test('Non YouTube rejected', () => assert.equal(run('toggle',{url:'https://example.com/watch?v=abcdefghijk'}).reply.error,'changed'));
test('HTTP rejected', () => assert.equal(run('toggle',{url:'http://www.youtube.com/watch?v=abcdefghijk'}).reply.error,'changed'));
test('Ad rejected', () => { let r=run('next',{ad:{}}); assert.equal(r.reply.error,'ad'); assert.equal(r.media.currentTime,80); });
test('No media rejected', () => assert.equal(run('toggle',{videos:[]}).reply.error,'noMedia'));
test('Ambiguous media rejected', () => { const v={readyState:4,currentSrc:'x',classList:{contains:()=>true}}; assert.equal(run('toggle',{videos:[v,v]}).reply.error,'ambiguous'); });
test('Live has play but no seeking', () => {let r=run('read',{media:{duration:Infinity}}).reply.snapshot; assert.equal(r.canToggle,true); assert.equal(r.canSeek,false); assert.equal(r.duration,0); });
test('Live back is no-op', () => assert.equal(run('previous',{media:{duration:Infinity}}).media.currentTime,80));
test('No seekable ranges disables seek', () => assert.equal(run('read',{ranges:[]}).reply.snapshot.canSeek,false));
test('Media stream disables seek', () => assert.equal(run('read',{media:{srcObject:{}}}).reply.snapshot.canSeek,false));
test('Shorts exact identity supported', () => assert.equal(run('read',{url:'https://www.youtube.com/shorts/abcdefghijk'}).reply.snapshot.trackID,'abcdefghijk'));
test('Music YouTube supported', () => assert.equal(run('read',{url:'https://music.youtube.com/watch?v=abcdefghijk'}).reply.snapshot.trackID,'abcdefghijk'));
test('Negative seek rejected', () => assert.equal(run('negative').reply.error,'invalid'));
test('NaN seek rejected', () => assert.equal(run('nan').reply.error,'invalid'));
test('Playback rate retained', () => assert.equal(run('read',{media:{playbackRate:1.5}}).reply.snapshot.rate,1.5));
test('SPA stale player identity rejected', () => assert.equal(run('toggle',{player:{getVideoData:()=>({video_id:'xxxxxxxxxxx'})}}).reply.error,'changed'));
test('SPA loading identity rejected', () => assert.equal(run('toggle',{player:{getVideoData:()=>({})}}).reply.error,'noMedia'));
test('Matching player identity accepted', () => assert.equal(run('toggle',{player:{getVideoData:()=>({video_id:'abcdefghijk'})}}).media.paused,true));
console.log(`${checks} transport checks passed`);
