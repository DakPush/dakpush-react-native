require "json"

package = JSON.parse(File.read(File.join(__dir__, "..", "package.json")))
ios_sdk = File.read(File.join(__dir__, "vendor", "VERSION"))[/^version=(.+)$/, 1]

# For the app's notification service extension: the DakPush iOS SDK's
# DakPushExtension module (images, buttons, delivery receipts), from the copy
# in ios/vendor. The Expo plugin adds it to the extension's target; by hand:
#
#   target 'NotificationService' do
#     pod 'DakPushExtension', :path => '../node_modules/dakpush-react-native/ios'
#   end
Pod::Spec.new do |s|
  s.name          = "DakPushExtension"
  s.version       = ios_sdk
  s.summary       = "DakPush notification service extension: images, buttons and delivery receipts."
  s.description   = "DakPushExtension #{ios_sdk} from dakpush-react-native #{package["version"]}. Safe for app extensions."
  s.homepage      = package["homepage"]
  s.license       = package["license"]
  s.authors       = "Md Shoriful Haque Hridoy"
  s.source        = { :git => "https://github.com/DakPush/dakpush-react-native.git", :tag => "v#{package["version"]}" }
  s.platform      = :ios, "15.0"
  s.swift_version = "5.9"
  s.source_files  = "vendor/DakPushExtension/**/*.swift"
  s.resource_bundles = { "DakPushExtension_Privacy" => ["vendor/DakPushExtension/PrivacyInfo.xcprivacy"] }
  s.frameworks    = "UserNotifications"
end
