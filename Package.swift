// swift-tools-version:5.9
import PackageDescription

/// web2app SDK (скелет, WEB-434). Тонкий SDK, MIT. iOS 14+.
/// MMP-адаптеры (AppsFlyer/Adjust) НЕ хардовая зависимость — интегратор достаёт
/// токен из колбэка СВОЕГО MMP-SDK (у AppsFlyer он лежит в `deep_link_sub1`,
/// НЕ в `deep_link_value`) и передаёт в `Web2App.identify(deepLinkValue:)`.
let package = Package(
    name: "Web2AppSDK",
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "Web2AppSDK", targets: ["Web2AppSDK"])
    ],
    targets: [
        .target(
            name: "Web2AppSDK",
            path: "Sources/Web2AppSDK",
            // Privacy-манифест обязан попадать в бандл (App Store требование).
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "Web2AppSDKTests",
            dependencies: ["Web2AppSDK"],
            path: "Tests/Web2AppSDKTests"
        )
    ]
)
