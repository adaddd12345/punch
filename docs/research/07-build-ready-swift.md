# 07: Build-ready Swift details for "Bass Shake"

Researched 2026-10-11. **Sources:**
- SDK headers from Apple: `CATapDescription.h`, `AudioHardwareTapping.h` and `AudioHardware.h` from MacOSX14.5.sdk and MacOSX26.5.sdk, mirrored at `github.com/alexey-lysiuk/macos-sdk`.
- Apple's DocC JSON (`developer.apple.com/tutorials/data/documentation/...json`), which gives the exact Swift declarations.
- Real source from:
  - **insidegui/AudioCap** (BSD-2)
  - **zollans/OnlyEQ** (public domain/Unlicense). This is SwiftPM, tools 5.10 and macOS 14.4, with the same architecture we plan to use. It is the closest reference.
  - **dariuscorvus/iqualize** (MIT; SwiftPM, CI and releases)
  - **ronitsingh10/FineTune** (GPL-3). I read it to learn from it and copied nothing.

**Legend:**
- **[H]** confirmed from the SDK header.
- **[D]** confirmed from Apple's DocC Swift declaration.
- **[S]** confirmed from working open-source code.
- **[U]** unconfirmed or inferred. Test it on hardware.

---

## 1. Process tap + aggregate + IOProc: exact Swift

### 1.1 Availability matrix

| API | Swift signature | Availability |
|---|---|---|
| `CATapDescription` (class) | `class CATapDescription : NSObject` | header `API_AVAILABLE(macos(12.0))` [H] |
| `init(stereoGlobalTapButExcludeProcesses:)` | `convenience init(stereoGlobalTapButExcludeProcesses processesIDsToExcludeFromTap: [AudioObjectID])` (**non-optional array**, so pass `[]` for none) | Swift refinement listed as macOS 14.0 [D]. The ObjC method is `NS_REFINED_FOR_SWIFT` and takes `NSArray<NSNumber*>*` [H] |
| other inits | `init(stereoMixdownOfProcesses: [AudioObjectID])`, `init(monoGlobalTapButExcludeProcesses:)`, `init(monoMixdownOfProcesses:)`, `init(processes: [AudioObjectID], deviceUID: String, stream: UInt)`, `init(excludingProcesses: [AudioObjectID], deviceUID: String, stream: UInt)` | [D] |
| properties | `var name: String`, `var uuid: UUID`, `var processes: [AudioObjectID]`, `var isMono: Bool`, `var isExclusive: Bool`, `var isMixdown: Bool`, `var isPrivate: Bool` (ObjC `privateTap`, getter `isPrivate`), `var muteBehavior: CATapMuteBehavior`, `var deviceUID: String?`, `var stream: UInt?` | [D][H] |
| macOS 26-only properties | `var bundleIDs: [String]`, `var isProcessRestoreEnabled: Bool` | `API_AVAILABLE(macos(26.0))` [H]. **Do not use them with a 14.4 deployment target** unless you wrap them in `if #available(macOS 26, *)` |
| `CATapMuteBehavior` | `enum CATapMuteBehavior: Int` with cases `.unmuted` (0), `.muted` (1), `.mutedWhenTapped` (2) | macOS 13.0 [H][D] |
| `AudioHardwareCreateProcessTap` | `func AudioHardwareCreateProcessTap(_ inDescription: CATapDescription!, _ outTapID: UnsafeMutablePointer<AudioObjectID>!) -> OSStatus` | `API_AVAILABLE(macos(14.2))` [H][D] |
| `AudioHardwareDestroyProcessTap` | `func AudioHardwareDestroyProcessTap(_ inTapID: AudioObjectID) -> OSStatus` | macOS 14.2 [H][D] |
| `AudioHardwareCreateAggregateDevice` | `func AudioHardwareCreateAggregateDevice(_ inDescription: CFDictionary, _ outDeviceID: UnsafeMutablePointer<AudioObjectID>) -> OSStatus` | 10.9 [D] |
| `AudioHardwareDestroyAggregateDevice` | `(_ inDeviceID: AudioObjectID) -> OSStatus` | 10.9 [D] |
| `AudioDeviceCreateIOProcIDWithBlock` | `func AudioDeviceCreateIOProcIDWithBlock(_ outIOProcID: UnsafeMutablePointer<AudioDeviceIOProcID?>, _ inDevice: AudioObjectID, _ inDispatchQueue: dispatch_queue_t?, _ inIOBlock: @escaping AudioDeviceIOBlock) -> OSStatus` | 10.7 [D] |
| `AudioDeviceIOBlock` | `typealias AudioDeviceIOBlock = (UnsafePointer<AudioTimeStamp>, UnsafePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>, UnsafeMutablePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>) -> Void`. The parameters are (inNow, inInputData, inInputTime, outOutputData, inOutputTime). It is **not `@Sendable`** in the imported type. | [D][H] |
| `AudioDeviceStart` / `AudioDeviceStop` | `(_ inDevice: AudioObjectID, _ inProcID: AudioDeviceIOProcID?) -> OSStatus` | [D] |
| `AudioDeviceDestroyIOProcID` | `(_ inDevice: AudioObjectID, _ inIOProcID: AudioDeviceIOProcID) -> OSStatus` (non-optional) | [D] |
| Tap / aggregate keys and selectors | `#define`s and enum constants with **no availability annotation** in the header | [H] |

**With `platforms: [.macOS("14.4")]` you do not need any `@available` annotations** for the tap APIs. The 14.2 floor is already met. Put `@available(macOS 14.2, *)` on the tap code only if you ever lower the deployment target.

**SDK 26 change [H].** The `AudioDeviceIOBlock` and `AudioDeviceIOProc` typedefs are now tagged `CA_REALTIME_API`, which expands to `[[clang::nonblocking]]`/`__attribute__((nonblocking))` (defined in `CoreAudioTypes/CoreAudioBaseTypes.h`).
- In Swift it has no effect: you get no diagnostics, and the code compiles the same with Xcode 16 and 26.
- In C/C++, clang may warn under `-Wfunction-effects` if a block with that type calls blocking code. Our C++ engine is called from Swift, so it is not affected.

### 1.2 Key constants: all are Swift `String`, so you never need `as String`

`#define kX "str"` macros are imported as `var kX: String { get }` [D]. You can use them directly as `[String: Any]` keys; AudioCap, OnlyEQ and iQualize all do this [S]. Adding `as String` compiles too, but it is redundant.

| Swift constant | literal [H] | value type |
|---|---|---|
| `kAudioAggregateDeviceNameKey` | `"name"` | String |
| `kAudioAggregateDeviceUIDKey` | `"uid"` | String (must be unique) |
| `kAudioAggregateDeviceMainSubDeviceKey` | `"master"` | output device UID |
| `kAudioAggregateDeviceClockDeviceKey` | `"clock"` | optional |
| `kAudioAggregateDeviceIsPrivateKey` | `"private"` | Bool/Int (the header says CFNumber; `true` works [S]) |
| `kAudioAggregateDeviceIsStackedKey` | `"stacked"` | `false` |
| `kAudioAggregateDeviceTapAutoStartKey` | `"tapautostart"` | `true`. The header says this also requires the private key. |
| `kAudioAggregateDeviceSubDeviceListKey` | `"subdevices"` | `[[String: Any]]` |
| `kAudioSubDeviceUIDKey` | `"uid"` | String |
| `kAudioSubDeviceInputChannelsKey` | `"channels-in"` | `0` (see below) |
| `kAudioSubDeviceDriftCompensationKey` | `"drift"` | for sub-devices |
| `kAudioAggregateDeviceTapListKey` | `"taps"` | `[[String: Any]]` |
| `kAudioSubTapUIDKey` | `"uid"` | `tapDesc.uuid.uuidString` |
| `kAudioSubTapDriftCompensationKey` | `"drift"` | `true` |

These selectors are `AudioObjectPropertySelector` [H]:
- `kAudioHardwarePropertyTranslatePIDToProcessObject = 'id2p'`
- `kAudioHardwarePropertyProcessObjectList = 'prs#'`
- `kAudioHardwarePropertyTapList = 'tps#'`
- `kAudioTapPropertyUID = 'tuid'`
- `kAudioTapPropertyDescription = 'tdsc'`. It is settable, so you can push a new exclusion list to a live tap; iQualize does this [S].
- `kAudioTapPropertyFormat = 'tfmt'` (an ASBD)

Two type traps [D]:
- `kAudioObjectSystemObject` is **`Int32`**, so always write `AudioObjectID(kAudioObjectSystemObject)`.
- `kAudioObjectUnknown` is an `AudioObjectID`.

### 1.3 Our own process object

```swift
import CoreAudio

/// kAudioObjectUnknown is a valid answer: per the header the property "does not return an
/// error if the PID doesn't refer to any Process" [H]. Our process becomes a HAL client once it
/// makes its first HAL call, so call this after some other HAL read (e.g. the device list). [U]
func processObjectID(for pid: pid_t = getpid()) -> AudioObjectID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var qualifier = pid
    var objectID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         UInt32(MemoryLayout<pid_t>.size), &qualifier,
                                         &size, &objectID)
    return err == noErr ? objectID : AudioObjectID(kAudioObjectUnknown)
}
```
This is the same pattern as the iQualize capture helper and OnlyEQ `processObjects(forBundleIDs:)` [S].

If the result is unknown, pass `[]` and re-apply the exclusion later by setting `kAudioTapPropertyDescription` on the live tap (iQualize's `applyTapExclusions`) [S]. **Excluding ourselves matters:** otherwise the global tap could capture our own re-rendered output and create a feedback loop. Every reference app excludes itself [S].

### 1.4 Create the tap, read its format, build the aggregate

```swift
import CoreAudio
import Foundation

struct CAError: Error { let status: OSStatus; let what: String }
@inline(__always) func ca(_ s: OSStatus, _ what: String) throws { if s != noErr { throw CAError(status: s, what: what) } }

final class TapGraph {
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private(set) var procID: AudioDeviceIOProcID?
    private(set) var tapFormat = AudioStreamBasicDescription()
    static let aggregateUIDPrefix = "com.bassshake.aggregate."   // filter these out of the device list

    func build(outputDeviceUID: String) throws {
        // 1. Global stereo tap minus our own process
        let me = processObjectID()
        let excluded: [AudioObjectID] = me == kAudioObjectUnknown ? [] : [me]
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.uuid = UUID()                 // init already assigns one; setting it is harmless (AudioCap does)
        desc.name = "Bass Shake Tap"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        try ca(AudioHardwareCreateProcessTap(desc, &tapID), "AudioHardwareCreateProcessTap")

        // 2. Tap format (observed: Float32, interleaved, 2 ch [S: OnlyEQ rejects anything else])
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try ca(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &tapFormat), "kAudioTapPropertyFormat")

        // 3. Private aggregate: main sub-device = chosen output, tap attached with drift compensation
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Bass Shake",
            kAudioAggregateDeviceUIDKey: Self.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[
                kAudioSubDeviceUIDKey: outputDeviceUID,
                // OnlyEQ: excludes the device's mic side (e.g. a BT headset) so starting
                // the IOProc doesn't trigger a microphone prompt. [S claim, U verified]
                kAudioSubDeviceInputChannelsKey: 0,
            ]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try ca(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateID),
               "AudioHardwareCreateAggregateDevice")
    }

    func start(block: @escaping AudioDeviceIOBlock) throws {
        try ca(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, block), "CreateIOProcIDWithBlock")
        try ca(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
    }

    func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            procID = nil
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
```
**Teardown order** is stop, destroy IOProc, destroy aggregate, destroy tap. AudioCap and OnlyEQ both use it [S].

**Notes:**
- **Dispatch queue.** Pass `nil`. The header says: "If this value is NULL, then the IOBlock will be directly invoked", and that with a queue "All IOBlocks are dispatched synchronously" [H]. `nil` therefore keeps us on the HAL realtime thread. OnlyEQ and iQualize pass `nil`; AudioCap and FineTune pass a queue [S].
- **`TapAutoStart`.** The header says `AudioDeviceStart` "will wait until a tapped process begins receiving its first audio" [H]. The reference apps call it from the main thread without visible hangs, so it does not appear to block the caller [U].
- **Don't hard-code the tap stream index.** With `channels-in: 0` the tap should be the only input stream. OnlyEQ still picks it robustly [S]:
  1. Read the aggregate's input streams (`kAudioDevicePropertyStreams`, input scope).
  2. Read each stream's `kAudioStreamPropertyVirtualFormat`.
  3. Choose the unique stereo stream whose format equals the tap ASBD.
  4. If that is ambiguous, use `kAudioStreamPropertyStartingChannel == physicalInputChannels + 1`, because "the tap starts immediately after the physical device inputs".

  Do this after creating the aggregate and before starting the IOProc.
- **Alternative to `channels-in: 0`.** FineTune switches the hardware input streams off per-IOProc with `kAudioDevicePropertyIOProcStreamUsage` (input scope). The payload is the variable-length struct `{ void* mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[] }` [S, idea only].
- **Sample rate.** Prepare the engine with the **aggregate's** `kAudioDevicePropertyNominalSampleRate`. With tap drift compensation the HAL resamples the tap into the main device's clock domain (neiro's code comment) [U].
- **`max_frames`.** Use `kAudioDevicePropertyBufferFrameSizeRange` (an `AudioValueRange`, `.mMaximum`) or a safe 4096. Read the current size with `kAudioDevicePropertyBufferFrameSize` (OnlyEQ `readIOBufferSize`) [S].
- **Restarts.** Listen for `kAudioDevicePropertyNominalSampleRate` changes on the output device and rebuild the graph. Biquads are rate-specific; OnlyEQ restarts here [S].
- **Silent zeros.** If `NSAudioCaptureUsageDescription` is missing, or permission is denied, every call can still return `noErr` while the buffers are all zeros. This is reported in the dev.to post "2000 buffers of nothing", which I saw only in a search summary because dev.to is blocked from here.

  **[U] risk:** with `.mutedWhenTapped`, find out whether a denied tap still mutes system audio. Add a watchdog: if the input stays at zero for several seconds while something is playing, tear the graph down and show a "grant permission" hint.

### 1.5 The IOProc: walking the buffer lists and calling `punch_process_interleaved`

`UnsafeMutableAudioBufferListPointer` [D] has two initializers:
- `init(_: UnsafeMutablePointer<AudioBufferList>)`
- `init?(_: UnsafeMutablePointer<AudioBufferList>?)`

It also has `count`, `subscript -> AudioBuffer`, `unsafePointer` and `unsafeMutablePointer`. The input list arrives as `UnsafePointer`, so wrap it with `UnsafeMutablePointer(mutating:)`; every reference app does this [S].

C import mapping for `punch_c.h`:
- `PunchEngine*` (an incomplete struct) imports as **`OpaquePointer`**.
- `int` imports as `Int32`.
- `const float*` imports as `UnsafePointer<Float>!`.

```swift
import CoreAudio
import PunchCore

/// Everything the realtime block touches. Immutable after creation; @unchecked Sendable
/// because OpaquePointer/UnsafeMutablePointer are NOT Sendable (stdlib) [D].
final class RenderContext: @unchecked Sendable {
    let engine: OpaquePointer            // PunchEngine*
    let tapBufferIndex: Int
    let maxFrames: Int
    let scratch: UnsafeMutablePointer<Float>   // interleaved stereo processed audio
    init(engine: OpaquePointer, tapBufferIndex: Int, maxFrames: Int) {
        self.engine = engine; self.tapBufferIndex = tapBufferIndex; self.maxFrames = maxFrames
        scratch = .allocate(capacity: maxFrames * 2)
        scratch.initialize(repeating: 0, count: maxFrames * 2)
    }
    deinit { scratch.deallocate() }      // only after AudioDeviceDestroyIOProcID returned
}

enum IOProcFactory {   // a plain enum => nonisolated in a SwiftPM target (no default MainActor isolation)
    static func make(_ ctx: RenderContext) -> AudioDeviceIOBlock {
        return { @Sendable _, inInputData, _, outOutputData, _ in
            let outList = UnsafeMutableAudioBufferListPointer(outOutputData)
            let inList  = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))

            guard ctx.tapBufferIndex < inList.count,
                  let inRaw = inList[ctx.tapBufferIndex].mData,
                  inList[ctx.tapBufferIndex].mNumberChannels == 2 else { zero(outList); return }
            let inFrames = Int(inList[ctx.tapBufferIndex].mDataByteSize) / (MemoryLayout<Float>.size * 2)
            let inPtr = inRaw.assumingMemoryBound(to: Float.self)

            // Fast path: one interleaved stereo output buffer (built-in speakers, most USB/BT).
            if outList.count == 1, let outRaw = outList[0].mData, outList[0].mNumberChannels == 2 {
                let outFrames = Int(outList[0].mDataByteSize) / (MemoryLayout<Float>.size * 2)
                let n = min(inFrames, outFrames, ctx.maxFrames)
                let outPtr = outRaw.assumingMemoryBound(to: Float.self)
                punch_process_interleaved(ctx.engine, inPtr, outPtr, 2, Int32(n))
                if outFrames > n { (outPtr + n * 2).update(repeating: 0, count: (outFrames - n) * 2) }
                return
            }

            // General path: process into scratch, then scatter L/R across whatever the device exposes
            // (multiple streams, >2 channels, mono). Cycles L,R,L,R… like OnlyEQ.
            let n = min(inFrames, ctx.maxFrames)
            punch_process_interleaved(ctx.engine, inPtr, ctx.scratch, 2, Int32(n))
            var src = 0
            for buf in outList {
                guard let raw = buf.mData else { continue }
                let ch = max(Int(buf.mNumberChannels), 1)
                let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch)
                let out = raw.assumingMemoryBound(to: Float.self)
                let m = min(frames, n)
                for c in 0..<ch {
                    let s = src & 1; src += 1
                    var f = 0
                    while f < m { out[f * ch + c] = ctx.scratch[f * 2 + s]; f += 1 }
                    while f < frames { out[f * ch + c] = 0; f += 1 }
                }
            }
        }
    }
    @inline(__always) static func zero(_ list: UnsafeMutableAudioBufferListPointer) {
        for b in list { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
    }
}
```
The output buffers are assumed to be Float32 (the HAL client format). OnlyEQ, iQualize and AudioCap all assume this [S].

**Realtime rules inside the block:**
- No Swift `Array` allocations or appends (OnlyEQ uses `removeAll(keepingCapacity:)`).
- No locks, no `print`, no `[weak self]`.
- No ObjC or Swift class allocation.
- Preallocate everything in `RenderContext` before `AudioDeviceStart`.

**`punch_engine_prepare` must not run concurrently with process calls** (from `punch_c.h`). Call `AudioDeviceStop` first, then prepare, then start again.

### 1.6 Swift 6 / strict concurrency

- **The crash mechanism.** `AudioDeviceIOBlock` is not `@Sendable` [D]. A closure literal written inside a `@MainActor` method (a SwiftUI view, or an `@MainActor @Observable` model) is therefore **inferred as MainActor-isolated**. In Swift 6 language mode the compiler adds dynamic isolation checks (SE-0423). The block runs on the HAL thread, so the check fails with `_dispatch_assert_queue_fail` / `EXC_BREAKPOINT`.
  - Apple DTS describes this mechanism for unannotated callbacks: https://developer.apple.com/forums/thread/764777?page=2
  - A Swift Forums report shows the same crash signature: https://forums.swift.org/t/crash-when-running-in-swift-6-language-mode/72431
- **How projects avoid it:**
  - **FineTune** (Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) writes `{ @Sendable [weak self] _, inInputData, _, outOutputData, _ in ... }`, calls a `nonisolated` processing function, and keeps its RT state in `nonisolated(unsafe) var`s [S].
  - **iQualize** (`swift-tools-version: 6.3`, `swiftLanguageModes: [.v6]`) builds the block in a top-level nonisolated function and uses `nonisolated(unsafe)` globals [S].
  - **OnlyEQ** (`swift-tools-version:5.10`, so Swift 5 mode) writes a plain `[weak self]` closure on a non-actor class. In Swift 5 mode the SE-0423 runtime checks are off [S].
- **Recommendation:**
  - Use `// swift-tools-version:5.10`, or 6.0 with `swiftLanguageModes: [.v5]`. Either builds on Xcode 16.x and 26.x.
  - Still write the block as above: created in a non-actor `enum`, `@Sendable`, capturing only an `@unchecked Sendable` context. Passing a `@Sendable` closure where a non-Sendable function type is expected is allowed.
  - If you ever add `.defaultIsolation(MainActor.self)` (tools 6.2), mark `IOProcFactory` `nonisolated`.
- **Property listeners.** `AudioObjectAddPropertyListenerBlock(obj, &addr, DispatchQueue.main, block)`: `dispatch_queue_t?` is `DispatchQueue?` in Swift. With `.main`, a block that inherits MainActor isolation runs on main, so the checks pass. Never pass `nil` or a background queue for a MainActor-inferred block.
- **`kAudioObjectPropertyElementMain`** is typed `AudioObjectPropertyScope` (a UInt32 alias) [D], so it works as `mElement` without conversion.

---

## 2. Device enumeration helper (compact, CFString-correct)

**CFString ownership.** The UID and name selectors return a **+1** CFString ("The caller is responsible for releasing the returned CFObject" [H]). The correct Swift pattern is `var v: Unmanaged<CFString>?` followed by `takeRetainedValue()`. OnlyEQ and iQualize do this [S].

The older `var name: CFString = "" as CFString; ... &name` pattern does compile. AudioCap does it through a generic helper, and iQualize's spikes use it directly. However, it forms a raw pointer to a variable that holds an object reference, and iQualize's comment says it "warns, and it leaks the retain". Use `Unmanaged`.

```swift
import CoreAudio

struct OutputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32        // kAudioDeviceTransportTypeBuiltIn/USB/Bluetooth/BluetoothLE/HDMI/DisplayPort/AirPlay/Aggregate/Virtual
    let nominalSampleRate: Double
}

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    @inline(__always) static func addr(_ sel: AudioObjectPropertySelector,
                                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func scalar<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var a = addr(sel, scope)
        guard AudioObjectHasProperty(obj, &a) else { return nil }
        var v = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = addr(sel)
        guard AudioObjectHasProperty(obj, &a) else { return nil }
        var v: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr, let cf = v?.takeRetainedValue() else { return nil }
        return cf as String
    }

    static func objectList(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = addr(sel, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Sum of mNumberChannels in kAudioDevicePropertyStreamConfiguration (an AudioBufferList).
    static func channelCount(_ dev: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var a = addr(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func outputDevices() -> [OutputDevice] {
        objectList(system, kAudioHardwarePropertyDevices).compactMap { id in
            guard channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix(TapGraph.aggregateUIDPrefix),          // our private aggregate is visible to us
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return OutputDevice(id: id, uid: uid, name: name,
                                transport: scalar(id, kAudioDevicePropertyTransportType, UInt32(0)) ?? 0,
                                nominalSampleRate: scalar(id, kAudioDevicePropertyNominalSampleRate, Float64(0)) ?? 0)
        }
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        let id = scalar(system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(kAudioObjectUnknown))
        return id == kAudioObjectUnknown ? nil : id
    }

    static func device(forUID uid: String) -> AudioObjectID? {   // kAudioHardwarePropertyTranslateUIDToDevice, qualifier = CFString
        var a = addr(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(system, &a, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        return err == noErr && id != kAudioObjectUnknown ? id : nil
    }
}

/// Property listener that keeps the block so it can be removed (Remove requires the SAME block).
final class HALListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock   // (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void [D]
    init?(object: AudioObjectID, selector: AudioObjectPropertySelector,
          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, onChange: @escaping () -> Void) {
        self.object = object
        self.address = HAL.addr(selector, scope)
        self.block = { _, _ in onChange() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr else { return nil }
    }
    deinit { AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block) }
}
// Usage:
//  HALListener(object: HAL.system, selector: kAudioHardwarePropertyDevices) { refresh() }
//  HALListener(object: HAL.system, selector: kAudioHardwarePropertyDefaultOutputDevice) { followDefault() }
//  HALListener(object: dev, selector: kAudioDevicePropertyDeviceIsAlive) { rebuildOrFallback() }
//  HALListener(object: dev, selector: kAudioDevicePropertyNominalSampleRate) { rebuild() }
```
**Notes:**
- `kAudioObjectPropertyName` is preferred over `kAudioDevicePropertyDeviceNameCFString`. Both exist [D].
- The `TranslateUIDToDevice` qualifier passing is [U]-style, but it matches the header semantics ("UID is passed in via the qualifier as a CFString").
- Persist device choice **by UID**, not by AudioObjectID.

---

## 3. Info.plist, entitlements and TCC

**Info.plist** (`Contents/Info.plist`). The minimal set below matches OnlyEQ's plist, which is the same shape [S]:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>BassShake</string>
  <key>CFBundleIdentifier</key><string>com.bassshake.app</string>
  <key>CFBundleName</key><string>Bass Shake</string>
  <key>CFBundleDisplayName</key><string>Bass Shake</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.4</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>Bass Shake processes system audio to apply EQ and bass enhancement. Audio never leaves your Mac.</string>
  <key>NSMicrophoneUsageDescription</key><string>Only used if your output device also has a microphone; Bass Shake never records it.</string>
</dict></plist>
```
- `NSAudioCaptureUsageDescription` is **mandatory**. Xcode does not list it, so you add it manually (AudioCap README). Without it the tap silently returns zeros (dev.to report).
- `NSMicrophoneUsageDescription` is a belt-and-braces addition in case a device's input side ends up in the aggregate. FineTune includes it [S]. [U] whether it is ever needed when `channels-in: 0` is used.

**Entitlements.**
- A non-sandboxed app signed ad hoc **without** hardened runtime needs **no entitlements at all**.
- `com.apple.security.device.audio-input` is only meaningful under App Sandbox (AudioCap is sandboxed and has it) or under Hardened Runtime resource access (Apple's hardened runtime docs). FineTune has hardened runtime enabled, so it carries the entitlement [S].
- iQualize's ad-hoc build signs with only `com.apple.security.get-task-allow` [S].
- Hardened runtime is only required for notarization, so skip it for ad-hoc builds.

**TCC "System Audio Recording" with ad-hoc signing:**
- **No public API exists to check or request the permission.** AudioCap uses the private `TCCAccessPreflight`/`TCCAccessRequest` behind a flag. Otherwise the prompt appears "the first time audio recording is started", which means our `AudioDeviceStart` (AudioCap README). iQualize notes the tap triggers its own narrower audio-only prompt, so do **not** call `CGRequestScreenCaptureAccess` [S, CHANGELOG #83].
- **Re-prompts with ad-hoc signing.** A plain ad-hoc signature's designated requirement is its **cdhash**, so **every code change gives a new identity and a new TCC prompt**. iQualize AGENTS.md: "Ad-hoc TCC grants pin the cdhash… any real code change gets a fresh TCC prompt" [S].
- **Workaround used by OnlyEQ [S claim, U].** Sign ad hoc with an explicit identifier-only designated requirement so TCC's stored requirement keeps matching across builds:
  ```bash
  codesign --force --sign - --identifier com.bassshake.app \
    --requirements '=designated => identifier "com.bassshake.app"' "Bass Shake.app"
  ```
  This is consistent with TN3127 (TCC evaluates the stored designated requirement). It is weak, because any binary with that identifier would match. Verify it on a real Mac by granting permission, rebuilding and relaunching.
- **Reset during testing:** `tccutil reset AudioCapture com.bassshake.app`. `AudioCapture` is the documented service name in Apple's "Resetting access to protected resources in macOS".
- The permission appears in System Settings › Privacy & Security › Screen & System Audio Recording. The label for the audio-only sub-list is [U].

---

## 4. Packaging on GitHub Actions

### 4.1 Runner images (from actions/runner-images README, fetched 2026-10-11)

| label | OS | Xcode (default **bold**) |
|---|---|---|
| `macos-latest` = `macos-26` (arm64) | 26.6.2 | **26.6**, 26.5, 26.4.1, 26.3, 26.2, 26.1.1, 26.0.1 |
| `macos-15` (arm64) | 15.7.9 | 26.3, 26.2, 26.1.1, 26.0.1, **16.4**, 16.3, 16.2, 16.1, 16.0 |
| `macos-15-intel` / `macos-26-intel` | x64 | same families |
| `xcode-27` (preview) | 27.0.1 | **27.0**, 27.1, 27.2 beta |
| `macos-14` | deprecated | n/a |

To test both toolchains, use `macos-15` with Xcode 16.4 and `macos-26` with Xcode 26.6. Switch with `sudo xcode-select -s /Applications/Xcode_16.4.app` or `DEVELOPER_DIR`.
- Xcode 16.x ships Swift 6.0/6.1.
- Xcode 26.x ships Swift 6.2+. iQualize's `swift-tools-version: 6.3` builds on `macos-latest` [S].

### 4.2 Package.swift (C++ core with a C-only module map, plus the app)

The existing `core/include/module.modulemap` already declares `module PunchCore { header "punch/punch_c.h" export * }`, and `punch_c.h` is pure C with `extern "C"` guards. That is exactly what Swift needs.
- Swift's clang importer parses the header as C. **No C++ interop flag is needed**, and the `.hpp` files are never parsed by Swift.
- SwiftPM uses a custom `include/module.modulemap` as-is (PackageBuilderTests: `moduleMapType: .custom(".../include/module.modulemap")`).
- Keep the target name equal to the module name (`PunchCore`).

```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BassShake",
    platforms: [.macOS("14.4")],                       // string form is valid; .v14 also exists
    targets: [
        .target(
            name: "PunchCore",
            path: "core",
            sources: ["src"],                          // only core/src/*.cpp is compiled
            publicHeadersPath: "include",              // contains module.modulemap + punch/punch_c.h
            cxxSettings: [
                .headerSearchPath("include"),
                .define("NDEBUG", .when(configuration: .release)),
                .unsafeFlags(["-O3", "-ffast-math"], .when(configuration: .release)) // optional; unsafeFlags OK for a root package
            ]
        ),
        .executableTarget(
            name: "BassShake",
            dependencies: ["PunchCore"],
            path: "Sources/BassShake",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20                        // CXXLanguageStandard.cxx20 exists [D]
)
```
**Details:**
- **Initializer signatures** [D]: `Package(name:defaultLocalization:platforms:pkgConfig:providers:products:dependencies:targets:swiftLanguageVersions:cLanguageStandard:cxxLanguageStandard:)` for tools 5.x, and `swiftLanguageModes:` for 6.x. `.target(name:dependencies:path:exclude:sources:resources:publicHeadersPath:...cxxSettings:...)`.
- **[U] tools version for `.cxx20`.** It is in current docs; I did not confirm the tools version that added it. The fallback is `cxxSettings: [.unsafeFlags(["-std=c++20"])]`.
- **libc++.** SwiftPM links libc++ automatically when a target has C++ sources [U, the norm for whisper.cpp/llama.cpp SPM packages]. If you see undefined `std::` symbols, add `linkerSettings: [.linkedLibrary("c++")]` to the app target.
- **Entry point.** Do not name any file `main.swift` in the app target if you use `@main struct BassShakeApp: App`.
- **The `core/build*` directories** are outside `sources:`, so they are ignored. Keep them out of git anyway.

### 4.3 Universal build, bundle, sign, zip

```bash
#!/bin/bash
# scripts/package-app.sh
set -euo pipefail
APP_NAME="Bass Shake"; EXE="BassShake"; BUNDLE_ID="com.bassshake.app"
FLAGS=(-c release --arch arm64 --arch x86_64)      # multi --arch needs full Xcode (xcbuild), not CLT [S: OnlyEQ comment]
swift build "${FLAGS[@]}" --product "$EXE"
BIN_DIR="$(swift build "${FLAGS[@]}" --show-bin-path)"   # don't hard-code .build/apple/Products/Release
APP="dist/$APP_NAME.app"
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXE" "$APP/Contents/MacOS/$EXE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GITHUB_RUN_NUMBER:-1}" "$APP/Contents/Info.plist"
lipo -archs "$APP/Contents/MacOS/$EXE" | grep -q "x86_64 arm64"     # same check iQualize runs [S]
# Sign the WHOLE bundle last (Info.plist must be sealed; editing it after signing => "damaged").
codesign --force --sign - --identifier "$BUNDLE_ID" \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" \
  "$APP"                                   # add: --entitlements Resources/BassShake.entitlements (optional)
codesign --verify --strict --verbose=2 "$APP"
( cd dist && ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "BassShake-macOS.zip" )
```
- `--deep` is unnecessary because there is no nested code. Add it only if you embed frameworks or helpers, and sign those inside-out instead.
- If `--arch` multi-builds cause trouble, use the fallback: `swift build -c release --triple arm64-apple-macosx14.4`, the same for `x86_64-apple-macosx14.4`, then `lipo -create .build/arm64-apple-macosx/release/BassShake .build/x86_64-apple-macosx/release/BassShake -output …` [S: OnlyEQ build-app.sh].

### 4.4 Workflow

Current major versions from `git ls-remote --tags`:
- `actions/checkout@v7`
- `actions/upload-artifact@v7` (node24; has `archive:`)
- `softprops/action-gh-release@v3` (node24; inputs include `tag_name`, `name`, `prerelease`, `files`, `target_commitish`, `generate_release_notes`, `make_latest`)

```yaml
name: build
on:
  push:
    branches: [main]
    tags: ["v*"]
  pull_request:
  workflow_dispatch:
permissions:
  contents: write
concurrency: { group: build-${{ github.ref }}, cancel-in-progress: true }
jobs:
  compat-xcode16:            # proves the code still builds with Xcode 16 / Swift 6.1
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v7
      - run: sudo xcode-select -s /Applications/Xcode_16.4.app && swift --version
      - run: swift build -c release
  package:
    runs-on: macos-26        # Xcode 26.6 default
    steps:
      - uses: actions/checkout@v7
      - run: swift --version
      - run: bash scripts/package-app.sh
      - uses: actions/upload-artifact@v7
        with:
          path: dist/BassShake-macOS.zip
          archive: false     # upload the zip as-is (avoid zip-in-zip). Never upload the raw .app dir: exec bits/symlinks are lost.
      - name: Prerelease (every push to main / tag)
        if: github.event_name == 'push'
        uses: softprops/action-gh-release@v3
        with:
          tag_name: ${{ startsWith(github.ref, 'refs/tags/') && github.ref_name || format('build-{0}', github.run_number) }}
          name: Bass Shake ${{ startsWith(github.ref, 'refs/tags/') && github.ref_name || format('build {0}', github.run_number) }}
          target_commitish: ${{ github.sha }}
          prerelease: true
          files: dist/BassShake-macOS.zip
          generate_release_notes: true
```

---

## 5. Gatekeeper steps for users (macOS 15 / 26 / 27)

On macOS 15 Sequoia Apple **removed the Control-click › Open bypass**. Unnotarized apps must be approved in System Settings (Cult of Mac, AppleInsider, mjtsai, 2024).

These steps follow iQualize's release notes, which were written with macOS Tahoe screenshots for exactly this ad-hoc-signed SwiftPM case [S]:
1. Unzip and move **Bass Shake.app** to /Applications.
2. Open it. The dialog says "Bass Shake Not Opened – Apple could not verify… free of malware". Click **Done**, not "Move to Trash".
3. Go to **System Settings › Privacy & Security** and scroll to **Security**. The row "Bass Shake was blocked…" only appears after step 2. Click **Open Anyway**.
4. Confirm **Open Anyway** again in the second dialog and enter your admin password if asked.
5. Allow the **system audio recording** prompt, which comes from Bass Shake itself.

The one-line alternative, after moving the app to /Applications:
```bash
xattr -dr com.apple.quarantine "/Applications/Bass Shake.app"
```
- If you see "**is damaged and can't be opened**", the signature is broken, not merely missing. The usual cause is editing the bundle after `codesign`. Re-sign as in 4.3.
- [U] Some guides say the "Open Anyway" button disappears about an hour after the blocked launch.
- [U] I have not confirmed whether macOS 27 changed the wording.

---

## 6. SwiftUI `MenuBarExtra(.window)`

**App structure** for a menu-bar-only app. `LSUIElement = true` means no Dock icon. `MenuBarExtra` and `.window` are available from macOS 13 [D], and `@Observable`/`.environment(_:)` from macOS 14:
```swift
import SwiftUI

@main
struct BassShakeApp: App {
    @State private var model = AppModel()          // @MainActor @Observable final class
    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(model)
                .frame(width: 360)                 // window style sizes to content; give a fixed width
        } label: {
            Image(systemName: model.isOn ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)
        // Optional: Settings { SettingsView().environment(model) }  + SettingsLink { Text("Settings…") }
    }
}
```
- The `MenuBarExtra(_ title:, systemImage:, content:)` and `init(content:label:)` forms compile from the macOS 13 SDK through the 27 SDK. The newest docs show `LocalizedStringResource`/`@ContentBuilder` overloads, but string literals still resolve [D].
- **No first-party API to open, close or query presentation.** MenuBarExtraAccess (`.menuBarExtraAccess(isPresented:)`, status item and NSWindow introspection) exists for this. FineTune uses FluidMenuBarExtra, an NSStatusItem plus NSPanel replacement [S]. OnlyEQ skips MenuBarExtra and uses an AppKit `NSStatusItem` [S]. MenuBarExtraAccess was last released in 2023; [U] on macOS 26/27.
- **Closing from inside.** With plain SwiftUI you cannot close the panel programmatically. Work around it with `NSApp.keyWindow?.close()` or MenuBarExtraAccess's binding.
- **Settings windows from an `LSUIElement` app.** `SettingsLink` (macOS 14 [D]) opens behind other apps unless you also call `NSApp.activate(ignoringOtherApps: true)` [U, a common community report].
- **Sizing.** The panel takes the content's fitting size. Animated height changes can jump, so prefer a fixed `frame(width:height:)` and in-place disclosure.

**60/120 fps meters.** Use `TimelineView(.animation(minimumInterval:paused:))` [D]. It is display-synced; `Timer` is not frame-locked and runs in `.default` run-loop mode. Pull the meters from the engine inside the `Canvas` renderer, not through `@Observable` state, so SwiftUI does not invalidate the whole view tree every frame:
```swift
final class MeterSource {          // NOT @Observable: polled per frame, no SwiftUI invalidation
    let engine: OpaquePointer
    private var smoothed: (Float, Float) = (0, 0)
    private var last = Date()
    init(engine: OpaquePointer) { self.engine = engine }
    func sample(at now: Date) -> (Float, Float) {
        let m = punch_take_meters(engine)          // PunchMeters; C float[2] imports as a tuple (Float, Float)
        let dt = Float(now.timeIntervalSince(last)); last = now
        let fall = expf(-dt / 0.3)                 // 300 ms release
        smoothed.0 = max(m.out_peak.0, smoothed.0 * fall)
        smoothed.1 = max(m.out_peak.1, smoothed.1 * fall)
        return smoothed
    }
}

struct MeterView: View {
    let source: MeterSource
    @State private var visible = false
    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !visible)) { tl in
            Canvas(rendersAsynchronously: false) { ctx, size in
                let (l, r) = source.sample(at: tl.date)
                let w = size.width / 2 - 2
                for (i, v) in [l, r].enumerated() {
                    let h = size.height * CGFloat(min(max(v, 0), 1))
                    ctx.fill(Path(CGRect(x: CGFloat(i) * (w + 4), y: size.height - h, width: w, height: h)),
                             with: .color(.green))
                }
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }   // [U] verify MenuBarExtra(.window) delivers onDisappear when the panel closes;
                                           // if not, observe NSWindow.didChangeOcclusionStateNotification.
    }
}
```
- Canvas initializer [D]: `Canvas(opaque:colorMode:rendersAsynchronously:renderer:)`, where the renderer is `(inout GraphicsContext, CGSize) -> Void`.
- Canvas is immediate-mode with no per-shape view diffing, which suits spectra, curves and meters. Keep paths small (for example 256 curve points from `punch_eq_curve`) and avoid allocating arrays per frame where you can.
- `.drawingGroup()` (Metal offscreen) is optional. Try it only if profiling shows a cost.
- OnlyEQ ties the frame rate to the screen's `maximumFramesPerSecond` (60 or 120 Hz ProMotion) [S].

**Dragging EQ nodes on a Canvas:**
```swift
struct EQCanvas: View {
    @Environment(AppModel.self) private var model
    @State private var dragging: Int?
    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in model.drawCurveAndNodes(in: &ctx, size: size) }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if dragging == nil { dragging = model.hitTestNode(v.startLocation, in: geo.size, radius: 10) }
                            if let i = dragging { model.moveNode(i, to: v.location, in: geo.size) } // -> punch_set_band + punch_engine_publish
                        }
                        .onEnded { _ in dragging = nil })
                .onContinuousHover { phase in model.hover(phase) }   // macOS 14 [D]
        }
    }
}
```
- `DragGesture` is `@MainActor`, so the callbacks run on main. That is the right thread for the engine's control API (`punch_set_*`, then `punch_engine_publish`).
- For finer Q or gain, use modifier keys (`NSEvent.modifierFlags`). SwiftUI on macOS 14 has no scroll-wheel gesture, so use an `NSViewRepresentable` overriding `scrollWheel(with:)` if you need it.
- The same gesture pattern appears in OnlyEQ's `EQCurveView.swift` (`Canvas` + `.gesture(DragGesture(minimumDistance: 0))`) [S].

---

## Unconfirmed items to test first on real hardware

1. Whether `kAudioSubDeviceInputChannelsKey: 0` really removes a headset mic from the aggregate and avoids the mic prompt (OnlyEQ claim).
2. Whether the identifier-only designated requirement keeps the TCC grant across CI builds (OnlyEQ claim).
3. What happens to system audio with `.mutedWhenTapped` when TCC is denied. Is it muted, and do we output silence? Add a watchdog.
4. Whether `TranslatePIDToProcessObject(getpid())` returns a valid object before our first IO.
5. Whether `MenuBarExtra(.window)` delivers `onDisappear` when the panel closes, which decides whether pausing the TimelineView works.
6. The tools version that introduced `.cxx20`, and whether libc++ is auto-linked. Check with the first CI run.

## URLs
- SDK headers: https://github.com/alexey-lysiuk/macos-sdk (MacOSX14.5.sdk / MacOSX26.5.sdk …/CoreAudio.framework/Versions/A/Headers/{CATapDescription.h, AudioHardwareTapping.h, AudioHardware.h}; CoreAudioTypes.framework/…/CoreAudioBaseTypes.h)
- Apple docs: https://developer.apple.com/documentation/coreaudio/catapdescription · …/audiohardwarecreateprocesstap(_:_:) · …/audiodevicecreateioprocidwithblock(_:_:_:_:) · …/audiodeviceioblock · …/unsafemutableaudiobufferlistpointer · https://developer.apple.com/documentation/swiftui/menubarextra · …/timelineschedule/animation(minimuminterval:paused:) · …/canvas · https://developer.apple.com/documentation/packagedescription/cxxlanguagestandard · https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos
- AudioCap (BSD-2): https://github.com/insidegui/AudioCap (AudioCap/ProcessTap/ProcessTap.swift, CoreAudioUtils.swift, AudioRecordingPermission.swift, README)
- OnlyEQ (Unlicense): https://github.com/zollans/OnlyEQ (Sources/OnlyEQ/Audio/ProcessTapEngine.swift, AudioDeviceManager.swift, scripts/build-app.sh, Resources/Info.plist, Package.swift)
- iQualize (MIT): https://github.com/dariuscorvus/iqualize (Package.swift, Sources/iQualizeCapture/main.swift, Sources/iQualize/CoreAudioHelpers.swift, scripts/install.sh, .github/workflows/release.yml, .github/release-notes/install-unsigned.md, AGENTS.md, CHANGELOG.md)
- FineTune (GPL-3, learned from only): https://github.com/ronitsingh10/FineTune (FineTune/Audio/Engine/ProcessTapController.swift, project.pbxproj settings, FineTune.entitlements, Info.plist)
- Runner images: https://github.com/actions/runner-images (README; images/macos/macos-26-arm64-Readme.md, macos-15-arm64-Readme.md, xcode-27-arm64-Readme.md)
- Actions: https://github.com/actions/upload-artifact (v7 README, `archive`), https://github.com/softprops/action-gh-release (v3 action.yml)
- Swift 6 isolation crash: https://forums.swift.org/t/crash-when-running-in-swift-6-language-mode/72431 · https://developer.apple.com/forums/thread/764777?page=2 · https://hackernoon.com/swift-6-gave-me-zero-warnings-but-two-objective-c-callbacks-still-crashed-at-runtime
- Gatekeeper/Sequoia: https://www.cultofmac.com/864843/macos-sequoia-removes-handy-shortcut-bypass-gatekeeper-security/ · https://mjtsai.com/blog/?p=43993
- Silent-zeros report (search summary only, site blocked here): https://dev.to/nickdelv/2000-buffers-of-nothing-3i8
- TCC + designated requirement: https://developer.apple.com/forums/thread/730043 (DTS → TN3127)
- MenuBarExtraAccess: https://github.com/orchetect/MenuBarExtraAccess
