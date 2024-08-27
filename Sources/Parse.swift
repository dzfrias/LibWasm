import Foundation

/// An error that occurs when parsing the WebAssembly binary format.
public enum ParseError: Error {
  case invalidModuleMagic
  case invalidVersion
  case invalidSectionId
  case invalidFunctionTypeTag
  case invalidValueTypeTag
  case invalidUtf8
  case invalidExternTag
  case expectedReferenceType
  case invalidLimitsFlag
  case invalidMutabilityFlag
  case invalidElementTag
  case invalidDataTag
}

/// A protocol for extending `Cursor` with reading capabilities specifc
/// to the WebAssembly binary format.
public protocol WasmReader {
  mutating func readValueType() throws -> ValueType
  mutating func readBlockType() throws -> BlockType
  mutating func readMemArg() throws -> MemArg
  mutating func readBrTable() throws -> BrTable
}

extension Cursor: WasmReader {
  public mutating func readValueType() throws -> ValueType {
    let tag = try readByte()
    switch tag {
    case 0x7F:
      return ValueType.i32
    case 0x7E:
      return ValueType.i64
    case 0x7D:
      return ValueType.f32
    case 0x7C:
      return ValueType.f64
    case 0x70:
      return ValueType.funcref
    case 0x6F:
      return ValueType.externref
    default:
      throw ParseError.invalidValueTypeTag
    }
  }
  
  public mutating func readBlockType() throws -> BlockType {
    let byte = try readByte()
    if byte == 0x40 {
      return .empty
    }
    pos -= 1
    do {
      return .single(result: try readValueType())
    } catch ParseError.invalidValueTypeTag {
      pos -= 1
    }
    let index = try read(LEB: TypeIndex.self)
    return .index(index)
  }
  
  public mutating func readBrTable() throws -> BrTable {
    let count = try read(LEB: UInt32.self)
    var labels: [LabelIndex] = []
    for _ in 0..<count {
      labels.append(try read())
    }
    let defaultLabel = try read(LEB: LabelIndex.self)
    return BrTable(labels: labels, defaultLabel: defaultLabel)
  }
  
  public mutating func readMemArg() throws -> MemArg {
    var align = try read(LEB: UInt32.self)
    var memoryIndex: MemoryIndex = 0
    if align & 0x40 != 0 {
      align &= ~0x40
      memoryIndex = try read(LEB: UInt32.self)
    }
    let offset = try read(LEB: UInt32.self)
    return MemArg(align: align, memoryIndex: memoryIndex, offset: offset)
  }
}

private class ValidationTask {
  private struct Input {
    public let data: Data
    public let locals: [Function.Locals]
    public let type: FunctionType
  }
  
  private let stream: AsyncStream<Input>
  private let continuation: AsyncStream<Input>.Continuation
  private var task: Task<Void, Error>? = nil
  
  public init(for module: Module) {
    (stream, continuation) = AsyncStream.makeStream()
    task = nil
    task = Task {
      try await withThrowingTaskGroup(of: Void.self) { taskGroup in
        for await function in self.stream {
          taskGroup.addTask {
            var validator = CodeValidator(for: module)
            try validator.validate(data: function.data, locals: function.locals, type: function.type)
          }
        }
        try await taskGroup.next()
      }
    }
  }
  
  public func validate(data: Data, locals: [Function.Locals], type: FunctionType) {
    continuation.yield(Input(data: data, locals: locals, type: type))
  }
  
  public func finish() {
    continuation.finish()
  }
  
  public func awaitCompletion() async throws {
    try await task!.value
  }
}

/// A parser for the WebAssembly binary format.
///
/// The `Parser` will simultaneously validate a WebAssembly module as 
/// it is being parsed. Thus, the returned output from the `finish()` method
/// will be a valid module.
///
/// `Parser` parses chunks of data, supporting incremental payloads (a
/// push-style parser).
public struct Parser: ~Copyable {
  private enum State {
    case magic
    case version
    case sectionStart
    case section(SectionId)
    case sectionWithSize(id: SectionId, size: UInt32)
    case funcBody(current: UInt32, max: UInt32)
    case funcBodyWithSize(current: UInt32, max: UInt32, size: UInt32)
  }

  private var module = Module()
  private var cursor = Cursor()
  private var state: State = .magic
  // This validator is used for init expressions only
  private var validator: CodeValidator
  private let validationTask: ValidationTask

  /// Creates a new parser.
  public init() {
    validator = CodeValidator(for: module)
    validationTask = ValidationTask(for: module)
  }
  
  /// Pushes a payload into the parser.
  public mutating func push(buf: Data) throws {
    cursor.push(bytes: buf)
    try advanceAll()
  }

  /// Signals to the parser that no more payloads should be received,
  /// returning the produced module.
  public consuming func finish() async throws -> Module {
    try await validationTask.awaitCompletion()
    // If there cursor is not at eof by now, an actual eof error occured
    guard cursor.isAtEof else {
      throw ReadError.unexpectedEof
    }

    return (consume self).module
  }

  private mutating func advanceAll() throws {
    while true {
      let prevPos = cursor.pos
      do {
        try advance()
      } catch ReadError.unexpectedEof {
        // Reset our position and return, waiting for more data
        cursor.pos = prevPos
        return
      }
    }
  }

  private mutating func advance() throws {
    switch state {
    case .magic:
      let expected = Data([0, 97, 115, 109])
      let buf = try cursor.read(count: 4)
      guard buf == expected else {
        throw ParseError.invalidModuleMagic
      }
      state = .version
 
    case .version:
      let expected = Data([1, 0, 0, 0])
      let buf = try cursor.read(count: 4)
      guard buf == expected else {
        throw ParseError.invalidVersion
      }
      state = .sectionStart

    case .sectionStart:
      let sectionId = try parseSectionId()
      state = .section(sectionId)

    case .section(let sectionId):
      let size = try cursor.read(LEB: UInt32.self)
      // Quit early if we know we can't fulfill the expected size
      guard cursor.pos + Int(size) <= cursor.buf.count else {
        throw ReadError.unexpectedEof
      }
      state = .sectionWithSize(id: sectionId, size: size)

    case .sectionWithSize(let id, let size):
      switch id {
      case .custom:
        module.customSections.append(try parseCustomSection(size: size))
        state = .sectionStart
      case .type:
        module.types = try parseVector { (parser) in try parser.parseFunctionType() }
        state = .sectionStart
      case .import_:
        module.imports = try parseVector { (parser) in try parser.parseImport() }
        state = .sectionStart
      case .function:
        module.functions = try parseVector { (parser) in try parser.parseTypeIndex() }
        state = .sectionStart
      case .table:
        module.tables = try parseVector { (parser) in try parser.parseTable() }
        state = .sectionStart
      case .memory:
        module.memories = try parseVector { (parser) in try parser.parseMemory() }
        state = .sectionStart
      case .global:
        module.globals = try parseVector { (parser) in try parser.parseGlobal() }
        state = .sectionStart
      case .export:
        module.exports = try parseVector { (parser) in try parser.parseExport() }
        state = .sectionStart
      case .start:
        module.startFunction = try parseFunctionIndex()
        state = .sectionStart
      case .element:
        module.elements = try parseVector { (parser) in try parser.parseElement() }
        state = .sectionStart
      case .code:
        let count = try cursor.read(LEB: UInt32.self)
        module.codes.reserveCapacity(Int(count))
        // We handle function bodies individually, with their own separate
        // state. That way, we don't have to redo every function if our
        // section payload isn't big enough.
        state = .funcBody(current: 0, max: count)
      case .data:
        module.datas = try parseVector { (parser) in try parser.parseDataSegment() }
        if let expectedCount = module.dataCount {
          guard module.datas.count == expectedCount else {
            throw ValidationError.dataCountMismatch
          }
        }
        state = .sectionStart
      case .dataCount:
        module.dataCount = try cursor.read(LEB: UInt32.self)
        state = .sectionStart
      }

    case .funcBody(let current, let max):
      // This means that we've read all the function bodies that were declared
      if current == max {
        state = .sectionStart
        guard module.codes.count == module.functions.count else {
          throw ValidationError.codeCountMismatch
        }
        validationTask.finish()
      } else {
        let size = try cursor.read(LEB: UInt32.self)
        state = .funcBodyWithSize(current: current, max: max, size: size)
      }

    case .funcBodyWithSize(let current, let max, let size):
      guard current < module.functions.count else {
        throw ValidationError.invalidFunctionIndex
      }
      let function = try parseFunction(size: size, type: module.types[Int(module.functions[Int(current)])])
      let code = Code(size: size, function: function)
      module.codes.append(code)
      state = .funcBody(current: current + 1, max: max)
    }
  }

  private mutating func parseVector<T>(parseFunc: (inout Self) throws -> T) throws -> [T] {
    let count = try cursor.read(LEB: UInt32.self)
    var results: [T] = []
    results.reserveCapacity(Int(count))
    for _ in 0..<count {
      results.append(try parseFunc(&self))
    }
    return results
  }

  private mutating func parseData() throws -> Data {
    let count = try cursor.read(LEB: UInt32.self)
    let results = try cursor.read(count: Int(count))
    return results
  }

  private mutating func parseName() throws -> String {
    let data = try parseData()
    let string = String(decoding: data, as: UTF8.self)
    guard string.isContiguousUTF8 else {
      throw ParseError.invalidUtf8
    }
    return string
  }

  private mutating func parseLimits(bound: UInt64) throws -> Limits {
    let flag = try cursor.readByte()
    guard flag <= 1 else {
      throw ParseError.invalidLimitsFlag
    }

    let min = try cursor.read(LEB: UInt32.self)
    guard min <= bound else {
      throw ValidationError.invalidLimits
    }
    var max: UInt32? = nil
    if flag == 1 {
      let value = try cursor.read(LEB: UInt32.self)
      max = value
      guard value >= min && value <= bound else {
        throw ValidationError.invalidLimits
      }
    }
    return Limits(min: min, max: max)
  }

  private mutating func parseSectionId() throws -> SectionId {
    let id = try cursor.readByte()
    switch id {
    case 0x00:
      return .custom
    case 0x01:
      return .type
    case 0x02:
      return .import_
    case 0x03:
      return .function
    case 0x04:
      return .table
    case 0x05:
      return .memory
    case 0x06:
      return .global
    case 0x07:
      return .export
    case 0x08:
      return .start
    case 0x09:
      return .element
    case 0x0a:
      return .code
    case 0x0b:
      return .data
    case 0x0c:
      return .dataCount
    default:
      throw ParseError.invalidSectionId
    }
  }

  private mutating func parseInitExpression(expected type: ValueType) throws -> Expression {
    let consumed = try validator.validateInitExpr(data: cursor.rest, expected: type)
    let data = try cursor.read(count: consumed)
    return Expression(data: data)
  }

  private mutating func parseFunctionType() throws -> FunctionType {
    let tag = try cursor.readByte()
    guard tag == 0x60 else {
      throw ParseError.invalidFunctionTypeTag
    }

    let params = try parseVector { (parser) in try parser.cursor.readValueType() }
    let results = try parseVector { (parser) in try parser.cursor.readValueType() }

    return FunctionType(parameters: params, results: results)
  }

  private mutating func parseTableType() throws -> TableType {
    let type = try cursor.readValueType()
    guard type.isReference else {
      throw ParseError.expectedReferenceType
    }
    let limits = try parseLimits(bound: (1 << 32) - 1)

    return TableType(elementType: type, limits: limits)
  }

  private mutating func parseMemoryType() throws -> MemoryType {
    let limits = try parseLimits(bound: 1 << 16)
    return MemoryType(limits: limits)
  }

  private mutating func parseGlobalType() throws -> GlobalType {
    let type = try cursor.readValueType()
    let mutabilityFlag = try cursor.readByte()
    guard mutabilityFlag <= 1 else {
      throw ParseError.invalidMutabilityFlag
    }
    return GlobalType(valueType: type, mutability: mutabilityFlag == 1 ? .mutable : .immutable)
  }

  private mutating func parseExport() throws -> Export {
    let name = try parseName()
    let tag = try cursor.readByte()

    switch tag {
    case 0x00:
      let index = try parseFunctionIndex()
      return Export(name: name, description: .function(index))
    case 0x01:
      let index = try parseTableIndex()
      return Export(name: name, description: .table(index))
    case 0x02:
      let index = try parseMemoryIndex()
      return Export(name: name, description: .memory(index))
    case 0x03:
      let index = try parseGlobalIndex()
      return Export(name: name, description: .global(index))
    default:
      throw ParseError.invalidExternTag
    }
  }

  private mutating func parseImport() throws -> Import {
    let moduleName = try parseName()
    let name = try parseName()
    let tag = try cursor.readByte()

    switch tag {
    case 0x00:
      let index = try parseTypeIndex()
      return Import(module: moduleName, name: name, description: .function(index))
    case 0x01:
      let tableType = try parseTableType()
      return Import(module: moduleName, name: name, description: .table(tableType))
    case 0x02:
      let memoryType = try parseMemoryType()
      return Import(module: moduleName, name: name, description: .memory(memoryType))
    case 0x03:
      let globalType = try parseGlobalType()
      return Import(module: moduleName, name: name, description: .global(globalType))
    default:
      throw ParseError.invalidExternTag
    }
  }

  private mutating func parseTable() throws -> Table {
    return Table(type: try parseTableType())
  }

  private mutating func parseMemory() throws -> Memory {
    return Memory(type: try parseMemoryType())
  }

  private mutating func parseGlobal() throws -> Global {
    let type = try parseGlobalType()
    let expr = try parseInitExpression(expected: type.valueType)
    return Global(type: type, initExpr: expr)
  }

  private mutating func parseElement() throws -> Element {
    let tag = try cursor.readByte()
    guard tag <= 0x07 else {
      throw ParseError.invalidElementTag
    }

    let hasPassive = (tag & 0x01) != 0
    let hasExplicitIndex = (tag & 0x02) != 0
    let hasExprs = (tag & 0x04) != 0

    var mode: Element.Mode
    if hasPassive {
      mode = hasExplicitIndex ? .declarative : .passive
    } else {
      let index = hasExplicitIndex ? try parseTableIndex() : 0
      let expr = try parseInitExpression(expected: .i32)
      mode = .active(table: index, offset: expr)
    }

    var type = ValueType.funcref
    if hasPassive || hasExplicitIndex {
      if hasExprs {
        type = try cursor.readValueType()
        guard type.isReference else {
          throw ParseError.expectedReferenceType
        }
      } else {
        let externTag = try cursor.readByte()
        guard externTag == 0x00 else {
          throw ParseError.invalidExternTag
        }
      }
    }

    var items: [Expression] = []
    if !hasExprs {
      let indices = try parseVector { (parser) in try parser.parseFunctionIndex() }
      // TODO
      items = indices.map { (_) in Expression(data: Data()) }
    } else {
      items = try parseVector { (parser) in try parser.parseInitExpression(expected: type) }
    }

    return Element(type: type, initExprs: items, mode: mode)
  }

  private mutating func parseDataSegment() throws -> DataSegment {
    let tag = try cursor.readByte()

    switch tag {
    case 0x00:
      let expr = try parseInitExpression(expected: .i32)
      let data = try parseData()
      return DataSegment(data: data, memoryIndex: nil, offset: expr)
    case 0x01:
      let data = try parseData()
      return DataSegment(data: data, memoryIndex: nil, offset: nil)
    case 0x02:
      let index = try parseMemoryIndex()
      let expr = try parseInitExpression(expected: .i32)
      let data = try parseData()
      return DataSegment(data: data, memoryIndex: index, offset: expr)
    default:
      throw ParseError.invalidDataTag
    }
  }
  
  private mutating func parseFunction(size: UInt32, type: FunctionType) throws -> Function {
    let startPos = cursor.pos
    let allLocals = try parseVector { (parser) in
      let typeCount = try parser.cursor.read(LEB: UInt32.self)
      let type = try parser.cursor.readValueType()
      return Function.Locals(n: typeCount, type: type)
    }
    let body = try cursor.read(count: Int(size) - (cursor.pos - startPos))
    validationTask.validate(data: body, locals: allLocals, type: type)
    return Function(locals: allLocals, body: Expression(data: body))
  }

  private mutating func parseCustomSection(size: UInt32) throws -> CustomSection {
    let startPos = cursor.pos
    let name = try parseName()
    let buffer = try cursor.read(count: Int(size) - (cursor.pos - startPos))
    let contents = String(decoding: buffer, as: UTF8.self)
    guard contents.isContiguousUTF8 else {
      throw ParseError.invalidUtf8
    }
    return CustomSection(name: name, contents: contents)
  }
  
  private mutating func parseFunctionIndex() throws -> FunctionIndex {
    let index = try cursor.read(LEB: FunctionIndex.self)
    guard index < module.totalFunctions else {
      throw ValidationError.invalidFunctionIndex
    }
    return index
  }
  
  private mutating func parseTableIndex() throws -> TableIndex {
    let index = try cursor.read(LEB: TableIndex.self)
    guard index < module.totalTables else {
      throw ValidationError.invalidTableIndex
    }
    return index
  }
  
  private mutating func parseMemoryIndex() throws -> MemoryIndex {
    let index = try cursor.read(LEB: MemoryIndex.self)
    guard index < module.totalMemories else {
      throw ValidationError.invalidMemoryIndex
    }
    return index
  }
  
  private mutating func parseGlobalIndex() throws -> GlobalIndex {
    let index = try cursor.read(LEB: GlobalIndex.self)
    guard index < module.totalGlobals else {
      throw ValidationError.invalidGlobalIndex
    }
    return index
  }
  
  private mutating func parseTypeIndex() throws -> TypeIndex {
    let index = try cursor.read(LEB: TypeIndex.self)
    guard index < module.types.count else {
      throw ValidationError.invalidTypeIndex
    }
    return index
  }
}
