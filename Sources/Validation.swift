import Foundation

/// An error that occurs when validating a WebAssembly module.
public enum ValidationError: Error {
  case invalidLimits
  case invalidFunctionIndex
  case invalidTableIndex
  case invalidMemoryIndex
  case invalidGlobalIndex
  case invalidTypeIndex
  case invalidDataIndex
  case invalidElementIndex
  case dataCountMismatch
  case codeCountMismatch
  case stackHeightMismatch(expected: Int, got: Int)
  case unexpectedType(expected: ValueType, got: ValueType)
  case stackEmpty
  case noFramesLeft
  case invalidSelectType
  case hangingElse
  case invalidLabelIndex
  case brTableArityMismatch
  case invalidLocalIndex
  case invalidGlobalSet
  case missingDataCount
  case invalidAlignment
  case canOnlyCallFuncref
  case expectedReference
  case tableValueTypeMismatch
  case expectedNonReference
  case invalidInitExprInstruction(Opcode)
}

/// A validator for WebAssembly function bodies.
public struct CodeValidator: ~Copyable {
  private struct Frame {
    public enum Kind {
      case block
      case loop
      case if_
      case else_
      case function
    }

    public let type: FunctionType
    public let kind: Kind
    public let initCount: Int
    public var unreachable = false

    public var labelTypes: [ValueType] {
      kind == .loop ? type.parameters : type.results
    }
  }

  private enum StackEntry: Equatable {
    case known(type: ValueType)
    case unknown

    public var isNumeric: Bool {
      guard case let .known(type) = self else {
        return true
      }
      return type.isNumeric
    }

    public var isVector: Bool {
      guard case let .known(type) = self else {
        return true
      }
      return type == .v128
    }

    public var isReference: Bool {
      guard case let .known(type) = self else {
        return true
      }
      return type.isReference
    }

    public var isUnknown: Bool {
      return self == .unknown
    }
  }

  private enum MemoryInstructionKind {
    case load
    case store
  }

  private var module: Module

  // State depdendent on the function body being validated
  private var valueStack: [StackEntry] = []
  private var cursor = Cursor()
  private var locals: [ValueType] = []
  private var frames: [Frame] = []
  private var functionType: FunctionType = FunctionType(parameters: [], results: [])

  private var currentFrame: Frame { frames.last! }

  /// Creates a new code validator for the given module.
  public init(for module: Module) {
    self.module = module
  }

  /// Validates the passed byte buffer, ensuring that it respresents a
  /// valid sequence of WebAssembly instructions.
  public mutating func validate(data: Data, locals: [Function.Locals], type: FunctionType) throws {
    cursor = Cursor(for: data)
    functionType = type
    self.locals = functionType.parameters
    for local in locals {
      for _ in 0..<local.n {
        self.locals.append(local.type)
      }
    }
    appendFrame(kind: .function, type: type)

    while !frames.isEmpty {
      let opcode = try cursor.readOpcode()
      try validate(opcode: opcode)
    }
  }

  /// Validates a given byte buffer as an initialization expression, producing an
  /// expected type.
  ///
  /// - Returns: The number of bytes read.
  public mutating func validateInitExpr(data: Data, expected: ValueType) throws -> Int {
    // Do not build the cache when generating init exprs! They appear in
    // arbitrary places in the module, so we don't know if the necessary
    // information has been parsed into the module yet.
    cursor = Cursor(for: data)
    functionType = FunctionType(parameters: [], results: [expected])
    appendFrame(kind: .function, type: functionType)

    while !frames.isEmpty {
      let opcode = try cursor.readOpcode()
      guard opcode.isConstant || opcode == .end else {
        throw ValidationError.invalidInitExprInstruction(opcode)
      }
      try validate(opcode: opcode)
    }
    return cursor.pos
  }

  @discardableResult
  private mutating func popValue() throws -> StackEntry {
    if valueStack.count == currentFrame.initCount && currentFrame.unreachable { return .unknown }
    guard valueStack.count != currentFrame.initCount else {
      throw ValidationError.stackEmpty
    }
    return valueStack.popLast()!
  }

  private mutating func popValue(type: ValueType) throws {
    let actual = try popValue()
    guard case let .known(type: actualType) = actual else { return }
    guard actualType == type else {
      throw ValidationError.unexpectedType(expected: type, got: actualType)
    }
  }

  private mutating func popValuesAndCollect<S>(types: S) throws -> [ValueType]
  where S: Sequence, S.Element == ValueType {
    var popped: [ValueType] = []
    for t in types.reversed() {
      try popValue(type: t)
      popped.append(t)
    }
    return popped
  }

  private mutating func popValues<S>(types: S) throws
  where S: Sequence, S.Element == ValueType {
    for t in types.reversed() {
      try popValue(type: t)
    }
  }

  private mutating func appendValue(_ entry: StackEntry) {
    valueStack.append(entry)
  }

  private mutating func appendValues<S>(_ newEntries: S)
  where S: Sequence, S.Element == ValueType {
    for t in newEntries {
      appendValue(.known(type: t))
    }
  }

  private mutating func appendFrame(kind: Frame.Kind, type: FunctionType) {
    let frame = Frame(type: type, kind: kind, initCount: valueStack.count)
    frames.append(frame)
    if kind != .function {
      appendValues(frame.type.parameters)
    }
  }

  private mutating func popFrame() throws -> Frame {
    guard !frames.isEmpty else {
      throw ValidationError.noFramesLeft
    }
    try popValues(types: currentFrame.type.results)
    guard valueStack.count == currentFrame.initCount else {
      throw ValidationError.stackHeightMismatch(
        expected: currentFrame.initCount, got: valueStack.count)
    }
    return frames.popLast()!
  }

  private func getFrame(atDepth i: LabelIndex) throws -> Frame {
    guard i < frames.count else {
      throw ValidationError.invalidLabelIndex
    }
    return frames[frames.count - 1 - Int(i)]
  }

  private mutating func unreachable() {
    valueStack.removeSubrange(currentFrame.initCount...)
    frames[frames.count - 1].unreachable = true
  }

  private mutating func resolveBlockType(_ blockType: BlockType) throws -> FunctionType {
    switch blockType {
    case .empty:
      return FunctionType(parameters: [], results: [])
    case .single(let result):
      return FunctionType(parameters: [], results: [result])
    case .index(let typeIndex):
      guard typeIndex < module.types.count else {
        throw ValidationError.invalidTypeIndex
      }
      return module.types[Int(typeIndex)]
    }
  }

  private mutating func validate(opcode: Opcode) throws {
    switch opcode {
    case .drop:
      try popValue()
    case .nop: break
    case .select:
      try popValue(type: .i32)
      let t1 = try popValue()
      let t2 = try popValue()
      guard t1.isNumeric && t2.isNumeric || t1.isVector && t2.isVector else {
        throw ValidationError.expectedNonReference
      }
      guard t1 == t2 || t1.isUnknown || t2.isUnknown else {
        fatalError()
      }
      appendValue(t1.isUnknown ? t2 : t1)
    case .selectT:
      let count = try cursor.read(LEB: UInt32.self)
      guard count == 1 else {
        throw ValidationError.invalidSelectType
      }
      let type = try cursor.readValueType()
      try popValue(type: .i32)
      try popValue(type: type)
      try popValue(type: type)
      appendValue(.known(type: type))
    case .unreachable:
      unreachable()

    // Control instructions
    case .block:
      let blockType = try cursor.readBlockType()
      let type = try resolveBlockType(blockType)
      try popValues(types: type.parameters)
      appendFrame(kind: .block, type: type)
    case .loop:
      let blockType = try cursor.readBlockType()
      let type = try resolveBlockType(blockType)
      try popValues(types: type.parameters)
      appendFrame(kind: .loop, type: type)
    case .if_:
      let blockType = try cursor.readBlockType()
      let type = try resolveBlockType(blockType)
      try popValue(type: .i32)
      try popValues(types: type.parameters)
      appendFrame(kind: .if_, type: type)

    // Pseudo-instructions
    case .end:
      let frame = try popFrame()
      appendValues(frame.type.results)
    case .else_:
      let frame = try popFrame()
      guard frame.kind == .if_ else {
        throw ValidationError.hangingElse
      }
      appendFrame(kind: .else_, type: frame.type)

    // Branch instructions
    case .br:
      let labelIndex = try cursor.read(LEB: LabelIndex.self)
      try popValues(types: getFrame(atDepth: labelIndex).labelTypes)
      unreachable()
    case .brIf:
      let labelIndex = try cursor.read(LEB: LabelIndex.self)
      let labelTypes = try getFrame(atDepth: labelIndex).labelTypes
      try popValue(type: .i32)
      try popValues(types: labelTypes)
      appendValues(labelTypes)
    case .brTable:
      let brTable = try cursor.readBrTable()
      let defaultLabelTypes = try getFrame(atDepth: brTable.defaultLabel).labelTypes
      for label in brTable.labels {
        let labelTypes = try getFrame(atDepth: label).labelTypes
        guard labelTypes.count == defaultLabelTypes.count else {
          throw ValidationError.brTableArityMismatch
        }
        appendValues(try popValuesAndCollect(types: labelTypes))
      }
      try popValues(types: defaultLabelTypes)
      unreachable()

    // Local instructions
    case .localGet:
      let localIndex = try cursor.read(LEB: LocalIndex.self)
      guard localIndex < locals.count else {
        throw ValidationError.invalidLocalIndex
      }
      appendValue(.known(type: locals[Int(localIndex)]))
    case .localSet:
      let localIndex = try cursor.read(LEB: LocalIndex.self)
      guard localIndex < locals.count else {
        throw ValidationError.invalidLocalIndex
      }
      let type = locals[Int(localIndex)]
      try popValue(type: type)
    case .localTee:
      let localIndex = try cursor.read(LEB: LocalIndex.self)
      guard localIndex < locals.count else {
        throw ValidationError.invalidLocalIndex
      }
      let type = locals[Int(localIndex)]
      try popValue(type: type)
      appendValue(.known(type: type))

    // Global instructions
    case .globalGet:
      let index = try cursor.read(LEB: GlobalIndex.self)
      let global = try getGlobal(index: index)
      appendValue(.known(type: global.valueType))
    case .globalSet:
      let index = try cursor.read(LEB: GlobalIndex.self)
      let global = try getGlobal(index: index)
      guard global.mutability == .mutable else {
        throw ValidationError.invalidGlobalSet
      }
      try popValue(type: global.valueType)

    case .call:
      let index = try cursor.read(LEB: FunctionIndex.self)
      let typeIndex = try getFunction(index: index)
      let funcType = module.types[Int(typeIndex)]
      try popValues(types: funcType.parameters)
      appendValues(funcType.results)
    case .callIndirect:
      let typeIndex = try cursor.read(LEB: TypeIndex.self)
      let tableIndex = try cursor.read(LEB: TableIndex.self)
      let table = try getTable(index: tableIndex)
      guard table.elementType == .funcref else {
        throw ValidationError.canOnlyCallFuncref
      }
      let type = module.types[Int(typeIndex)]
      try popValue(type: .i32)
      try popValues(types: type.parameters)
      appendValues(type.results)

    case .dataDrop:
      let index = try cursor.read(LEB: DataIndex.self)
      guard let dataCount = module.dataCount else {
        throw ValidationError.missingDataCount
      }
      guard index < dataCount else {
        throw ValidationError.invalidDataIndex
      }
    case .elemDrop:
      let index = try cursor.read(LEB: ElementIndex.self)
      guard index < module.elements.count else {
        throw ValidationError.invalidElementIndex
      }

    // Const instructions
    case .f32Const:
      try cursor.read(count: 4)
      appendValue(.known(type: .f32))
    case .f64Const:
      try cursor.read(count: 8)
      appendValue(.known(type: .f64))
    case .i32Const:
      try cursor.read(LEB: Int32.self)
      appendValue(.known(type: .i32))
    case .i64Const:
      try cursor.read(LEB: Int64.self)
      appendValue(.known(type: .i64))

    // Float unary instructions
    case .f32Abs, .f32Ceil, .f32Floor, .f32Neg, .f32Trunc, .f32Sqrt, .f32Nearest:
      try popValue(type: .f32)
      appendValue(.known(type: .f32))
    case .f64Abs, .f64Ceil, .f64Floor, .f64Neg, .f64Trunc, .f64Sqrt, .f64Nearest:
      try popValue(type: .f64)
      appendValue(.known(type: .f64))

    // Float binary instructions
    case .f32Add, .f32Sub, .f32Mul, .f32Div, .f32Min, .f32Max, .f32Copysign:
      try popValue(type: .f32)
      try popValue(type: .f32)
      appendValue(.known(type: .f32))
    case .f64Add, .f64Sub, .f64Mul, .f64Div, .f64Min, .f64Max, .f64Copysign:
      try popValue(type: .f64)
      try popValue(type: .f64)
      appendValue(.known(type: .f64))

    // Float relational instructions
    case .f32Eq, .f32Ge, .f32Le, .f32Gt, .f32Lt, .f32Ne:
      try popValue(type: .f32)
      try popValue(type: .f32)
      appendValue(.known(type: .i32))
    case .f64Eq, .f64Ge, .f64Le, .f64Gt, .f64Lt, .f64Ne:
      try popValue(type: .f64)
      try popValue(type: .f64)
      appendValue(.known(type: .i32))

    // Float conversion instructions
    case .f32ConvertI32S, .f32ConvertI32U:
      try popValue(type: .i32)
      appendValue(.known(type: .f32))
    case .f32ConvertI64S, .f32ConvertI64U:
      try popValue(type: .i64)
      appendValue(.known(type: .f32))
    case .f32DemoteF64:
      try popValue(type: .f64)
      appendValue(.known(type: .f32))
    case .f32ReinterpretI32:
      try popValue(type: .i32)
      appendValue(.known(type: .f32))
    case .f64ConvertI32S, .f64ConvertI32U:
      try popValue(type: .i32)
      appendValue(.known(type: .f64))
    case .f64ConvertI64S, .f64ConvertI64U:
      try popValue(type: .i64)
      appendValue(.known(type: .f64))
    case .f64PromoteF32:
      try popValue(type: .f32)
      appendValue(.known(type: .f64))
    case .f64ReinterpretI64:
      try popValue(type: .i64)
      appendValue(.known(type: .f64))

    // Float memory instructions
    case .f32Load: try validateMemory(.load, type: .f32)
    case .f64Load: try validateMemory(.load, type: .f64)
    case .f32Store: try validateMemory(.store, type: .f32)
    case .f64Store: try validateMemory(.store, type: .f64)

    // Integer test instructions
    case .i32Eqz:
      try popValue(type: .i32)
      appendValue(.known(type: .i32))
    case .i64Eqz:
      try popValue(type: .i64)
      appendValue(.known(type: .i32))

    // Integer relational instructions
    case .i32Eq, .i32Ne, .i32LtS, .i32LtU, .i32LeS, .i32LeU, .i32GtS, .i32GtU, .i32GeS, .i32GeU:
      try popValue(type: .i32)
      try popValue(type: .i32)
      appendValue(.known(type: .i32))
    case .i64Eq, .i64Ne, .i64LtS, .i64LtU, .i64LeS, .i64LeU, .i64GtS, .i64GtU, .i64GeS, .i64GeU:
      try popValue(type: .i64)
      try popValue(type: .i64)
      appendValue(.known(type: .i32))

    // Integer unary instructions
    case .i32Clz, .i32Ctz, .i32Popcnt:
      try popValue(type: .i32)
      appendValue(.known(type: .i32))
    // Integer unary instructions
    case .i64Clz, .i64Ctz, .i64Popcnt:
      try popValue(type: .i64)
      appendValue(.known(type: .i64))

    // Integer binary instructions
    case .i32Add, .i32Sub, .i32Mul, .i32DivS, .i32DivU, .i32RemS, .i32RemU, .i32And, .i32Or,
      .i32Xor, .i32Shl, .i32ShrS, .i32ShrU, .i32Rotl, .i32Rotr:
      try popValue(type: .i32)
      try popValue(type: .i32)
      appendValue(.known(type: .i32))
    case .i64Add, .i64Sub, .i64Mul, .i64DivS, .i64DivU, .i64RemS, .i64RemU, .i64And, .i64Or,
      .i64Xor, .i64Shl, .i64ShrS, .i64ShrU, .i64Rotl, .i64Rotr:
      try popValue(type: .i64)
      try popValue(type: .i64)
      appendValue(.known(type: .i64))

    // Integer conversion instructions
    case .i64TruncF64S, .i64TruncF64U, .i64TruncSatF64S, .i64TruncSatF64U, .i64ReinterpretF64:
      try popValue(type: .f64)
      appendValue(.known(type: .i64))
    case .i64TruncF32S, .i64TruncF32U, .i64TruncSatF32S, .i64TruncSatF32U:
      try popValue(type: .f32)
      appendValue(.known(type: .i64))
    case .i32Extend16S, .i32Extend8S:
      try popValue(type: .i32)
      appendValue(.known(type: .i32))
    case .i32TruncF32S, .i32TruncF32U, .i32TruncSatF32S, .i32TruncSatF32U, .i32ReinterpretF32:
      try popValue(type: .f32)
      appendValue(.known(type: .i32))
    case .i32TruncF64S, .i32TruncF64U, .i32TruncSatF64S, .i32TruncSatF64U:
      try popValue(type: .f64)
      appendValue(.known(type: .i32))
    case .i32WrapI64:
      try popValue(type: .i64)
      appendValue(.known(type: .i32))
    case .i64Extend16S, .i64Extend8S, .i64Extend32S:
      try popValue(type: .i64)
      appendValue(.known(type: .i64))
    case .i64ExtendI32S, .i64ExtendI32U:
      try popValue(type: .i32)
      appendValue(.known(type: .i64))

    // Integer memory instructions
    case .i32Load: try validateMemory(.load, type: .i32)
    case .i32Load16S, .i32Load16U: try validateMemory(.load, type: .i32, size: 16)
    case .i32Load8S, .i32Load8U: try validateMemory(.load, type: .i32, size: 8)
    case .i64Load: try validateMemory(.load, type: .i64)
    case .i64Load16S, .i64Load16U: try validateMemory(.load, type: .i64, size: 16)
    case .i64Load32S, .i64Load32U: try validateMemory(.load, type: .i64, size: 32)
    case .i64Load8S, .i64Load8U: try validateMemory(.load, type: .i64, size: 8)
    case .i32Store: try validateMemory(.store, type: .i32)
    case .i32Store16: try validateMemory(.store, type: .i32, size: 16)
    case .i32Store8: try validateMemory(.store, type: .i32, size: 8)
    case .i64Store: try validateMemory(.store, type: .i64)
    case .i64Store16: try validateMemory(.store, type: .i64, size: 16)
    case .i64Store32: try validateMemory(.store, type: .i64, size: 32)
    case .i64Store8: try validateMemory(.store, type: .i64, size: 8)

    case .memoryCopy:
      let dst = try cursor.readByte()
      let src = try cursor.readByte()
      guard dst < module.totalMemories && src < module.totalMemories else {
        throw ValidationError.invalidMemoryIndex
      }
      try popValue(type: .i32)
      try popValue(type: .i32)
      try popValue(type: .i32)
    case .memoryFill:
      let memoryIndex = try cursor.readByte()
      guard memoryIndex < module.totalMemories else {
        throw ValidationError.invalidMemoryIndex
      }
      try popValue(type: .i32)
      try popValue(type: .i32)
      try popValue(type: .i32)
    case .memoryGrow:
      let memoryIndex = try cursor.readByte()
      guard memoryIndex < module.totalMemories else {
        throw ValidationError.invalidMemoryIndex
      }
      try popValue(type: .i32)
      appendValue(.known(type: .i32))
    case .memoryInit:
      let dataIndex = try cursor.read(LEB: DataIndex.self)
      let memoryIndex = try cursor.readByte()
      guard memoryIndex < module.totalMemories else {
        throw ValidationError.invalidMemoryIndex
      }
      guard let dataCount = module.dataCount else {
        throw ValidationError.missingDataCount
      }
      guard dataIndex < dataCount else {
        throw ValidationError.invalidDataIndex
      }
    case .memorySize:
      let memoryIndex = try cursor.readByte()
      guard memoryIndex < module.totalMemories else {
        throw ValidationError.invalidMemoryIndex
      }
      appendValue(.known(type: .i32))
    case .refFunc:
      let index = try cursor.read(LEB: FunctionIndex.self)
      try getFunction(index: index)
      appendValue(.known(type: .funcref))
    case .refIsNull:
      let value = try popValue()
      guard value.isReference else {
        throw ValidationError.expectedReference
      }
      appendValue(.known(type: .i32))
    case .refNull:
      let type = try cursor.readValueType()
      guard type.isReference else {
        throw ValidationError.expectedReference
      }
      appendValue(.known(type: type))
    case .return_:
      try popValues(types: functionType.results)
      unreachable()
    case .tableCopy:
      let dst = try cursor.read(LEB: TableIndex.self)
      let src = try cursor.read(LEB: TableIndex.self)
      let dstTable = try getTable(index: dst)
      let srcTable = try getTable(index: src)
      guard dstTable.elementType == srcTable.elementType else {
        throw ValidationError.tableValueTypeMismatch
      }
      try popValue(type: .i32)
      try popValue(type: .i32)
      try popValue(type: .i32)
    case .tableFill, .tableGrow:
      let tableIndex = try cursor.read(LEB: TableIndex.self)
      let table = try getTable(index: tableIndex)
      try popValue(type: .i32)
      try popValue(type: table.elementType)
      try popValue(type: .i32)
    case .tableSet:
      let tableIndex = try cursor.read(LEB: TableIndex.self)
      let table = try getTable(index: tableIndex)
      try popValue(type: table.elementType)
      try popValue(type: .i32)
    case .tableInit:
      let elementIndex = try cursor.read(LEB: ElementIndex.self)
      guard elementIndex < module.elements.count else {
        throw ValidationError.invalidElementIndex
      }
      let tableIndex = try cursor.read(LEB: TableIndex.self)
      let table = try getTable(index: tableIndex)
      let element = module.elements[Int(elementIndex)]
      guard table.elementType == element.type else {
        throw ValidationError.tableValueTypeMismatch
      }
      try popValue(type: .i32)
      try popValue(type: .i32)
      try popValue(type: .i32)
    case .tableGet:
      let tableIndex = try cursor.read(LEB: TableIndex.self)
      let table = try getTable(index: tableIndex)
      try popValue(type: .i32)
      appendValue(.known(type: table.elementType))
    case .tableSize:
      let tableIndex = try cursor.read(LEB: TableIndex.self)
      guard tableIndex < module.totalTables else {
        throw ValidationError.invalidTableIndex
      }
      appendValue(.known(type: .i32))
    }
  }

  private mutating func validateMemory(
    _ kind: MemoryInstructionKind, type: ValueType, size: UInt32? = nil
  ) throws {
    let memArg = try cursor.readMemArg()
    guard memArg.memoryIndex < module.totalMemories else {
      throw ValidationError.invalidMemoryIndex
    }
    let size = size ?? UInt32(type.bitWidth!)
    guard 1 << memArg.align <= size / 8 else {
      throw ValidationError.invalidAlignment
    }
    switch kind {
    case .load:
      try popValue(type: .i32)
      appendValue(.known(type: type))
    case .store:
      try popValue(type: type)
      try popValue(type: .i32)
    }
  }

  @discardableResult
  private func getGlobal(index: GlobalIndex) throws -> GlobalType {
    if index < module.importedGlobals {
      return module.getImportedGlobal(index: index)!
    }
    let baseIndex = Int(index) - module.importedGlobals
    guard baseIndex < module.globals.count else {
      throw ValidationError.invalidGlobalIndex
    }
    return module.globals[Int(index) - module.importedGlobals].type
  }

  @discardableResult
  private func getFunction(index: FunctionIndex) throws -> TypeIndex {
    if index < module.importedFunctions {
      return module.getImportedFunction(index: index)!
    }
    let baseIndex = Int(index) - module.importedFunctions
    guard baseIndex < module.functions.count else {
      throw ValidationError.invalidFunctionIndex
    }
    return module.functions[Int(index) - module.importedFunctions]
  }

  @discardableResult
  private func getTable(index: TableIndex) throws -> TableType {
    if index < module.importedTables {
      return module.getImportedTable(index: index)!
    }
    let baseIndex = Int(index) - module.importedTables
    guard baseIndex < module.tables.count else {
      throw ValidationError.invalidTableIndex
    }
    return module.tables[baseIndex].type
  }
}
