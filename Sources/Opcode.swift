public enum Opcode {
  case unreachable
  case nop
  case else_
  case end
  case return_
  case drop
  case select
  case i32Eqz
  case i32Eq
  case i32Ne
  case i32LtS
  case i32LtU
  case i32GtS
  case i32GtU
  case i32LeS
  case i32LeU
  case i32GeS
  case i32GeU
  case i64Eqz
  case i64Eq
  case i64Ne
  case i64LtS
  case i64LtU
  case i64GtS
  case i64GtU
  case i64LeS
  case i64LeU
  case i64GeS
  case i64GeU
  case f32Eq
  case f32Ne
  case f32Lt
  case f32Gt
  case f32Le
  case f32Ge
  case f64Eq
  case f64Ne
  case f64Lt
  case f64Gt
  case f64Le
  case f64Ge
  case i32Clz
  case i32Ctz
  case i32Popcnt
  case i32Add
  case i32Sub
  case i32Mul
  case i32DivS
  case i32DivU
  case i32RemS
  case i32RemU
  case i32And
  case i32Or
  case i32Xor
  case i32Shl
  case i32ShrS
  case i32ShrU
  case i32Rotl
  case i32Rotr
  case i64Clz
  case i64Ctz
  case i64Popcnt
  case i64Add
  case i64Sub
  case i64Mul
  case i64DivS
  case i64DivU
  case i64RemS
  case i64RemU
  case i64And
  case i64Or
  case i64Xor
  case i64Shl
  case i64ShrS
  case i64ShrU
  case i64Rotl
  case i64Rotr
  case f32Abs
  case f32Neg
  case f32Ceil
  case f32Floor
  case f32Trunc
  case f32Nearest
  case f32Sqrt
  case f32Add
  case f32Sub
  case f32Mul
  case f32Div
  case f32Min
  case f32Max
  case f32Copysign
  case f64Abs
  case f64Neg
  case f64Ceil
  case f64Floor
  case f64Trunc
  case f64Nearest
  case f64Sqrt
  case f64Add
  case f64Sub
  case f64Mul
  case f64Div
  case f64Min
  case f64Max
  case f64Copysign
  case i32WrapI64
  case i32TruncF32S
  case i32TruncF32U
  case i32TruncF64S
  case i32TruncF64U
  case i64ExtendI32S
  case i64ExtendI32U
  case i64TruncF32S
  case i64TruncF32U
  case i64TruncF64S
  case i64TruncF64U
  case f32ConvertI32S
  case f32ConvertI32U
  case f32ConvertI64S
  case f32ConvertI64U
  case f32DemoteF64
  case f64ConvertI32S
  case f64ConvertI32U
  case f64ConvertI64S
  case f64ConvertI64U
  case f64PromoteF32
  case i32ReinterpretF32
  case i64ReinterpretF64
  case f32ReinterpretI32
  case f64ReinterpretI64
  case memorySize
  case memoryGrow
  case memoryCopy
  case refIsNull
  case memoryFill
  case i32TruncSatF32S
  case i32TruncSatF32U
  case i32TruncSatF64S
  case i32TruncSatF64U
  case i64TruncSatF32S
  case i64TruncSatF32U
  case i64TruncSatF64S
  case i64TruncSatF64U
  case i32Extend8S
  case i32Extend16S
  case i64Extend8S
  case i64Extend16S
  case i64Extend32S
  case selectT
  case i32Load
  case i64Load
  case f32Load
  case f64Load
  case i32Load8S
  case i32Load8U
  case i32Load16S
  case i32Load16U
  case i64Load8S
  case i64Load8U
  case i64Load16S
  case i64Load16U
  case i64Load32S
  case i64Load32U
  case i32Store
  case i64Store
  case f32Store
  case f64Store
  case i32Store8
  case i32Store16
  case i64Store8
  case i64Store16
  case i64Store32
  case block
  case loop
  case if_
  case br
  case brIf
  case call
  case localGet
  case localSet
  case localTee
  case globalGet
  case globalSet
  case dataDrop
  case elemDrop
  case i32Const
  case f32Const
  case memoryInit
  case refFunc
  case tableGet
  case tableSet
  case tableGrow
  case tableSize
  case tableFill
  case refNull
  case i64Const
  case f64Const
  case callIndirect
  case tableCopy
  case tableInit
  case brTable
  
  public var isConstant: Bool {
    return self == .i32Const || self == .i64Const || self == .f32Const || self == .f64Const || self == .globalGet || self == .refNull || self == .refFunc
  }
}

public struct UnknownOpcode: Error {
  public let byte: UInt8
  public let extensionByte: UInt32?

  public init(_ byte: UInt8, extension_: UInt32? = nil) {
    self.byte = byte
    self.extensionByte = extension_
  }
}

public protocol OpcodeReader {
  mutating func readOpcode() throws -> Opcode
}

extension Cursor: OpcodeReader {
  @inline(__always)
  public mutating func readOpcode() throws -> Opcode {
    let byte = try readByte()
    switch byte {
    case 0x00: return .unreachable
    case 0x01: return .nop
    case 0x02: return .block
    case 0x03: return .loop
    case 0x04: return .if_
    case 0x05: return .else_
    case 0x0B: return .end
    case 0x0C: return .br
    case 0x0D: return .brIf
    case 0x0E: return .brTable
    case 0x0F: return .return_
    case 0x10: return .call
    case 0x11: return .callIndirect
    case 0x1A: return .drop
    case 0x1B: return .select
    case 0x1C: return .selectT
    case 0x20: return .localGet
    case 0x21: return .localSet
    case 0x22: return .localTee
    case 0x23: return .globalGet
    case 0x24: return .globalSet
    case 0x25: return .tableGet
    case 0x26: return .tableSet
    case 0x28: return .i32Load
    case 0x29: return .i64Load
    case 0x2A: return .f32Load
    case 0x2B: return .f64Load
    case 0x2C: return .i32Load8S
    case 0x2D: return .i32Load8U
    case 0x2E: return .i32Load16S
    case 0x2F: return .i32Load16U
    case 0x30: return .i64Load8S
    case 0x31: return .i64Load8U
    case 0x32: return .i64Load16S
    case 0x33: return .i64Load16U
    case 0x34: return .i64Load32S
    case 0x35: return .i64Load32U
    case 0x36: return .i32Store
    case 0x37: return .i64Store
    case 0x38: return .f32Store
    case 0x39: return .f64Store
    case 0x3A: return .i32Store8
    case 0x3B: return .i32Store16
    case 0x3C: return .i64Store8
    case 0x3D: return .i64Store16
    case 0x3E: return .i64Store32
    case 0x41: return .i32Const
    case 0x42: return .i64Const
    case 0x43: return .f32Const
    case 0x44: return .f64Const
    case 0x45: return .i32Eqz
    case 0x46: return .i32Eq
    case 0x47: return .i32Ne
    case 0x48: return .i32LtS
    case 0x49: return .i32LtU
    case 0x4A: return .i32GtS
    case 0x4B: return .i32GtU
    case 0x4C: return .i32LeS
    case 0x4D: return .i32LeU
    case 0x4E: return .i32GeS
    case 0x4F: return .i32GeU
    case 0x50: return .i64Eqz
    case 0x51: return .i64Eq
    case 0x52: return .i64Ne
    case 0x53: return .i64LtS
    case 0x54: return .i64LtU
    case 0x55: return .i64GtS
    case 0x56: return .i64GtU
    case 0x57: return .i64LeS
    case 0x58: return .i64LeU
    case 0x59: return .i64GeS
    case 0x5A: return .i64GeU
    case 0x5B: return .f32Eq
    case 0x5C: return .f32Ne
    case 0x5D: return .f32Lt
    case 0x5E: return .f32Gt
    case 0x5F: return .f32Le
    case 0x60: return .f32Ge
    case 0x61: return .f64Eq
    case 0x62: return .f64Ne
    case 0x63: return .f64Lt
    case 0x64: return .f64Gt
    case 0x65: return .f64Le
    case 0x66: return .f64Ge
    case 0x67: return .i32Clz
    case 0x68: return .i32Ctz
    case 0x69: return .i32Popcnt
    case 0x6A: return .i32Add
    case 0x6B: return .i32Sub
    case 0x6C: return .i32Mul
    case 0x6D: return .i32DivS
    case 0x6E: return .i32DivU
    case 0x6F: return .i32RemS
    case 0x70: return .i32RemU
    case 0x71: return .i32And
    case 0x72: return .i32Or
    case 0x73: return .i32Xor
    case 0x74: return .i32Shl
    case 0x75: return .i32ShrS
    case 0x76: return .i32ShrU
    case 0x77: return .i32Rotl
    case 0x78: return .i32Rotr
    case 0x79: return .i64Clz
    case 0x7A: return .i64Ctz
    case 0x7B: return .i64Popcnt
    case 0x7C: return .i64Add
    case 0x7D: return .i64Sub
    case 0x7E: return .i64Mul
    case 0x7F: return .i64DivS
    case 0x80: return .i64DivU
    case 0x81: return .i64RemS
    case 0x82: return .i64RemU
    case 0x83: return .i64And
    case 0x84: return .i64Or
    case 0x85: return .i64Xor
    case 0x86: return .i64Shl
    case 0x87: return .i64ShrS
    case 0x88: return .i64ShrU
    case 0x89: return .i64Rotl
    case 0x8A: return .i64Rotr
    case 0x8B: return .f32Abs
    case 0x8C: return .f32Neg
    case 0x8D: return .f32Ceil
    case 0x8E: return .f32Floor
    case 0x8F: return .f32Trunc
    case 0x90: return .f32Nearest
    case 0x91: return .f32Sqrt
    case 0x92: return .f32Add
    case 0x93: return .f32Sub
    case 0x94: return .f32Mul
    case 0x95: return .f32Div
    case 0x96: return .f32Min
    case 0x97: return .f32Max
    case 0x98: return .f32Copysign
    case 0x99: return .f64Abs
    case 0x9A: return .f64Neg
    case 0x9B: return .f64Ceil
    case 0x9C: return .f64Floor
    case 0x9D: return .f64Trunc
    case 0x9E: return .f64Nearest
    case 0x9F: return .f64Sqrt
    case 0xA0: return .f64Add
    case 0xA1: return .f64Sub
    case 0xA2: return .f64Mul
    case 0xA3: return .f64Div
    case 0xA4: return .f64Min
    case 0xA5: return .f64Max
    case 0xA6: return .f64Copysign
    case 0xA7: return .i32WrapI64
    case 0xA8: return .i32TruncF32S
    case 0xA9: return .i32TruncF32U
    case 0xAA: return .i32TruncF64S
    case 0xAB: return .i32TruncF64U
    case 0xAC: return .i64ExtendI32S
    case 0xAD: return .i64ExtendI32U
    case 0xAE: return .i64TruncF32S
    case 0xAF: return .i64TruncF32U
    case 0xB0: return .i64TruncF64S
    case 0xB1: return .i64TruncF64U
    case 0xB2: return .f32ConvertI32S
    case 0xB3: return .f32ConvertI32U
    case 0xB4: return .f32ConvertI64S
    case 0xB5: return .f32ConvertI64U
    case 0xB6: return .f32DemoteF64
    case 0xB7: return .f64ConvertI32S
    case 0xB8: return .f64ConvertI32U
    case 0xB9: return .f64ConvertI64S
    case 0xBA: return .f64ConvertI64U
    case 0xBB: return .f64PromoteF32
    case 0xBC: return .i32ReinterpretF32
    case 0xBD: return .i64ReinterpretF64
    case 0xBE: return .f32ReinterpretI32
    case 0xBF: return .f64ReinterpretI64
    case 0xD0: return .refNull
    case 0xD1: return .refIsNull
    case 0xD2: return .refFunc
    case 0x3F: return .memorySize
    case 0x40: return .memoryGrow
    case 0xC0: return .i32Extend8S
    case 0xC1: return .i32Extend16S
    case 0xC2: return .i64Extend8S
    case 0xC3: return .i64Extend16S
    case 0xC4: return .i64Extend32S
    case 0xFC:
      let extension_ = try read(LEB: UInt32.self)
      switch extension_ {
      case 0: return .i32TruncSatF32S
      case 1: return .i32TruncSatF32U
      case 2: return .i32TruncSatF64S
      case 3: return .i32TruncSatF64U
      case 4: return .i64TruncSatF32S
      case 5: return .i64TruncSatF32U
      case 6: return .i64TruncSatF64S
      case 7: return .i64TruncSatF64U
      case 8: return .memoryInit
      case 9: return .dataDrop
      case 10: return .memoryCopy
      case 11: return .memoryFill
      case 12: return .tableInit
      case 13: return .elemDrop
      case 14: return .tableCopy
      case 15: return .tableGrow
      case 16: return .tableSize
      case 17: return .tableFill
      default:
        throw UnknownOpcode(byte, extension_: extension_)
      }
    default:
      throw UnknownOpcode(byte)
    }
  }
}
