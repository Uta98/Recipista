import Foundation

#if canImport(GoogleMobileAds)
import GoogleMobileAds
#endif

enum AdMobBootstrap {
    static func configure() {
#if canImport(GoogleMobileAds)
        MobileAds.shared.start()
#endif
    }
}

