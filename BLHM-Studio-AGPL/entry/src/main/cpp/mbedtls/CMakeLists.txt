# 自定义 MbedTLS 编译：编译全部 library 源文件为静态库（使用默认配置）
file(GLOB MBEDTLS_SOURCES ${CMAKE_CURRENT_SOURCE_DIR}/library/*.c)
add_library(mbedtls-static STATIC ${MBEDTLS_SOURCES})
target_include_directories(mbedtls-static PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/library)
set_target_properties(mbedtls-static PROPERTIES POSITION_INDEPENDENT_CODE ON)
