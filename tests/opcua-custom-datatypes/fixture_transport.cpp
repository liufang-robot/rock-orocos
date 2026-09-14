#include "fixture_types.hpp"

#include <rtt/opcua/datatype_registry.hpp>
#include <rtt/opcua/type_protocol.hpp>

#include <open62541pp/datatype.hpp>

#include <rtt/Logger.hpp>
#include <rtt/OutputPort.hpp>
#include <rtt/internal/DataSource.hpp>
#include <rtt/internal/DataSources.hpp>
#include <rtt/types/TransportPlugin.hpp>
#include <rtt/types/TypeInfo.hpp>
#include <rtt/types/TypekitPlugin.hpp>

#include <map>
#include <memory>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

namespace orocos::opcua::fixture {
namespace {

const RTT::opcua::LogicalDataTypeId &pointDataTypeId() {
  static const RTT::opcua::LogicalDataTypeId id{
      std::string(kNamespaceUri), "types/Point", "encodings/Point/Binary"};
  return id;
}

const RTT::opcua::LogicalDataTypeId &envelopeDataTypeId() {
  static const RTT::opcua::LogicalDataTypeId id{std::string(kNamespaceUri),
                                                "types/Envelope",
                                                "encodings/Envelope/Binary"};
  return id;
}

template <typename T> struct CodecTraits {
  static constexpr ::opcua::ValueRank value_rank = ::opcua::ValueRank::Scalar;

  static bool decode(const ::opcua::Variant &variant,
                     const ::opcua::NodeId &data_type, T *value) noexcept {
    if (value == nullptr || !variant.isScalar() || !variant.isType(data_type) ||
        variant.data() == nullptr) {
      return false;
    }
    *value = *static_cast<const T *>(variant.data());
    return true;
  }

  static ::opcua::Variant encode(const T &value,
                                 const UA_DataType &native_type) {
    return ::opcua::Variant(value, native_type);
  }
};

template <typename T> struct CodecTraits<std::vector<T>> {
  using Value = std::vector<T>;
  static constexpr ::opcua::ValueRank value_rank =
      ::opcua::ValueRank::OneDimension;

  static bool decode(const ::opcua::Variant &variant,
                     const ::opcua::NodeId &data_type, Value *value) noexcept {
    if (value == nullptr || !variant.isArray() || !variant.isType(data_type) ||
        variant.arrayDimensions().size() > 1U) {
      return false;
    }
    if (variant.arrayLength() == 0U) {
      value->clear();
      return true;
    }
    const auto *data = static_cast<const T *>(variant.data());
    if (data == nullptr) {
      return false;
    }
    value->assign(data, data + variant.arrayLength());
    return true;
  }

  static ::opcua::Variant encode(const Value &value,
                                 const UA_DataType &native_type) {
    return ::opcua::Variant(value, native_type);
  }
};

template <typename T>
class ProxyDataSource final : public RTT::internal::DataSource<T> {
public:
  ProxyDataSource(RTT::opcua::VariantReader reader, ::opcua::NodeId data_type)
      : reader_(std::move(reader)), data_type_(std::move(data_type)) {}

  T get() const override {
    refresh();
    return last_value_;
  }

  T value() const override { return last_value_; }

  typename RTT::internal::DataSource<T>::const_reference_t
  rvalue() const override {
    return last_value_;
  }

  bool evaluate() const override { return refresh(); }

  ProxyDataSource *clone() const override {
    return new ProxyDataSource(reader_, data_type_);
  }

  ProxyDataSource *
  copy(std::map<const RTT::base::DataSourceBase *, RTT::base::DataSourceBase *>
           &already_cloned) const override {
    auto *self = const_cast<ProxyDataSource *>(this);
    already_cloned[this] = self;
    return self;
  }

private:
  bool refresh() const {
    ::opcua::Variant variant;
    T decoded{};
    if (!reader_ || !reader_(&variant) ||
        !CodecTraits<T>::decode(variant, data_type_, &decoded)) {
      return false;
    }
    last_value_ = std::move(decoded);
    return true;
  }

  RTT::opcua::VariantReader reader_;
  ::opcua::NodeId data_type_;
  mutable T last_value_{};
};

template <typename T>
class AssignableProxyDataSource final
    : public RTT::internal::AssignableDataSource<T> {
public:
  AssignableProxyDataSource(RTT::opcua::VariantReader reader,
                            RTT::opcua::VariantWriter writer,
                            ::opcua::NodeId data_type,
                            const UA_DataType *native_type)
      : reader_(std::move(reader)), writer_(std::move(writer)),
        data_type_(std::move(data_type)), native_type_(native_type) {}

  T get() const override {
    refresh();
    return last_value_;
  }

  T value() const override { return last_value_; }

  typename RTT::internal::AssignableDataSource<T>::const_reference_t
  rvalue() const override {
    return last_value_;
  }

  bool evaluate() const override { return refresh(); }

  void
  set(typename RTT::internal::AssignableDataSource<T>::param_t value) override {
    if (writer_ && native_type_ != nullptr &&
        writer_(CodecTraits<T>::encode(value, *native_type_))) {
      last_value_ = value;
    }
  }

  typename RTT::internal::AssignableDataSource<T>::reference_t set() override {
    refresh();
    return last_value_;
  }

  void updated() override { set(last_value_); }

  AssignableProxyDataSource *clone() const override {
    return new AssignableProxyDataSource(reader_, writer_, data_type_,
                                         native_type_);
  }

  AssignableProxyDataSource *
  copy(std::map<const RTT::base::DataSourceBase *, RTT::base::DataSourceBase *>
           &already_cloned) const override {
    auto *self = const_cast<AssignableProxyDataSource *>(this);
    already_cloned[this] = self;
    return self;
  }

private:
  bool refresh() const {
    ::opcua::Variant variant;
    T decoded{};
    if (!reader_ || !reader_(&variant) ||
        !CodecTraits<T>::decode(variant, data_type_, &decoded)) {
      return false;
    }
    last_value_ = std::move(decoded);
    return true;
  }

  RTT::opcua::VariantReader reader_;
  RTT::opcua::VariantWriter writer_;
  ::opcua::NodeId data_type_;
  const UA_DataType *native_type_;
  mutable T last_value_{};
};

template <typename T>
class CustomTypeCodec final : public RTT::opcua::TypeCodec {
public:
  CustomTypeCodec(::opcua::NodeId data_type, const UA_DataType *native_type)
      : TypeCodec(std::move(data_type), CodecTraits<T>::value_rank, true),
        native_type_(native_type) {}

  bool toVariant(const RTT::base::DataSourceBase::shared_ptr &source,
                 ::opcua::Variant *value) const override {
    auto typed =
        boost::dynamic_pointer_cast<RTT::internal::DataSource<T>>(source);
    if (!typed || value == nullptr || native_type_ == nullptr) {
      return false;
    }
    typed->evaluate();
    *value = CodecTraits<T>::encode(typed->value(), *native_type_);
    return true;
  }

  bool assignVariant(
      const ::opcua::Variant &value,
      const RTT::base::DataSourceBase::shared_ptr &destination) const override {
    auto typed =
        boost::dynamic_pointer_cast<RTT::internal::AssignableDataSource<T>>(
            destination);
    T decoded{};
    if (!typed || !CodecTraits<T>::decode(value, dataTypeNodeId(), &decoded)) {
      return false;
    }
    typed->set(decoded);
    return true;
  }

  RTT::base::DataSourceBase::shared_ptr
  makeDataSource(const ::opcua::Variant &value) const override {
    T decoded{};
    if (!CodecTraits<T>::decode(value, dataTypeNodeId(), &decoded)) {
      return {};
    }
    return new RTT::internal::ValueDataSource<T>(decoded);
  }

  RTT::base::DataSourceBase::shared_ptr
  makeProxyDataSource(RTT::opcua::VariantReader reader,
                      RTT::opcua::VariantWriter writer = {}) const override {
    if (!reader) {
      return {};
    }
    if (writer) {
      return new AssignableProxyDataSource<T>(
          std::move(reader), std::move(writer), dataTypeNodeId(), native_type_);
    }
    return new ProxyDataSource<T>(std::move(reader), dataTypeNodeId());
  }

  RTT::opcua::PortValueStatus
  portValue(const RTT::base::OutputPortInterface *port,
            ::opcua::Variant *value) const override {
    const auto *typed = dynamic_cast<const RTT::OutputPort<T> *>(port);
    if (typed == nullptr || value == nullptr || native_type_ == nullptr) {
      return RTT::opcua::PortValueStatus::error;
    }
    T sample{};
    if (!typed->snapshot(sample)) {
      return RTT::opcua::PortValueStatus::waiting_for_initial_data;
    }
    *value = CodecTraits<T>::encode(sample, *native_type_);
    return RTT::opcua::PortValueStatus::value;
  }

private:
  const UA_DataType *native_type_;
};

template <typename T>
class CustomTypeProtocol final : public RTT::opcua::TypeProtocol {
public:
  CustomTypeProtocol(RTT::opcua::LogicalDataTypeId id, std::string fingerprint)
      : id_(std::move(id)), fingerprint_(std::move(fingerprint)) {}

  RTT::opcua::DataTypeReference dataType() const override { return id_; }

  std::string registrationFingerprint() const override { return fingerprint_; }

  std::unique_ptr<RTT::opcua::TypeCodec>
  bind(const ::opcua::NodeId &data_type, const UA_DataType &native_type,
       std::string *error) const override {
    if (::opcua::NodeId(native_type.typeId) != data_type) {
      if (error != nullptr) {
        *error = "fixture protocol datatype mismatch";
      }
      return {};
    }
    if (error != nullptr) {
      error->clear();
    }
    return std::make_unique<CustomTypeCodec<T>>(data_type, &native_type);
  }

private:
  RTT::opcua::LogicalDataTypeId id_;
  std::string fingerprint_;
};

RTT::opcua::DataTypeProvider makeProvider() {
  RTT::opcua::CustomDataTypeDefinition point;
  point.name = "Point";
  point.id = pointDataTypeId();
  point.schema_fingerprint = "orocos-opcua-fixture/Point/v1";
  point.materialize = [](const RTT::opcua::DataTypeFactoryContext &context) {
    const auto &id = pointDataTypeId();
    return ::opcua::DataTypeBuilder<Point>::createStructure(
               "Point", context.nodeId(id),
               {context.namespaceIndex(id.namespace_uri),
                id.binary_encoding_node_id})
        .addField<&Point::x>("x")
        .addField<&Point::y>("y")
        .build();
  };

  RTT::opcua::CustomDataTypeDefinition envelope;
  envelope.name = "Envelope";
  envelope.id = envelopeDataTypeId();
  envelope.schema_fingerprint = "orocos-opcua-fixture/Envelope/v1";
  envelope.materialize = [](const RTT::opcua::DataTypeFactoryContext &context) {
    const auto &id = envelopeDataTypeId();
    const UA_DataType *point_type = context.dataType(pointDataTypeId());
    if (point_type == nullptr) {
      throw std::runtime_error("Point datatype was not materialized");
    }
    return ::opcua::DataTypeBuilder<Envelope>::createStructure(
               "Envelope", context.nodeId(id),
               {context.namespaceIndex(id.namespace_uri),
                id.binary_encoding_node_id})
        .addField<&Envelope::point>("point", *point_type)
        .addField<&Envelope::quality>("quality")
        .build();
  };

  RTT::opcua::DataTypeProvider provider;
  provider.name = std::string(kProviderName);
  provider.namespace_uri = std::string(kNamespaceUri);
  provider.data_types.push_back(std::move(point));
  provider.data_types.push_back(std::move(envelope));
  return provider;
}

class FixtureTransport final : public RTT::types::TransportPlugin {
public:
  bool registerTransport(std::string type_name,
                         RTT::types::TypeInfo *type_info) override {
    if (!ensureProvider()) {
      return false;
    }
    if (type_name == kPointTypeName) {
      return registerProtocol<Point>(type_info, pointDataTypeId(), "Point");
    }
    if (type_name == kEnvelopeTypeName) {
      return registerProtocol<Envelope>(type_info, envelopeDataTypeId(),
                                        "Envelope");
    }
    if (type_name == kPointArrayTypeName) {
      return registerProtocol<PointArray>(type_info, pointDataTypeId(),
                                          "PointArray");
    }
    return false;
  }

  std::string getTransportName() const override { return "OPCUA"; }
  std::string getTypekitName() const override {
    return "orocos-opcua-fixture-types";
  }
  std::string getName() const override {
    return "OPCUA://orocos-opcua-fixture-types";
  }

private:
  bool ensureProvider() {
    if (provider_attempted_) {
      return provider_registered_;
    }
    provider_attempted_ = true;
    std::string error;
    provider_registered_ =
        RTT::opcua::registerDataTypeProvider(makeProvider(), &error);
    if (!provider_registered_) {
      RTT::Logger::log().logf(RTT::Logger::Error, "FixtureTransport", "%s",
                              error.c_str());
    }
    return provider_registered_;
  }

  template <typename T>
  bool registerProtocol(RTT::types::TypeInfo *type_info,
                        const RTT::opcua::LogicalDataTypeId &id,
                        std::string_view short_name) {
    std::string error;
    const bool registered = RTT::opcua::registerTypeProtocol(
        type_info,
        std::make_unique<CustomTypeProtocol<T>>(
            id, "orocos-opcua-fixture/" + std::string(short_name) + "/v1"),
        &error);
    if (!registered) {
      RTT::Logger::log().logf(RTT::Logger::Error, "FixtureTransport",
                              "Unable to register OPC UA protocol for %s: %s",
                              std::string(short_name).c_str(), error.c_str());
    }
    return registered;
  }

  bool provider_attempted_{false};
  bool provider_registered_{false};
};

} // namespace
} // namespace orocos::opcua::fixture

ORO_TYPEKIT_PLUGIN(orocos::opcua::fixture::FixtureTransport)
