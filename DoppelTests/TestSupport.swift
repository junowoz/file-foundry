import Foundation
import XCTest

@discardableResult
func withTemporaryDirectory<T>(
    named name: String = UUID().uuidString,
    _ body: (URL) throws -> T
) throws -> T {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DoppelTests", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try body(root)
}

@discardableResult
func withTemporaryDirectory<T>(
    named name: String = UUID().uuidString,
    _ body: (URL) async throws -> T
) async throws -> T {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DoppelTests", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await body(root)
}

@discardableResult
func writeFile(_ directory: URL, _ name: String, _ contents: Data) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try contents.write(to: url, options: .atomic)
    return url
}

func makeData(_ string: String) -> Data {
    Data(string.utf8)
}

func makeWaveData(seconds: Int = 1, sampleByte: UInt8) -> Data {
    let sampleRate: UInt32 = 8_000
    let dataSize = UInt32(seconds) * sampleRate
    var data = Data("RIFF".utf8)
    appendLittleEndian(UInt32(36) + dataSize, to: &data)
    data.append(Data("WAVEfmt ".utf8))
    appendLittleEndian(UInt32(16), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(sampleRate, to: &data)
    appendLittleEndian(sampleRate, to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(UInt16(8), to: &data)
    data.append(Data("data".utf8))
    appendLittleEndian(dataSize, to: &data)
    data.append(Data(repeating: sampleByte, count: Int(dataSize)))
    return data
}

private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}
