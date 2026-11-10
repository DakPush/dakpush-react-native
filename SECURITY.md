# Security policy

## Supported versions

The SDK is below 1.0, so only the newest release gets security fixes. Fixes go
into a new patch release; update to it.

| Version | Supported |
|---|---|
| Newest 0.x release | Yes |
| Older releases | No |

## Reporting a vulnerability

Please do not open a public issue, discussion or pull request for a security
problem.

Report it privately on GitHub: open the repository's **Security** tab and
choose **Report a vulnerability**. Only the maintainers can see the report.

Include what you can of:

- the affected version or commit, React Native / Expo version, and the
  Android or iOS version;
- what an attacker can do, and what they need first (another app on the
  phone, a network position, a stolen device, access to the DakPush server);
- steps or a small app that shows the problem.

Problems in the native SDKs themselves belong to
[dakpush-android](https://github.com/DakPush/dakpush-android/security) and
[dakpush-ios](https://github.com/DakPush/dakpush-ios/security); report them
there (the iOS SDK's code in `ios/vendor` here is a copy).

## What happens next

You get an answer within a week. Once the problem is confirmed, the fix is
released and the report published with credit to you, unless you ask
otherwise.
