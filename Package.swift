// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "AmazonChimeSDK",
    products: [
        .library(name: "AmazonChimeSDK", targets: ["AmazonChimeSDK", "AmazonChimeSDKMedia"])
    ],
    dependencies: [    
        .package(url: "https://github.com/birdrides/mockingbird.git", from: "0.15.0")
    ],
    targets: [
        .binaryTarget(
            name: "AmazonChimeSDK",
            url: "https://amazon-chime-sdk-ios.s3.amazonaws.com/sdk/0.21.1/AmazonChimeSDK-0.21.1.tar.gz",
            checksum: "8951722e21bd9fb39437d88bcaa82f18695415d5435ba58b63cf4a15ccb8bf7b21f7b8e10c5081d18b738435af35c859449ce0309b1c32127b2a300a43b3cbf1"
        ),
        .binaryTarget(
            name: "AmazonChimeSDKMedia",
            url: "https://amazon-chime-sdk-ios.s3.amazonaws.com/media/0.17.1/AmazonChimeSDKMedia-0.17.1.tar.gz",
            checksum: "6ed6e0219166450773de4190a0a53f00548beab0f645a4554ad3f2b9162fd6200b9f91c679eb4d302526bfb4c897b4e74040c8b88fcfb03b1f2e2ef4a339e921"
        )
    ]
)