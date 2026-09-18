# host-test.cmake — native x86 unit tests for firmware logic.
#
# Baked into the image at /opt/embedded/cmake/host-test.cmake.
#
# Pure-logic modules (protocol parsers, state machines, ring buffers, fixed-point
# maths) do not need silicon to be tested. Testing them natively gives an agent a
# fast, hardware-free feedback loop; only hardware-touching code then needs the
# `mcu test` HIL path.
#
# Layout this expects:
#
#   src/            firmware sources (cross-compiled)
#   src/logic/      hardware-independent sources (compiled BOTH ways)
#   test/host/      GoogleTest or Catch2 test sources
#
# Usage — configure a SEPARATE build dir with the host compiler:
#
#   cmake -S . -B build-host -G Ninja -DHOST_TESTS=ON
#   cmake --build build-host && ctest --test-dir build-host --output-on-failure
#
# In the project's top-level CMakeLists.txt:
#
#   option(HOST_TESTS "Build native unit tests instead of firmware" OFF)
#   if(HOST_TESTS)
#       include(/opt/embedded/cmake/host-test.cmake)
#       add_host_test_suite(logic_tests
#           SOURCES  test/host/test_ringbuffer.cpp test/host/test_protocol.cpp
#           UNDER_TEST src/logic/ringbuffer.cpp src/logic/protocol.cpp
#           INCLUDES src/logic)
#       return()   # skip the cross-compiled firmware target entirely
#   endif()

include_guard(GLOBAL)

enable_testing()

find_package(GTest QUIET)
find_package(Catch2 3 QUIET)

if(NOT GTest_FOUND AND NOT Catch2_FOUND)
    message(FATAL_ERROR
        "Neither GoogleTest nor Catch2 found. Both ship in the embedded-base image; "
        "are you configuring with the cross toolchain by mistake? Host tests must be "
        "configured in a separate build dir WITHOUT -DCMAKE_TOOLCHAIN_FILE.")
endif()

if(CMAKE_CROSSCOMPILING)
    message(FATAL_ERROR
        "host-test.cmake included while cross-compiling. Configure host tests in a "
        "separate build directory with no toolchain file:\n"
        "  cmake -S . -B build-host -G Ninja -DHOST_TESTS=ON")
endif()

# ---------------------------------------------------------------------------
# add_host_test_suite(<name>
#     SOURCES    <test sources...>
#     UNDER_TEST <production sources compiled into the test binary...>
#     INCLUDES   <include dirs...>
#     DEFINES    <extra -D...>)
#
# Registers the binary with CTest and, when gcovr is available, adds a
# <name>-coverage target.
# ---------------------------------------------------------------------------
function(add_host_test_suite name)
    cmake_parse_arguments(HT "" "" "SOURCES;UNDER_TEST;INCLUDES;DEFINES" ${ARGN})

    if(NOT HT_SOURCES)
        message(FATAL_ERROR "add_host_test_suite(${name}): SOURCES is required")
    endif()

    add_executable(${name} ${HT_SOURCES} ${HT_UNDER_TEST})
    target_compile_features(${name} PRIVATE cxx_std_20)
    target_include_directories(${name} PRIVATE ${HT_INCLUDES})
    target_compile_definitions(${name} PRIVATE HOST_TEST=1 ${HT_DEFINES})

    # Same warning discipline as the firmware build, so host tests catch the
    # same class of mistake before it reaches the target.
    target_compile_options(${name} PRIVATE
        -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow
        -g -O0 --coverage)
    target_link_options(${name} PRIVATE --coverage)

    if(GTest_FOUND)
        target_link_libraries(${name} PRIVATE GTest::gtest GTest::gtest_main)
    else()
        target_link_libraries(${name} PRIVATE Catch2::Catch2WithMain)
    endif()

    add_test(NAME ${name} COMMAND ${name})

    find_program(GCOVR_EXE gcovr)
    if(GCOVR_EXE)
        add_custom_target(${name}-coverage
            COMMAND ${CMAKE_CTEST_COMMAND} --output-on-failure
            COMMAND ${GCOVR_EXE} --root ${CMAKE_SOURCE_DIR}
                                 --exclude '.*/test/.*'
                                 --print-summary
                                 --html-details ${CMAKE_BINARY_DIR}/coverage.html
            WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
            COMMENT "Running ${name} and generating coverage.html"
            VERBATIM)
    endif()
endfunction()
