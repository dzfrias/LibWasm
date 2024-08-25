import Foundation

/// An error that occurs when reading a buffer using a `Cursor`.
public enum ReadError: Error {
  case unexpectedEof
  case leb128TooLarge
  case leb128TooLong
}

/// A cursor over a growable in-memory buffer.
///
/// `Cursor` provides the ability to read LEB128-encoded types, along with
/// other standard reading capabilities.
public struct Cursor {
  /// The position of the cursor in the buffer.
  public var pos: Int = 0
  /// The buffer being read.
  public private(set) var buf: Data = Data()
  
  public var rest: Data {
    buf.subdata(in: pos..<buf.count)
  }

  /// Creates a cursor with no data.
  public init() {}
  
  /// Create a cursor with some initial data.
  public init(for data: Data) {
    buf = data
  }

  /// A boolean indicating whether the cursor is at the end of the buffer
  /// or not.
  public var isAtEof: Bool {
    return self.pos == buf.count
  }

  /// Reads a single byte in the buffer.
  @discardableResult
  public mutating func readByte() throws -> UInt8 {
    guard pos < buf.count else {
      throw ReadError.unexpectedEof
    }
    let byte = buf[pos]
    pos += 1
    return byte
  }

  /// Reads a number of bytes and returns a sub-buffer containing those bytes.
  @discardableResult
  public mutating func read(count: Int) throws -> Data {
    let range = pos..<pos + count
    guard range.count <= buf.count - pos else {
      throw ReadError.unexpectedEof
    }
    pos += range.count
    return buf.subdata(in: range)
  }

  /// Reads an unsigned integer encoded in the [LEB128 format][leb128].
  ///
  /// [leb128]: https://en.wikipedia.org/wiki/LEB128
  @discardableResult
  public mutating func read<T: UnsignedInteger>(LEB _: T.Type = T.self) throws -> T {
    let size = MemoryLayout<T>.size * 8

    // First loop item unrolled
    var byte = try readByte()
    if _fastPath(byte & 0x80 == 0) {
      return T(byte)
    }

    var result = T(byte & 0x7F)
    var shift = 7
    repeat {
      byte = try readByte()
      result |= T(byte & 0x7F) << shift
      if shift >= size - 7 && byte >> (size - shift) != 0 {
        throw byte & 0x80 != 0 ? ReadError.leb128TooLarge : ReadError.leb128TooLong
      }
      shift += 7
    } while byte & 0x80 != 0

    return result
  }

  /// Reads a signed integer encoded in the [LEB128 format][leb128].
  ///
  /// [leb128]: https://en.wikipedia.org/wiki/LEB128
  @discardableResult
  public mutating func read<T: SignedInteger>(LEB _: T.Type = T.self) throws -> T {
    let size = MemoryLayout<T>.size * 8

    var result: T = 0
    var shift = 0
    var byte: UInt8

    repeat {
      byte = try readByte()
      result |= T(byte & 0x7F) << shift

      if shift >= size - 7 {
        let hasContinuation = byte & 0x80 != 0
        let signAndUnused = Int8(bitPattern: byte << 1) >> (size - shift)
        if hasContinuation || (signAndUnused != 0 && signAndUnused != -1) {
          throw hasContinuation ? ReadError.leb128TooLarge : ReadError.leb128TooLong
        }
        return result
      }

      shift += 7
    } while byte & 0x80 != 0

    if shift < size && byte & 0x40 != 0 {
      // Sign extend
      result |= ~0 << shift
    }

    return result
  }

  /// Pushes new data to the buffer.
  public mutating func push(bytes: Data) {
    buf.append(bytes)
  }
}
