# toothless-ip-camera
An iOS app turning your iPhone into an IP camera

Native SwiftUI app for iOS 17 or later. The iPhone runs an RTSP server and sends
hardware-encoded H.264 video over RTP, with UDP or interleaved TCP transport.
No relay server or cloud account is needed.

## Developer Quick Start

### Prerequisites

- macOS and Xcode with the iOS 17.4 SDK or later. The deployment target is iOS 17;
	the newer SDK is needed to compile the hardware-encoder availability check.
	Builds have been verified with Xcode 27.
- Select Xcode under **Xcode > Settings > Locations > Command Line Tools** so
	`swift` and `xcodebuild` use the same toolchain.
- For device testing, an iPhone running iOS 17 or later, paired with Xcode and
	with Developer Mode enabled under **Settings > Privacy & Security**.
- Add your Apple Account under **Xcode > Settings > Accounts** for signing.
	A Personal Team can be used for local device testing, subject to Apple's free
	provisioning limits; distribution requires the appropriate developer membership.
- Optional: FFmpeg with `libx264` for interoperability tests and `ffplay` for
	viewing streams. The protocol tests do not require an iPhone.

### Set Up and Run

1. Clone the repository and open a terminal in its root directory.
2. Create `Config/Signing.local.xcconfig` and set your development team ID using
	 the [local signing instructions](#local-signing) below. Never put it in the
	 shared Xcode project or `Config/Signing.xcconfig`.
3. Open the maintained project:

	 ```sh
	 open ToothlessCamera.xcodeproj
	 ```

4. Select the **ToothlessCamera** scheme and a physical iPhone. In the app target's
	 **Signing & Capabilities**, leave automatic signing enabled. The team should
	 resolve from the local configuration; do not select it using the Team picker.
	 Change the bundle identifier to a unique value if provisioning reports that
	 `com.toothless.camera` is unavailable. Bundle identifiers are shared project
	 settings, so review that change before committing.
5. Run with **Product > Run**. On the phone, allow Camera and Local Network access.
6. Follow [Run on an iPhone](#run-on-an-iphone) to connect a player to the stream.
	 Use a trusted local network; the stream has no authentication or encryption.

For a first check without device signing, run the commands in [Test](#test).
The simulator can run the UI but cannot replace physical camera/encoder testing.
No project-generation tool or external package installation is needed to build
the app; `StreamingCore` is a local Swift package in this repository.

## Run on an iPhone

1. Open `ToothlessCamera.xcodeproj` in Xcode.
2. Set your team ID in `Config/Signing.local.xcconfig` as described below. Select
	 the `ToothlessCamera` target and use a unique bundle identifier if needed.
3. Select a physical iPhone and run. Allow Camera and Local Network access.
4. Connect the phone and player to the same local network. Tap **Start streaming**.
5. Open the URL shown in the main screen in VLC using **Open Network**:
	 `rtsp://<iphone-ip>:8554/live`.

The screen includes a live preview, front/back camera selection, streaming status,
elapsed time, viewer count, and copy/share buttons for the stream URL. Camera
selection is available while stopped. Portrait video is 720 x 1280, targeting
30 fps and 2 Mbps, with a keyframe every second.

For FFmpeg/ffplay, choose either transport:

```sh
ffplay -rtsp_transport tcp rtsp://<iphone-ip>:8554/live
ffplay -rtsp_transport udp rtsp://<iphone-ip>:8554/live
```

The app keeps the screen awake during streaming. Locking the phone or putting the
app in the background stops capture and streaming; start again after returning.
The simulator can display the UI but cannot validate iPhone camera capture.

## Local Signing

Debug and Release both use `Config/Signing.xcconfig`, which optionally includes
the Git-ignored `Config/Signing.local.xcconfig`.

1. Find your **10-character Team ID** in your Apple Developer account's
	**Membership details**. It is not your Apple Account email or team display name.
	You can also copy the `DEVELOPMENT_TEAM` value from Build Settings in another
	Xcode project already signed with the same team, including a Personal Team.
2. Create `Config/Signing.local.xcconfig` locally with this content, replacing the
	placeholder with your actual ID:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

3. Confirm the file is ignored from the repository root:

	```sh
	git check-ignore -v Config/Signing.local.xcconfig
	```

	The output should identify the signing-file rule in `.gitignore`. Do not force
	add this file. On a new checkout it must be recreated locally.

Edit that local file to change your team. Avoid changing the Team picker in Xcode:
it can write a `DEVELOPMENT_TEAM` override back into the shared project file.
Without the local file, unsigned simulator builds still work; signed device builds
require a team and the appropriate certificate/profile.

If Xcode reports that a team is missing, check the file name and ID, ensure the
account belongs to that team, and remove any target-level `DEVELOPMENT_TEAM`
override in Build Settings. Both app configurations should inherit the value
through `Config/Signing.xcconfig`. If provisioning fails, check the bundle
identifier, device registration, and signing certificate in Xcode's Accounts
settings. Do not commit certificates, profiles, or private keys to fix signing.

Local signing settings, `.p12` files, `.p8` keys, and `.mobileprovision` profiles are
ignored by Git. Keep private keys in Keychain or a CI secret store. Review
`git diff --cached` before committing; ignore rules do not remove files already
tracked or erase Git history, and `git add -f` can bypass them.

## Test

```sh
swift test
xcodebuild -project ToothlessCamera.xcodeproj -scheme ToothlessCamera \
	-sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
	CODE_SIGNING_ALLOWED=NO build
```

Tests cover RTP fragmentation, sequence rollover, marker bits, RTCP counters,
incremental RTSP parsing, transport validation, and real TCP/UDP RTSP sessions.
When FFmpeg is installed with the `libx264` encoder, two additional tests generate
H.264 video and verify decoding through RTSP over both transports. They skip when
FFmpeg is not installed.
Camera permissions, capture, orientation, thermal behavior, and playback over an
actual Wi-Fi network still require testing on a physical iPhone.