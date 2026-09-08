# Development

vcam is a SwiftUI and AppKit macOS app. The deployment target is macOS 15; the project currently uses Xcode 27's project format.

## Build

Select Xcode 27 beta under **Xcode → Settings → Locations → Command Line Tools**, or set `DEVELOPER_DIR` to that installation's `Contents/Developer` directory. Choose your own signing team in the project before building.

```sh
xcodebuild -project vcam.xcodeproj -scheme vcam -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build build
```

Keep one copy running while testing so the controls and permission prompts belong to the same app. Screen recording access is required for preview and recording. Microphone access is optional when **No microphone** is selected. The setup panel rechecks access when you return from System Settings and explains when a restart is needed.

## Capture pipeline

- `RecorderModel` coordinates settings, access, save-folder bookmarks, and recording lifetime.
- `FrameOverlayController` owns separate nonactivating guide and handle panels. ScreenCaptureKit excludes the entire vcam application from capture.
- `CaptureEngine` captures a selected display, crops cached frames on a serial queue with Core Image, and writes H.264 MP4 through AVAssetWriter. Moving the frame does not restart the stream.
- Capture and rendering use sRGB with explicit buffer color tags. AVAssetWriter converts to standard Rec.709 video. Source-pixel-aligned crop positions prevent fractional-position blur.
- The native preview uses IOSurface-backed buffers and AVSampleBufferDisplayLayer, capped at 30 fps.
- `CaptureMicrophone` uses AVFoundation to capture the selected device. `CapturePCM` routes a physical input to mono AAC and computes peak dBFS. Auto selects between the first two inputs and locks the choice for a take.

Microphone timestamps are converted to the screen stream's clock. Finalization drains queued audio, and quitting waits for a recording to finish. App Sandbox and Hardened Runtime remain enabled.

The frame stays within one selected display. Its size is editable during preview and locked during recording. Guide margins are composition suggestions; the full frame is saved. System audio, webcam overlays, and editing are not currently implemented.

## Validation

Run from the repository root with the same selected Xcode installation. These checks use generated pixels and audio; they do not capture the screen or microphone.

```sh
xcrun swiftc -swift-version 5 -target arm64-apple-macos15.0 \
  vcam/CaptureTypes.swift scripts/validate-geometry.swift \
  -o /tmp/vcam-validate-geometry
/tmp/vcam-validate-geometry

xcrun swiftc -D VCAM_CAPTURE_VALIDATION -swift-version 5 \
  -target arm64-apple-macos15.0 \
  vcam/CaptureTypes.swift vcam/CapturePCM.swift vcam/CaptureMicrophone.swift \
  vcam/CaptureEngine.swift scripts/validate-capture.swift \
  -o /tmp/vcam-validate-capture
/tmp/vcam-validate-capture 30
/tmp/vcam-validate-capture 60
/tmp/vcam-validate-capture 30 1440 portrait
/tmp/vcam-validate-capture 30 1440 landscape

xcrun swiftc -D VCAM_CAPTURE_VALIDATION -swift-version 5 \
  -target arm64-apple-macos15.0 \
  vcam/CaptureTypes.swift vcam/CapturePCM.swift vcam/CaptureMicrophone.swift \
  vcam/CaptureEngine.swift scripts/validate-color.swift \
  -o /tmp/vcam-validate-color
/tmp/vcam-validate-color 1080
/tmp/vcam-validate-color 1440
```

These commands target Apple silicon. For an Intel Mac, use `x86_64-apple-macos15.0` instead; that configuration has not been validated yet.

The checks cover crop geometry, Retina scaling, negative display origins, pixel alignment, frame timing, movement over static content, microphone routing, and audio/video alignment. Color validation compares known sRGB patches and stripe detail with both preview buffers and decoded video.

For a manual check, drag while recording, confirm the target app keeps keyboard focus, speak while performing a visible action, and play the saved file to check perceived synchronization.
