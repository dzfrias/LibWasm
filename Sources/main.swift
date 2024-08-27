import Foundation

func readFileInChunks(url: URL, chunkSize: Int) async {
  do {
    let fileHandle = try FileHandle(forReadingFrom: url)
    defer {
      fileHandle.closeFile()
    }
    var parser = Parser()

    while true {
      let data = fileHandle.readData(ofLength: chunkSize)
      if data.isEmpty {
        break
      }

      try parser.push(buf: data)
    }
    let m = try await parser.finish()
    print("\(m.types.count)")
  } catch {
    print("Error reading file: \(error)")
  }
}

await readFileInChunks(url: URL(fileURLWithPath: "/Users/dzfrias/code/LibWasm/spidermonkey.wasm"), chunkSize: 1024)
