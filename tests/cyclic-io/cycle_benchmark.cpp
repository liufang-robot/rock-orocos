// Build twice against the unchanged RTT 2 baseline and feature RTT 3 prefix.
#include <rtt/TaskContext.hpp>
#include <rtt/os/main.h>
#include <rtt/Port.hpp>
#include <rtt/extras/SlaveActivity.hpp>
#include <rtt/Service.hpp>
#include <rtt/rtt-config.h>
#include <rtt/types/StructTypeInfo.hpp>
#include <rtt/types/CArrayTypeInfo.hpp>
#include <rtt/types/TypeInfoRepository.hpp>
#include <boost/serialization/nvp.hpp>
#include <algorithm>
#include <chrono>
#include <iostream>
#include <vector>
#include <thread>
#include <atomic>

struct Frame {
    double values[64]{};
    template<class Archive> void serialize(Archive& archive, unsigned int) {
        archive & boost::serialization::make_nvp("values", boost::serialization::make_array(values, 64));
    }
};
using namespace RTT;

class Source : public TaskContext {
public:
#if RTT_VERSION_MAJOR >= 3
    OutputPort<Frame> output{"output"};
#else
    OutputPort<Frame> output{"output", true};
    Frame image{};
#endif
    unsigned value{};
    explicit Source(unsigned depth) : TaskContext("source") {
        setActivity(new extras::SlaveActivity(0.001));
        auto service = provides();
        for (unsigned i = 0; i < depth; ++i) service = service->provides("nested");
        service->addPort(output);
    }
    void updateHook() override {
#if RTT_VERSION_MAJOR >= 3
        auto& image = output.data();
#endif
        ++value;
        for (auto& field : image.values) field = value;
#if RTT_VERSION_MAJOR < 3
        output.write(image);
#endif
    }
};
class Sink : public TaskContext {
public:
    InputPort<Frame> input{"input"};
#if RTT_VERSION_MAJOR < 3
    Frame image{};
#endif
    unsigned fields;
    double result{};
    bool coherent{true};
    Sink(unsigned count, unsigned depth) : TaskContext("sink"), fields(count) {
        setActivity(new extras::SlaveActivity(0.001));
        auto service = provides();
        for (unsigned i = 0; i < depth; ++i) service = service->provides("nested");
        service->addPort(input);
    }
    void updateHook() override {
#if RTT_VERSION_MAJOR >= 3
        const auto& image = input.data();
#else
        input.read(image);
#endif
        result = 0;
        for (unsigned i = 0; i < fields; ++i) {
            result += image.values[i];
            coherent = coherent && image.values[i] == image.values[0];
        }
    }
};
int ORO_main(int, char**) {
    types::Types()->addType(new types::CArrayTypeInfo<types::carray<double>>("bench_array"));
    types::Types()->addType(new types::StructTypeInfo<Frame, false>("bench_frame"));
    std::cout << "version,mode,fields,service_depth,concurrent,p50_ns,p95_ns,p99_ns,max_ns\n";
    for (bool concurrent : {false, true}) for (unsigned depth : {0u, 4u})
    for (unsigned fields : {0u, 1u, 4u, 16u, 64u}) {
        Source source(depth);
        Sink sink(fields ? fields : 64, depth);
#if RTT_VERSION_MAJOR >= 3
        if (fields) {
            for (unsigned i = 0; i < fields; ++i) {
                auto selector = "values[" + std::to_string(i) + "]";
                if (!connectMembers(source.output, selector, sink.input, selector)) return 2;
            }
        } else
#endif
        if (!source.output.connectTo(&sink.input)) return 3;
        if (!source.start() || !sink.start()) return 4;
        std::atomic<bool> stop{false};
        std::thread producer;
        if (concurrent) producer = std::thread([&] {
            while (!stop.load(std::memory_order_relaxed)) source.getActivity()->execute();
        });
        auto cycle = [&] {
            if (!concurrent) source.getActivity()->execute();
            sink.getActivity()->execute();
        };
        for (unsigned warm = 0; warm < 2000; ++warm) cycle();
        std::vector<double> samples;
        samples.reserve(1000);
        for (unsigned batch = 0; batch < 1000; ++batch) {
            auto before = std::chrono::steady_clock::now();
            for (unsigned i = 0; i < 100; ++i) cycle();
            auto elapsed = std::chrono::steady_clock::now() - before;
            samples.push_back(std::chrono::duration<double, std::nano>(elapsed).count() / 100);
        }
        stop.store(true, std::memory_order_relaxed);
        if (producer.joinable()) producer.join();
        sink.stop(); source.stop();
        if (!sink.coherent || sink.result <= 0) return 5;
        std::sort(samples.begin(), samples.end());
        std::cout << RTT_VERSION_MAJOR << "," << (fields ? "selected_fields" : "whole_frame")
                  << ',' << (fields ? fields : 64) << ',' << depth << ',' << concurrent
                  << ',' << samples[500] << ',' << samples[950] << ',' << samples[990] << ',' << samples.back() << '\n';
    }
    return 0;
}
