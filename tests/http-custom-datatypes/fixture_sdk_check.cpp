#include "fixture_components.hpp"
#include <rtt/http/reflected_codec.hpp>
#include <rtt/InputPort.hpp>
#include <rtt/extras/SlaveActivity.hpp>
#include <rtt/internal/PortDataAccess.hpp>
#include <rtt/PropertyBag.hpp>
#include <rtt/plugin/PluginLoader.hpp>
#include <rtt/typekit/RealTimeTypekit.hpp>
#include <rtt/types/Types.hpp>

#include <iostream>
#include <stdexcept>

using namespace RTT::http;
using namespace orocos::opcua::fixture;

void require(bool condition, const char *message) {
  if (!condition) { throw std::runtime_error(message); }
}
boost::json::value read(const TypeCodec &codec, const DataSourcePtr &source) {
  CodecContext context;
  boost::json::value result(context.storage());
  require(codec.toJson(source, &result, context, nullptr), "encode reflected component value");
  return result;
}
int main(int argc, char **argv) {
  try {
    require(argc == 3, "expected ordinary typekit and HTTP transport paths");
    RTT::types::RealTimeTypekitPlugin().loadTypes();
    const auto loader = RTT::plugin::PluginLoader::Instance();
    require(loader->loadLibrary(argv[1]), "load ordinary RTT typekit");
    auto *point_type = RTT::types::Types()->type(std::string(kPointTypeName));
    require(point_type && !point_type->hasProtocol(kTransportProtocolId) && !point_type->hasProtocol(1042),
            "ordinary typekit has no protocol dependency");
    FixtureComponent component("fixture");
    require(registerCanonicalTypeProtocols(), "register canonical HTTP dependencies before custom transport");
    require(loader->loadLibrary(argv[2]), "load separate HTTP codec transport");
    const auto diagnostics = registerReflectedTypeProtocols();
    require(diagnostics.count(std::string(kUnsupportedTypeName)), "unreflected type has explicit diagnostic");
    std::string error;
    const auto catalog = freezeTypeCatalog(&error);
    if (!catalog) { throw std::runtime_error(error); }
    require(!point_type->hasProtocol(1042), "HTTP registration leaves OPC UA untouched");
    const auto *point = catalog->find(point_type);
    const auto *envelope = catalog->find(std::string(kEnvelopeTypeName));
    const auto *sequence = catalog->find(std::string(kPointArrayTypeName));
    require(point && envelope && sequence && point->codec->supportsPortValue(), "custom reflection and typed sample support");
    require(catalog->find(RTT::types::Types()->type("orocos.fixture.Point")) == point,
            "dotted RTT lookup shares canonical type binding");
    const boost::json::string_view point_name(kPointTypeName.data(), kPointTypeName.size());
    require(envelope->registration.descriptor.at("fields").as_array()[0].as_object().at("rttType").as_string() == point_name &&
                sequence->registration.descriptor.at("elementType").as_string() == point_name,
            "client schemas reference canonical custom types");

    auto *property = component.properties()->getProperty("EnvelopeProperty");
    require(property != nullptr, "ordinary component property exists");
    const auto source = property->getDataSource();
    const auto original = read(*envelope->codec, source);
    const auto replacement = boost::json::parse(R"({"quality":42,"point":{"y":20.0,"x":10.0}})");
    CodecContext context;
    const auto staged = envelope->codec->makeDataSource(replacement, context, nullptr);
    require(staged && read(*envelope->codec, source) == original, "decode does not modify live component");
    require(envelope->codec->assign(staged, source, nullptr) && read(*envelope->codec, source) == replacement,
            "whole reflected object assignment preserves declared field order independence");
    for (const auto *invalid : {R"({"quality":9,"point":{"x":1}})",
                               R"({"quality":9,"point":{"x":1,"y":2,"extra":3}})",
                               R"({"quality":"wrong","point":{"x":1,"y":2}})"}) {
      require(!envelope->codec->makeDataSource(boost::json::parse(invalid), context, nullptr) &&
                  read(*envelope->codec, source) == replacement,
              "invalid nested object cannot partially update a component");
    }
    const auto sequence_source = component.properties()->getProperty("PointArrayProperty")->getDataSource();
    const auto before = read(*sequence->codec, sequence_source);
    require(!sequence->codec->makeDataSource(boost::json::parse(R"([{"x":1,"y":2},{"x":3}])"), context, nullptr) &&
                read(*sequence->codec, sequence_source) == before,
            "invalid sequence element cannot partially replace a component array");
    const auto points = boost::json::parse(R"([{"x":11.0,"y":12.0}])");
    const auto staged_points = sequence->codec->makeDataSource(points, context, nullptr);
    require(staged_points && sequence->codec->assign(staged_points, sequence_source, nullptr) &&
                read(*sequence->codec, sequence_source) == points, "reflected sequence resize and assignment");

    auto *output = dynamic_cast<RTT::OutputPort<Point> *>(component.ports()->getPort("PointOutput"));
    RTT::InputPort<Point> observer("observer");
    require(output && output->createConnection(observer, RTT::ConnPolicy::data(RTT::ConnPolicy::LOCK_FREE, false)),
            "connect custom output observer");
    boost::json::value latest(context.storage());
    require(point->codec->portValue(output, &latest, context, nullptr) == PortValueStatus::waiting_for_initial_data,
            "custom codec distinguishes no initial sample");
    auto* activity = new RTT::extras::SlaveActivity(0.01);
    require(component.setActivity(activity), "use deterministic fixture activity");
    output->data() = Point{7, 8};
    require(component.configure() && component.start(), "start custom cyclic component");
    require(activity->execute(), "execute custom component cycle");
    require(component.stop(), "stop custom cyclic component");
    require(point->codec->portValue(output, &latest, context, nullptr) == PortValueStatus::value &&
                latest == boost::json::parse(R"({"x":7.0,"y":8.0})"), "custom retained sample encoded through reflection");
    Point consumed;
    require(RTT::internal::PortDataAccess::receive(observer, consumed) == RTT::NewData && consumed == Point{7, 8},
            "HTTP read leaves the independent reader's sample intact");
    std::cout << "Installed HTTP SDK: independent typekit/component/transport, composites, and ports passed\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
