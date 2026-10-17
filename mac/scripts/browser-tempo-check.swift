import Foundation
import JavaScriptCore
import AppKit

@main struct Check {
  static var count = 0
  static func expect(_ ok: @autoclosure () -> Bool, _ name: String) {
    guard ok() else { fatalError(name) }
    count += 1
  }
  static func main() {
    expect(abs(BrowserTempoScript.rate(original: 147, target: 140)! - 140.0 / 147) < 0.000001, "147 to 140")
    expect(BrowserTempoScript.rate(original: .nan, target: 140) == nil, "NaN")
    expect(BrowserTempoScript.rate(original: 0, target: 140) == nil, "zero")
    expect(BrowserTempoScript.rate(original: 140, target: 30) == nil, "unsupported ratio")
    expect(BrowserTempoScript.titleBPM("Type beat • 147 BPM • C minor") == 147, "title BPM")
    expect(BrowserTempoScript.titleBPM("147 / 73 BPM or 146 BPM") == nil, "ambiguous title")
    expect(BrowserTempoScript.titleBPM("2027 type beat") == nil, "no invented BPM")
    expect(BrowserTempoScript.titleBPM("82.5 bpm") == 82.5, "fractional BPM")
    let js = BrowserTempoScript.javascript(videoID: "abcdefghijk", token: "quote\"slash\\", operation: .apply)
    var error: NSDictionary?
    let literal = NSAppleScript(source: "return " + BrowserTempoScript.appleString(js))!
      .executeAndReturnError(&error).stringValue
    expect(error == nil && literal == js, "AppleScript preserves JavaScript newlines and escaping")

    let c = JSContext()!
    c.exceptionHandler = { _, e in fatalError(e?.toString() ?? "JS exception") }
    func eval(_ script: String) -> JSValue { c.evaluateScript(script)! }
    func fixture() {
      _ = eval("""
      var window = this, fakeNow = 1000, ad = false, timers = {}, nextTimer = 0, windowEvents = {};
      Date.now = () => fakeNow;
      var location = {href:'https://www.youtube.com/watch?v=abcdefghijk'};
      var media = {readyState:4, currentSrc:'blob:one', duration:180, srcObject:null, playbackRate:1.2,
        preservesPitch:false, isConnected:true, events:{}, classList:{contains:()=>true},
        addEventListener:(name,fn)=>{media.events[name]=fn}, removeEventListener:(name)=>{delete media.events[name]}};
      var videos = [media];
      var document = {querySelector:()=>ad, querySelectorAll:()=>videos};
      window.addEventListener = (name,fn)=>{windowEvents[name]=fn};
      window.removeEventListener = name=>{delete windowEvents[name]};
      var setInterval = fn=>{timers[++nextTimer]=fn;return nextTimer};
      var clearInterval = id=>{delete timers[id]};
      // JavaScriptCore has no browser URL object. This fixture parser supports
      // only the selected watch URL; native WebKit exercises the real DOM too.
      var URL = function(s) { this.hostname=s.split('/')[2];this.protocol=s.split(':')[0]+':';
        this.pathname='/watch';this.searchParams={get:()=>s.split('v=')[1]}; };
      delete window.__bassShakerTempoV1;
      """)
    }
    func command(_ op: BrowserTempoScript.Operation, _ rate: Double = 140.0 / 147, token: String = "ours") -> [String: Any] {
      let text = eval(BrowserTempoScript.javascript(videoID: "abcdefghijk", token: token, operation: op, rate: rate)).toString()!
      return try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }
    fixture()
    expect(command(.apply)["active"] as? Bool == true, "apply")
    expect(eval("media.preservesPitch").toBool(), "pitch preserved")
    expect(abs(eval("media.playbackRate").toDouble() - 140.0/147) < 0.000001, "exact rate")
    expect(command(.read)["active"] as? Bool == true, "read owned rate")
    _ = command(.restore, token: "wrong")
    expect(eval("!!window.__bassShakerTempoV1").toBool(), "foreign token cannot restore")
    _ = command(.restore)
    expect(eval("media.playbackRate === 1.2 && !media.preservesPitch").toBool(), "restore previous settings")
    expect(eval("Object.keys(timers).length === 0 && Object.keys(media.events).length === 0").toBool(), "listeners cleaned")

    fixture(); _ = command(.apply); _ = command(.apply, 1.1); _ = command(.restore)
    expect(eval("media.playbackRate === 1.2").toBool(), "repeated adjustment preserves initial speed")
    fixture(); _ = command(.apply); _ = eval("media.playbackRate=1.5")
    expect(command(.read)["active"] as? Bool == false, "manual speed ends ownership")
    expect(eval("media.playbackRate===1.5").toBool(), "do not override user's change")
    fixture(); _ = command(.apply); _ = eval("fakeNow=40000; Object.values(timers).forEach(fn=>fn())")
    expect(eval("media.playbackRate===1.2 && !window.__bassShakerTempoV1").toBool(), "crash lease restores")
    fixture(); _ = command(.apply); _ = eval("fakeNow=40000"); _ = command(.read)
    expect(eval("media.playbackRate===1.2 && !window.__bassShakerTempoV1").toBool(), "late heartbeat cannot revive expired ownership")
    fixture()
    for i in 0..<100 { _ = command(.apply, 0.9 + Double(i % 10) * 0.01) }
    expect(eval("Object.keys(timers).length===1 && Object.keys(media.events).length===2").toBool(), "repeated changes retain one lease")
    fixture(); _ = command(.apply); _ = eval("fakeNow=25000")
    _ = command(.read); _ = eval("fakeNow=40000; Object.values(timers).forEach(fn=>fn())")
    expect(eval("!!window.__bassShakerTempoV1").toBool(), "heartbeat renews lease")
    fixture(); _ = command(.apply); _ = eval("location.href='https://www.youtube.com/watch?v=othertrack1'; media.events.timeupdate()")
    expect(eval("media.playbackRate===1.2 && !window.__bassShakerTempoV1").toBool(), "SPA navigation restores")
    fixture(); _ = command(.apply); _ = eval("media.currentSrc='blob:two'; media.events.loadedmetadata()")
    expect(eval("media.playbackRate===1.2").toBool(), "new media restores")
    fixture(); _ = command(.apply); _ = eval("media.currentSrc='blob:two'"); _ = command(.read)
    expect(eval("media.playbackRate===1.2 && !window.__bassShakerTempoV1").toBool(), "read before metadata event restores")
    fixture(); _ = command(.apply)
    _ = eval("var speed=media.playbackRate; Object.defineProperty(media,'playbackRate',{get:()=>speed,set:v=>{if(v===1.1)throw Error('rejected');speed=v}})")
    expect(command(.apply, 1.1)["error"] as? String == "unsupported", "rejected rate reported")
    expect(eval("media.playbackRate===1.2 && !window.__bassShakerTempoV1").toBool(), "failed adjustment restores original")
    fixture(); _ = eval("ad=true")
    expect(command(.apply)["error"] as? String == "ad", "ads rejected")
    fixture(); _ = eval("media.duration=Infinity")
    expect(command(.apply)["error"] as? String == "live", "live rejected")
    fixture(); _ = eval("videos.push(media)")
    expect(command(.apply)["error"] as? String == "ambiguous", "ambiguous media rejected")
    fixture(); _ = eval("delete media.preservesPitch")
    expect(command(.apply)["error"] as? String == "pitch", "pitch required")
    fixture(); _ = eval("location.href='https://wrong.example/watch?v=abcdefghijk'")
    expect(command(.apply)["error"] as? String == "changed", "host guard")
    print("\(count) browser tempo checks passed")
  }
}
