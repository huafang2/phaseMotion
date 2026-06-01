#if canImport(UIKit)
import UIKit

public typealias PlatformImage = UIImage
public typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit

public typealias PlatformImage = NSImage
public typealias PlatformColor = NSColor
#endif

extension PlatformImage {
    static func from(cgImage: CGImage) -> PlatformImage {
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #elseif canImport(AppKit)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }

    var cgImageRepresentation: CGImage? {
        #if canImport(UIKit)
        return cgImage
        #elseif canImport(AppKit)
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #endif
    }
}
