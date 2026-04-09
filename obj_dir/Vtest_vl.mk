# Verilated -*- Makefile -*-
# DESCRIPTION: Verilator output: Makefile for building Verilated archive or executable
#
# Execute this makefile from the object directory:
#    make -f Vtest_vl.mk

default: libVtest_vl

### Constants...
# Perl executable (from $PERL)
PERL = perl
# Path to Verilator kit (from $VERILATOR_ROOT)
VERILATOR_ROOT = C:/msys64/mingw64/share/verilator
# SystemC include directory with systemc.h (from $SYSTEMC_INCLUDE)
SYSTEMC_INCLUDE ?= 
# SystemC library directory with libsystemc.a (from $SYSTEMC_LIBDIR)
SYSTEMC_LIBDIR ?= 

### Switches...
# C++ code coverage  0/1 (from --prof-c)
VM_PROFC = 0
# SystemC output mode?  0/1 (from --sc)
VM_SC = 0
# Legacy or SystemC output mode?  0/1 (from --sc)
VM_SP_OR_SC = $(VM_SC)
# Deprecated
VM_PCLI = 1
# Deprecated: SystemC architecture to find link library path (from $SYSTEMC_ARCH)
VM_SC_TARGET_ARCH = cygwin

### Vars...
# Design prefix (from --prefix)
VM_PREFIX = Vtest_vl
# Module prefix (from --prefix)
VM_MODPREFIX = Vtest_vl
# User CFLAGS (from -CFLAGS on Verilator command line)
VM_USER_CFLAGS = \

# User LDLIBS (from -LDFLAGS on Verilator command line)
VM_USER_LDLIBS = \

# User .cpp files (from .cpp's on Verilator command line)
VM_USER_CLASSES = \

# User .cpp directories (from .cpp's on Verilator command line)
VM_USER_DIR = \


### Default rules...
# Include list of all generated classes
include Vtest_vl_classes.mk
# Include global rules
include $(VERILATOR_ROOT)/include/verilated.mk

### Library rules (default lib mode)
libVtest_vl.a: $(VK_OBJS) $(VK_USER_OBJS) $(VM_HIER_LIBS)
libverilated.a: $(VK_GLOBAL_OBJS)
libVtest_vl: libVtest_vl.a libverilated.a $(VM_PREFIX)__ALL.a

# Verilated -*- Makefile -*-
