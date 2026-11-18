# Base IPA

Place the unsigned Filza 4.0 IPA here before building:

```
base/FilzaSlop-v1.2.0-unsigned.ipa
```

The build scripts inject `FilzaApplySandboxExt.dylib`, patch the bundle ID and
package the app. The base IPA is not committed because it contains Filza's
original application payload. You can set `BASE_IPA` to any compatible
unsigned Filza IPA instead.

The developer build also needs an a-Shell IPA for its command frameworks:

```
ASHELL_IPA=$HOME/Downloads/Terminal.ipa
```
