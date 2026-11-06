# SPDX-License-Identifier: MIT
# Copyright (C) 2026 scullymi
# Object files end in .o on every machine: CMake's .obj on Windows goes into the ELF through the
# names of the files.
set(CMAKE_C_OUTPUT_EXTENSION .o)
set(CMAKE_CXX_OUTPUT_EXTENSION .o)
set(CMAKE_ASM_OUTPUT_EXTENSION .o)
