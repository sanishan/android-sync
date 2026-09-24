import Foundation
import AppKit
import CoreMedia
import CoreVideo
import VideoToolbox
import CoreImage
import Network

final class H264VideoDecoder {
    var onFrame: ((NSImage) -> Void)?
    private let queue = DispatchQueue(label: "dev.androidsync.h264-decoder", qos: .userInteractive)
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?

    func configure(csd0: Data, csd1: Data?) {
        queue.async { [weak self] in self?.configureNow(csd0: csd0, csd1: csd1) }
    }

    func decode(_ encoded: Data, presentationTime: Int64, keyFrame: Bool) {
        queue.async { [weak self] in self?.decodeNow(encoded,presentationTime: presentationTime,keyFrame: keyFrame) }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }
            self.session = nil; self.format = nil
        }
    }

    private func configureNow(csd0: Data, csd1: Data?) {
        let parameterSets = Self.nalUnits(in: csd0) + (csd1.map(Self.nalUnits) ?? [])
        guard let sps = parameterSets.first(where: { $0.first.map { $0 & 0x1f == 7 } == true }),
              let pps = parameterSets.first(where: { $0.first.map { $0 & 0x1f == 8 } == true }) else { return }
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil
        var description: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in pps.withUnsafeBytes { ppsBytes in
            let pointers = [spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)]
            let sizes = [sps.count,pps.count]
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        } }
        guard status == noErr, let videoDescription = description else { return }
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { refcon, _, status, _, imageBuffer, _, _ in
            guard status == noErr, let refcon, let imageBuffer else { return }
            Unmanaged<H264VideoDecoder>.fromOpaque(refcon).takeUnretainedValue().render(imageBuffer)
        }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        let attributes: [NSString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                            kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: videoDescription, decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary, outputCallback: &callback, decompressionSessionOut: &session) == noErr else { session = nil; return }
        if let session { VTSessionSetProperty(session,key: kVTDecompressionPropertyKey_RealTime,value: kCFBooleanTrue) }
        format = videoDescription
    }

    private func decodeNow(_ encoded: Data, presentationTime: Int64, keyFrame: Bool) {
        guard let session, let format else { return }
        let data = Self.avcc(encoded)
        guard !data.isEmpty else { return }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return }
        let copied = data.withUnsafeBytes { bytes in CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        guard copied == kCMBlockBufferNoErr else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: presentationTime,timescale: 1_000_000), decodeTimeStamp: .invalid)
        var size = data.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return }
        _ = keyFrame
        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: flags, frameRefcon: nil, infoFlagsOut: nil)
    }

    private func render(_ pixelBuffer: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = imageContext.createCGImage(image, from: image.extent) else { return }
        let frame = NSImage(cgImage: cg,size: NSSize(width: image.extent.width,height: image.extent.height))
        DispatchQueue.main.async { [weak self] in self?.onFrame?(frame) }
    }

    private static func nalUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(offset: Int,prefix: Int)] = []; var i = 0
        while i + 3 <= bytes.count {
            if i + 4 <= bytes.count, bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 0, bytes[i+3] == 1 { starts.append((i,4)); i += 4 }
            else if bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 1 { starts.append((i,3)); i += 3 }
            else { i += 1 }
        }
        guard !starts.isEmpty else { return data.isEmpty ? [] : [data] }
        return starts.enumerated().compactMap { index, marker in
            let start = marker.offset + marker.prefix; let end = index + 1 < starts.count ? starts[index+1].offset : bytes.count
            return end > start ? Data(bytes[start..<end]) : nil
        }
    }

    private static func avcc(_ data: Data) -> Data {
        let units = nalUnits(in: data)
        if units.count == 1, units[0] == data, data.count >= 4 {
            let declared = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            if declared > 0, declared <= data.count - 4 { return data }
        }
        return units.reduce(into: Data()) { output, unit in
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(unit)
        }
    }
}

enum ADBClientError: LocalizedError {
    case unavailable, invalidEndpoint, invalidCode, timedOut, failed(String)
    var errorDescription: String? { switch self {
    case .unavailable: "The bundled ADB client is unavailable in this build."
    case .invalidEndpoint: "Enter the private IP address and port shown under Android Wireless debugging."
    case .invalidCode: "Enter the six-digit Android pairing code."
    case .timedOut: "ADB did not respond within 20 seconds."
    case .failed(let value): value
    } }
}

final class BundledADBClient {
    private var executable: URL? { Bundle.main.url(forResource: "adb",withExtension: nil) }
    var available: Bool { executable != nil }

    func pair(endpoint: String, code: String) async throws -> String {
        guard code.range(of: #"^\d{6}$"#,options: .regularExpression) != nil else { throw ADBClientError.invalidCode }
        return try await invoke(["pair",try validated(endpoint),code])
    }
    func connect(endpoint: String) async throws -> String { try await invoke(["connect",try validated(endpoint)]) }
    func disconnect(endpoint: String) async throws -> String { try await invoke(["disconnect",try validated(endpoint)]) }

    private func validated(_ endpoint: String) throws -> String {
        let fields = endpoint.split(separator: ":",omittingEmptySubsequences: false)
        guard fields.count == 2, let port = UInt16(fields[1]), port > 0, let address = IPv4Address(String(fields[0])) else { throw ADBClientError.invalidEndpoint }
        let bytes = [UInt8](address.rawValue)
        let local = bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 192 && bytes[1] == 168) || bytes[0] == 127
        guard local else { throw ADBClientError.invalidEndpoint }
        return "\(address):\(port)"
    }

    private func invoke(_ arguments: [String]) async throws -> String {
        guard let executable else { throw ADBClientError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process(); let output = Pipe(); let errors = Pipe()
            process.executableURL = executable; process.arguments = arguments; process.standardOutput = output; process.standardError = errors
            let gate = ADBContinuationGate(continuation)
            process.terminationHandler = { process in
                let text = String(data: output.fileHandleForReading.readDataToEndOfFile() + errors.fileHandleForReading.readDataToEndOfFile(),encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                gate.finish(process.terminationStatus == 0 ? .success(text) : .failure(ADBClientError.failed(text.isEmpty ? "ADB rejected the request." : text)))
            }
            do { try process.run() } catch { gate.finish(.failure(error)); return }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 20) {
                guard process.isRunning else { return }; process.terminate(); gate.finish(.failure(ADBClientError.timedOut))
            }
        }
    }
}

private final class ADBContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<String,Error>
    init(_ continuation: CheckedContinuation<String,Error>) { self.continuation = continuation }
    func finish(_ result: Result<String,Error>) {
        lock.lock(); guard !completed else { lock.unlock(); return }; completed = true; lock.unlock()
        continuation.resume(with: result)
    }
}
