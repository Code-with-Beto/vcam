import AVFoundation

/// Decode the actual PCM layout rather than assuming the microphone is Float32
/// or stereo. USB interfaces commonly expose signed 24-bit samples in 32-bit slots.
enum CapturePCM {
    struct Decoded {
        let sampleRate: Double
        let channels: [[Float]]
        let peaks: [Float]
        var frameCount: Int { channels.first?.count ?? 0 }
    }

    static func decode(_ sample: CMSampleBuffer) throws -> Decoded {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM else { throw error("The microphone did not provide PCM audio.") }
        let channelCount = Int(description.mChannelsPerFrame)
        let frameCount = CMSampleBufferGetNumSamples(sample)
        let bits = Int(description.mBitsPerChannel)
        let floating = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let signed = description.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let nonInterleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bigEndian = description.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        let alignedHigh = description.mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0
        let sampleBytes = Int(description.mBytesPerFrame) / max(nonInterleaved ? 1 : channelCount, 1)
        guard channelCount > 0, channelCount <= 64, frameCount > 0,
              sampleBytes > 0, sampleBytes <= 8,
              (floating && (bits == 32 || bits == 64)) || (signed && bits > 0 && bits <= 32) else {
            throw error("The microphone PCM layout is not supported (\(channelCount) channels, \(bits)-bit).")
        }
        var requiredSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample,
            bufferListSizeNeededOut: &requiredSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil) == noErr,
            requiredSize > 0 else { throw error("Microphone audio buffers could not be read.") }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: requiredSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlock: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample,
            bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: requiredSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlock) == noErr else { throw error("Microphone PCM data could not be retained.") }
        var channels = [[Float]](repeating: [Float](repeating: 0, count: frameCount), count: channelCount)
        var peaks = [Float](repeating: 0, count: channelCount)
        var channelOffset = 0
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            let bufferChannels = Int(buffer.mNumberChannels)
            let stride = sampleBytes * bufferChannels
            guard let data = buffer.mData, bufferChannels > 0,
                  channelOffset + bufferChannels <= channelCount,
                  Int(buffer.mDataByteSize) >= frameCount * stride else { throw error("The microphone returned an incomplete PCM buffer.") }
            let bytes = data.assumingMemoryBound(to: UInt8.self)
            for frame in 0..<frameCount {
                for channel in 0..<bufferChannels {
                    let position = frame * stride + channel * sampleBytes
                    var raw: UInt64 = 0
                    for byte in 0..<sampleBytes {
                        let shift = (bigEndian ? sampleBytes - 1 - byte : byte) * 8
                        raw |= UInt64(bytes[position + byte]) << shift
                    }
                    let value: Float
                    if floating {
                        value = bits == 32 ? Float(bitPattern: UInt32(truncatingIfNeeded: raw)) : Float(Double(bitPattern: raw))
                    } else {
                        if alignedHigh, sampleBytes * 8 > bits { raw >>= sampleBytes * 8 - bits }
                        let integer = Int64(bitPattern: raw << (64 - bits)) >> (64 - bits)
                        value = Float(Double(integer) / Double(UInt64(1) << (bits - 1)))
                    }
                    let finite = value.isFinite ? min(max(value, -1), 1) : 0
                    channels[channelOffset + channel][frame] = finite
                    peaks[channelOffset + channel] = max(peaks[channelOffset + channel], abs(finite))
                }
            }
            channelOffset += bufferChannels
        }
        guard channelOffset == channelCount else { throw error("The microphone channel count does not match its PCM buffers.") }
        return Decoded(sampleRate: description.mSampleRate, channels: channels, peaks: peaks)
    }

    static func monoFormat(sampleRate: Double) throws -> CMAudioFormatDescription {
        var description = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format) == noErr, let format else {
            throw error("The mono microphone format could not be configured.")
        }
        return format
    }

    static func monoSample(_ decoded: Decoded, channel: Int, format: CMAudioFormatDescription, at time: CMTime) throws -> CMSampleBuffer {
        guard decoded.channels.indices.contains(channel) else { throw error("The selected microphone input is not available.") }
        let samples = decoded.channels[channel]
        let size = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: size, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: size, flags: 0, blockBufferOut: &block) == noErr, let block else {
            throw error("The mono microphone buffer could not be allocated.")
        }
        let copied = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: size)
        }
        guard copied == noErr else { throw error("The microphone samples could not be copied.") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(decoded.sampleRate)),
            presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: samples.count, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample) == noErr, let sample else { throw error("The mono microphone sample could not be created.") }
        return sample
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "vcam.pcm", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
