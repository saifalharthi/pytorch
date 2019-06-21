#pragma once

#include <ATen/Parallel.h>
#include <c10/core/thread_pool.h>

#if USE_EIGEN_THREADPOOL
#include "unsupported/Eigen/CXX11/ThreadPool"
#include "Eigen/src/Core/util/Macros.h"
#endif

namespace at {

#if USE_EIGEN_THREADPOOL

struct PTThreadPoolEnvironment {
  struct Task {
    std::function<void()> f;
  };

  class EnvThread {
   public:
    explicit EnvThread(std::function<void()> f) : thr_(std::move(f)) {}
    ~EnvThread() { thr_.join(); }
    void OnCancel() { }

    private:
    std::thread thr_;
  };

  EnvThread* CreateThread(std::function<void()> func) {
    return new EnvThread([func]() {
      c10::setThreadName("PTThreadPool-Eigen");
      at::init_num_threads();
      func();
    });
  }

  Task CreateTask(std::function<void()> func) {
    return Task { std::move(func) };
  }

   void ExecuteTask(Task task) {
    task.f();
  }
};

struct CAFFE2_API PTThreadPool
#if EIGEN_VERSION_AT_LEAST(3, 3, 90)
  : Eigen::ThreadPoolTempl<PTThreadPoolEnvironment>, TaskThreadPoolBase {
#else
  : Eigen::NonBlockingThreadPoolTempl<PTThreadPoolEnvironment>, TaskThreadPoolBase {
#endif

  explicit PTThreadPool(
    int pool_size,
    int /* unused */ = -1) :
#if EIGEN_VERSION_AT_LEAST(3, 3, 90)
    Eigen::ThreadPoolTempl<PTThreadPoolEnvironment>(
        pool_size < 0 ? defaultNumThreads() : pool_size, false) {}
#else
    Eigen::NonBlockingThreadPoolTempl<PTThreadPoolEnvironment>(
        pool_size < 0 ? defaultNumThreads() : pool_size) {}
#endif

  void run(const std::function<void()>& func) override {
    Schedule(func);
  }

  size_t size() const override {
    return NumThreads();
  }

  size_t numAvailable() const override {
    // treating all threads as available
    return NumThreads();
  }

  bool inThreadPool() const override {
    return CurrentThreadId() != -1;
  }
};

#else

class CAFFE2_API PTThreadPool : public c10::ThreadPool {
 public:
  explicit PTThreadPool(
      int pool_size,
      int numa_node_id = -1)
    : c10::ThreadPool(pool_size, numa_node_id, [](){
        c10::setThreadName("PTThreadPool");
        at::init_num_threads();
      }) {}
};

#endif

} // namespace at
