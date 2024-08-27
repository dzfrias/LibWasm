import Foundation

public enum ValueType {
  case i32
  case i64
  case f32
  case f64
  case funcref
  case externref
  case v128
  
  public var bitWidth: Int? {
    switch self {
    case .i32, .f32: return 32
    case .i64, .f64: return 64
    case .v128: return 128
    case .funcref, .externref: return nil
    }
  }

  public var isReference: Bool {
    return self == .funcref || self == .externref
  }
  public var isNumeric: Bool {
    return !isReference && self != .v128
  }
}

public typealias TypeIndex = UInt32
public typealias MemoryIndex = UInt32
public typealias TableIndex = UInt32
public typealias FunctionIndex = UInt32
public typealias GlobalIndex = UInt32
public typealias DataIndex = UInt32
public typealias ElementIndex = UInt32
public typealias LabelIndex = UInt32
public typealias LocalIndex = UInt32

public struct Limits {
  public let min: UInt32
  public let max: UInt32?
}

public struct TableType {
  public let elementType: ValueType
  public let limits: Limits
}

public struct MemoryType {
  public let limits: Limits
}

public struct Expression {
  public let data: Data
}

public enum Mutability {
  case mutable
  case immutable
}

public struct GlobalType {
  public let valueType: ValueType
  public let mutability: Mutability
}

public struct FunctionType {
  public let parameters: [ValueType]
  public let results: [ValueType]
}

public enum BlockType {
  case empty
  case single(result: ValueType)
  case index(TypeIndex)
}

public struct BrTable {
  public let labels: [LabelIndex]
  public let defaultLabel: LabelIndex
}

public struct MemArg {
  public let align: UInt32
  public let memoryIndex: MemoryIndex
  public let offset: UInt32
}

public enum SectionId {
  case custom
  case type
  case import_
  case function
  case table
  case memory
  case global
  case export
  case start
  case element
  case code
  case data
  case dataCount
}

public struct CustomSection {
  public let name: String
  public let contents: String
}

public struct TypeSection {
  public let types: [FunctionType]
}

public struct Import {
  public enum ImportDesc {
    // Function imports use type index
    case function(TypeIndex)
    case table(TableType)
    case memory(MemoryType)
    case global(GlobalType)
  }

  public let module: String
  public let name: String
  public let description: ImportDesc
}

public struct Table {
  public let type: TableType
}

public struct Memory {
  public let type: MemoryType
}

public struct Global {
  public let type: GlobalType
  public let initExpr: Expression
}

public struct Export {
  public enum ExportDesc {
    case function(FunctionIndex)
    case table(TableIndex)
    case memory(MemoryIndex)
    case global(GlobalIndex)
  }

  public let name: String
  public let description: ExportDesc
}

public struct Element {
  public enum Mode {
    case active(table: TableIndex, offset: Expression)
    case declarative
    case passive
  }

  public let type: ValueType
  public let initExprs: [Expression]
  public let mode: Mode
}

public struct Function {
  public struct Locals {
    public let n: UInt32
    public let type: ValueType
  }

  public let locals: [Locals]
  public let body: Expression
}

public struct Code {
  public let size: UInt32
  public let function: Function
}

public struct DataSegment {
  public let data: Data
  public let memoryIndex: MemoryIndex?
  public let offset: Expression?
}

public class Module {
  public var customSections: [CustomSection] = []
  public var types: [FunctionType] = []
  public var imports: [Import] = []
  public var functions: [TypeIndex] = []
  public var tables: [Table] = []
  public var memories: [Memory] = []
  public var globals: [Global] = []
  public var exports: [Export] = []
  public var elements: [Element] = []
  public var startFunction: FunctionIndex? = nil
  public var codes: [Code] = []
  public var datas: [DataSegment] = []
  public var dataCount: UInt32? = nil

  // The totals should comprise of the number of imported instances.
  // They are computed lazily and then cached.
  private var computedImportedFunctions: Int? = nil
  private var computedImportedTables: Int? = nil
  private var computedImportedMemories: Int? = nil
  private var computedImportedGlobals: Int? = nil
  
  public func getImportedFunction(index: FunctionIndex) -> TypeIndex? {
    var seen = 0
    for import_ in imports {
      guard case let .function(type) = import_.description else { continue }
      if index == seen {
        return type
      }
      seen += 1
    }
    return nil
  }

  public func getImportedTable(index: TableIndex) -> TableType? {
    var seen = 0
    for import_ in imports {
      guard case let .table(type) = import_.description else { continue }
      if index == seen {
        return type
      }
      seen += 1
    }
    return nil
  }
  
  public func getImportedMemory(index: MemoryIndex) -> MemoryType? {
    var seen = 0
    for import_ in imports {
      guard case let .memory(type) = import_.description else { continue }
      if index == seen {
        return type
      }
      seen += 1
    }
    return nil
  }

  public func getImportedGlobal(index: GlobalIndex) -> GlobalType? {
    var seen = 0
    for import_ in imports {
      guard case let .global(type) = import_.description else { continue }
      if index == seen {
        return type
      }
      seen += 1
    }
    return nil
  }
  
  public var importedFunctions: Int {
    guard let total = computedImportedFunctions else {
      computeTotals()
      return computedImportedFunctions!
    }
    return total
  }
  
  public var importedTables: Int {
    guard let total = computedImportedTables else {
      computeTotals()
      return computedImportedTables!
    }
    return total
  }
  
  public var importedMemories: Int {
    guard let total = computedImportedMemories else {
      computeTotals()
      return computedImportedMemories!
    }
    return total
  }
  
  public var importedGlobals: Int {
    guard let total = computedImportedGlobals else {
      computeTotals()
      return computedImportedGlobals!
    }
    return total
  }

  public var totalFunctions: Int {
    guard let total = computedImportedFunctions else {
      computeTotals()
      return computedImportedFunctions! + functions.count
    }
    return total + functions.count
  }
  
  public var totalTables: Int {
    guard let total = computedImportedTables else {
      computeTotals()
      return computedImportedTables! + tables.count
    }
    return total + tables.count
  }

  public var totalMemories: Int {
    guard let total = computedImportedMemories else {
      computeTotals()
      return computedImportedMemories! + memories.count
    }
    return total + memories.count
  }

  public var totalGlobals: Int {
    guard let total = computedImportedGlobals else {
      computeTotals()
      return computedImportedGlobals! + globals.count
    }
    return total + globals.count
  }

  private func computeTotals() {
    var numFuncs = 0
    var numTables = 0
    var numMemories = 0
    var numGlobals = 0
    for import_ in imports {
      switch import_.description {
      case .function:
        numFuncs += 1
      case .table:
        numTables += 1
      case .memory:
        numMemories += 1
      case .global:
        numGlobals += 1
      }
    }
    computedImportedFunctions = numFuncs
    computedImportedTables = numTables
    computedImportedMemories = numMemories
    computedImportedGlobals = numGlobals
  }
}
