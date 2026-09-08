# vcam

A native macOS utility for creating vertical screen videos. Frame any app, check your composition, and move the recording area while you record.

Built for our own workflow at Code with Beto. This is an early version and will keep evolving.

## Features

- A movable 9:16 recording frame, with free, horizontal, and vertical movement.
- Switch between one region and two or three stacked regions while recording, with adjustable dividers.
- Add your camera to any stacked region or use a movable, resizable overlay. Turn it off and back on during a take.
- Zoom and reposition the camera image inside its frame to focus on your face.
- Safe-area and caption guides in the output preview that do not appear in the saved video.
- A resizable live preview, microphone selection, input-channel controls, and a decibel meter.
- Cancel, restart, or finish a take from the app or floating frame controls.
- 1080 × 1920 or 1440 × 2560 (2K) MP4 export at 30 or 60 fps.
- Editable frame dimensions, accurate SDR colors, and optional landscape recording.

## Run locally

Requires **macOS 15+** and **Xcode 27 beta** for the current project format.

```sh
git clone https://github.com/Code-with-Beto/vcam.git
open vcam/vcam.xcodeproj
```

1. Select the **vcam** scheme and **My Mac**. Choose your signing team under **Signing & Capabilities**, then press **⌘R**.
2. Follow the access setup, select your microphone, and choose a save folder.
3. Use **Setup** for devices and export format, and **Live** for layout, frame size, and camera placement. Show and position the frames, start preview, then press **Record**. Resize the app window for a larger preview.
4. **Finish** saves the video and opens it in **QuickTime Player**. **Cancel** discards the current take; **Restart** discards it and starts a fresh take with the same composition.

To include your face, choose a camera device and enable access in **Setup**. In **Live**, choose **Floating overlay** or replace a stacked region. For camera + simulator + code, choose **3 stacked** and assign the camera to A, B, or C. Position the other two capture frames over your apps, then drag the preview dividers to balance the sections. All regions are saved in one video, with your separately selected microphone.

Use the camera's **Zoom** slider for a closer crop. Choose **Adjust crop**, then drag inside the camera image to frame your face. **Done** returns to moving the overlay; **Reset** restores the original framing. These adjustments also work during recording.

Use **Safe areas** in the preview to check the full video's edge margins, and enable **Reserve caption space** for subtitles. These are general composition guides. The entire outer frame is recorded. Layout and camera placement can change during a take; output format and devices are set beforehand.

**⇧⌘R** starts or stops recording. **⇧⌘F** shows or hides the frame while idle.

Build details and validation commands are in [the developer notes](docs/DEVELOPMENT.md). Feedback and ideas are welcome in [Issues](https://github.com/Code-with-Beto/vcam/issues).

## Code with Beto

We create tools, courses, and app templates to help you build and ship your own apps. Explore more at [codewithbeto.dev](https://codewithbeto.dev).

- [Learn React Native & Expo](https://cwb.sh/rn?r=vcam-readme): build real iOS and Android apps with our practical course.
- [Get Pro Access](https://cwb.sh/pro?r=vcam-readme): courses, premium codebases, Figma files, and priority support.
- [Explore Platano](https://cwb.sh/platano?r=vcam-readme): an AI image-app starter with payments and generation built in.
- [Watch on YouTube](https://cwb.sh/youtube?r=vcam-readme): tutorials on React Native, Expo, and building with AI.
