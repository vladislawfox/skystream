import CoreVideo
import Foundation

/// Clamp NV12 decoder padding to the visible edge before AVKit scales a frame.
/// Clean-aperture metadata sets the geometry, but filtering can still sample
/// beyond that aperture. Unwritten chroma padding would then appear green.
enum VlcSampleBufferPadding {
  static func extendEdges(of buffer: CVPixelBuffer, visibleWidth: Int, visibleHeight: Int) {
    let format = CVPixelBufferGetPixelFormatType(buffer)
    guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
            format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
          CVPixelBufferGetPlaneCount(buffer) == 2,
          visibleWidth > 0, visibleHeight > 0 else { return }
    let width = min(visibleWidth, CVPixelBufferGetWidth(buffer))
    let height = min(visibleHeight, CVPixelBufferGetHeight(buffer))
    guard width < CVPixelBufferGetWidth(buffer) || height < CVPixelBufferGetHeight(buffer),
          CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return }
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    for plane in 0..<2 {
      let divisor = plane == 0 ? 1 : 2
      let bytesPerPixel = plane == 0 ? 1 : 2 // Never split a CbCr pair.
      let columns = CVPixelBufferGetWidthOfPlane(buffer, plane)
      let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
      let visibleColumns = min(columns, (width + divisor - 1) / divisor)
      let visibleRows = min(rows, (height + divisor - 1) / divisor)
      let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
      let rowBytes = columns * bytesPerPixel
      guard visibleColumns > 0, visibleRows > 0, stride >= rowBytes,
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }

      if visibleColumns < columns {
        for row in 0..<visibleRows {
          let rowStart = base.advanced(by: row * stride)
          let lastPixel = rowStart.advanced(by: (visibleColumns - 1) * bytesPerPixel)
          for column in visibleColumns..<columns {
            memcpy(rowStart.advanced(by: column * bytesPerPixel), lastPixel, bytesPerPixel)
          }
        }
      }
      if visibleRows < rows {
        // The last visible row already includes any right-edge extension.
        let lastRow = base.advanced(by: (visibleRows - 1) * stride)
        for row in visibleRows..<rows {
          memcpy(base.advanced(by: row * stride), lastRow, rowBytes)
        }
      }
    }
  }
}
