// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    
    name: "StreamingKit",
    platforms: [
        
        .iOS(.v11),
        .watchOS(.v6),
    ],
    products: [
        
        .library(
            
            name: "StreamingKit",
            targets: ["StreamingKit"]
        ),
    ],
    targets: [
        
        .target(
            
            name: "StreamingKit",
            path: "StreamingKit",
            exclude: [
        
                "StreamingKitMac",
                "StreamingKitTests",
                "StreamingKitMacTests",
            ],
            publicHeadersPath: ".",
            cSettings: [
                
                .headerSearchPath("StreamingKit/**/*"),
            ]
        )
    ]
)
