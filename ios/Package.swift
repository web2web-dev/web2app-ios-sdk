// swift-tools-version:5.9
import PackageDescription

/// web2app SDK (скелет, WEB-434). Тонкий SDK, MIT. iOS 14+.
/// MMP-адаптеры (AppsFlyer/Adjust) НЕ хардовая зависимость — интегратор передаёт
/// deep_link_value из СВОЕГО MMP-SDK в `Web2App.identify(deepLinkValue:)`.
let package = Package(
    name: "Web2AppSDK",
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "Web2AppSDK", targets: ["Web2AppSDK"])
    ],
    targets: [
        .target(name: "Web2AppSDK", path: "Sources/Web2AppSDK"),
        .testTarget(
            name: "Web2AppSDKTests",
            dependencies: ["Web2AppSDK"],
            path: "Tests/Web2AppSDKTests"
        )
    ]
)
