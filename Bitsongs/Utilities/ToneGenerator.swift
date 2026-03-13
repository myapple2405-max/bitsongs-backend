import AVFoundation
import Foundation

/// Generates simple tone audio files for demo purposes when no real audio files are available
class ToneGenerator {
    
    /// Musical note frequencies for generating distinct tones per song
    private static let noteFrequencies: [Double] = [
        261.63, // C4
        293.66, // D4
        329.63, // E4
        349.23, // F4
        392.00, // G4
        440.00, // A4
        493.88, // B4
        523.25, // C5
        587.33, // D5
        659.25  // E5
    ]
    
    /// Generate a WAV file with a pleasant tone at the given frequency
    static func generateTone(frequency: Double, duration: TimeInterval, sampleRate: Double = 44100) -> Data {
        let frameCount = Int(duration * sampleRate)
        var audioData = Data()
        
        // WAV header
        let dataSize = frameCount * 2 // 16-bit samples
        let fileSize = 36 + dataSize
        
        // RIFF header
        audioData.append(contentsOf: "RIFF".utf8)
        audioData.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Array($0) })
        audioData.append(contentsOf: "WAVE".utf8)
        
        // fmt chunk
        audioData.append(contentsOf: "fmt ".utf8)
        audioData.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        audioData.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM
        audioData.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // Mono
        audioData.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        audioData.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { Array($0) }) // byte rate
        audioData.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) }) // block align
        audioData.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) }) // bits per sample
        
        // data chunk
        audioData.append(contentsOf: "data".utf8)
        audioData.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        
        // Generate audio samples with harmonics and envelope for a richer tone
        for i in 0..<frameCount {
            let t = Double(i) / sampleRate
            let progress = Double(i) / Double(frameCount)
            
            // ADSR envelope
            let attack = 0.05
            let decay = 0.1
            let sustainLevel = 0.6
            let releaseStart = 0.85
            
            var envelope: Double
            if progress < attack {
                envelope = progress / attack
            } else if progress < attack + decay {
                envelope = 1.0 - (1.0 - sustainLevel) * ((progress - attack) / decay)
            } else if progress < releaseStart {
                envelope = sustainLevel
            } else {
                envelope = sustainLevel * (1.0 - (progress - releaseStart) / (1.0 - releaseStart))
            }
            
            // Mix fundamental with harmonics
            let fundamental = sin(2.0 * .pi * frequency * t)
            let harmonic2 = 0.5 * sin(2.0 * .pi * frequency * 2.0 * t)
            let harmonic3 = 0.25 * sin(2.0 * .pi * frequency * 3.0 * t)
            let harmonic5 = 0.1 * sin(2.0 * .pi * frequency * 5.0 * t)
            
            let mixed = (fundamental + harmonic2 + harmonic3 + harmonic5) / 1.85
            let sample = Int16(mixed * envelope * 24000)
            
            audioData.append(contentsOf: withUnsafeBytes(of: sample.littleEndian) { Array($0) })
        }
        
        return audioData
    }
    
    /// Create a temporary WAV file for a song at a given index
    static func createTemporaryAudioFile(forSongIndex index: Int, duration: TimeInterval) -> URL? {
        let frequency = noteFrequencies[index % noteFrequencies.count]
        let audioData = generateTone(frequency: frequency, duration: duration)
        
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("bitsong_\(index).wav")
        
        do {
            try audioData.write(to: fileURL)
            return fileURL
        } catch {
            print("Failed to write temp audio file: \(error)")
            return nil
        }
    }
}
