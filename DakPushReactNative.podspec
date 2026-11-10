require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))
ios_sdk = File.read(File.join(__dir__, "ios", "vendor", "VERSION"))[/^version=(.+)$/, 1]

# The React Native bridge, with the DakPush iOS SDK's sources (ios/vendor, a
# copy of a release of github.com/DakPush/dakpush-ios) compiled into the same
# module. Autolinking adds this pod; the app's Podfile needs nothing.
Pod::Spec.new do |s|
  s.name         = "DakPushReactNative"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.description  = "React Native bridge for DakPush, with DakPush iOS #{ios_sdk}."
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = "Md Shoriful Haque Hridoy"

  s.platforms    = { :ios => min_ios_version_supported }
  s.source       = { :git => "https://github.com/DakPush/dakpush-react-native.git", :tag => "v#{s.version}" }

  s.source_files = [
    "ios/*.{h,m,mm,swift}",
    "ios/vendor/DakPush/**/*.swift",
    "ios/vendor/DakPushExtension/**/*.swift",
  ]
  s.private_header_files = "ios/*.h"
  s.swift_version = "5.9"
  s.resource_bundles = {
    "DakPush_Privacy" => ["ios/vendor/DakPush/PrivacyInfo.xcprivacy"],
    "DakPushExtension_Privacy" => ["ios/vendor/DakPushExtension/PrivacyInfo.xcprivacy"],
  }
  s.frameworks = "UIKit", "UserNotifications", "Security", "CryptoKit", "ImageIO", "SwiftUI"
  s.pod_target_xcconfig = { "DEFINES_MODULE" => "YES" }

  install_modules_dependencies(s)
end
