cmake_minimum_required(VERSION 3.20)
project(punch_core LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

option(PUNCH_SANITIZE "Build with ASan/UBSan" OFF)

add_library(punch_core STATIC
  src/parametric_eq.cpp
  src/limiter.cpp
  src/enhancers.cpp
  src/character.cpp
  src/engine.cpp
  src/autoeq.cpp
  src/punch_c.cpp)
target_include_directories(punch_core PUBLIC include)
if(MSVC)
  target_compile_options(punch_core PRIVATE /W4)
else()
  target_compile_options(punch_core PRIVATE -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Wno-sign-conversion)
endif()
if(PUNCH_SANITIZE)
  add_compile_options(-fsanitize=address,undefined -fno-omit-frame-pointer)
  add_link_options(-fsanitize=address,undefined)
  target_compile_options(punch_core PRIVATE -fsanitize=address,undefined -fno-omit-frame-pointer)
endif()

enable_testing()
add_executable(punch_tests tests/test_main.cpp)
target_link_libraries(punch_tests PRIVATE punch_core)
find_package(Threads REQUIRED)
target_link_libraries(punch_tests PRIVATE Threads::Threads)
add_test(NAME punch_tests COMMAND punch_tests)

add_executable(punch_c_smoke tests/c_smoke.c)
target_link_libraries(punch_c_smoke PRIVATE punch_core)
set_target_properties(punch_c_smoke PROPERTIES LINKER_LANGUAGE CXX)
add_test(NAME punch_c_smoke COMMAND punch_c_smoke)

add_executable(punch_render tools/punch_render.cpp)
target_link_libraries(punch_render PRIVATE punch_core)

add_executable(punch_bench tools/punch_bench.cpp)
target_link_libraries(punch_bench PRIVATE punch_core)
