# Audio Controller (macOS menu bar app)

Universal app (Intel + Apple Silicon), macOS 13+. Built on GitHub's servers into a `.dmg`. No Xcode needed.

## Build it
1. Create a new GitHub repository and upload everything in this folder (keep the folder structure).
   The workflow file must end up at `.github/workflows/build.yml`. If your upload skipped the hidden `.github` folder, use **Add file > Create new file**, type `.github/workflows/build.yml` as the name and paste the contents of `build.yml`.
2. Open the **Actions** tab. The "Build macOS DMG" run starts by itself (or click **Run workflow**). It takes about 5-10 minutes.
3. Download `AudioController.dmg`: from the finished run (**Artifacts**) or from the repository's **Releases > Latest build**.
4. Open the dmg, drag the app to Applications, then **right-click > Open** the first time (the app is not notarized).

## First run permissions
- **Accessibility** (and Input Monitoring if macOS lists it): needed for global shortcuts.
- **Automation**: asked on first control of Spotify, Music, VLC, Chrome, Safari, etc.
- Chrome/Brave/Edge: View > Developer > Allow JavaScript from Apple Events. Safari: Develop > Allow JavaScript from Apple Events.

## Default shortcuts (change them in the Shortcuts tab)
Ctrl+Option+Space play/pause, Ctrl+Option+Left/Right seek, Ctrl+Option+Up toggle 1x/2x, Ctrl+Option+Shift+Esc emergency disable.
Plain Space/arrows/Command can be assigned, but they then block that key in every app.

## Using it
- Opens as a normal app (Dock, Cmd-Tab, Force Quit, full screen). The menu bar icon opens the mini-player; right-click it for Open / Quit.
- Mini-player closes with the X button, Esc, a click elsewhere, or the 15 s timer. The power button quits the app.
- Folders you add are watched; new songs appear in Recents.

## Folders
- `Sources/AudioController/` Swift source
- `Resources/Info.plist` app metadata
- `Scripts/build.sh` run by GitHub, not by you
