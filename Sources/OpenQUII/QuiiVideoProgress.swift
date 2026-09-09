import Foundation

/// Transport-level H.264 prerequisites, NOT proof of successful decoding.
/// Only VCL records after SPS/PPS/IDR renew liveness; audio, control, empty NALs,
/// metadata-only records and unconfigured inter frames cannot hold a stream open.
/// A renderer must independently time out unsuccessful decoding or presentation.
struct QuiiVideoProgress {
    private var hasSPS = false
    private var hasPPS = false
    private var hasIDR = false

    mutating func observe(_ annexB: Data) -> Bool {
        let bytes = Array(annexB)
        var starts: [(prefix: Int, payload: Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    starts.append((index, index + 3))
                    index += 3
                    continue
                }
                if index + 4 <= bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    starts.append((index, index + 4))
                    index += 4
                    continue
                }
            }
            index += 1
        }
        var progress = false
        for (offset, start) in starts.enumerated() {
            let end = offset + 1 < starts.count ? starts[offset + 1].prefix : bytes.count
            // Header alone isn't a NAL payload; forbidden_zero_bit must be zero.
            guard end - start.payload >= 2, bytes[start.payload] & 0x80 == 0 else { continue }
            switch bytes[start.payload] & 0x1f {
            case 7: hasSPS = true
            case 8: hasPPS = true
            case 5:
                if hasSPS && hasPPS { hasIDR = true; progress = true }
            case 1:
                if hasIDR { progress = true }
            default: break
            }
        }
        return progress
    }
}
