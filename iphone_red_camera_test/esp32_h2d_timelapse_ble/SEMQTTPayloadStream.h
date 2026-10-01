#pragma once

#include <Arduino.h>
#include <Stream.h>
#include <cstring>

// PubSubClient can stream a PUBLISH body while retaining only its small MQTT
// header/topic buffer. One fixed DRAM body is shared by primary/fleet clients;
// the main loop already ensures that only one TLS session is pumped at a time.
// Reserving this at boot avoids reallocating 24 KB after a fragmented TLS
// handshake. The existing JSON readers still receive the complete, original
// body, so no printer fields are filtered or silently truncated.
template <size_t Capacity>
class SEMQTTPayloadStream final : public Stream {
 public:
  static_assert(Capacity > 0 && Capacity <= 65535, "MQTT body capacity invalid");

  void reset() {
    length_ = 0;
    overflowed_ = false;
  }

  size_t write(uint8_t value) override {
    if (length_ < Capacity) {
      payload_[length_++] = value;
    } else {
      overflowed_ = true;
    }
    // Drain the entire network packet even when too large; reject it as a
    // whole in the callback and begin cleanly on the next packet.
    return 1;
  }

  size_t write(const uint8_t *data, size_t size) override {
    const size_t available = Capacity - length_;
    const size_t accepted = size < available ? size : available;
    if (accepted != 0) std::memcpy(payload_ + length_, data, accepted);
    length_ += accepted;
    if (accepted != size) overflowed_ = true;
    return size;
  }

  int available() override { return 0; }
  int read() override { return -1; }
  int peek() override { return -1; }
  void flush() override {}

  uint8_t *data() { return payload_; }
  size_t size() const { return length_; }
  bool overflowed() const { return overflowed_; }

 private:
  uint8_t payload_[Capacity];
  size_t length_ = 0;
  bool overflowed_ = false;
};
