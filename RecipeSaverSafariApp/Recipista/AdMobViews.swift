import SwiftUI
import UIKit

#if canImport(GoogleMobileAds)
import GoogleMobileAds

@MainActor
final class AppOpenAdManager: NSObject {
    static let shared = AppOpenAdManager()
    private var appOpenAd: AppOpenAd?
    private var isLoading = false
    private var isShowing = false

    func loadAndPresent(adUnitID: String) {
        guard !isLoading, !isShowing else { return }
        isLoading = true
        AppOpenAd.load(with: adUnitID, request: Request()) { [weak self] ad, _ in
            guard let self else { return }
            Task { @MainActor in
                self.isLoading = false
                self.appOpenAd = ad
                self.presentIfReady()
            }
        }
    }

    private func presentIfReady() {
        guard let appOpenAd, let root = UIApplication.shared.recipistaTopViewController else { return }
        do {
            try appOpenAd.canPresent(from: root)
        } catch {
            return
        }
        isShowing = true
        appOpenAd.present(from: root)
        self.appOpenAd = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.isShowing = false
        }
    }
}

private extension UIApplication {
    var recipistaTopViewController: UIViewController? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController?
            .topPresented
    }
}

private extension UIViewController {
    var topPresented: UIViewController {
        presentedViewController?.topPresented ?? self
    }
}

final class NativeAdModel: NSObject, ObservableObject, NativeAdLoaderDelegate {
    @Published var nativeAd: NativeAd?
    @Published var didFail = false
    private var adLoader: AdLoader?

    func load(adUnitID: String) {
        guard nativeAd == nil, adLoader?.isLoading != true else { return }
        adLoader = AdLoader(
            adUnitID: adUnitID,
            rootViewController: UIApplication.shared.recipistaTopViewController,
            adTypes: [.native],
            options: nil
        )
        adLoader?.delegate = self
        adLoader?.load(Request())
    }

    func adLoader(_ adLoader: AdLoader, didReceive nativeAd: NativeAd) {
        nativeAd.rootViewController = UIApplication.shared.recipistaTopViewController
        self.nativeAd = nativeAd
        didFail = false
    }

    func adLoader(_ adLoader: AdLoader, didFailToReceiveAdWithError error: Error) {
        didFail = true
    }
}

struct AdMobNativeAdView: UIViewRepresentable {
    let nativeAd: NativeAd

    func makeUIView(context: Context) -> NativeAdView {
        let view = NativeAdView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 8
        view.layer.masksToBounds = true

        let badge = UILabel()
        badge.text = "広告"
        badge.font = .systemFont(ofSize: 10, weight: .bold)
        badge.textColor = .secondaryLabel

        let headline = UILabel()
        headline.font = .systemFont(ofSize: 13, weight: .bold)
        headline.textColor = .label
        headline.numberOfLines = 1

        let body = UILabel()
        body.font = .systemFont(ofSize: 11, weight: .regular)
        body.textColor = .secondaryLabel
        body.numberOfLines = 1

        let button = UIButton(type: .system)
        button.titleLabel?.font = .systemFont(ofSize: 11, weight: .bold)
        button.tintColor = UIColor(red: 0.125, green: 0.353, blue: 0.243, alpha: 1)

        let stack = UIStackView(arrangedSubviews: [badge, headline, body, button])
        stack.axis = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])

        view.headlineView = headline
        view.bodyView = body
        view.callToActionView = button
        return view
    }

    func updateUIView(_ view: NativeAdView, context: Context) {
        (view.headlineView as? UILabel)?.text = nativeAd.headline
        (view.bodyView as? UILabel)?.text = nativeAd.body
        (view.callToActionView as? UIButton)?.setTitle(nativeAd.callToAction, for: .normal)
        view.bodyView?.isHidden = nativeAd.body == nil
        view.callToActionView?.isHidden = nativeAd.callToAction == nil
        view.nativeAd = nativeAd
    }
}
#endif
