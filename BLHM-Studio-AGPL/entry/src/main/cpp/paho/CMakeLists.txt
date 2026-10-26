# 自定义 Paho MQTT C 编译：仅异步客户端静态库（无 TLS）
set(CLIENT_VERSION "1.3.13")
set(BUILD_TIMESTAMP "2026-01-01")
configure_file(VersionInfo.h.in ${CMAKE_CURRENT_BINARY_DIR}/VersionInfo.h @ONLY)

set(common_src
  MQTTTime.c
  MQTTProtocolClient.c
  Clients.c
  utf-8.c
  MQTTPacket.c
  MQTTPacketOut.c
  Messages.c
  Tree.c
  Socket.c
  Log.c
  MQTTPersistence.c
  Thread.c
  MQTTProtocolOut.c
  MQTTPersistenceDefault.c
  SocketBuffer.c
  LinkedList.c
  MQTTProperties.c
  MQTTReasonCodes.c
  Base64.c
  SHA1.c
  WebSocket.c
  Proxy.c
  StackTrace.c
  Heap.c)

add_library(paho-mqtt3a-static STATIC ${common_src} MQTTAsync.c MQTTAsyncUtils.c)
target_compile_definitions(paho-mqtt3a-static PUBLIC PAHO_MQTT_STATIC=1)
target_include_directories(paho-mqtt3a-static PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_BINARY_DIR})
set_target_properties(paho-mqtt3a-static PROPERTIES POSITION_INDEPENDENT_CODE ON)
