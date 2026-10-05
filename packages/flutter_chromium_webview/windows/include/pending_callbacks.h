#ifndef FLUTTER_CHROMIUM_PENDING_CALLBACKS_H_
#define FLUTTER_CHROMIUM_PENDING_CALLBACKS_H_
#include <map>
#include <utility>

// UI-thread only. Ownership is removed before callers invoke a callback so
// synchronous CEF re-entry cannot invalidate an iterator or complete it twice.
template <class Callback>
class PendingCallbacks {
 public:
  int Add(Callback callback) {
    const int id = next_id_++;
    callbacks_.emplace(id, std::move(callback));
    return id;
  }
  Callback Take(int id) {
    auto found = callbacks_.find(id);
    if (found == callbacks_.end()) return {};
    auto callback = std::move(found->second);
    callbacks_.erase(found);
    return callback;
  }
  std::map<int, Callback> Drain() {
    std::map<int, Callback> result;
    result.swap(callbacks_);
    return result;
  }
  void Clear() { callbacks_.clear(); }
 private:
  int next_id_ = 1;
  std::map<int, Callback> callbacks_;
};
#endif
