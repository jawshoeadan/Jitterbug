# CMAKE generated file: DO NOT EDIT!
# Generated by "Unix Makefiles" Generator, CMake Version 3.24

# Delete rule output on recipe failure.
.DELETE_ON_ERROR:

#=============================================================================
# Special targets provided by cmake.

# Disable implicit rules so canonical targets will work.
.SUFFIXES:

# Disable VCS-based implicit rules.
% : %,v

# Disable VCS-based implicit rules.
% : RCS/%

# Disable VCS-based implicit rules.
% : RCS/%,v

# Disable VCS-based implicit rules.
% : SCCS/s.%

# Disable VCS-based implicit rules.
% : s.%

.SUFFIXES: .hpux_make_needs_suffix_list

# Command-line flag to silence nested $(MAKE).
$(VERBOSE)MAKESILENT = -s

#Suppress display of executed commands.
$(VERBOSE).SILENT:

# A target that is always out of date.
cmake_force:
.PHONY : cmake_force

#=============================================================================
# Set environment variables for the build.

# The shell in which to execute make rules.
SHELL = /bin/sh

# The CMake executable.
CMAKE_COMMAND = /opt/homebrew/Cellar/cmake/3.24.1/bin/cmake

# The command to remove a file.
RM = /opt/homebrew/Cellar/cmake/3.24.1/bin/cmake -E rm -f

# Escaping for special characters.
EQUALS = =

# The top-level source directory on which CMake was run.
CMAKE_SOURCE_DIR = /Users/Josh/Downloads/libzip

# The top-level build directory on which CMake was run.
CMAKE_BINARY_DIR = /Users/Josh/Downloads/libzip/build

# Include any dependencies generated for this target.
include regress/CMakeFiles/liboverride-test.dir/depend.make
# Include any dependencies generated by the compiler for this target.
include regress/CMakeFiles/liboverride-test.dir/compiler_depend.make

# Include the progress variables for this target.
include regress/CMakeFiles/liboverride-test.dir/progress.make

# Include the compile flags for this target's objects.
include regress/CMakeFiles/liboverride-test.dir/flags.make

regress/CMakeFiles/liboverride-test.dir/liboverride-test.c.o: regress/CMakeFiles/liboverride-test.dir/flags.make
regress/CMakeFiles/liboverride-test.dir/liboverride-test.c.o: /Users/Josh/Downloads/libzip/regress/liboverride-test.c
regress/CMakeFiles/liboverride-test.dir/liboverride-test.c.o: regress/CMakeFiles/liboverride-test.dir/compiler_depend.ts
	@$(CMAKE_COMMAND) -E cmake_echo_color --switch=$(COLOR) --green --progress-dir=/Users/Josh/Downloads/libzip/build/CMakeFiles --progress-num=$(CMAKE_PROGRESS_1) "Building C object regress/CMakeFiles/liboverride-test.dir/liboverride-test.c.o"
	cd /Users/Josh/Downloads/libzip/build/regress && /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/cc $(C_DEFINES) $(C_INCLUDES) $(C_FLAGS) -MD -MT regress/CMakeFiles/liboverride-test.dir/liboverride-test.c.o -MF CMakeFiles/liboverride-test.dir/liboverride-test.c.o.d -o CMakeFiles/liboverride-test.dir/liboverride-test.c.o -c /Users/Josh/Downloads/libzip/regress/liboverride-test.c

regress/CMakeFiles/liboverride-test.dir/liboverride-test.c.i: cmake_force
	@$(CMAKE_COMMAND) -E cmake_echo_color --switch=$(COLOR) --green "Preprocessing C source to CMakeFiles/liboverride-test.dir/liboverride-test.c.i"
	cd /Users/Josh/Downloads/libzip/build/regress && /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/cc $(C_DEFINES) $(C_INCLUDES) $(C_FLAGS) -E /Users/Josh/Downloads/libzip/regress/liboverride-test.c > CMakeFiles/liboverride-test.dir/liboverride-test.c.i

regress/CMakeFiles/liboverride-test.dir/liboverride-test.c.s: cmake_force
	@$(CMAKE_COMMAND) -E cmake_echo_color --switch=$(COLOR) --green "Compiling C source to assembly CMakeFiles/liboverride-test.dir/liboverride-test.c.s"
	cd /Users/Josh/Downloads/libzip/build/regress && /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/cc $(C_DEFINES) $(C_INCLUDES) $(C_FLAGS) -S /Users/Josh/Downloads/libzip/regress/liboverride-test.c -o CMakeFiles/liboverride-test.dir/liboverride-test.c.s

# Object files for target liboverride-test
liboverride__test_OBJECTS = \
"CMakeFiles/liboverride-test.dir/liboverride-test.c.o"

# External object files for target liboverride-test
liboverride__test_EXTERNAL_OBJECTS =

regress/liboverride-test: regress/CMakeFiles/liboverride-test.dir/liboverride-test.c.o
regress/liboverride-test: regress/CMakeFiles/liboverride-test.dir/build.make
regress/liboverride-test: lib/libzip.5.5.dylib
regress/liboverride-test: regress/CMakeFiles/liboverride-test.dir/link.txt
	@$(CMAKE_COMMAND) -E cmake_echo_color --switch=$(COLOR) --green --bold --progress-dir=/Users/Josh/Downloads/libzip/build/CMakeFiles --progress-num=$(CMAKE_PROGRESS_2) "Linking C executable liboverride-test"
	cd /Users/Josh/Downloads/libzip/build/regress && $(CMAKE_COMMAND) -E cmake_link_script CMakeFiles/liboverride-test.dir/link.txt --verbose=$(VERBOSE)

# Rule to build all files generated by this target.
regress/CMakeFiles/liboverride-test.dir/build: regress/liboverride-test
.PHONY : regress/CMakeFiles/liboverride-test.dir/build

regress/CMakeFiles/liboverride-test.dir/clean:
	cd /Users/Josh/Downloads/libzip/build/regress && $(CMAKE_COMMAND) -P CMakeFiles/liboverride-test.dir/cmake_clean.cmake
.PHONY : regress/CMakeFiles/liboverride-test.dir/clean

regress/CMakeFiles/liboverride-test.dir/depend:
	cd /Users/Josh/Downloads/libzip/build && $(CMAKE_COMMAND) -E cmake_depends "Unix Makefiles" /Users/Josh/Downloads/libzip /Users/Josh/Downloads/libzip/regress /Users/Josh/Downloads/libzip/build /Users/Josh/Downloads/libzip/build/regress /Users/Josh/Downloads/libzip/build/regress/CMakeFiles/liboverride-test.dir/DependInfo.cmake --color=$(COLOR)
.PHONY : regress/CMakeFiles/liboverride-test.dir/depend

