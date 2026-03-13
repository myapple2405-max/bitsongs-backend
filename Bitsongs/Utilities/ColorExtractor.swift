import SwiftUI
import UIKit

/// Extracts dominant colors from a UIImage for dynamic theming
struct ColorExtractor {
    
    struct DominantColors {
        let primary: Color
        let secondary: Color
        let accent: Color
        let background: Color
        let textColor: Color
        
        static let `default` = DominantColors(
            primary: Color(red: 0.15, green: 0.15, blue: 0.25),
            secondary: Color(red: 0.25, green: 0.20, blue: 0.35),
            accent: Color(red: 0.6, green: 0.4, blue: 0.8),
            background: Color(red: 0.08, green: 0.08, blue: 0.12),
            textColor: .white
        )
    }
    
    /// Extract dominant colors from a UIImage using pixel sampling
    static func extractColors(from image: UIImage) -> DominantColors {
        guard let cgImage = image.cgImage else {
            return .default
        }
        
        let width = 50
        let height = 50
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return .default
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        guard let data = context.data else {
            return .default
        }
        
        let pointer = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        
        var colorBuckets: [String: (r: CGFloat, g: CGFloat, b: CGFloat, count: Int)] = [:]
        
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let offset = (y * width + x) * 4
                let r = CGFloat(pointer[offset]) / 255.0
                let g = CGFloat(pointer[offset + 1]) / 255.0
                let b = CGFloat(pointer[offset + 2]) / 255.0
                
                // Quantize to reduce noise
                let qr = Int(r * 8) * 32
                let qg = Int(g * 8) * 32
                let qb = Int(b * 8) * 32
                let key = "\(qr)-\(qg)-\(qb)"
                
                if let existing = colorBuckets[key] {
                    colorBuckets[key] = (
                        r: existing.r + r,
                        g: existing.g + g,
                        b: existing.b + b,
                        count: existing.count + 1
                    )
                } else {
                    colorBuckets[key] = (r: r, g: g, b: b, count: 1)
                }
            }
        }
        
        // Sort buckets by count
        let sortedBuckets = colorBuckets.values
            .sorted { $0.count > $1.count }
            .map { bucket -> (r: CGFloat, g: CGFloat, b: CGFloat) in
                let count = CGFloat(bucket.count)
                return (r: bucket.r / count, g: bucket.g / count, b: bucket.b / count)
            }
        
        guard !sortedBuckets.isEmpty else {
            return .default
        }
        
        let primaryColor = sortedBuckets[0]
        let secondaryColor = sortedBuckets.count > 1 ? sortedBuckets[1] : primaryColor
        let accentColor = sortedBuckets.count > 2 ? sortedBuckets[2] : secondaryColor
        
        // Darken colors for background use
        let primary = Color(
            red: primaryColor.r * 0.7,
            green: primaryColor.g * 0.7,
            blue: primaryColor.b * 0.7
        )
        
        let secondary = Color(
            red: secondaryColor.r * 0.6,
            green: secondaryColor.g * 0.6,
            blue: secondaryColor.b * 0.6
        )
        
        let accent = Color(
            red: min(accentColor.r * 1.3, 1.0),
            green: min(accentColor.g * 1.3, 1.0),
            blue: min(accentColor.b * 1.3, 1.0)
        )
        
        let background = Color(
            red: primaryColor.r * 0.15,
            green: primaryColor.g * 0.15,
            blue: primaryColor.b * 0.15
        )
        
        // Determine text color based on background luminance
        let luminance = primaryColor.r * 0.299 + primaryColor.g * 0.587 + primaryColor.b * 0.114
        let textColor: Color = luminance > 0.6 ? .black : .white
        
        return DominantColors(
            primary: primary,
            secondary: secondary,
            accent: accent,
            background: background,
            textColor: textColor
        )
    }
    
    /// Extract colors from a named asset
    static func extractColors(fromAssetNamed name: String) -> DominantColors {
        guard let image = UIImage(named: name) else {
            return .default
        }
        return extractColors(from: image)
    }
}
