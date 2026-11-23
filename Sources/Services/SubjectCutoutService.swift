import UIKit
import Vision
import CoreImage

/// Vision のオンデバイス被写体切り抜き（iOS 17+）。
/// 通信もモデルのダウンロードもせず、端末内のモデルだけで前景マスクを作る。
final class SubjectCutoutService {
    private let ciContext = CIContext()

    static var isAvailable: Bool {
        if #available(iOS 17.0, *) { return true }
        return false
    }

    /// 被写体だけを透過した画像を返す。被写体が見つからない場合は nil。
    func extractForeground(from image: UIImage) async -> UIImage? {
        guard #available(iOS 17.0, *) else { return nil }
        guard let cgImage = image.cgImage else { return nil }

        let orientation = CGImagePropertyOrientation(uiOrientation: image.imageOrientation)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])

        do {
            try handler.perform([request])
            guard let observation = request.results?.first,
                  !observation.allInstances.isEmpty else { return nil }
            let maskedBuffer = try observation.generateMaskedImage(
                ofInstances: observation.allInstances,
                from: handler,
                croppedToInstancesExtent: false
            )
            let ciImage = CIImage(cvPixelBuffer: maskedBuffer)
            guard let output = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
            return UIImage(cgImage: output, scale: image.scale, orientation: .up)
        } catch {
            return nil
        }
    }
}

private extension CGImagePropertyOrientation {
    init(uiOrientation: UIImage.Orientation) {
        switch uiOrientation {
        case .up:
            self = .up
        case .down:
            self = .down
        case .left:
            self = .left
        case .right:
            self = .right
        case .upMirrored:
            self = .upMirrored
        case .downMirrored:
            self = .downMirrored
        case .leftMirrored:
            self = .leftMirrored
        case .rightMirrored:
            self = .rightMirrored
        @unknown default:
            self = .up
        }
    }
}
