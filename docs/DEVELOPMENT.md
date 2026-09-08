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
- Each `FrameOverlayController` owns nonactivating border and handle panels. Blue A, orange B, and purple C move independently, including their movement locks. ScreenCaptureKit excludes the entire vcam application from capture.
- `CaptureEngine` captures one selected display, crops cached frames on a serial queue with Core Image, and writes H.264 MP4 through AVAssetWriter. Split layouts sample all regions from the same source buffer and compose them into one output. Moving frames or either divider does not restart the stream.
- Capture and rendering use sRGB with explicit buffer color tags. AVAssetWriter converts to standard Rec.709 video. Source-pixel-aligned crop positions prevent fractional-position blur.
- The native preview uses IOSurface-backed buffers and AVSampleBufferDisplayLayer, capped at 30 fps.
- `CaptureMicrophone` uses AVFoundation to capture the selected device. `CapturePCM` routes a physical input to mono AAC and computes peak dBFS. Auto selects between the first two inputs and locks the choice for a take.
- `CaptureCamera` owns a separate AVFoundation video session on a serial control queue. The compositor uses its latest frame as region A/B/C or a masked overlay. Live activation waits for a valid frame before publishing camera placement; Off releases the camera. Camera transitions never restart screen capture, microphone capture, or the current writer. The shared preview/export composition applies mirroring once and respects the camera's color attachments. Camera input never supplies or replaces the selected microphone track.

Microphone timestamps are converted to the screen stream's clock. Finalization drains queued audio, and quitting waits for a recording to finish. App Sandbox and Hardened Runtime remain enabled.

All screen regions stay within one selected display. Single, two-stack, and three-stack layouts share the selected output resolution. Panels are ordered A/B/C from top to bottom. Three-stack uses two cumulative boundaries, each constrained to leave at least 15% for every panel. The compositor rounds cumulative boundaries to even output pixels so panels tile without gaps or overlap. Layout and split changes are live, applied atomically with camera composition on the render queue. Source frames follow their output panel's aspect ratio; the compositor defensively uses centered aspect-fill for mismatched frames, avoiding stretching. Automatic split resizing preserves the requested width when a region temporarily reaches the display bounds. Hidden B/C source frames remain available when switching back to more panels. Legacy horizontal split preferences migrate to two-stack, retaining both sources.

The Live tab exposes screen-source sizing, camera placement, overlay geometry, and mirroring during recording. Setup holds device and encoding settings; output orientation, resolution, frame rate, and devices remain fixed during a take. Switching a camera region to Single keeps it as an overlay. Camera access can be requested explicitly in Setup, including during a screen-only take. A camera interruption turns it Off and leaves screen and microphone recording active. Guide margins are composition suggestions, and divider/resize controls never appear in the saved video. Separate per-region files, capture across multiple displays, system audio, and editing are not currently implemented.

The main window has a flexible native preview and a scrolling settings sidebar. Resizing the window changes only preview presentation, preserving output dimensions and screen-source regions. Finish saves and opens QuickTime. Cancel serially detaches and cancels the unfinished writer, then deletes only its active output URL. Restart uses the same operation followed by a new writer, with a fresh timeline and microphone channel selection. Screen/camera/microphone capture and folder access remain active across the restart; previously saved recordings are never deleted.

Safe-area guides are drawn only by the SwiftUI preview, across the final canvas rather than within each source region. They use an 8% edge margin and optional 20% bottom caption margin. The guide converts the shared bottom-left geometry to top-left preview coordinates and ignores hit testing. Screen capture rectangles retain only their outer border and region identity. Safe areas, labels, and divider/crop controls never enter the encoded video.

Camera framing is separate from overlay placement. `CameraFramingConfiguration` stores 1–4× zoom and a normalized focal center in the displayed source's top-left coordinates. The shared source-crop calculation fills the destination at its aspect ratio and clamps within the camera image, then the compositor scales it into either the overlay or a stacked panel. Preview and export use the same crop. Source dimensions come from current camera frames, including portrait cameras; stale-session updates are ignored. Crop editing pans the image inside its frame, while normal overlay gestures move and resize the frame itself. Changing Mirror reflects the focal center to keep the same subject framed.

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

xcrun swiftc -D VCAM_CAPTURE_VALIDATION -swift-version 5 \
  -target arm64-apple-macos15.0 \
  vcam/CaptureTypes.swift vcam/CapturePCM.swift vcam/CaptureMicrophone.swift \
  vcam/CaptureCamera.swift vcam/CaptureEngine.swift scripts/validate-recording-lifecycle.swift \
  -o /tmp/vcam-validate-recording-lifecycle
/tmp/vcam-validate-recording-lifecycle

sed -e 's/UserDefaults\.standard/ModelValidation.defaults/g' \
  -e 's/private func restoreFrame()/func restoreFrame()/' vcam/RecorderModel.swift \
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

The checks cover crop geometry, Retina scaling, negative display origins, pixel alignment, frame timing, movement over static content, microphone routing, and audio/video alignment. Color validation compares known sRGB patches and stripe detail with both preview buffers and decoded video. Composition validation decodes recordings of one, two, and three regions, checking independent A/B/C movement, both live dividers, count transitions on one timeline, exact panel placement, unstretched shapes, and mono audio.

Model validation redirects a temporary source copy to an isolated preferences suite and exposes its frame restoration method only in that copy. It checks source sizing through narrow splits, display clamping, layout/orientation roundtrips, independent B/C edits, remembered two/three-panel divider positions, restored hidden source frames, legacy layout migration, camera A/B/C transitions, and camera framing persistence/reset without requesting permissions or starting capture.

Camera validation uses a generated Rec.709 NV12 camera feed and an independent color reference. It checks overlay movement, resizing, both masks, zoom/pan/reset, mirrored framing, crop boundaries, camera replacement in A/B/C, live Off/On and layout transitions on one writer timeline, physical-provider release, and microphone preservation. Live camera capture targets 1080p at up to 30 fps; a 60 fps screen export uses the latest available camera frame.

Recording lifecycle validation exercises camera startup failures, no-frame timeouts, cancellation during activation, late callbacks from stopped cameras, and recoverable interruption. It verifies discard removes only the unfinished take, restart retains capture inputs, and earlier saved/unrelated files survive. The restarted movie is fully decoded to verify video timestamps, nonzero microphone samples, and audio/video alignment.

For a manual check, drag while recording, confirm the target app keeps keyboard focus, speak while performing a visible action, and play the saved file to check perceived synchronization.
