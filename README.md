# vcam

A native macOS utility for creating vertical screen videos. Frame any app, check your composition, and move the recording area while you record.

Built for our own workflow at Code with Beto. This is an early version and will keep evolving.

## Features

- A movable 9:16 recording frame, with free, horizontal, and vertical movement.
- Two independent regions in side-by-side or stacked layouts, with a divider you can adjust while recording.
- Add your camera to either region, or use a movable, resizable camera overlay above the screen layout.
- Composition and caption guides that do not appear in the saved video.
- Live preview, microphone selection, input-channel controls, and a decibel meter.
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
3. Choose **Single region**, **Side by side**, or **Stacked**, then show and position the frames. Start preview and press **Record** when ready. In split layouts, drag the preview divider to adjust the balance; both regions are saved in one video.
4. Stop recording to save the video and open it automatically in **QuickTime Player**.

To include your face, choose a camera placement and device, then enable Camera access. **Floating overlay** keeps both screen regions; drag the camera or its resize handle in the preview, even while recording. In a split layout, the camera can also fill **Region A** or **Region B**. Your microphone is selected separately.

**⇧⌘R** starts or stops recording. **⇧⌘F** shows or hides the frame while idle.

Build details and validation commands are in [the developer notes](docs/DEVELOPMENT.md). Feedback and ideas are welcome in [Issues](https://github.com/Code-with-Beto/vcam/issues).

## Code with Beto

We create tools, courses, and app templates to help you build and ship your own apps. Explore more at [codewithbeto.dev](https://codewithbeto.dev).

- [Learn React Native & Expo](https://cwb.sh/rn?r=vcam-readme): build real iOS and Android apps with our practical course.
- [Get Pro Access](https://cwb.sh/pro?r=vcam-readme): courses, premium codebases, Figma files, and priority support.
- [Explore Platano](https://cwb.sh/platano?r=vcam-readme): an AI image-app starter with payments and generation built in.
- [Watch on YouTube](https://cwb.sh/youtube?r=vcam-readme): tutorials on React Native, Expo, and building with AI.
