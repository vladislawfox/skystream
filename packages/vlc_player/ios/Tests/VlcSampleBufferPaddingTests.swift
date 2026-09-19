import CoreVideo
import Foundation

@main
struct PaddingTests {
  static func main() {
    var checks = 0
    func expect(_ condition: Bool, _ message: String) {
      guard condition else { print("FAIL: \(message)"); exit(1) }
      checks += 1
    }

    let padded = frame(width: 8, height: 8, visibleWidth: 6, visibleHeight: 4)
    let original = pixels(padded)
    VlcSampleBufferPadding.extendEdges(of: padded, visibleWidth: 6, visibleHeight: 4)
    let extended = pixels(padded)
    expect(extended[0][0] == [40, 41, 42, 43, 44, 45, 45, 45], "luma right edge must clamp to the last visible pixel")
    expect(extended[0][7] == [70, 71, 72, 73, 74, 75, 75, 75], "bottom luma padding must repeat the last visible row")
    expect(extended[1][3] == [101, 151, 102, 152, 103, 153, 103, 153], "chroma padding must repeat complete CbCr pairs")
    for row in 0..<4 {
      expect(Array(extended[0][row].prefix(6)) == Array(original[0][row].prefix(6)), "visible luma must not change")
    }
    for row in 0..<2 {
      expect(Array(extended[1][row].prefix(6)) == Array(original[1][row].prefix(6)), "visible chroma must not change")
    }
    VlcSampleBufferPadding.extendEdges(of: padded, visibleWidth: 6, visibleHeight: 4)
    expect(pixels(padded) == extended, "repeated delivery must be idempotent")

    let odd = frame(width: 8, height: 8, visibleWidth: 5, visibleHeight: 3)
    VlcSampleBufferPadding.extendEdges(of: odd, visibleWidth: 5, visibleHeight: 3)
    let oddPixels = pixels(odd)
    expect(oddPixels[0][7] == [60, 61, 62, 63, 64, 64, 64, 64], "odd luma dimensions must clamp safely")
    expect(oddPixels[1][3] == [101, 151, 102, 152, 103, 153, 103, 153], "odd dimensions retain their partial chroma pair")

    let full = frame(width: 8, height: 8, visibleWidth: 8, visibleHeight: 8)
    let fullPixels = pixels(full)
    VlcSampleBufferPadding.extendEdges(of: full, visibleWidth: 8, visibleHeight: 8)
    expect(pixels(full) == fullPixels, "un-padded frames must not change")
    VlcSampleBufferPadding.extendEdges(of: full, visibleWidth: 100, visibleHeight: 100)
    expect(pixels(full) == fullPixels, "oversized metadata must stay within the coded buffer")
    VlcSampleBufferPadding.extendEdges(of: full, visibleWidth: 0, visibleHeight: -1)
    expect(pixels(full) == fullPixels, "invalid metadata must not modify a frame")

    let bottomOnly = frame(width: 8, height: 8, visibleWidth: 8, visibleHeight: 4)
    VlcSampleBufferPadding.extendEdges(of: bottomOnly, visibleWidth: 8, visibleHeight: 4)
    expect(pixels(bottomOnly)[0][7] == [70, 71, 72, 73, 74, 75, 76, 77], "bottom-only padding preserves the entire visible width")
    let rightOnly = frame(width: 8, height: 8, visibleWidth: 6, visibleHeight: 8)
    VlcSampleBufferPadding.extendEdges(of: rightOnly, visibleWidth: 6, visibleHeight: 8)
    expect(pixels(rightOnly)[0][7] == [110, 111, 112, 113, 114, 115, 115, 115], "right-only padding preserves the entire visible height")
    print("Passed \(checks) native NV12 padding checks")
  }

  private static func frame(width: Int, height: Int, visibleWidth: Int, visibleHeight: Int) -> CVPixelBuffer {
    var output: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &output)
    guard status == kCVReturnSuccess, let output else { fatalError("Cannot allocate NV12 fixture: \(status)") }
    CVPixelBufferLockBaseAddress(output, [])
    defer { CVPixelBufferUnlockBaseAddress(output, []) }
    for plane in 0..<2 {
      let stride = CVPixelBufferGetBytesPerRowOfPlane(output, plane)
      let rows = CVPixelBufferGetHeightOfPlane(output, plane)
      let base = CVPixelBufferGetBaseAddressOfPlane(output, plane)!.assumingMemoryBound(to: UInt8.self)
      memset(base, 0, stride * rows) // Zero NV12 padding is visibly green.
      let divisor = plane == 0 ? 1 : 2
      for y in 0..<((visibleHeight + divisor - 1) / divisor) {
        for x in 0..<((visibleWidth + divisor - 1) / divisor) {
          if plane == 0 {
            base[y * stride + x] = UInt8(40 + y * 10 + x)
          } else {
            base[y * stride + x * 2] = UInt8(100 + y + x)
            base[y * stride + x * 2 + 1] = UInt8(150 + y + x)
          }
        }
      }
    }
    return output
  }

  private static func pixels(_ buffer: CVPixelBuffer) -> [[[UInt8]]] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    return (0..<2).map { plane in
      let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
      let count = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
      let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self)
      return (0..<CVPixelBufferGetHeightOfPlane(buffer, plane)).map { row in
        Array(UnsafeBufferPointer(start: base.advanced(by: row * stride), count: count))
      }
    }
  }
}
