// RTT 3 selected-field scaling probe. See README.md for measurement limits.
#include <rtt/TaskContext.hpp>
#include <rtt/Port.hpp>
#include <rtt/extras/SlaveActivity.hpp>
#include <rtt/os/main.h>
#include <rtt/rtt-config.h>
#include <rtt/types/CArrayTypeInfo.hpp>
#include <rtt/types/StructTypeInfo.hpp>
#include <rtt/types/TypeInfoRepository.hpp>
#include <boost/serialization/nvp.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <iostream>
#include <limits>
#include <memory>
#include <new>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#if RTT_VERSION_MAJOR < 3
#error This probe requires the RTT 3 cyclic port API.
#endif

// Count requested C++ allocation bytes, excluding malloc metadata and overhead.
// Allocation bookkeeping is enabled only for setup and a separate checked pass.
// Every allocation carries its epoch so destruction outside the pass is safe.
namespace allocations {
enum Kind { scalar, array, aligned_scalar, aligned_array, kind_count };
struct Header { void* allocation; std::size_t bytes; std::uint64_t epoch; };
struct Result {
    std::uint64_t count[kind_count]{};
    std::uint64_t producer_count{};
    std::uint64_t live_bytes{};
    std::uint64_t peak_bytes{};
    std::uint64_t background_count{};
    std::uint64_t background_bytes{};
};
std::atomic<bool> enabled{false};
std::atomic<bool> cyclic_pass{false};
std::atomic<std::uint64_t> epoch{0};
std::atomic<std::uint64_t> counts[kind_count]{};
std::atomic<std::uint64_t> producer_count{0}, live_bytes{0}, peak_bytes{0};
std::atomic<std::uint64_t> background_count{0}, background_bytes{0};
thread_local bool producer = false;
thread_local bool inside_component_cycle = false;
std::atomic_flag bookkeeping_lock = ATOMIC_FLAG_INIT;
struct BookkeepingLock {
    BookkeepingLock() {
        while (bookkeeping_lock.test_and_set(std::memory_order_acquire)) {}
    }
    ~BookkeepingLock() { bookkeeping_lock.clear(std::memory_order_release); }
};

void begin(bool cyclic = false) {
    BookkeepingLock lock;
    enabled.store(false);
    epoch.fetch_add(1);
    cyclic_pass.store(cyclic);
    for (auto& count : counts) count.store(0);
    producer_count.store(0);
    live_bytes.store(0);
    peak_bytes.store(0);
    background_count.store(0);
    background_bytes.store(0);
    enabled.store(true);
}
Result end() {
    BookkeepingLock lock;
    enabled.store(false);
    Result result;
    for (unsigned i = 0; i < kind_count; ++i) result.count[i] = counts[i].load();
    result.producer_count = producer_count.load();
    result.live_bytes = live_bytes.load();
    result.peak_bytes = peak_bytes.load();
    result.background_count = background_count.load();
    result.background_bytes = background_bytes.load();
    return result;
}
void* allocate(std::size_t bytes, std::size_t alignment, Kind kind) {
    alignment = std::max(alignment, alignof(Header));
    if (bytes > std::numeric_limits<std::size_t>::max() - sizeof(Header) - alignment)
        throw std::bad_alloc();
    void* raw = std::malloc(std::max<std::size_t>(bytes, 1) + sizeof(Header) + alignment);
    if (!raw) throw std::bad_alloc();
    const auto start = reinterpret_cast<std::uintptr_t>(raw) + sizeof(Header);
    const auto address = (start + alignment - 1) & ~(alignment - 1);
    auto* header = reinterpret_cast<Header*>(address) - 1;
    *header = {raw, bytes, 0};
    if (enabled.load(std::memory_order_relaxed)) {
        BookkeepingLock lock;
        if (!enabled.load(std::memory_order_relaxed)) return reinterpret_cast<void*>(address);
        if (cyclic_pass.load(std::memory_order_relaxed) && !inside_component_cycle) {
            background_count.fetch_add(1, std::memory_order_relaxed);
            background_bytes.fetch_add(bytes, std::memory_order_relaxed);
            return reinterpret_cast<void*>(address);
        }
        header->epoch = epoch.load(std::memory_order_relaxed);
        counts[kind].fetch_add(1, std::memory_order_relaxed);
        if (producer) producer_count.fetch_add(1, std::memory_order_relaxed);
        const auto live = live_bytes.fetch_add(bytes, std::memory_order_relaxed) + bytes;
        auto peak = peak_bytes.load(std::memory_order_relaxed);
        while (peak < live && !peak_bytes.compare_exchange_weak(peak, live,
                                                              std::memory_order_relaxed)) {}
    }
    return reinterpret_cast<void*>(address);
}
void release(void* value) noexcept {
    if (!value) return;
    const auto* header = reinterpret_cast<Header*>(value) - 1;
    if (header->epoch) {
        BookkeepingLock lock;
        if (header->epoch == epoch.load(std::memory_order_relaxed))
            live_bytes.fetch_sub(header->bytes, std::memory_order_relaxed);
    }
    std::free(header->allocation);
}
}

void* operator new(std::size_t n) { return allocations::allocate(n, alignof(std::max_align_t), allocations::scalar); }
void* operator new[](std::size_t n) { return allocations::allocate(n, alignof(std::max_align_t), allocations::array); }
void* operator new(std::size_t n, std::align_val_t a) { return allocations::allocate(n, static_cast<std::size_t>(a), allocations::aligned_scalar); }
void* operator new[](std::size_t n, std::align_val_t a) { return allocations::allocate(n, static_cast<std::size_t>(a), allocations::aligned_array); }
void* operator new(std::size_t n, const std::nothrow_t&) noexcept { try { return ::operator new(n); } catch (...) { return nullptr; } }
void* operator new[](std::size_t n, const std::nothrow_t&) noexcept { try { return ::operator new[](n); } catch (...) { return nullptr; } }
void* operator new(std::size_t n, std::align_val_t a, const std::nothrow_t&) noexcept { try { return ::operator new(n, a); } catch (...) { return nullptr; } }
void* operator new[](std::size_t n, std::align_val_t a, const std::nothrow_t&) noexcept { try { return ::operator new[](n, a); } catch (...) { return nullptr; } }
void operator delete(void* p) noexcept { allocations::release(p); }
void operator delete[](void* p) noexcept { allocations::release(p); }
void operator delete(void* p, std::size_t) noexcept { allocations::release(p); }
void operator delete[](void* p, std::size_t) noexcept { allocations::release(p); }
void operator delete(void* p, std::align_val_t) noexcept { allocations::release(p); }
void operator delete[](void* p, std::align_val_t) noexcept { allocations::release(p); }
void operator delete(void* p, std::size_t, std::align_val_t) noexcept { allocations::release(p); }
void operator delete[](void* p, std::size_t, std::align_val_t) noexcept { allocations::release(p); }
void operator delete(void* p, const std::nothrow_t&) noexcept { allocations::release(p); }
void operator delete[](void* p, const std::nothrow_t&) noexcept { allocations::release(p); }
void operator delete(void* p, std::align_val_t, const std::nothrow_t&) noexcept { allocations::release(p); }
void operator delete[](void* p, std::align_val_t, const std::nothrow_t&) noexcept { allocations::release(p); }

namespace {
using Clock = std::chrono::steady_clock;
constexpr double generation_stride = 2048.0;

template<std::size_t N> struct Frame {
    double values[N]{};
    template<class Archive> void serialize(Archive& archive, unsigned int) {
        archive & boost::serialization::make_nvp("values", boost::serialization::make_array(values, N));
    }
};
template<std::size_t N> void registerFrame() {
    RTT::types::Types()->addType(new RTT::types::StructTypeInfo<Frame<N>, false>(
        "scaling_frame_" + std::to_string(N)));
}
void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
void execute(RTT::TaskContext& component) {
    struct CycleScope {
        bool previous = allocations::inside_component_cycle;
        CycleScope() { allocations::inside_component_cycle = true; }
        ~CycleScope() { allocations::inside_component_cycle = previous; }
    } scope;
    require(component.getActivity()->execute(), "activity execution failed");
}

template<std::size_t N> class Source : public RTT::TaskContext {
public:
    RTT::OutputPort<Frame<N>> output{"output"};
    std::uint64_t generation{};
    Source() : RTT::TaskContext("scaling_source") {
        setActivity(new RTT::extras::SlaveActivity(0.001));
        addPort(output);
    }
    void updateHook() override {
        const double base = static_cast<double>(++generation) * generation_stride;
        for (std::size_t i = 0; i < N; ++i) output.data().values[i] = base + i;
    }
};

struct Checks {
    std::uint64_t coherence_failures{}, selector_failures{}, status_failures{};
    std::uint64_t retention_failures{}, latest_generation_failures{}, new_samples{}, old_samples{}, no_samples{};
};
class Consumer : public RTT::TaskContext {
public:
    bool checking{true};
    int expected_status{RTT::NoData}; // -1 accepts any status in concurrent pass.
    std::uint64_t expected_generation{}; // Nonzero only after producer quiescence.
    Checks checks;
    double checksum{};
    Consumer(unsigned id, unsigned count, unsigned source_fields, unsigned offset)
      : RTT::TaskContext("scaling_consumer_" + std::to_string(id)),
        count_(count), source_fields_(source_fields), offset_(offset), previous_(count) {
        setActivity(new RTT::extras::SlaveActivity(0.001));
    }
    virtual void connect(RTT::base::OutputPortInterface& source) = 0;
    void updateHook() override {
        if (!checking) {
            checksum = value(0) + value(count_ - 1);
            return;
        }
        double first_generation = -1;
        bool coherent = true;
        for (unsigned i = 0; i < count_; ++i) {
            const auto state = status(i);
            const double sample = value(i);
            const double field = static_cast<double>((offset_ + i) % source_fields_);
            if (expected_generation && sample != expected_generation * generation_stride + field)
                ++checks.latest_generation_failures;
            if (expected_status >= 0 && state != expected_status) ++checks.status_failures;
            if (state == RTT::NoData) {
                ++checks.no_samples;
                if (sample != 0) ++checks.retention_failures;
            } else {
                if (state == RTT::NewData) ++checks.new_samples;
                if (state == RTT::OldData) {
                    ++checks.old_samples;
                    if (sample != previous_[i]) ++checks.retention_failures;
                }
                const double generation = (sample - field) / generation_stride;
                if (generation < 1 || generation != std::floor(generation)) ++checks.selector_failures;
                if (first_generation < 0) first_generation = generation;
                if (generation != first_generation) coherent = false;
            }
            previous_[i] = sample;
        }
        if (!coherent) ++checks.coherence_failures;
    }
protected:
    unsigned count_, source_fields_, offset_;
    virtual double value(unsigned index) const = 0;
    virtual RTT::FlowStatus status(unsigned index) const = 0;
    std::string sourceSelector(unsigned i) const {
        return "values[" + std::to_string((offset_ + i) % source_fields_) + "]";
    }
private:
    std::vector<double> previous_;
};

template<std::size_t N> class GroupedConsumer : public Consumer {
    RTT::InputPort<Frame<N>> input_{"input"};
public:
    GroupedConsumer(unsigned id, unsigned source_fields, unsigned offset)
      : Consumer(id, N, source_fields, offset) { addPort(input_); }
    void connect(RTT::base::OutputPortInterface& source) override {
        for (unsigned i = 0; i < N; ++i)
            require(RTT::connectMembers(source, sourceSelector(i), input_,
                                       "values[" + std::to_string(i) + "]"), "grouped mapping failed");
    }
    double value(unsigned index) const override { return input_.data().values[index]; }
    RTT::FlowStatus status(unsigned) const override { return input_.status(); }
};
class ScalarConsumer : public Consumer {
    std::vector<std::unique_ptr<RTT::InputPort<double>>> inputs_;
public:
    ScalarConsumer(unsigned id, unsigned count, unsigned source_fields, unsigned offset)
      : Consumer(id, count, source_fields, offset) {
        inputs_.reserve(count);
        for (unsigned i = 0; i < count; ++i) {
            inputs_.emplace_back(new RTT::InputPort<double>("input_" + std::to_string(i)));
            addPort(*inputs_.back());
        }
    }
    void connect(RTT::base::OutputPortInterface& source) override {
        for (unsigned i = 0; i < count_; ++i)
            require(RTT::connectMembers(source, sourceSelector(i), *inputs_[i], ""), "scalar mapping failed");
    }
    double value(unsigned index) const override { return inputs_[index]->data(); }
    RTT::FlowStatus status(unsigned index) const override { return inputs_[index]->status(); }
};
std::unique_ptr<Consumer> consumer(unsigned id, unsigned count, unsigned source_fields,
                                   unsigned offset, bool scalar) {
    if (scalar) return std::make_unique<ScalarConsumer>(id, count, source_fields, offset);
    switch (count) {
#define GROUPED_CASE(N) case N: return std::make_unique<GroupedConsumer<N>>(id, source_fields, offset)
    GROUPED_CASE(8); GROUPED_CASE(32); GROUPED_CASE(128); GROUPED_CASE(512); GROUPED_CASE(2048);
#undef GROUPED_CASE
    default: throw std::runtime_error("unsupported grouped frame size");
    }
}

// Explicit pause acknowledgement keeps setup, checks, and allocation epochs
// outside any in-flight producer cycle. Thread creation is never timed/counted.
class Producer {
    std::atomic<bool> run_{false}, paused_{false}, done_{false};
    std::thread thread_;
public:
    std::atomic<std::uint64_t> cycles{0};
    explicit Producer(RTT::TaskContext& source) : thread_([&, this] {
        allocations::producer = true;
        while (!done_.load()) {
            if (!run_.load()) { paused_.store(true); std::this_thread::yield(); continue; }
            paused_.store(false);
            execute(source);
            cycles.fetch_add(1, std::memory_order_relaxed);
        }
    }) { while (!paused_.load()) std::this_thread::yield(); }
    void resume() { run_.store(true); while (paused_.load()) std::this_thread::yield(); }
    void pause() { run_.store(false); while (!paused_.load()) std::this_thread::yield(); }
    ~Producer() { done_.store(true); thread_.join(); }
};

struct Options {
    unsigned iterations{2000}, check_iterations{128}, warmup{200};
    unsigned mappings{}, source_bytes{};
    unsigned period_us{};
    std::string layout, mode;
    bool require_coherence{false};
};
struct Distribution {
    double p50{}, p95{}, p99{}, maximum{};
};
Distribution distribution(std::vector<double>& samples) {
    std::sort(samples.begin(), samples.end());
    auto percentile = [&](double fraction) {
        return samples[static_cast<std::size_t>(std::ceil(fraction * samples.size())) - 1];
    };
    return {percentile(.50), percentile(.95), percentile(.99), samples.back()};
}
void printDistribution(const Distribution& value) {
    std::cout << ',' << value.p50 << ',' << value.p95 << ',' << value.p99
              << ',' << value.maximum << ',' << value.p99 - value.p50;
}

template<std::size_t SourceFields>
bool scenario(unsigned mappings, const std::string& layout, bool concurrent, const Options& options) {
    const unsigned consumer_count = layout == "grouped16" || layout == "scalar16" ? 16 : 1;
    const bool scalar = layout == "scalar" || layout == "scalar16";
    const unsigned fields_per_consumer = mappings / consumer_count;
    const auto setup_begin = Clock::now();
    allocations::begin();
    auto source = std::make_unique<Source<SourceFields>>();
    std::vector<std::unique_ptr<Consumer>> consumers;
    consumers.reserve(consumer_count);
    for (unsigned id = 0; id < consumer_count; ++id) {
        consumers.push_back(consumer(id, fields_per_consumer, SourceFields,
                                     id * fields_per_consumer, scalar));
        consumers.back()->connect(source->output);
    }
    require(source->start(), "source start failed");
    for (auto& sink : consumers) require(sink->start(), "consumer start failed");
    const auto setup_allocations = allocations::end();
    const double setup_ms = std::chrono::duration<double, std::milli>(Clock::now() - setup_begin).count();

    // Baseline semantics: no publication, first publication, retained old value.
    for (auto& sink : consumers) execute(*sink);
    execute(*source);
    for (auto& sink : consumers) { sink->expected_status = RTT::NewData; execute(*sink); }
    for (auto& sink : consumers) { sink->expected_status = RTT::OldData; execute(*sink); }

    std::unique_ptr<Producer> producer;
    if (concurrent) producer = std::make_unique<Producer>(*source);
    auto sweep = [&] {
        if (!concurrent) execute(*source);
        for (auto& sink : consumers) execute(*sink);
    };
    for (auto& sink : consumers) sink->expected_status = concurrent ? -1 : RTT::NewData;
    // An intentionally separate checked pass counts C++ allocations during
    // component execution on both producer and consumer threads. Unrelated RTT
    // background threads (including log draining) are reported separately.
    // No clocks, sample buffers, or printing inside this pass.
    const auto checked_producer_before = producer ? producer->cycles.load() : source->generation;
    allocations::begin(true);
    if (producer) producer->resume();
    for (unsigned i = 0; i < options.check_iterations; ++i) sweep();
    if (producer) producer->pause();
    const auto cyclic_allocations = allocations::end();
    const auto checked_producer_cycles =
        (producer ? producer->cycles.load() : source->generation) - checked_producer_before;

    // Check OldData retention after concurrent producer has quiesced.
    for (auto& sink : consumers) {
        sink->expected_status = -1;
        sink->expected_generation = source->generation;
        execute(*sink);
    }
    for (auto& sink : consumers) { sink->expected_status = RTT::OldData; execute(*sink); }
    Checks checks;
    for (auto& sink : consumers) {
        const auto& value = sink->checks;
        checks.coherence_failures += value.coherence_failures;
        checks.selector_failures += value.selector_failures;
        checks.status_failures += value.status_failures;
        checks.retention_failures += value.retention_failures;
        checks.latest_generation_failures += value.latest_generation_failures;
        checks.new_samples += value.new_samples;
        checks.old_samples += value.old_samples;
        checks.no_samples += value.no_samples;
        sink->checking = false;
    }

    std::vector<double> consumer_samples(options.iterations * consumer_count);
    std::vector<double> sweep_samples(options.iterations);
    std::vector<double> round_samples(options.iterations);
    std::vector<double> wake_lateness_samples(options.period_us ? options.iterations : 0);
    std::uint64_t deadline_misses = 0;
    if (producer) producer->resume();
    for (unsigned i = 0; i < options.warmup; ++i) sweep();
    const auto producer_before = producer ? producer->cycles.load() : source->generation;
    const auto period = std::chrono::microseconds(options.period_us);
    auto release = Clock::now() + period;
    for (unsigned i = 0; i < options.iterations; ++i) {
        if (options.period_us) std::this_thread::sleep_until(release);
        const auto round_begin = Clock::now();
        if (options.period_us) wake_lateness_samples[i] = std::max(0.0,
            std::chrono::duration<double, std::nano>(round_begin - release).count());
        if (!concurrent) execute(*source);
        const auto sweep_begin = Clock::now();
        for (unsigned id = 0; id < consumer_count; ++id) {
            const auto before = Clock::now();
            execute(*consumers[id]);
            const auto after = Clock::now();
            consumer_samples[i * consumer_count + id] =
                std::chrono::duration<double, std::nano>(after - before).count();
        }
        sweep_samples[i] = std::chrono::duration<double, std::nano>(Clock::now() - sweep_begin).count();
        const auto round_end = Clock::now();
        round_samples[i] = std::chrono::duration<double, std::nano>(round_end - round_begin).count();
        if (options.period_us) {
            if (round_end > release + period) ++deadline_misses;
            release += period;
        }
    }
    if (producer) producer->pause();
    const auto producer_cycles = (producer ? producer->cycles.load() : source->generation) - producer_before;
    producer.reset();
    for (auto& sink : consumers) sink->stop();
    source->stop();
    const auto cycle_distribution = distribution(consumer_samples);
    const auto sweep_distribution = distribution(sweep_samples);
    const auto round_distribution = distribution(round_samples);
    const auto wake_distribution = options.period_us ? distribution(wake_lateness_samples) : Distribution{};
    std::cout << SourceFields * sizeof(double) << ',' << mappings << ',' << layout
              << ',' << consumer_count << ',' << (scalar ? mappings : consumer_count)
              << ',' << (concurrent ? "concurrent" : "sequential") << ',' << options.iterations
              << ',' << consumer_samples.size() << ',' << options.check_iterations
              << ',' << producer_cycles << ',' << checked_producer_cycles << ',' << options.period_us << ',' << setup_ms
              << ',' << setup_allocations.live_bytes << ',' << setup_allocations.peak_bytes;
    printDistribution(cycle_distribution);
    printDistribution(sweep_distribution);
    printDistribution(round_distribution);
    std::cout << ',' << wake_distribution.p50 << ',' << wake_distribution.p99
              << ',' << wake_distribution.maximum << ',' << deadline_misses;
    for (auto count : cyclic_allocations.count) std::cout << ',' << count;
    std::cout << ',' << cyclic_allocations.producer_count << ',' << cyclic_allocations.peak_bytes
              << ',' << cyclic_allocations.background_count << ',' << cyclic_allocations.background_bytes
              << ',' << checks.coherence_failures << ',' << checks.selector_failures
              << ',' << checks.status_failures << ',' << checks.retention_failures
              << ',' << checks.latest_generation_failures
              << ',' << checks.new_samples << ',' << checks.old_samples << ',' << checks.no_samples << '\n';
    std::cout.flush();
    const bool no_allocations = std::all_of(std::begin(cyclic_allocations.count), std::end(cyclic_allocations.count),
                                          [](auto count) { return count == 0; });
    return checked_producer_cycles > 0 && no_allocations && checks.selector_failures == 0 && checks.status_failures == 0
        && checks.retention_failures == 0 && checks.latest_generation_failures == 0
        && (!options.require_coherence || checks.coherence_failures == 0);
}

unsigned number(const std::string& text) {
    std::size_t parsed = 0;
    const auto value = std::stoul(text, &parsed);
    require(parsed == text.size() && value > 0 && value <= 1000000, "numeric argument out of range");
    return static_cast<unsigned>(value);
}
Options parseOptions(int argc, char** argv) {
    Options options;
    for (int i = 1; i < argc; ++i) {
        const std::string name = argv[i];
        if (name == "--require-coherence") { options.require_coherence = true; continue; }
        require(i + 1 < argc, "missing argument value");
        const std::string value = argv[++i];
        if (name == "--iterations") options.iterations = number(value);
        else if (name == "--check-iterations") options.check_iterations = number(value);
        else if (name == "--warmup") options.warmup = number(value);
        else if (name == "--mappings") options.mappings = number(value);
        else if (name == "--source-bytes") options.source_bytes = number(value);
        else if (name == "--period-us") options.period_us = value == "0" ? 0 : number(value);
        else if (name == "--layout") options.layout = value;
        else if (name == "--mode") options.mode = value;
        else throw std::runtime_error("unknown argument: " + name);
    }
    require(options.mappings == 0 || options.mappings == 128 || options.mappings == 512 || options.mappings == 2048,
            "mappings must be 128, 512 or 2048");
    require(options.source_bytes == 0 || options.source_bytes == 512 || options.source_bytes == 8192,
            "source bytes must be 512 or 8192");
    require(options.layout.empty() || options.layout == "grouped" || options.layout == "scalar"
                || options.layout == "grouped16" || options.layout == "scalar16", "invalid layout");
    require(options.mode.empty() || options.mode == "sequential" || options.mode == "concurrent", "invalid mode");
    if (options.period_us) {
        require(options.mode != "concurrent", "periodic observation requires sequential producer mode");
        options.mode = "sequential";
    }
    return options;
}
}

int ORO_main(int argc, char** argv) {
    try {
        const Options options = parseOptions(argc, argv);
        RTT::types::Types()->addType(new RTT::types::CArrayTypeInfo<RTT::types::carray<double>>("scaling_double_array"));
        registerFrame<8>(); registerFrame<32>(); registerFrame<64>(); registerFrame<128>();
        registerFrame<512>(); registerFrame<1024>(); registerFrame<2048>();
        std::cout << "source_bytes,mappings,layout,consumers,input_ports,producer_mode,iterations,consumer_cycle_samples,check_iterations,timing_producer_cycles,checked_producer_cycles,period_us,setup_ms,setup_cpp_live_bytes,setup_cpp_peak_bytes"
                     ",consumer_p50_ns,consumer_p95_ns,consumer_p99_ns,consumer_max_ns,consumer_p99_minus_p50_ns"
                     ",sweep_p50_ns,sweep_p95_ns,sweep_p99_ns,sweep_max_ns,sweep_p99_minus_p50_ns"
                     ",round_p50_ns,round_p95_ns,round_p99_ns,round_max_ns,round_p99_minus_p50_ns"
                     ",wake_lateness_p50_ns,wake_lateness_p99_ns,wake_lateness_max_ns,deadline_misses"
                     ",cyclic_new,cyclic_new_array,cyclic_aligned_new,cyclic_aligned_new_array,cyclic_producer_allocations,cyclic_cpp_peak_bytes,background_cpp_allocations,background_cpp_requested_bytes"
                     ",coherence_failures,selector_failures,status_failures,retention_failures,latest_generation_failures,new_field_samples,old_field_samples,no_field_samples\n";
        bool success = true;
        for (unsigned bytes : {512u, 8192u}) for (unsigned mappings : {128u, 512u, 2048u})
        for (const std::string layout : {"grouped", "scalar", "grouped16", "scalar16"})
        for (bool concurrent : {false, true}) {
            if (options.source_bytes && bytes != options.source_bytes) continue;
            if (options.mappings && mappings != options.mappings) continue;
            if (!options.layout.empty() && layout != options.layout) continue;
            if (!options.mode.empty() && options.mode != (concurrent ? "concurrent" : "sequential")) continue;
            success = (bytes == 512 ? scenario<64>(mappings, layout, concurrent, options)
                                    : scenario<1024>(mappings, layout, concurrent, options)) && success;
        }
        return success ? 0 : 1;
    } catch (const std::exception& error) {
        allocations::enabled.store(false);
        std::cerr << "scaling benchmark failed: " << error.what() << '\n';
        return 2;
    }
}
