#include "fixture_components.hpp"

#include <rtt/opcua/datatype_registry.hpp>
#include <rtt/opcua/object_model.hpp>
#include <rtt/opcua/server.hpp>
#include <rtt/opcua/type_protocol.hpp>

#include <rtt/os/main.h>
#include <rtt/plugin/PluginLoader.hpp>
#include <rtt/typekit/RealTimeTypekit.hpp>
#include <rtt/types/Types.hpp>

#include <atomic>
#include <charconv>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

namespace {

using orocos::opcua::fixture::FixtureComponent;

volatile std::sig_atomic_t stop_requested = 0;

void stopHandler(int) { stop_requested = 1; }

std::string argumentValue(int argc, char **argv, std::string_view name) {
  for (int index = 1; index + 1 < argc; ++index) {
    if (argv[index] == name) {
      return argv[index + 1];
    }
  }
  throw std::runtime_error("missing argument " + std::string(name));
}

std::uint16_t parsePort(const std::string &text) {
  std::uint16_t port{0};
  const auto result =
      std::from_chars(text.data(), text.data() + text.size(), port);
  if (result.ec != std::errc{} || result.ptr != text.data() + text.size() ||
      port == 0U) {
    throw std::runtime_error("invalid --port value: " + text);
  }
  return port;
}

void loadTypesAndTransports(const std::string &typekit,
                            const std::string &transport) {
  if (RTT::types::Types()->type("Int32") == nullptr &&
      !RTT::types::RealTimeTypekitPlugin().loadTypes()) {
    throw std::runtime_error("unable to load canonical RTT types");
  }
  std::string error;
  if (!RTT::opcua::registerCanonicalTypeProtocols(&error)) {
    throw std::runtime_error(error);
  }
  if (!RTT::plugin::PluginLoader::Instance()->loadLibrary(typekit)) {
    throw std::runtime_error("unable to load fixture typekit: " + typekit);
  }
  if (!RTT::plugin::PluginLoader::Instance()->loadLibrary(transport)) {
    throw std::runtime_error("unable to load fixture transport: " + transport);
  }
}

} // namespace

int ORO_main(int argc, char **argv) {
  try {
    const std::string typekit = argumentValue(argc, argv, "--typekit");
    const std::string transport = argumentValue(argc, argv, "--transport");
    const std::string ready_file = argumentValue(argc, argv, "--ready");
    const std::uint16_t port = parsePort(argumentValue(argc, argv, "--port"));

    loadTypesAndTransports(typekit, transport);

    std::string error;
    if (!RTT::opcua::freezeDataTypeRegistry(&error)) {
      throw std::runtime_error(error);
    }

    RTT::opcua::ServerOptions server_options;
    server_options.bind_address = "0.0.0.0";
    server_options.port = port;
    server_options.additional_namespace_uris = {
        "urn:orocos:rtt:fixture:unrelated"};
    RTT::opcua::Server server(server_options);
    if (!server.start(&error)) {
      throw std::runtime_error(error);
    }

    std::unique_ptr<RTT::opcua::ObjectModel> model;
    std::unique_ptr<FixtureComponent> component;
    try {
      RTT::opcua::ObjectModelOptions model_options;
      model_options.warning_sink = [](const std::string &warning) {
        std::cerr << warning << '\n';
      };
      model = std::make_unique<RTT::opcua::ObjectModel>(server, model_options);
      component = std::make_unique<FixtureComponent>("fixture/component");
      std::vector<RTT::opcua::UnsupportedResource> unsupported;
      if (!model->publishComponent(*component, &error, &unsupported)) {
        throw std::runtime_error(error);
      }
      if (!unsupported.empty()) {
        throw std::runtime_error("fixture component has " +
                                 std::to_string(unsupported.size()) +
                                 " unsupported resources");
      }

      for (const std::string stem : {"Float64Array", "Int32Array", "StringArray",
                                     "RtString", "Point", "Envelope", "PointArray"}) {
        if (!model->enableInputWrite(*component, stem + "Input", &error))
          throw std::runtime_error(error);
      }

      std::ofstream ready(ready_file, std::ios::trunc);
      if (!ready) {
        throw std::runtime_error("unable to create ready file: " + ready_file);
      }
      ready << server.endpointUrl() << '\n';
      ready.close();

      std::signal(SIGINT, stopHandler);
      std::signal(SIGTERM, stopHandler);
      while (stop_requested == 0) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
      }

      server.stop();
      model.reset();
      component.reset();
      return 0;
    } catch (...) {
      server.stop();
      model.reset();
      component.reset();
      throw;
    }
  } catch (const std::exception &exception) {
    std::cerr << "fixture-server: " << exception.what() << '\n';
    return 1;
  }
}
