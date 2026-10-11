// swift-tools-version:5.10
// Swift 5 language mode on purpose: Core Audio's C callbacks and property
// listener blocks predate Sendable, and the real-time path is C anyway.
import PackageDescription

let package = Package(
  name: "BassShake",
  platforms: [.macOS("14.4")],  // process taps are reliable from 14.4
  products: [
    .executable(name: "BassShake", targets: ["BassShake"]),
  ],
  targets: [
    // Portable C++ DSP engine (also built + tested with CMake on Linux).
    .target(
      name: "PunchCore",
      path: "core",
      exclude: ["tests", "tools", "CMakeLists.txt", "README.md"],
      sources: ["src"],
      publicHeadersPath: "include",
      cxxSettings: [
        .unsafeFlags(["-O3", "-fno-math-errno"], .when(configuration: .release)),
      ]
    ),
    // Real-time IOProc glue (C, no Swift on the audio thread).
    .target(
      name: "BassShakeRT",
      dependencies: ["PunchCore"],
      path: "mac/Sources/BassShakeRT",
      cSettings: [.unsafeFlags(["-O3"], .when(configuration: .release))],
      linkerSettings: [.linkedFramework("CoreAudio")]
    ),
    .executableTarget(
      name: "BassShake",
      dependencies: ["PunchCore", "BassShakeRT"],
      path: "mac/Sources/BassShake",
      linkerSettings: [
        .linkedFramework("CoreAudio"),
        .linkedFramework("AudioToolbox"),
        .linkedFramework("Accelerate"),
        .linkedFramework("AppKit"),
        .linkedFramework("SwiftUI"),
      ]
    ),
  ],
  cxxLanguageStandard: .cxx20
)
