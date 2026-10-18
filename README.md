<div align="center">
   <img width="217" height="217" src="./screenshots/swiftcontainer_icon.png" alt="SwiftContainer logo">
</div>

<div align="center">
  <h1><b>SwiftContainer</b></h1>
  <p><i>A SwiftStore app launcher. It runs iOS apps inside one host app, and it can turn an exported Swift Playgrounds package into an installed app in one pass.</i></p>
</div>

SwiftContainer is based on [LiveContainer](https://github.com/LiveContainer/LiveContainer). It is a launcher, not an emulator. Guest apps run as the SwiftContainer process, so they share its app ID, entitlements, and certificate.

This fork changes two things on top of that launcher: the app is rebranded in the SwiftStore orange theme, and a Create tab takes an exported `.swiftpm` package through GitHub Actions and installs the result on the device without a Mac.

## What changed from LiveContainer

**Orange SwiftStore rebrand.** The display name is SwiftContainer. Icons, accent, badges, banners, and AltStore source tint use the SwiftStore orange (`#FF5C25` in the app, `#FF5C24` in sources): a geometric swift facing right, with an open padlock cut out of the lower wing, on black. Settings, share sheet, and source copy use the new name.

The internal identity is unchanged so existing shortcuts and extra copies keep working. The bundle ID is still `com.kdt.livecontainer`, the URL scheme is still `livecontainer`, and the executable inside the IPA is still `LiveContainer`. A second and third copy are labeled SwiftContainer 2 and SwiftContainer 3, while their bundles stay `LiveContainer2` and `LiveContainer3`.

**A `.swiftpm` installs in one go.** LiveContainer only installs IPA files you already built. SwiftContainer treats an exported Swift Playgrounds package as an app to build. Open a `.swiftpm` from Files, or import it on the Create tab. One **Build and install** action then:

1. Creates or reuses a private GitHub repository named from the package.
2. Uploads the package plus a macOS Actions workflow.
3. Waits while a GitHub-hosted Mac runs `xcodebuild` and produces an unsigned IPA.
4. Downloads that IPA.
5. Signs it on the device with the certificate already stored in Settings.
6. Installs it into the Apps list.

You do not export an Xcode project, archive on a Mac, or run a separate signer. GitHub sign-in and a signing certificate are set up once. After that, each package is one action from import to installed app.

Apple ID credentials stay in the local signer. They are not uploaded with the project. Code is pushed only to a private repository on the signed-in GitHub account.

**SwiftInstaller is not in this app.** A separate bootstrap that installs SwiftContainer and can then be deleted is a future project. Nothing in this repository implements it.

## How it runs apps

SwiftContainer is installed once, with one app ID. Every guest app lives in a container inside it, so the free developer limit of 3 or 10 app IDs does not apply to those guests. The same app can have several data containers.

On launch, SwiftContainer picks the selected guest and:

1. Patches the guest Mach-O so dyld will load it. `__PAGEZERO` is moved to `0xFFFFC000` with a size of `0x4000`, `MH_EXECUTE` becomes `MH_DYLIB`, and a load command pulls in `TweakLoader.dylib`.
2. Hooks `_NSGetExecutablePath` so the process reports the guest executable path.
3. Replaces `NSBundle.mainBundle` with the guest bundle.
4. `dlopen`s the guest executable, lets TweakLoader inject the selected tweaks, finds the entry point, and jumps to it. The guest calls `UIApplicationMain` and runs like a normal iOS app.

Below iOS 26, JIT can skip codesign entirely, so a guest does not have to be signed before install. Without JIT, the guest is signed with the same certificate as SwiftContainer. On iOS 26 and later, signing is required.

Each container of an app can get its own keychain access group. The host declares 128 groups and assigns them so separate containers of the same app do not share keychain items.

What the host cannot do for a guest:

- Guest entitlements are not applied. Sideloaded apps usually only need the host’s basic entitlements.
- Permissions (camera, photos, and so on) are the host’s permissions.
- Guest containers are not sandboxed from each other.
- App extensions inside a guest cannot be registered with SpringBoard.
- Remote push does not work.
- Several apps at once need either the in-app multitasking windows (iOS 16+) or another installed copy of SwiftContainer.

## How a Playgrounds package becomes an app

The Create tab is the new path. It expects a Swift Playgrounds app exported as a `.swiftpm` folder, or a zip that contains one.

Sign in once with a GitHub OAuth device code, or paste a personal access token that has the `repo` and `workflow` scopes. The token stays in the device keychain. Import a signing certificate in Settings the same way LiveContainer does. SwiftContainer uses that certificate and does not implement its own Apple ID login.

When you tap **Build and install**:

- The package’s `Package.swift` supplies the display name, bundle ID, and iOS version.
- SwiftContainer writes those sources into a private repo, together with `BuildSupport/generate_xcodeproj.py` and `.github/workflows/swiftcontainer.yml`.
- The workflow turns the package into an unsigned iOS app project and archives it with `xcodebuild`. Code signing is disabled on the runner.
- The artifact is downloaded, optionally attached to a private GitHub release, written to a temporary file, and handed to the existing IPA installer.
- The installer signs with the on-device certificate and adds the app to the Apps tab.

A free GitHub account includes 2,000 Actions minutes per month. macOS runners count at 10×, which is typically 15 to 20 builds. A compile usually takes 2 to 5 minutes. The Create tab shows the account’s remaining Actions quota when GitHub returns it.

The same screen can copy the repository URL and an AltStore/SideStore `source.json` link, or add that source inside SwiftContainer. Another person can use the source only if they can read the repository. There is no central SwiftContainer server.

Opening a `.swiftpm` from Files switches straight to Create and loads that package, instead of trying to install the folder as an IPA.

## Installing and using the launcher

Requirements are iOS or iPadOS 15 or later, and AltStore 2.0+ or SideStore 0.6.0+. Multitasking needs iOS 16 or later.

Install an IPA from the plus button on the Apps tab, then long-press its banner to manage it. Home screen shortcuts, multiple copies, multitasking windows, JIT, tweak injection, extra data containers, and app hiding behave as they do in LiveContainer. Those guides still apply: [installation](https://livecontainer.github.io/docs/installation), [home screen](https://livecontainer.github.io/docs/guides/add-to-home-screen), [multiple copies](https://livecontainer.github.io/docs/guides/multiple-livecontainers), [multitasking](https://livecontainer.github.io/docs/guides/multitask), [JIT](https://livecontainer.github.io/docs/guides/jit-support), [tweaks](https://livecontainer.github.io/docs/guides/tweaks), [containers](https://livecontainer.github.io/docs/guides/containers-and-external-data).

Some guests need **Fix File Picker** or **Fix Local Notifications** in their own settings. To hand a file or URL to a guest, use the system share sheet and pick SwiftContainer, or use the link button on the Apps tab.

CI publishes `SwiftContainer.ipa`, plus `SwiftContainer+SideStore.ipa` and the 2-AppID and 1-AppID SideStore variants. To build locally, set `DEVELOPMENT_TEAM[config=Debug]` in `xcconfigs/Global.xcconfig` to your team ID and archive the `LiveContainer` scheme in Xcode. That scheme name is the Xcode target. The packaged file is still named `SwiftContainer.ipa`.

## Project layout

- **Main executable.** Sets up the guest environment and loads the selected app. With no app selected, it shows the SwiftUI interface.
- **LiveContainerSwiftUI.** The SwiftUI interface, including the Create tab (`LCBuildView`, `GitHubCloudClient`, `PlaygroundPackage`). Strings live in `Localizable.xcstrings`.
- **MultitaskSupport.** In-app windows, based on [FrontBoardAppLauncher](https://github.com/khanhduytran0/FrontBoardAppLauncher).
- **TweakLoader.** Injected into every guest. Loads CydiaSubstrate and the selected tweaks.
- **ZSign.** On-device signer, from [zhlynn/zsign](https://github.com/zhlynn/zsign) via [Feather](https://github.com/khcrysalis/Feather)’s fork.
- **SideStore support.** Refresh integration and the SideStore-bundled IPA variants.

## License

[GNU Affero General Public License v3.0](./LICENSE)

SwiftContainer is a modified LiveContainer. Launcher behavior that this README does not restate comes from that project and its contributors, including the dyld loading approach described in [Restoring Dyld Memory Loading](https://blog.xpnsec.com/restoring-dyld-memory-loading), [litehook](https://github.com/opa334/litehook), and [CFastFind](https://github.com/pinauten/PatchfinderUtils).
