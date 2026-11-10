# DakPush iOS SDK, vendored

These are the Swift sources of the DakPush iOS SDK
([github.com/DakPush/dakpush-ios](https://github.com/DakPush/dakpush-ios)) at
the release in `VERSION`, copied by `scripts/vendor-ios.sh`. Do not edit them
here: change the iOS SDK, release it, then run the script with the new tag.
CI runs `scripts/vendor-ios.sh --check`, which fails if anything here differs
from the tag.

The one change the script makes: the iOS SDK has two Swift modules
(`DakPush` and `DakPushExtension`); here both are compiled into the bridge's
module, so the lines importing `DakPushExtension` are dropped. The
notification service extension builds `DakPushExtension/` alone, through
`ios/DakPushExtension.podspec`.

Why the sources are here, not a pod dependency: CocoaPods trunk becomes
read-only on 2 December 2026, so the iOS SDK is not on trunk, and a library's
podspec cannot depend on a pod from git. Vendoring lets autolinking build
everything with no Podfile lines for the app.
