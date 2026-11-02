---
title: Home Row Privacy Policy
---

# Home Row Privacy Policy

_Last updated: November 2, 2026_

Home Row is an SSH and Screen Sharing client for the Macs on your home
network. It's built so that your data stays on your iPhone and your own Macs.

## The short version

- Home Row **does not collect any data**. Nothing is sent to the developer or to
  any third party.
- There are **no accounts, no analytics, no advertising, no tracking, and no
  crash reporting**.
- Home Row only connects to devices on your **local network**. It refuses to
  connect to any address that isn't private, link-local or `.local`, and it
  uses no cloud relay.

## What stays on your iPhone

To work, Home Row keeps the following on your device:

- **Saved Macs**: each Mac's name, hostname, username, ports, pinned SSH host
  key, its last known local IP address and hardware (MAC) address (used for
  Wake-on-LAN), and when you last connected. These are stored in the app's
  local settings.
- **App settings**, such as font size, input mode, image quality and haptics.
- **Credentials**: the SSH key that Home Row generates on your iPhone, plus
  any Mac passwords you choose to save. These are kept in the iOS Keychain,
  marked "this device only", so they aren't synced to iCloud Keychain or
  moved to other devices. If you enable it, every use of the SSH key requires
  Face ID, Touch ID or your passcode.

When you pair a Mac with an SSH key, Home Row asks for your Mac password once
to add its public key to that Mac's `~/.ssh/authorized_keys`. That password is
used for that one step and isn't saved.

Your app settings and saved-Mac list may be included in your iPhone backups
(iCloud or computer), the same as other apps' data. Keychain items marked
"this device only" aren't restored to a different device.

## What goes between your iPhone and your Macs

When you connect, Home Row talks directly to your Mac over your local network:

- **Terminal (SSH):** your keystrokes and the terminal output. This traffic is
  encrypted by SSH.
- **Screen Sharing:** the Mac's screen image, your touches, mouse input and
  keystrokes. macOS Screen Sharing doesn't encrypt this stream for third-party
  clients, which is a big part of why Home Row only works on your local network.
- **Clipboard:** when you paste from your phone, Home Row sends your iPhone's
  clipboard text to the Mac. Text the Mac sends over Screen Sharing is put on
  your iPhone's clipboard.
- **Discovery and wake:** Home Row uses Bonjour to find Macs on your network
  and can send a Wake-on-LAN packet to wake a Mac you've saved.

None of this goes to the developer or to any server.

## Permissions

- **Local Network:** to find your Macs and connect to them.
- **Face ID:** to unlock the SSH key Home Row uses to sign in to your Macs.
  Face ID is handled entirely by iOS. Home Row never sees your face data.

## Deleting your data

You can remove a saved Mac, along with its saved password, from the Hosts screen (long-press → Edit).
Deleting Home Row removes its settings and saved Macs from your iPhone. To
revoke Home Row's access to a Mac, remove the `home-row-ed25519` line from
`~/.ssh/authorized_keys` on that Mac.

## Children

Home Row isn't aimed at children and collects no data from anyone.

## Changes

If this policy changes, the updated version will be posted here with a new
"Last updated" date.

## Contact

Questions? Email [itscharlieliu@gmail.com](mailto:itscharlieliu@gmail.com).
