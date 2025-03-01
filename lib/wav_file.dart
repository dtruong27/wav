// Copyright 2022 The wav authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:typed_data';

import 'bytes_reader.dart';
import 'bytes_writer.dart';
import 'util.dart';
import 'wav_format.dart';
import 'wav_no_io.dart' if (dart.library.io) 'wav_io.dart';

/// A WAV file, containing audio, and metadata.
class Wav {
  /// Audio data, as a list of channels.
  ///
  /// In the typical stereo case the channels will be `[left, right]`.
  ///
  /// The audio samples are in the range `[-1, 1]`.
  final List<Float64List> channels;

  /// The sampling frequency of the audio data, in Hz.
  final int samplesPerSecond;

  /// The format of the WAV file.
  final WavFormat format;

  /// The sub-format in case format is extensible
  final WavFormat? subFormat;

  /// The effective bit depth in case format is extensible.
  ///
  /// Specifies the actual number of valid bits in each sample,
  /// the remaining bits are padding.
  final int? validBitsPerSample;

  /// In case format is extensible, a channel mask specifies
  /// how each audio channel should be interpreted.
  /// Example: Bit 0 -> Front left, Bit 1 -> Front right,
  /// Bit 2 -> Front center.
  final int channelMask;

  /// Constructs a Wav directly from audio data.
  Wav(
    this.channels,
    this.samplesPerSecond, [
    this.format = WavFormat.pcm16bit,
    this.subFormat,
    this.validBitsPerSample,
    this.channelMask = 0,
  ]);

  /// Read a Wav from a file.
  ///
  /// Convenience wrapper around [read]. See that method for details.
  static Future<Wav> readFile(String filename) async {
    return read(await internalReadFile(filename));
  }

  /// Returns the duration of the Wav in seconds.
  double get duration =>
      channels.isEmpty ? 0 : channels[0].length / samplesPerSecond;

  static const _kFormatSize = 16;
  static const _kFactSize = 4;
  static const _kFileSizeWithoutData = 36;
  static const _kFloatFmtExtraSize = 12;
  static const _kPCM = 1;
  static const _kFloat = 3;
  static const _kWavExtensible = 0xFFFE;
  static const _kExCbSize = 22;
  static const _kStrRiff = 'RIFF';
  static const _kStrWave = 'WAVE';
  static const _kStrFmt = 'fmt ';
  static const _kStrData = 'data';
  static const _kStrFact = 'fact';

  static WavFormat _getFormat(int formatCode, int bitsPerSample) {
    if (formatCode == _kPCM) {
      if (bitsPerSample == 8) return WavFormat.pcm8bit;
      if (bitsPerSample == 16) return WavFormat.pcm16bit;
      if (bitsPerSample == 24) return WavFormat.pcm24bit;
      if (bitsPerSample == 32) return WavFormat.pcm32bit;
    } else if (formatCode == _kFloat) {
      if (bitsPerSample == 32) return WavFormat.float32;
      if (bitsPerSample == 64) return WavFormat.float64;
    } else if (formatCode == _kWavExtensible) {
      return WavFormat.extensible;
    }
    throw FormatException('Unsupported format: $formatCode, $bitsPerSample');
  }

  /// Read a Wav from a byte buffer.
  ///
  /// Not all formats are supported. See [WavFormat] for a canonical list.
  /// Unrecognized metadata will be ignored.
  static Wav read(Uint8List bytes) {
    // Utils for reading.
    var byteReader = BytesReader(bytes)
      ..assertString(_kStrRiff)
      ..readUint32() // File size.
      ..assertString(_kStrWave)
      ..findChunk(_kStrFmt);

    final fmtSize = roundUpToEven(byteReader.readUint32());
    final formatCode = byteReader.readUint16();
    final numChannels = byteReader.readUint16();
    final samplesPerSecond = byteReader.readUint32();
    byteReader.readUint32(); // Bytes per second.
    final bytesPerSampleAllChannels = byteReader.readUint16();
    final bitsPerSample = byteReader.readUint16();

    int validBitsPerSample = bitsPerSample;
    int channelMask = 0;
    WavFormat? subFormat;

    if (formatCode == _kWavExtensible) {
      // Size of the extension
      // 22 for wav extensible, 0 otherwise
      final cbSize = byteReader.readUint16();

      if (cbSize == _kExCbSize) {
        validBitsPerSample = byteReader.readUint16();
        channelMask = byteReader.readUint32();

        // The rest 16 bytes are the GUID including the data format code.
        // The first two bytes are the data format code.
        final subFormatCode = byteReader.readUint16();
        subFormat = _getFormat(subFormatCode, bitsPerSample);

        byteReader.skip(14);
      }
    } else if (fmtSize > _kFormatSize) {
      byteReader.skip(fmtSize - _kFormatSize);
    }

    byteReader.findChunk(_kStrData);
    final dataSize = byteReader.readUint32();
    final numSamples = dataSize ~/ bytesPerSampleAllChannels;

    final channels = <Float64List>[];
    for (int i = 0; i < numChannels; ++i) {
      channels.add(Float64List(numSamples));
    }

    final format = _getFormat(formatCode, bitsPerSample);

    // Read samples.
    final readSample = byteReader.getSampleReader(subFormat ?? format);
    for (int i = 0; i < numSamples; ++i) {
      for (int j = 0; j < numChannels; ++j) {
        channels[j][i] = readSample();
      }
    }

    return Wav(
      channels,
      samplesPerSecond,
      format,
      subFormat,
      validBitsPerSample,
      channelMask,
    );
  }

  /// Mix the audio channels down to mono.
  Float64List toMono() {
    if (channels.isEmpty) return Float64List(0);
    final mono = Float64List(channels[0].length);
    for (int i = 0; i < mono.length; ++i) {
      for (int j = 0; j < channels.length; ++j) {
        mono[i] += channels[j][i];
      }
      mono[i] /= channels.length;
    }
    return mono;
  }

  /// Write the Wav to a file.
  ///
  /// Convenience wrapper around [write]. See that method for details.
  Future<void> writeFile(String filename) async {
    await internalWriteFile(filename, write());
  }

  /// Write the Wav to a byte buffer.
  ///
  /// If your audio samples exceed `[-1, 1]`, they will be clamped (unless
  /// you're using float32 or float64 format). If your channels are different
  /// lengths, they will be padded with zeros.
  Uint8List write() {
    // Calculate sizes etc.
    final sampleFormat = subFormat ?? format;
    final isExtensible = format == WavFormat.extensible;
    final bitsPerSample = sampleFormat.bitsPerSample;
    final isFloat =
        sampleFormat == WavFormat.float32 || sampleFormat == WavFormat.float64;
    final bytesPerSample = bitsPerSample ~/ 8;
    final numChannels = channels.length;
    int numSamples = 0;
    for (final channel in channels) {
      if (channel.length > numSamples) numSamples = channel.length;
    }
    final bytesPerSampleAllChannels = bytesPerSample * numChannels;
    final dataSize = numSamples * bytesPerSampleAllChannels;
    final bytesPerSecond = bytesPerSampleAllChannels * samplesPerSecond;
    var fileSize = _kFileSizeWithoutData + roundUpToEven(dataSize);
    if (isFloat) {
      fileSize += _kFloatFmtExtraSize;
    }

    // Write metadata.
    final bytes = BytesWriter()
      ..writeString(_kStrRiff)
      ..writeUint32(fileSize)
      ..writeString(_kStrWave)
      ..writeString(_kStrFmt)
      ..writeUint32(
        _kFormatSize + (isExtensible ? 24 : 0),
      )
      ..writeUint16(
        isExtensible
            ? _kWavExtensible
            : isFloat
                ? _kFloat
                : _kPCM,
      )
      ..writeUint16(numChannels)
      ..writeUint32(samplesPerSecond)
      ..writeUint32(bytesPerSecond)
      ..writeUint16(bytesPerSampleAllChannels)
      ..writeUint16(bitsPerSample);

    if (isExtensible) {
      // Size of the extension
      bytes.writeUint16(isExtensible ? _kExCbSize : 0);
    }

    if (isExtensible) {
      bytes
        ..writeUint16(validBitsPerSample ?? bitsPerSample)
        ..writeUint32(channelMask)
        ..writeUint16(isFloat ? _kFloat : _kPCM)
        ..writeUint8(0x00)
        ..writeUint8(0x00)
        ..writeUint8(0x00)
        ..writeUint8(0x00)
        ..writeUint8(0x10)
        ..writeUint8(0x00)
        ..writeUint8(0x80)
        ..writeUint8(0x00)
        ..writeUint8(0x00)
        ..writeUint8(0xAA)
        ..writeUint8(0x00)
        ..writeUint8(0x38)
        ..writeUint8(0x9B)
        ..writeUint8(0x71);
    }

    if (isFloat) {
      bytes
        ..writeString(_kStrFact)
        ..writeUint32(_kFactSize)
        ..writeUint32(numSamples);
    }

    bytes
      ..writeString(_kStrData)
      ..writeUint32(dataSize);

    // Write samples.
    final writeSample = bytes.getSampleWriter(sampleFormat);
    for (int i = 0; i < numSamples; ++i) {
      for (int j = 0; j < numChannels; ++j) {
        double sample = i < channels[j].length ? channels[j][i] : 0;
        writeSample(sample);
      }
    }
    if (dataSize % 2 != 0) {
      bytes.writeUint8(0);
    }
    return bytes.takeBytes();
  }
}
