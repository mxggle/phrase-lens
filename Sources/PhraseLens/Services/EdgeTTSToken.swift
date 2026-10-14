import Foundation

/// Generates the v2 `Sec-MS-GEC` token that Microsoft's Edge read-aloud service requires.
///
/// The service no longer accepts the plain SHA-256 (v1) token. This is a port
/// of `generate_sec_ms_gec_v2` from edge-tts 7.3.1 (rany2/edge-tts, `edge_tts/drm.py`, LGPL-3.0
/// / GPL-3.0), which combines a keyed SHA-256 digest with a CS64 checksum as
/// `"<16 hex>-<64 hex>"`. All arithmetic is modulo 2^32, matching the reference's masking.
enum EdgeTTSToken {
  static let version = "2"

  static func secMSGEC(trustedClientToken: String, unixTime: TimeInterval) -> String {
    var ticks = UInt64(max(0, unixTime.rounded(.down))) + 11_644_473_600
    ticks -= ticks % 300
    ticks *= 10_000_000
    let data = Array("\(ticks)\(trustedClientToken)".utf8)
    let digest = sha256Digest(data)
    let (first, second) = cs64Digest(data, digest: digest)
    let checksum = littleEndianBytes(first) + littleEndianBytes(second)
    return hex(checksum) + "-" + hex(digest)
  }

  // MARK: - SHA-256 with a fixed secret prefix

  private static let initialState: [UInt32] = [
    0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
    0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
  ]
  private static let prefixState: [UInt32] = [
    0xFD9F_BEA2, 0x9124_3CE7, 0xBE49_9094, 0xCD2E_1E0A,
    0x6C00_6F49, 0x04BD_35AB, 0xFEB0_A7E4, 0x03EF_FBD2,
  ]
  private static let prefixSchedule: [UInt32] = [
    0xEB24_BF9E, 0x1558_691F, 0xA0C0_9EE2, 0x0CFA_32BA, 0xA622_EE8C, 0xD1DD_9491, 0xC0DD_25A0,
    0xF9E7_0AB6, 0xF0C3_1573, 0x7058_CE4E, 0x7188_E606, 0x00E5_AB33, 0xD258_B060, 0x7276_6564,
  ]
  private static let roundConstants: [UInt32] = [
    0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5, 0x3956_C25B, 0x59F1_11F1, 0x923F_82A4,
    0xAB1C_5ED5, 0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3, 0x72BE_5D74, 0x80DE_B1FE,
    0x9BDC_06A7, 0xC19B_F174, 0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC, 0x2DE9_2C6F,
    0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA, 0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7,
    0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967, 0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC,
    0x5338_0D13, 0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85, 0xA2BF_E8A1, 0xA81A_664B,
    0xC24B_8B70, 0xC76C_51A3, 0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070, 0x19A4_C116,
    0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5, 0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
    0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208, 0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7,
    0xC671_78F2,
  ]
  private static let roundAdjustment: UInt32 = 0xC9DC_06A7
  private static let sigma0Adjustment: UInt32 = 0x059C_0B80
  private static let sigma1Adjustment: UInt32 = 0x000B_92C0

  private static func rotateRight(_ value: UInt32, _ count: UInt32) -> UInt32 {
    (value >> count) | (value << (32 - count))
  }

  private static func sigma0(_ value: UInt32) -> UInt32 {
    rotateRight(value, 7) ^ rotateRight(value, 18) ^ (value >> 3)
  }

  private static func sigma1(_ value: UInt32) -> UInt32 {
    rotateRight(value, 17) ^ rotateRight(value, 19) ^ (value >> 10)
  }

  private static func expandSchedule(_ words: inout [UInt32], from firstWord: Int) {
    for index in firstWord..<64 {
      words.append(
        sigma1(words[index - 2]) &+ words[index - 7] &+ sigma0(words[index - 15])
          &+ words[index - 16])
    }
  }

  private static func rounds(_ state: [UInt32], _ words: [UInt32], from firstRound: Int)
    -> [UInt32]
  {
    var constants = roundConstants
    if firstRound == 14 { constants[14] = roundAdjustment }
    var (a, b, c, d, e, f, g, h) = (
      state[0], state[1], state[2], state[3], state[4], state[5], state[6], state[7]
    )
    for index in firstRound..<64 {
      let sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
      let choice = g ^ (e & (f ^ g))
      let t1 = h &+ sum1 &+ choice &+ constants[index] &+ words[index]
      let sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
      let majority = (a & b) | (c & (a | b))
      let t2 = sum0 &+ majority
      (a, b, c, d, e, f, g, h) = (t1 &+ t2, a, b, c, d &+ t1, e, f, g)
    }
    return [a, b, c, d, e, f, g, h]
  }

  private static func bigEndianWord(_ bytes: ArraySlice<UInt8>) -> UInt32 {
    bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  }

  private static func stateAfterPrefix(_ data: [UInt8]) -> [UInt32] {
    var words = [UInt32](repeating: 0, count: 14)
    words.append(bigEndianWord(data[0..<3]))
    words.append(bigEndianWord(data[3..<7]))
    for index in 16..<30 {
      var value = prefixSchedule[index - 16]
      if index - 2 >= 14 {
        let term = sigma1(words[index - 2])
        value &+= index == 16 ? term ^ sigma1Adjustment : term
      }
      if index - 7 >= 14 {
        value &+= words[index - 7]
      }
      if index - 15 >= 14 {
        let term = sigma0(words[index - 15])
        value &+= index == 29 ? term ^ sigma0Adjustment : term
      }
      words.append(value)
    }
    words.append(
      sigma1(words[28]) &+ words[23] &+ sigma0(words[15]) &+ words[14] &+ roundAdjustment
        &- roundConstants[14])
    expandSchedule(&words, from: 31)
    let working = rounds(prefixState, words, from: 14)
    return zip(initialState, working).map { $0 &+ $1 }
  }

  static func sha256Digest(_ data: [UInt8]) -> [UInt8] {
    precondition(data.count >= 7, "Token salt must contain at least seven bytes")
    let length = 57 + data.count
    var padded = Array(data[7...])
    padded.append(0x80)
    padded += [UInt8](repeating: 0, count: ((55 - length) % 64 + 64) % 64)
    let bitLength = UInt64(length * 8)
    padded += (0..<8).reversed().map { UInt8(truncatingIfNeeded: bitLength >> ($0 * 8)) }

    var state = stateAfterPrefix(data)
    for offset in stride(from: 0, to: padded.count, by: 64) {
      var words = (0..<16).map { bigEndianWord(padded[(offset + $0 * 4)..<(offset + $0 * 4 + 4)]) }
      expandSchedule(&words, from: 16)
      let working = rounds(state, words, from: 0)
      state = zip(state, working).map { $0 &+ $1 }
    }
    return state.flatMap { word in
      (0..<4).reversed().map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }
    }
  }

  // MARK: - CS64 checksum

  private static let cs64Coefficients: [(UInt32, UInt32)] = [
    (0xE82E_91B1, 0xB327_00D0), (0x44DE_24C6, 0x88DF_F51D), (0x3BEB_65BC, 0x2951_4038),
    (0xC89C_5933, 0xB328_CBDF), (0x8D1E_C211, 0xD405_B4D5), (0x314E_F5D5, 0x26E5_5F3C),
    (0xE924_91B1, 0x6078_01C6), (0xF0A5_B9D5, 0x82B2_C1FB), (0x0606_4CF3, 0xFA51_A3DA),
    (0xDA79_FA60, 0x207C_C464), (0xBED2_0560, 0x3C3C_74F3), (0x89F9_C9F8, 0xD2D1_4B61),
    (0x35FA_38C6, 0xBB04_A2C1), (0xCB49_E3C6, 0xC562_6167),
  ]
  private static let cs64Factor: UInt32 = 0x8289_3933
  private static let cs64Adjustment0: UInt32 = 0xF2F9_0B1A
  private static let cs64Adjustment1: UInt32 = 0x0B1A_0000

  private static func rotate16(_ value: UInt32) -> UInt32 {
    (value << 16) | (value >> 16)
  }

  private static func littleEndianWord(_ bytes: ArraySlice<UInt8>) -> UInt32 {
    bytes.reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  }

  private static func evenLittleEndianWords(_ data: [UInt8]) -> [UInt32] {
    var padded = data
    padded += [UInt8](repeating: 0, count: (4 - data.count % 4) % 4)
    var words = stride(from: 0, to: padded.count, by: 4).map {
      littleEndianWord(padded[$0..<($0 + 4)])
    }
    if words.count % 2 == 1 { words.append(0) }
    return words
  }

  static func cs64Digest(_ data: [UInt8], digest: [UInt8]) -> (UInt32, UInt32) {
    let keyA = littleEndianWord(digest[0..<4]) | 1
    let keyB = littleEndianWord(digest[4..<8]) | 1
    let factors = [keyA &* cs64Factor, keyB &* cs64Factor]
    var terms = cs64Coefficients.enumerated().map { $0.element.0 &* factors[$0.offset % 2] }
    var offsets = cs64Coefficients.map { $0.1 }
    for (index, word) in evenLittleEndianWords([0] + data).enumerated() {
      var term = word &* (index % 2 == 0 ? keyA : keyB)
      var offset = rotate16(word) &* (index % 2 == 0 ? 0xEF05_69FB : 0xC317_13DB)
      if index == 0 {
        term &+= cs64Adjustment0 &* factors[0]
        offset &+= cs64Adjustment1
      }
      terms.append(term)
      offsets.append(offset)
    }

    var swapAccumulator: UInt32 = 0
    var swapLast: UInt32 = 0
    var state: UInt32 = 0
    var accumulator: UInt32 = 0
    for index in stride(from: 0, to: terms.count, by: 2) {
      let x = terms[index]
      let y = terms[index + 1]
      var t = rotate16(offsets[index] &+ x)
      var q = t &* 0x76F5_0F34
      swapAccumulator &+= rotate16(q) &* 0xC3EF_EA97 &+ q
      t = rotate16(offsets[index + 1] &+ y)
      q = t &* 0x1881_CE3C
      swapLast = rotate16(q) &* 0x35BD_1EC9 &+ q
      swapAccumulator &+= swapLast

      state = state &* keyA &+ x
      state = rotate16(state) &* 0xCF98_B111
      state = rotate16(state) &* 0x8708_5B9F
      state = rotate16(state) &* 0x12CE_B96D
      state = rotate16(state) &* 0x257E_1D83
      accumulator &+= state
      t = state &* keyB &+ y
      t = rotate16(t) &* 0xA274_16F5
      t = rotate16(t) &* 0xD383_96FF
      state = rotate16(rotate16(t) &* 0x7C93_2B89) &* 0xBFA4_9F69
      accumulator &+= state
    }
    return (swapLast ^ state, swapAccumulator ^ accumulator)
  }

  // MARK: - Encoding

  private static func littleEndianBytes(_ word: UInt32) -> [UInt8] {
    (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }
  }

  private static func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined()
  }
}
