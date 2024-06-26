import UIKit
import Accelerate
import Display

private func generateHistogram(cgImage: CGImage) -> ([[vImagePixelCount]], Int)? {
    var sourceBuffer = vImage_Buffer()
    defer {
        sourceBuffer.data?.deallocate()
    }
    
    var cgImageFormat = vImage_CGImageFormat(
        bitsPerComponent: UInt32(cgImage.bitsPerComponent),
        bitsPerPixel: UInt32(cgImage.bitsPerPixel),
        colorSpace: Unmanaged.passUnretained(cgImage.colorSpace!),
        bitmapInfo: cgImage.bitmapInfo,
        version: 0,
        decode: nil,
        renderingIntent: .defaultIntent
    )
    
    let noFlags = vImage_Flags(kvImageNoFlags)
    var error = vImageBuffer_InitWithCGImage(&sourceBuffer, &cgImageFormat, nil, cgImage, noFlags)
    assert(error == kvImageNoError)
    
    if cgImage.alphaInfo == .premultipliedLast {
        error = vImageUnpremultiplyData_RGBA8888(&sourceBuffer, &sourceBuffer, noFlags)
    } else if cgImage.alphaInfo == .premultipliedFirst {
        error = vImageUnpremultiplyData_ARGB8888(&sourceBuffer, &sourceBuffer, noFlags)
    }
    assert(error == kvImageNoError)
    
    var histogramBinZero = [vImagePixelCount](repeating: 0, count: 256)
    var histogramBinOne = [vImagePixelCount](repeating: 0, count: 256)
    var histogramBinTwo = [vImagePixelCount](repeating: 0, count: 256)
    var histogramBinThree = [vImagePixelCount](repeating: 0, count: 256)
    
    histogramBinZero.withUnsafeMutableBufferPointer { zeroPtr in
        histogramBinOne.withUnsafeMutableBufferPointer { onePtr in
            histogramBinTwo.withUnsafeMutableBufferPointer { twoPtr in
                histogramBinThree.withUnsafeMutableBufferPointer { threePtr in
                    var histogramBins = [zeroPtr.baseAddress, onePtr.baseAddress, twoPtr.baseAddress, threePtr.baseAddress]
                    histogramBins.withUnsafeMutableBufferPointer { histogramBinsPtr in
                        let error = vImageHistogramCalculation_ARGB8888(
                            &sourceBuffer,
                            histogramBinsPtr.baseAddress!,
                            noFlags
                        )
                        assert(error == kvImageNoError)
                    }
                }
            }
        }
    }
    
    let alphaBinIndex = [.last, .premultipliedLast].contains(cgImage.alphaInfo) ? 3 : 0
    return ([histogramBinZero, histogramBinOne, histogramBinTwo, histogramBinThree], alphaBinIndex)
}

public func imageHasTransparency(_ image: UIImage) -> Bool {
    guard let cgImage = image.cgImage, cgImage.bitsPerComponent == 8, cgImage.bitsPerPixel == 32 else {
        return false
    }
    guard [.first, .last, .premultipliedFirst, .premultipliedLast].contains(cgImage.alphaInfo) else {
        return false
    }
    if let (histogramBins, alphaBinIndex) = generateHistogram(cgImage: cgImage) {
        let opaqueCount: vImagePixelCount = histogramBins[alphaBinIndex][255]
        var transparentCount: vImagePixelCount = 0
        for i in 0 ..< 255 {
            transparentCount += histogramBins[alphaBinIndex][i]
        }
        let totalCount = opaqueCount + transparentCount
        return Double(transparentCount) / Double(totalCount) > 0.05
    }
    return false
}

private func scaledDrawingContext(_ cgImage: CGImage, maxSize: CGSize) -> DrawingContext? {
    var size = CGSize(width: cgImage.width, height: cgImage.height)
    if (size.width > maxSize.width && size.height > maxSize.height) {
        size = size.aspectFilled(maxSize)
    }
    guard let context = DrawingContext(size: size, scale: 1.0, clear: true) else {
        return nil
    }
    context.withFlippedContext { context in
        context.draw(cgImage, in: CGRect(origin: CGPoint(), size: size))
    }
    return context
}

public func imageRequiresInversion(_ cgImage: CGImage) -> Bool {
    guard cgImage.bitsPerComponent == 8, cgImage.bitsPerPixel == 32 else {
        return false
    }
    guard [.first, .last, .premultipliedFirst, .premultipliedLast].contains(cgImage.alphaInfo) else {
        return false
    }
    
    guard let context = scaledDrawingContext(cgImage, maxSize: CGSize(width: 128.0, height: 128.0)) else {
        return false
    }
    if let cgImage = context.generateImage()?.cgImage, let (histogramBins, alphaBinIndex) = generateHistogram(cgImage: cgImage) {
        var hasAlpha = false
        for i in 0 ..< 255 {
            if histogramBins[alphaBinIndex][i] > 0 {
                hasAlpha = true
                break
            }
        }
        
        if hasAlpha {
            guard let probingContext = DrawingContext(size: CGSize(width: cgImage.width, height: cgImage.height)) else {
                return false
            }
            probingContext.withContext { c in
                c.draw(cgImage, in: CGRect(origin: CGPoint(), size: probingContext.size))
            }

            var matching: Int = 0
            var total: Int = 0
            for y in 0 ..< Int(probingContext.size.height) {
                for x in 0 ..< Int(probingContext.size.width) {
                    var saturation: CGFloat = 0.0
                    var brightness: CGFloat = 0.0
                    var alpha: CGFloat = 0.0
                    if probingContext.colorAt(CGPoint(x: x, y: y)).getHue(nil, saturation: &saturation, brightness: &brightness, alpha: &alpha) {
                        if alpha < 1.0 {
                            hasAlpha = true
                        }
                        
                        if alpha > 0.0 {
                            total += 1
                            if saturation < 0.1 && brightness < 0.25 {
                                matching += 1
                            }
                        }
                    }
                }
            }
            return CGFloat(matching) / CGFloat(total) > 0.85
        }
    }
    return false
}
