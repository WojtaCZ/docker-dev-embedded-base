# embedded-common.cmake — shared helpers for firmware projects in this fleet.
# Baked into the image at /opt/embedded/cmake/embedded-common.cmake.
#
#   include(/opt/embedded/cmake/embedded-common.cmake)
#
# Provides:
#   embedded_hardening(<target>)      the fleet's standard C++ flags
#   embedded_artifacts(<target>)      .hex/.bin + size report as post-build steps
#   embedded_stack_usage(<target>)    enable -fstack-usage for the stack skill
#   find_cmsis_dsp(<core> <outvar>)   pick the right prebuilt CMSIS-DSP variant

include_guard(GLOBAL)

# ---------------------------------------------------------------------------
# Standard compile/link flags for bare-metal C++ in this fleet.
# Matches the cpp-embedded-conventions skill so the docs and the build agree.
# ---------------------------------------------------------------------------
function(embedded_hardening target)
    target_compile_features(${target} PRIVATE cxx_std_20)
    set_target_properties(${target} PROPERTIES CXX_EXTENSIONS OFF)

    target_compile_options(${target} PRIVATE
        $<$<COMPILE_LANGUAGE:CXX>:-fno-exceptions>
        $<$<COMPILE_LANGUAGE:CXX>:-fno-rtti>
        $<$<COMPILE_LANGUAGE:CXX>:-fno-threadsafe-statics>
        $<$<COMPILE_LANGUAGE:CXX>:-fno-use-cxa-atexit>
        -ffunction-sections
        -fdata-sections
        -Wall -Wextra -Wpedantic
        -Wconversion -Wsign-conversion
        -Wshadow -Wdouble-promotion
        -Wundef
    )

    target_link_options(${target} PRIVATE
        -Wl,--gc-sections
        -Wl,-Map,$<TARGET_FILE_DIR:${target}>/$<TARGET_NAME:${target}>.map
        -Wl,--print-memory-usage
        --specs=nano.specs
        --specs=nosys.specs
    )
endfunction()

# ---------------------------------------------------------------------------
# .hex / .bin next to the .elf, plus a size report at the end of every build.
# ---------------------------------------------------------------------------
function(embedded_artifacts target)
    if(NOT CMAKE_OBJCOPY)
        find_program(CMAKE_OBJCOPY ${CMAKE_C_COMPILER_TARGET}-objcopy objcopy REQUIRED)
    endif()
    if(NOT CMAKE_SIZE)
        find_program(CMAKE_SIZE ${CMAKE_C_COMPILER_TARGET}-size size REQUIRED)
    endif()

    add_custom_command(TARGET ${target} POST_BUILD
        COMMAND ${CMAKE_OBJCOPY} -O ihex   $<TARGET_FILE:${target}> $<TARGET_FILE_DIR:${target}>/$<TARGET_NAME:${target}>.hex
        COMMAND ${CMAKE_OBJCOPY} -O binary $<TARGET_FILE:${target}> $<TARGET_FILE_DIR:${target}>/$<TARGET_NAME:${target}>.bin
        COMMAND ${CMAKE_SIZE} $<TARGET_FILE:${target}>
        COMMENT "Generating .hex / .bin and reporting size"
        VERBATIM
    )
endfunction()

# ---------------------------------------------------------------------------
# -fstack-usage, consumed by the stack-usage-estimate skill.
# ---------------------------------------------------------------------------
function(embedded_stack_usage target)
    target_compile_options(${target} PRIVATE -fstack-usage)
endfunction()

# ---------------------------------------------------------------------------
# Select the CMSIS-DSP build matching the target core.
#
# The arm leaf builds one static library per core under
# $ENV{CMSIS_DSP_DIR}/lib/<core>/libCMSISDSP.a. Linking the cortex-m4 build into
# a cortex-m33 (ARMv8-M) image is an architecture mismatch, so pick explicitly.
#
#   find_cmsis_dsp(cortex-m33f DSP_LIB)
#   target_link_libraries(firmware PRIVATE ${DSP_LIB})
# ---------------------------------------------------------------------------
function(find_cmsis_dsp core outvar)
    set(_root "$ENV{CMSIS_DSP_DIR}")
    if(NOT _root)
        message(FATAL_ERROR "CMSIS_DSP_DIR is not set — is this the arm leaf image?")
    endif()

    set(_lib "${_root}/lib/${core}/libCMSISDSP.a")
    if(NOT EXISTS "${_lib}")
        file(GLOB _available RELATIVE "${_root}/lib" "${_root}/lib/*")
        message(FATAL_ERROR
            "No CMSIS-DSP build for core '${core}'.\n"
            "Available: ${_available}\n"
            "Build one with: build-cmsis-dsp ${core}")
    endif()

    set(${outvar} "${_lib}" PARENT_SCOPE)
    set(${outvar}_INCLUDE_DIRS
        "${_root}/Include"
        "${_root}/PrivateInclude"
        "$ENV{CMSIS_DIR}/CMSIS/Core/Include"
        PARENT_SCOPE)
endfunction()
