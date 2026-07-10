# Signing and notarization

Plate ships outside the Mac App Store, so its releases take the Developer ID
route: a **Developer ID Application** signature, the **hardened runtime**, and
an Apple **notarization** ticket stapled to both the `.app` and the `.dmg`.
That combination is what lets a downloaded build open on a double-click instead
of "Plate.app cannot be opened because the developer cannot be verified".

Everything below is done once. After that, pushing a `v*` tag produces signed,
notarized DMGs on its own.

- Team ID: `R6QM7B7GB7` — the paid team. The free personal team `PZKFWN2C3U`,
  which the *Apple Development* certificate belongs to, cannot sign releases;
  using it fails with `No certificate for team 'PZKFWN2C3U' found`.
- Bundle ID: `com.lfkdsk.Plate`
- The app declares **no entitlements**. It isn't sandboxed, and its Live Photo
  support reads local files via `PHLivePhoto.request(withResourceFileURLs:)`
  rather than touching the system photo library, so it needs no TCC-gated
  entitlement. If that ever changes, add an `.entitlements` file and wire it up
  through `CODE_SIGN_ENTITLEMENTS` in `PlateApp/project.yml`.

## 1. Create the Developer ID Application certificate

An **Apple Development** certificate is not enough — it cannot be notarized,
and the result only runs on the machine that built it.

Xcode ▸ Settings ▸ Accounts ▸ (your Apple ID) ▸ Manage Certificates ▸ **+** ▸
**Developer ID Application**.

Confirm it landed:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

## 2. Create an App Store Connect API key for notarytool

App Store Connect ▸ Users and Access ▸ Integrations ▸ **App Store Connect API**
▸ **+**. Give it the **Developer** role. Download the `.p8` — it is offered
exactly once — and note the **Key ID** and the **Issuer ID**.

A key is preferable to an app-specific password: it isn't tied to your Apple ID
password, and it can be revoked on its own.

## 3. Building locally

Save the credentials into a keychain profile once:

```sh
xcrun notarytool store-credentials plate-notary \
    --key ~/private_keys/AuthKey_XXXXXXXXXX.p8 \
    --key-id XXXXXXXXXX \
    --issuer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

Then cut a build:

```sh
NOTARY_PROFILE=plate-notary scripts/release-macos.sh --arch arm64
```

The DMG lands in `dist/`. Notarization takes a few minutes; the script waits.
Pass `--skip-notarize` to exercise the signing half without the round-trip —
the DMG that produces is signed but Gatekeeper will still block it.

The script also accepts the raw key instead of a profile, via `NOTARY_KEY`,
`NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`. That is the form CI uses.

## 4. Building in CI

Add five repository secrets (Settings ▸ Secrets and variables ▸ Actions):

| Secret | What it holds |
|--------|---------------|
| `MACOS_CERTIFICATE_P12` | The Developer ID certificate **and its private key**, exported as `.p12`, base64-encoded |
| `MACOS_CERTIFICATE_PASSWORD` | The password you set when exporting the `.p12` |
| `NOTARY_KEY_P8` | The App Store Connect `.p8` key, base64-encoded |
| `NOTARY_KEY_ID` | The key's Key ID |
| `NOTARY_ISSUER_ID` | The key's Issuer ID |

To export the certificate: Keychain Access ▸ **My Certificates** ▸ right-click
the *Developer ID Application* entry ▸ Export. Pick `.p12` and set a password.
Export the certificate row (which carries the private key), not the bare key.

Then base64 both files:

```sh
base64 -i Certificates.p12 | pbcopy                    # → MACOS_CERTIFICATE_P12
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy               # → NOTARY_KEY_P8
```

Or set them straight from the command line, which keeps the values out of your
shell history and out of `ps`:

```sh
base64 -i Certificates.p12 | gh secret set MACOS_CERTIFICATE_P12
```

To check what a `.p12` actually holds before uploading it, note that
Keychain Access exports with RC2-40, which OpenSSL 3 refuses unless asked:

```sh
openssl pkcs12 -in Certificates.p12 -nokeys -legacy | openssl x509 -noout -subject
```

`.github/workflows/build.yml` imports the certificate into a throwaway keychain,
builds, notarizes, staples, and asserts the result with `spctl` before uploading.

**When the secrets are missing** — a fork, or before you've added them — the
release job falls back to ad-hoc signing and skips notarization so the build
still goes green. The DMG it produces is *not* distributable. Only tag builds
from this repository are.

## Why each piece is there

- **Hardened runtime** (`ENABLE_HARDENED_RUNTIME=YES`, Release only): a
  precondition for notarization. It's off in Debug because it blocks the
  debugger unless the build also carries `get-task-allow`.
- **`CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`** (Release only): Xcode otherwise
  injects `com.apple.security.get-task-allow` into the entitlements, and
  notarization rejects any build carrying it.
- **`--timestamp`**: notarization requires a secure timestamp. It is only
  passed on the real-identity path — ad-hoc signatures can't carry one.
- **Stapling the `.app` as well as the `.dmg`**: they are two distributable
  artifacts and each needs its own ticket. Once a user drags the app out of the
  disk image, the image's ticket no longer covers it, and a first launch while
  offline would be refused.

## Verifying a build by hand

```sh
codesign --verify --deep --strict --verbose=2 Plate.app
codesign -dvvv Plate.app 2>&1 | grep CodeDirectory   # want flags=…(runtime)
codesign --display --entitlements :- Plate.app        # want: empty
xcrun stapler validate Plate.app
spctl --assess --type exec -vv Plate.app              # want: accepted, Notarized Developer ID
```

Note the `-dvvv`: the `flags=` line lives on the `CodeDirectory` output, which
`--verbose=2` doesn't print.

## `plate-cli`

The CLI stays ad-hoc signed. A bare Mach-O executable can't carry a stapled
ticket, and people who run command-line tools are equipped to clear the
quarantine attribute themselves:

```sh
xattr -d com.apple.quarantine plate-cli
```
