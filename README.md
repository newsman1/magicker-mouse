# Magicker Mouse

A macOS menu-bar app that maps Apple Magic Mouse taps, holds, and swipes to browser controls, system actions, and keyboard macros.

## Install

Download **Magicker-Mouse-25.zip** from [Releases](../../releases), unzip it, and move **Magicker Mouse.app** to Applications. Open it and grant Accessibility access under **System Settings → Privacy & Security → Accessibility** when prompted. If macOS blocks the download, review the prompt in Privacy & Security before opening it. The release build is ad hoc signed and has not been notarized.

Use **Gesture Actions** in the menu bar to customize or disable each gesture. For the left and right taps, holds, and horizontal swipes, plant one finger and move or touch with the other. For Refresh, slide both fingers toward your palm together and lift. macOS may also scroll during that motion.

| Gesture | Default action |
|---|---|
| Left tap / Right tap | Previous tab / Next tab |
| Left hold / Right hold | Paste / Copy |
| Swipe left / Swipe right | Backspace / Enter |
| Two-finger tap | Space |
| Two-finger hold | Close Window |
| Two-finger swipe down | Refresh |
| Three-finger tap | Notification Center |
| Three-finger double tap | App Exposé |
| Three-finger hold | Launchpad |
| Four-finger tap / hold | Disabled |

**Auto Reconnect** is on by default and lets the app respond to macOS touch-device connection changes. **Reconnect Mouse** is always available for a manual refresh. To start the app at login, add it under **System Settings → General → Login Items**. If upgrading from Magic Mouse Mapper, quit the old app and update its login item to point to Magicker Mouse. Saved gesture mappings carry over.

## App exceptions

Use **App Exceptions → Add Application…**, select an app, then reopen **App Exceptions** and select that app. Check any gestures you want disabled there. Unchecked gestures use your normal **Gesture Actions** mappings. You can also disable or enable all listed gestures, or remove the app exception entirely.

Fresh installs include an exception for **Adobe Premiere Pro 2022** that disables **Two-Finger Hold**, so resting two fingers does not close an editing window. Other Premiere versions can be added separately. Existing saved mappings, icons, reconnect choices, and app exception lists take precedence over these defaults. Scrolling and Notification Center behavior are unchanged.

## Menu bar icons

Choose **Menu Bar Icon** from the app menu to switch among 13 styles. Lightning Mouse is the fresh-install default. The selection is saved between launches.

## Compatibility

The download targets Apple silicon and macOS 15 or later. The app uses private macOS interfaces for touch capture and App Exposé, so behavior may vary by macOS version. The app expects one external multitouch device. Browser actions work in supported browsers, including Safari and Chrome.

## Build from source

Install the Xcode Command Line Tools, then run `bash build.sh`. The app and release ZIP appear in `build/`.
