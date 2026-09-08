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
- Each `FrameOverlayController` owns nonactivating guide and handle panels. Blue A and orange B move independently, including their movement locks. ScreenCaptureKit excludes the entire vcam application from capture.
- `CaptureEngine` captures one selected display, crops cached frames on a serial queue with Core Image, and writes H.264 MP4 through AVAssetWriter. Split layouts sample both regions from the same source buffer and compose them into one output. Moving frames or the divider does not restart the stream.
- Capture and rendering use sRGB with explicit buffer color tags. AVAssetWriter converts to standard Rec.709 video. Source-pixel-aligned crop positions prevent fractional-position blur.
- The native preview uses IOSurface-backed buffers and AVSampleBufferDisplayLayer, capped at 30 fps.
- `CaptureMicrophone` uses AVFoundation to capture the selected device. `CapturePCM` routes a physical input to mono AAC and computes peak dBFS. Auto selects between the first two inputs and locks the choice for a take.
- `CaptureCamera` owns a separate AVFoundation video session on a serial control queue. The compositor uses its latest frame as region A/B or a masked overlay. The shared preview/export composition applies mirroring once and respects the camera's color attachments. Camera input never supplies or replaces the selected microphone track.

Microphone timestamps are converted to the screen stream's clock. Finalization drains queued audio, and quitting waits for a recording to finish. App Sandbox and Hardened Runtime remain enabled.

Both regions stay within one selected display. Single, side-by-side, and stacked layouts share the selected output resolution. A occupies the left or top portion; its split ratio ranges from 15% to 85%, with even output-pixel boundaries. Layout changes are locked during recording, but the split remains adjustable. Source frames follow their output panel's aspect ratio; the compositor defensively uses centered aspect-fill for mismatched frames, avoiding stretching. Automatic split resizing preserves the requested scale when a region temporarily reaches the display bounds.

Individual screen-source sizes are editable during preview and locked during recording. Camera overlay position, size, shape, and mirroring remain adjustable during recording. Camera device and placement changes restart an idle preview; switching a camera region to a single layout keeps the camera as an overlay. Camera access is requested only when enabled, and denying it does not block screen-only recording. Guide margins are composition suggestions, and divider/resize controls never appear in the saved video. Separate per-region files, capture across multiple displays, system audio, and editing are not currently implemented.

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
  vcam/CaptureCamera.swift vcam/CaptureEngine.swift scripts/validate-capture.swift \
  -o /tmp/vcam-validate-capture
/tmp/vcam-validate-capture 30
/tmp/vcam-validate-capture 60
/tmp/vcam-validate-capture 30 1440 portrait
/tmp/vcam-validate-capture 30 1440 landscape

xcrun swiftc -D VCAM_CAPTURE_VALIDATION -swift-version 5 \
  -target arm64-apple-macos15.0 \
  vcam/CaptureTypes.swift vcam/CapturePCM.swift vcam/CaptureMicrophone.swift \
  vcam/CaptureCamera.swift vcam/CaptureEngine.swift scripts/validate-color.swift \
  -o /tmp/vcam-validate-color
/tmp/vcam-validate-color 1080
/tmp/vcam-validate-color 1440

xcrun swiftc -D VCAM_CAPTURE_VALIDATION -swift-version 5 \
  -target arm64-apple-macos15.0 \
  vcam/CaptureTypes.swift vcam/CapturePCM.swift vcam/CaptureMicrophone.swift \
  vcam/CaptureCamera.swift vcam/CaptureEngine.swift scripts/validate-composition.swift \
  -o /tmp/vcam-validate-composition
/tmp/vcam-validate-composition
/tmp/vcam-validate-composition 2560 1440

xcrun swiftc -D VCAM_CAPTURE_VALIDATION -swift-version 5 \
  -target arm64-apple-macos15.0 \
  vcam/CaptureTypes.swift vcam/CapturePCM.swift vcam/CaptureMicrophone.swift \
  vcam/CaptureCamera.swift vcam/CaptureEngine.swift scripts/validate-camera.swift \
  -o /tmp/vcam-validate-camera
/tmp/vcam-validate-camera

sed 's/UserDefaults\.standard/ModelValidation.defaults/g' vcam/RecorderModel.swift \
  > /tmp/vcam-model-validation-source.swift
xcrun swiftc -swift-version 5 -target arm64-apple-macos15.0 \
  vcam/CaptureTypes.swift vcam/CapturePCM.swift vcam/CaptureMicrophone.swift \
  vcam/CaptureCamera.swift vcam/CaptureEngine.swift vcam/CameraPreview.swift vcam/SafeAreaGuide.swift \
  vcam/FrameOverlay.swift vcam/GlobalShortcuts.swift \
  /tmp/vcam-model-validation-source.swift scripts/validate-model.swift \
  -o /tmp/vcam-validate-model
/tmp/vcam-validate-model
```

These commands target Apple silicon. For an Intel Mac, use `x86_64-apple-macos15.0` instead; that configuration has not been validated yet.

The checks cover crop geometry, Retina scaling, negative display origins, pixel alignment, frame timing, movement over static content, microphone routing, and audio/video alignment. Color validation compares known sRGB patches and stripe detail with both preview buffers and decoded video. Composition validation decodes recordings of single, side-by-side, and stacked layouts, checking independent A/B movement, a live split change, exact panel placement, unstretched shapes, and mono audio.

Model validation redirects a temporary source copy to an isolated preferences suite. It checks source sizing through narrow splits, display clamping, layout/orientation roundtrips, and independent region edits without requesting permissions or starting capture.

Camera validation uses a generated Rec.709 NV12 camera feed and an independent color reference. It checks overlay movement, resizing, both masks, mirroring, camera replacement in either region, screen-only output after disabling the camera, and microphone preservation. Live camera capture targets 1080p at up to 30 fps; a 60 fps screen export uses the latest available camera frame.

For a manual check, drag while recording, confirm the target app keeps keyboard focus, speak while performing a visible action, and play the saved file to check perceived synchronization.
