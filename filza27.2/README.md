# Filza 27.2 — worse_query build

Filza fork for iOS 26.0–26.7.2 and iOS 27.0–27.2, built around
[forcequitOS/worse_query](https://github.com/forcequitOS/worse_query). It runs
under a normal Apple signing identity and does not require a jailbreak or a
root helper.

## Two builds

| | Public | Developer |
|---|---|---|
| Bundle ID | `com.jbjf.filza` | `com.jbjf.filzanb` |
| Display name | `filza27.2` | `filza27.2` |
| Install together | yes | yes |
| worse_query browser | yes | yes |
| App data / App Groups browser | yes | yes |
| WebDAV server | yes | yes |
| `.deb` installer + apt/dpkg | yes | yes |
| Terminal | — | full a-Shell command set |
| SSH server | — | mobile / root, password `alpine`, port 2222 |
| `mount`, `extract`, archive support | terminal only | yes |
| `neofetch`, `respring` | — | yes |

Release assets are named exactly:

```
filza_public.ipa
filza_develop.ipa
```

## Features

- Per-container worse_query grants for app, extension, internal-daemon and
  system-group data.
- App Manager names come from lsd's LaunchServices database (no per-app bundle
  reads needed) and each row shows the app data container size.
- App discovery uses the LaunchServices container list instead of a full
  inode scan on supported versions, so the first launch and App Manager open
  much faster.
- App icons are used where iOS returns them (`_applicationIconImageForBundle-`
  `Identifier:format:scale:`); otherwise Filza's placeholder is shown.
- Accessible roots, App Data (by app), App Data (UUID), App Groups and System
  Data links saved as Filza favorites.
- Startup progress overlay; first launch indexes installed apps and container
  families.
- Moves Filza's Trash into the app sandbox.
- In-process WebDAV server on port 11111 (fallback ports if busy).
- In-process dpkg/apt with support for `.deb` installation, `dpkg -l/-L/-s/-r`,
  `apt update/list/search/show/install/remove`.
- Developer terminal command set excludes Python, Node.js and Lua/TeX, and
  includes Perl, ImageMagick, FFmpeg, ripgrep, make and the rest of a-Shell.
- `mount` lists mounted filesystems.
- `extract`, `unzip`, `untar`, `un7z`, `unrar` extract zip, tar, tar.gz, gz,
  bz2, xz, zst, 7z and rar through libarchive.
- `test.deb` (official Procursus `apt 2.9.4-1`) and an executable `test` script
  are copied into `worse_query` on first launch.
- `respring` uses Erosion's WebKit pressure method.

## Build

Requirements:

- macOS with Theos and iOS SDKs.
- An unsigned Filza base IPA at `base/FilzaSlop-v1.2.0-unsigned.ipa`
  (or set `BASE_IPA`).
- A signing profile with at least one App Group. Set `WQ_APP_GROUPS`
  (space-separated).
- For the developer build: an a-Shell IPA at `$HOME/Downloads/Terminal.ipa`
  (or set `ASHELL_IPA`).

Public:

```sh
export WQ_APP_GROUPS="group.example.01"
export PROFILE="/path/to/profile.mobileprovision"
export ENTITLEMENTS="/path/to/entitlements.plist"
export SIGN_IDENTITY="Apple Distribution: ..."
export KEYCHAIN="$HOME/Library/Keychains/signing.keychain-db"
./scripts/build_public.sh
```

Developer:

```sh
export ASHELL_IPA="$HOME/Downloads/Terminal.ipa"
./scripts/build_developer.sh
```

Both:

```sh
./scripts/build_release.sh
# build/filza_public.ipa
# build/filza_develop.ipa
```

Without `SIGN_IDENTITY` the script produces an ad-hoc-signed IPA. Nested
Mach-O files and the app are signed in the same pass.

## Terminal quick test

```sh
cd "$(sbx_status | sed -n 's/^hub: //p')"
ls -l test test.deb
./test
mount
extract test.deb -C apt
extract sample.zip -C out
```

`./test` is a `#!/bin/dash` script; iOS does not allow executing Mach-O files
from the app data container, so scripts are run through the bundled `dash`.

SSH (developer build):

```sh
ssh -p 2222 mobile@DEVICE_IP     # password: alpine
ssh -p 2222 root@DEVICE_IP       # password: alpine
```

Sessions start in the `worse_query` hub.

## Signing notes

The app needs one App Group entitlement for worse_query. The public and
developer bundle IDs must match their provisioning profiles. The build script
removes Filza's `CFBundleURLTypes` and the bundled Sharing extension so the
single-App-ID profile can sign the app.

## Credits

- [0xjohnnydev/FilzaSlop](https://github.com/0xjohnnydev/FilzaSlop)
- [forcequitOS/worse_query](https://github.com/forcequitOS/worse_query)
- [a-Shell](https://github.com/holzschu/a-Shell) / ios_system
- [libssh](https://www.libssh.org/)
- [jailbreakdotparty/Erosion](https://github.com/jailbreakdotparty/Erosion) for
  the WebKit respring method
