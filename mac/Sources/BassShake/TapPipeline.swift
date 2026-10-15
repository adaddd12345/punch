import BassShakeRT
import CoreAudio
import Foundation
import PunchCore

/// One live tap → private aggregate → output-device pipeline.
///
///   apps ─► [process tap on the output device, mutedWhenTapped, excludes us]
///             │  (originals are silenced only while we are reading the tap)
///             ▼
///   private aggregate: main sub-device = the real output, tap as input
///             │  BSIOProc (C): DSP engine → fade → device buffers
///             ▼
///   real output device ─► hardware volume (volume keys keep working)
///
/// The system default output is never changed, nothing is installed, and if
/// we stop or crash the tap stops being read so the original audio resumes.
@available(macOS 14.2, *)
final class TapPipeline {
  struct Info {
    var deviceName: String
    var sampleRate: Double
    var channels: Int
    var bufferFrames: UInt32
    var tapIsGlobal: Bool
    /// What this pipeline was built for, so a rebuild request can tell
    /// whether anything it depends on actually changed.
    var deviceID: AudioObjectID
    var deviceUID: String
    var deviceOutputChannels: Int
    /// Uptime when IO was started (a just-built pipeline may not be called yet).
    var startedAt: TimeInterval
  }

  private let engine: OpaquePointer
  private var context: OpaquePointer?
  private var tapID = unknownObject
  private var aggregateID = unknownObject
  private var procID: AudioDeviceIOProcID?
  private(set) var info: Info?

  init(engine: OpaquePointer) {
    self.engine = engine
  }

  deinit { stop(fade: false) }

  var isRunning: Bool { procID != nil }

  /// HAL call: audioQueue only. Our aggregate exists and its IO is running.
  var aggregateIsRunning: Bool {
    aggregateID != unknownObject &&
      ((try? HAL.get(aggregateID, .global(kAudioDevicePropertyDeviceIsRunning), default: UInt32(0))) ?? 0) != 0
  }

  /// HAL call: audioQueue only. The aggregate's live sub-devices (it should
  /// hold the output device's current object), or nil if unreadable.
  var activeSubDevices: [AudioObjectID]? {
    guard aggregateID != unknownObject else { return nil }
    return try? HAL.array(aggregateID, .global(kAudioAggregateDevicePropertyActiveSubDeviceList), of: AudioObjectID.self, zero: 0)
  }

  /// HAL calls: audioQueue only. The tap and aggregate still have the
  /// channel count and rate the engine was prepared for.
  func liveFormatMatches() -> Bool {
    guard let info, tapID != unknownObject, aggregateID != unknownObject,
          let f = try? HAL.get(tapID, .global(kAudioTapPropertyFormat), default: AudioStreamBasicDescription())
    else { return false }
    guard max(1, Int(f.mChannelsPerFrame)) == info.channels else { return false }
    let aggRate = Devices.nominalSampleRate(aggregateID)
    guard aggRate > 0, abs(aggRate - info.sampleRate) < 0.5 else { return false }
    if !info.tapIsGlobal && f.mSampleRate > 0 && abs(f.mSampleRate - info.sampleRate) >= 0.5 { return false }
    return true
  }

  var stats: BSRenderStats? {
    guard let context else { return nil }
    return BSRenderContextStats(context)
  }

  /// Builds and starts the pipeline. Blocking (AudioDeviceStart can stall
  /// while another tap client holds the device); call off the main thread.
  ///
  /// `alsoExclude`: extra HAL process objects to leave out of the tap, on top
  /// of our own process. Live Channels passes the processes of apps the user
  /// muted: their `.muted` taps keep them off the hardware, but this tap
  /// would otherwise capture their audio and play it again, processed.
  func start(output: OutputDevice, alsoExclude: [AudioObjectID] = []) throws -> Info {
    stop(fade: false)
    do {
      let own = Self.ownProcessObject()
      var excluded: [AudioObjectID] = own.map { [$0] } ?? []
      for obj in alsoExclude where obj != unknownObject && !excluded.contains(obj) {
        excluded.append(obj)
      }

      // Prefer a tap scoped to the device's audio (format matches the device);
      // fall back to a stereo global tap if the device-scoped one fails.
      var isGlobal = false
      var desc = CATapDescription(excludingProcesses: excluded, deviceUID: output.uid, stream: 0)
      configure(desc)
      var tap = unknownObject
      var status = AudioHardwareCreateProcessTap(desc, &tap)
      if status != noErr {
        desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        configure(desc)
        status = AudioHardwareCreateProcessTap(desc, &tap)
        isGlobal = true
      }
      try check(status, "create process tap")
      tapID = tap
      BSCrashGuardSet(unknownObject, tap)

      let format = try HAL.get(tapID, .global(kAudioTapPropertyFormat), default: AudioStreamBasicDescription())
      let channels = max(1, Int(format.mChannelsPerFrame))

      // Private aggregate: the real output is the clock master; the tap is
      // drift-compensated onto it.
      let aggUID = "com.bassshake.aggregate.\(UUID().uuidString)"
      let dict: [String: Any] = [
        kAudioAggregateDeviceNameKey: "The Bass Shaker",
        kAudioAggregateDeviceUIDKey: aggUID,
        kAudioAggregateDeviceMainSubDeviceKey: output.uid,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        // channels-in 0: keep a headset's mic out of the aggregate so we
        // never trigger the microphone indicator or flip AirPods to HFP.
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid,
                                                 kAudioSubDeviceInputChannelsKey: 0]],
        kAudioAggregateDeviceTapListKey: [[
          kAudioSubTapUIDKey: desc.uuid.uuidString,
          // Drift compensation on a Bluetooth clock produces a periodic
          // crackle (~every 0.7 s); the BT device is the clock anyway.
          // AirPlay runs its own (buffered) clock too.
          kAudioSubTapDriftCompensationKey: !output.isBluetooth && output.transport != UInt32(kAudioDeviceTransportTypeAirPlay),
        ]],
      ]
      var agg = unknownObject
      try check(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg), "create aggregate device")
      aggregateID = agg
      BSCrashGuardSet(agg, tapID)

      let sampleRate = Devices.nominalSampleRate(agg) > 0 ? Devices.nominalSampleRate(agg) : format.mSampleRate
      let bufferFrames = Devices.bufferFrameSize(agg)

      // DSP engine must be prepared before IO starts (never concurrently).
      punch_engine_prepare(engine, sampleRate, Int32(channels), Int32(max(4096, bufferFrames * 2)))

      guard let ctx = BSRenderContextCreate(engine) else { throw CAError(-1, "render context") }
      context = ctx
      // Real sub-device input streams (if any survive channels-in 0) come
      // first in the aggregate's input buffer list and the tap is appended
      // after them, so the last input buffer is always the tap.
      BSRenderContextSetTapBufferIndex(ctx, UInt32.max)

      var proc: AudioDeviceIOProcID?
      try check(AudioDeviceCreateIOProcID(agg, BSIOProc, UnsafeMutableRawPointer(ctx), &proc), "create IOProc")
      procID = proc

      BSRenderContextFadeIn(ctx, sampleRate, 80)
      try check(AudioDeviceStart(agg, proc), "start IO")

      let i = Info(deviceName: output.name, sampleRate: sampleRate, channels: channels,
                   bufferFrames: bufferFrames, tapIsGlobal: isGlobal,
                   deviceID: output.id, deviceUID: output.uid,
                   deviceOutputChannels: HAL.channelCount(output.id, scope: kAudioObjectPropertyScopeOutput),
                   startedAt: ProcessInfo.processInfo.systemUptime)
      info = i
      return i
    } catch {
      stop(fade: false)
      throw error
    }
  }

  /// Fades out (so the hand-back to the unprocessed signal doesn't click)
  /// and destroys everything in reverse order.
  /// coreaudiod restarted: every object ID we hold is dead and may already
  /// be reused for someone else's tap, so forget them without destroying.
  func abandon() {
    procID = nil
    aggregateID = unknownObject
    tapID = unknownObject
    BSCrashGuardClear()
    if let ctx = context {
      BSRenderContextDestroy(ctx)  // the dead daemon won't call the IOProc again
      context = nil
    }
    info = nil
  }

  func stop(fade: Bool = true) {
    if fade, let ctx = context, procID != nil, let sr = info?.sampleRate {
      BSRenderContextFadeOut(ctx, sr, 40)
      let deadline = Date().addingTimeInterval(0.25)
      while !BSRenderContextIsFadedOut(ctx) && Date() < deadline { usleep(5_000) }
    }
    // The rescue path (AudioController's wedge rescue) may already have
    // destroyed these from another queue: never touch a released ID again.
    var ownsAgg = false, ownsTap = false
    BSCrashGuardRelease(aggregateID, tapID, &ownsAgg, &ownsTap)
    if let proc = procID {
      if ownsAgg {
        AudioDeviceStop(aggregateID, proc)
        AudioDeviceDestroyIOProcID(aggregateID, proc)
      }
      procID = nil
    }
    if aggregateID != unknownObject {
      if ownsAgg { AudioHardwareDestroyAggregateDevice(aggregateID) }
      aggregateID = unknownObject
    }
    if tapID != unknownObject {
      if ownsTap { AudioHardwareDestroyProcessTap(tapID) }
      tapID = unknownObject
    }
    if let ctx = context {
      BSRenderContextDestroy(ctx)
      context = nil
    }
    info = nil
  }

  private func configure(_ d: CATapDescription) {
    d.name = "The Bass Shaker"
    d.uuid = UUID()
    d.isPrivate = true
    d.muteBehavior = .mutedWhenTapped
  }

  /// Our own HAL process object, so the tap never captures what we play
  /// (that would be a feedback loop).
  static func ownProcessObject() -> AudioObjectID? {
    var pid = getpid()
    var addr = AudioObjectPropertyAddress.global(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var obj = unknownObject
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let st = AudioObjectGetPropertyData(systemObject, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
    return st == noErr && obj != unknownObject ? obj : nil
  }

  /// Destroys aggregates left behind by a previous instance that died
  /// without cleaning up (they would keep muting audio). Run at launch.
  static func sweepLeftovers() {
    let ids = (try? HAL.array(systemObject, .global(kAudioHardwarePropertyDevices), of: AudioObjectID.self, zero: 0)) ?? []
    for id in ids {
      guard let uid = try? HAL.string(id, .global(kAudioDevicePropertyDeviceUID)),
            uid.hasPrefix("com.bassshake.aggregate.") else { continue }
      AudioHardwareDestroyAggregateDevice(id)
    }
  }

  /// True if any process other than us is currently producing output.
  /// Used by the watchdog to tell "nothing is playing" from "dead tap".
  /// Pass the same objects as `alsoExclude`: a muted app that keeps playing
  /// never reaches our tap, so counting it would make a healthy tap look
  /// dead (rebuild loop, or a false "needs permission" banner).
  static func othersArePlaying(excluding extra: Set<AudioObjectID> = []) -> Bool {
    !playingProcesses(excluding: extra).isEmpty
  }

  /// The processes (other than us and `extra`) running output right now.
  static func playingProcesses(excluding extra: Set<AudioObjectID> = []) -> Set<AudioObjectID> {
    let own = ownProcessObject()
    let procs = (try? HAL.array(systemObject, .global(kAudioHardwarePropertyProcessObjectList),
                                of: AudioObjectID.self, zero: 0)) ?? []
    var out: Set<AudioObjectID> = []
    for p in procs where p != own && !extra.contains(p) {
      let running = (try? HAL.get(p, .global(kAudioProcessPropertyIsRunningOutput), default: UInt32(0))) ?? 0
      if running != 0 { out.insert(p) }
    }
    return out
  }
}
