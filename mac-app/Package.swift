// swift-tools-version:6.2
// pia — нативное окно-чат для Mac. Сборка: ./build.sh (swift build -c release + бандл pia.app).
import PackageDescription

// Sources/PiaChat/Context/ — модуль захвата контекста по двойному нажатию правого Shift (RightShiftDoubleTapMonitor + DoubleTapDetector, ContextCapture).
// Тест логики жеста: tests/run.sh

let package = Package(
    name: "PiaChat",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "PiaChat",
            path: "Sources/PiaChat",
            swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("BareSlashRegexLiterals")]
        )
    ]
)
