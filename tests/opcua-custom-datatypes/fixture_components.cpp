#include "fixture_components.hpp"

#include <rtt/InputPort.hpp>
#include <rtt/Activity.hpp>
#include <rtt/OutputPort.hpp>
#include <rtt/Service.hpp>
#include <rtt/rt_string.hpp>

#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace orocos::opcua::fixture {
namespace {

template <typename T> struct Surface {
  Surface(std::string configured_stem, T initial)
      : stem(std::move(configured_stem)), property(initial), attribute(initial),
        constant(initial), output(stem + "Output"), input(stem + "Input") {}

  T echo(T value) { return value; }

  // OwnThread operations edit the owner image; the next successful cycle
  // publishes it through the ordinary component execution engine.
  bool emit(T value) {
    output.data() = std::move(value);
    return output.connected();
  }

  T take() { return input.data(); }

  std::string stem;
  T property;
  T attribute;
  const T constant;
  RTT::OutputPort<T> output;
  RTT::InputPort<T> input;
};

template <typename T>
void publishSurface(RTT::TaskContext &owner, Surface<T> &surface) {
  owner.addProperty(surface.stem + "Property", surface.property);
  owner.addAttribute(surface.stem + "Attribute", surface.attribute);
  owner.addConstant(surface.stem + "Constant", surface.constant);
  owner.addPort(surface.output);
  owner.addPort(surface.input);
  owner
      .addOperation(surface.stem + "Echo", &Surface<T>::echo, &surface,
                    RTT::OwnThread)
      .arg("value", "Value to return.");
  owner
      .addOperation(surface.stem + "Emit", &Surface<T>::emit, &surface,
                    RTT::OwnThread)
      .arg("value", "Value to publish.");
  owner.addOperation(surface.stem + "Take", &Surface<T>::take, &surface,
                     RTT::OwnThread);
}

PointArray makeLargePointArray() {
  PointArray points;
  points.reserve(1000);
  for (std::size_t index = 0; index < 1000; ++index) {
    const double x = static_cast<double>(index * 2 + 1);
    points.push_back(Point{x, x + 1.0});
  }
  return points;
}

} // namespace

struct FixtureComponent::Impl {
  explicit Impl(FixtureComponent &owner)
      : float64_array("Float64Array", {1.25, 2.5}),
        int32_array("Int32Array", {10, 20}),
        string_array("StringArray", {"alpha", "beta"}),
        rt_string("RtString", RTT::rt_string("initial")),
        point("Point", Point{1.0, 2.0}),
        envelope("Envelope", Envelope{{3.0, 4.0}, 5}),
        point_array("PointArray", {{6.0, 7.0}, {8.0, 9.0}}),
        large_point_array(makeLargePointArray()),
        internal(RTT::Service::Create("internal")) {
    owner.addProperty("Gain", gain);
    owner.addAttribute("Status", status);
    owner.addConstant("Limit", limit);
    owner.addOperation("echo", &Impl::echo, this, RTT::OwnThread)
        .arg("value", "Value to return.");

    publishSurface(owner, float64_array);
    publishSurface(owner, int32_array);
    publishSurface(owner, string_array);
    publishSurface(owner, rt_string);
    publishSurface(owner, point);
    publishSurface(owner, envelope);
    publishSurface(owner, point_array);
    owner.addAttribute("LargePointArrayAttribute", large_point_array);
    internal->addOperation("reset", &Impl::reset, this, RTT::OwnThread);
    owner.provides()->addService(internal);
  }

  std::int32_t echo(std::int32_t value) { return value; }
  void reset() {}

  std::int32_t gain{1};
  std::string status{"idle"};
  const std::int32_t limit{100};

  Surface<std::vector<double>> float64_array;
  Surface<std::vector<std::int32_t>> int32_array;
  Surface<std::vector<std::string>> string_array;
  Surface<RTT::rt_string> rt_string;
  Surface<Point> point;
  Surface<Envelope> envelope;
  Surface<PointArray> point_array;
  PointArray large_point_array;
  RTT::Service::shared_ptr internal;
};

FixtureComponent::FixtureComponent(const std::string &name)
    : RTT::TaskContext(name, RTT::TaskContext::PreOperational),
      impl_(std::make_unique<Impl>(*this)) {
  setActivity(new RTT::Activity(ORO_SCHED_OTHER, 0, 0.01));
}

FixtureComponent::~FixtureComponent() {
  stop();
}

UnsupportedComponent::UnsupportedComponent(const std::string &name)
    : RTT::TaskContext(name, RTT::TaskContext::PreOperational) {
  addProperty("UnsupportedProperty", value_);
}

} // namespace orocos::opcua::fixture
