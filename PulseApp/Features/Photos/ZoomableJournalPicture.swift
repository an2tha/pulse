import SwiftUI
import UIKit

struct ZoomableJournalPicture: UIViewRepresentable {
    let jpeg: Data
    let title: String

    func makeUIView(context: Context) -> PictureScrollView { PictureScrollView(frame: .zero) }
    func updateUIView(_ view: PictureScrollView, context: Context) { view.show(jpeg, title: title) }

    final class PictureScrollView: UIScrollView, UIScrollViewDelegate {
        private let picture = UIImageView()
        private var lastBytes: Data?
        private var lastBounds = CGSize.zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self
            bouncesZoom = true
            showsVerticalScrollIndicator = false
            showsHorizontalScrollIndicator = false
            contentInsetAdjustmentBehavior = .never
            picture.isAccessibilityElement = true
            picture.accessibilityTraits = .image
            addSubview(picture)
            let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
            tap.numberOfTapsRequired = 2
            addGestureRecognizer(tap)
            picture.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Zoom in", actionHandler: { [weak self] _ in
                    guard let self else { return false }
                    setZoomScale(min(maximumZoomScale, zoomScale * 2), animated: !UIAccessibility.isReduceMotionEnabled)
                    return true
                }),
                UIAccessibilityCustomAction(name: "Fit photo", actionHandler: { [weak self] _ in
                    guard let self else { return false }
                    setZoomScale(minimumZoomScale, animated: !UIAccessibility.isReduceMotionEnabled)
                    return true
                }),
            ]
        }
        required init?(coder: NSCoder) { nil }

        func show(_ data: Data, title: String) {
            picture.accessibilityLabel = title
            guard lastBytes != data else { return }
            lastBytes = data
            zoomScale = 1
            picture.image = UIImage(data: data)
            let size = picture.image?.size ?? .zero
            picture.frame = CGRect(origin: .zero, size: size)
            contentSize = size
            lastBounds = .zero
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let size = picture.image?.size, size.width > 0, size.height > 0,
                  bounds.width > 0, bounds.height > 0 else { return }
            if lastBounds != bounds.size {
                lastBounds = bounds.size
                let fit = min(bounds.width / size.width, bounds.height / size.height)
                minimumZoomScale = fit
                maximumZoomScale = max(1, fit * 4)
                setZoomScale(fit, animated: false)
            }
            centerPicture()
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { centerPicture() }
        private func centerPicture() {
            let x = max(0, (bounds.width - contentSize.width) / 2)
            let y = max(0, (bounds.height - contentSize.height) / 2)
            let inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
            if contentInset != inset { contentInset = inset }
        }
        @objc private func doubleTap(_ tap: UITapGestureRecognizer) {
            let animated = !UIAccessibility.isReduceMotionEnabled
            if zoomScale > minimumZoomScale * 1.05 {
                setZoomScale(minimumZoomScale, animated: animated)
            } else {
                let point = tap.location(in: picture)
                let target = min(maximumZoomScale, minimumZoomScale * 2.5)
                let size = CGSize(width: bounds.width / target, height: bounds.height / target)
                zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                width: size.width, height: size.height), animated: animated)
            }
        }
    }
}
