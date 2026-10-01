#pragma once

#include "SEMQTTPayloadStream.h"

// Exercises the actual shared receiver before any Wi-Fi/BLE session exists.
// No additional large buffer is allocated and no persisted data is touched.
template <size_t Capacity>
bool verifyMQTTPayloadStream(SEMQTTPayloadStream<Capacity> &stream) {
  stream.reset();
  if (stream.size() != 0 || stream.overflowed() || stream.available() != 0 ||
      stream.read() != -1 || stream.peek() != -1) return false;

  for (size_t i = 0; i < Capacity; ++i) {
    if (stream.write(static_cast<uint8_t>(i)) != 1) return false;
  }
  if (stream.size() != Capacity || stream.overflowed()) return false;
  for (size_t i = 0; i < Capacity; ++i) {
    if (stream.data()[i] != static_cast<uint8_t>(i)) return false;
  }
  stream.write(static_cast<uint8_t>(0xAA));
  if (!stream.overflowed() || stream.size() != Capacity) return false;

  stream.reset();
  const uint8_t body[] = "{\"print\":{\"gcode_state\":\"RUNNING\",\"mc_percent\":42}}";
  const size_t length = sizeof(body) - 1;
  static_assert(Capacity > length, "Self-test JSON exceeds body capacity");
  if (stream.write(body, length) != length || stream.size() != length ||
      stream.overflowed() || std::memcmp(stream.data(), body, length) != 0) {
    return false;
  }

  stream.reset();
  const uint8_t chunk[] = {0x41, 0x42, 0x43, 0x44};
  for (size_t i = 0; i < Capacity; i += sizeof(chunk)) {
    stream.write(chunk, sizeof(chunk));
  }
  stream.write(chunk, sizeof(chunk));
  if (!stream.overflowed() || stream.size() != Capacity ||
      stream.data()[0] != 0x41 ||
      stream.data()[Capacity - 1] != chunk[(Capacity - 1) % sizeof(chunk)]) {
    return false;
  }
  stream.reset();
  return stream.size() == 0 && !stream.overflowed();
}
