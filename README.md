# Magicker Mouse

A macOS menu-bar app that maps Apple Magic Mouse taps, holds, and swipes to browser controls, system actions, and keyboard macros.

## Install

Download **Magicker-Mouse-24.zip** from [Releases](../../releases), unzip it, and move **Magicker Mouse.app** to Applications. Open it and grant Accessibility access under **System Settings → Privacy & Security → Accessibility** when prompted. If macOS blocks the download, review the prompt in Privacy & Security before opening it. The release build is ad hoc signed and has not been notarized.

Use **Gesture Actions** in the menu bar to customize or disable each gesture. For the left and right taps, holds, and horizontal swipes, plant one finger and move or touch with the other. For Refresh, slide both fingers toward your palm together and lift. macOS may also scroll during that motion.

| Gesture | Default action |
|---|---|
| Left tap / Right tap | Previous tab / Next tab |
| Left hold / Right hold | Paste / Copy |
| Swipe left / Swipe right | Backspace / Enter |
| Two-finger tap | App Exposé |
| Two-finger hold | Disabled |
| Two-finger swipe down | Refresh |
| Three-finger tap | Notification Center |
| Three-finger double tap | Close Window |
| Three-finger hold | Launchpad |
| Four-finger tap / hold | Disabled |

**Auto Reconnect** is off by default. Turn on **Auto Reconnect** to let the app respond to macOS touch-device connection changes. **Reconnect Mouse** is always available for a manual refresh. To start the app at login, add it under **System Settings → General → Login Items**. If upgrading from Magic Mouse Mapper, quit the old app and update its login item to point to Magicker Mouse. Saved gesture mappings carry over.

## Menu bar icons

Choose **Menu Bar Icon** from the app menu to switch among 13 styles. The selection is saved between launches.

## Compatibility

The download targets Apple silicon and macOS 15 or later. The app uses private macOS interfaces for touch capture and App Exposé, so behavior may vary by macOS version. The app expects one external multitouch device. Browser actions work in supported browsers, including Safari and Chrome.

## Build from source

Install the Xcode Command Line Tools, then run `bash build.sh`. The app and release ZIP appear in `build/`.
