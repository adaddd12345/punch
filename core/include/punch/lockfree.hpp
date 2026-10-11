// Real-time-safe primitives for crossing between the control (UI) thread and
// the audio IO thread. Nothing here allocates, locks, or makes syscalls on
// the audio side.
#pragma once

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <type_traits>
#include <vector>

namespace punch {

// Single-producer / single-consumer "latest value" mailbox. The writer
// publishes whole snapshots; the reader always sees the most recent complete
// one and never blocks. Used for EQ/effect parameter sets.
template <typename T>
class TripleBuffer {
  static_assert(std::is_trivially_copyable_v<T>, "snapshots are copied by value");

 public:
  explicit TripleBuffer(const T& initial = T{}) {
    for (auto& s : slots_) s = initial;
  }

  // Control thread.
  void write(const T& value) {
    slots_[back_] = value;
    const std::uint8_t prev = middle_.exchange(std::uint8_t(back_ | kDirty), std::memory_order_acq_rel);
    back_ = prev & kIndexMask;
  }

  // Audio thread. Returns true if a new snapshot arrived since the last call.
  bool read(T& out) {
    bool fresh = false;
    if (middle_.load(std::memory_order_relaxed) & kDirty) {
      const std::uint8_t prev = middle_.exchange(front_, std::memory_order_acq_rel);
      front_ = prev & kIndexMask;
      fresh = true;
    }
    out = slots_[front_];
    return fresh;
  }

 private:
  static constexpr std::uint8_t kDirty = 0x4;
  static constexpr std::uint8_t kIndexMask = 0x3;
  T slots_[3];
  std::uint8_t back_ = 0;   // writer-owned
  std::uint8_t front_ = 1;  // reader-owned
  std::atomic<std::uint8_t> middle_{2};
};

// Bounded single-producer / single-consumer FIFO of trivially copyable
// items (audio samples, meter frames). Capacity is rounded up to a power of
// two; storage is allocated once at construction.
template <typename T>
class SpscRing {
  static_assert(std::is_trivially_copyable_v<T>);

 public:
  explicit SpscRing(std::size_t minCapacity) {
    std::size_t cap = 1;
    while (cap < minCapacity + 1) cap <<= 1;
    buf_.resize(cap);
    mask_ = cap - 1;
  }

  std::size_t capacity() const { return mask_; }

  std::size_t availableToRead() const {
    return (head_.load(std::memory_order_acquire) - tail_.load(std::memory_order_relaxed)) & mask_;
  }
  std::size_t availableToWrite() const { return capacity() - availableToRead(); }

  // Producer. Writes up to n items, returns how many were written.
  std::size_t push(const T* src, std::size_t n) {
    const std::size_t head = head_.load(std::memory_order_relaxed);
    const std::size_t tail = tail_.load(std::memory_order_acquire);
    const std::size_t free = mask_ - ((head - tail) & mask_);
    n = n < free ? n : free;
    copyIn(head & mask_, src, n);
    head_.store((head + n) & mask_, std::memory_order_release);
    return n;
  }

  // Consumer. Reads up to n items, returns how many were read.
  std::size_t pop(T* dst, std::size_t n) {
    const std::size_t tail = tail_.load(std::memory_order_relaxed);
    const std::size_t head = head_.load(std::memory_order_acquire);
    const std::size_t avail = (head - tail) & mask_;
    n = n < avail ? n : avail;
    copyOut(tail & mask_, dst, n);
    tail_.store((tail + n) & mask_, std::memory_order_release);
    return n;
  }

 private:
  void copyIn(std::size_t at, const T* src, std::size_t n) {
    const std::size_t first = std::min(n, buf_.size() - at);
    std::memcpy(&buf_[at], src, first * sizeof(T));
    std::memcpy(&buf_[0], src + first, (n - first) * sizeof(T));
  }
  void copyOut(std::size_t at, T* dst, std::size_t n) const {
    const std::size_t first = std::min(n, buf_.size() - at);
    std::memcpy(dst, &buf_[at], first * sizeof(T));
    std::memcpy(dst + first, &buf_[0], (n - first) * sizeof(T));
  }

  std::vector<T> buf_;
  std::size_t mask_ = 0;
  alignas(64) std::atomic<std::size_t> head_{0};
  alignas(64) std::atomic<std::size_t> tail_{0};
};

}  // namespace punch
