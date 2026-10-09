"""Builds libairport_finder_spinel.so, which superwings_spinel loads with
ctypes, from csrc/: the C that Spinel generated from the Ruby port and
Spinel's runtime (prepared by ../ext/build.sh). Building needs only a C
compiler, never Spinel.

The library uses no Python C API, so a wheel fits every Python 3 on its
platform: it is tagged py3-none-<platform>.
"""

import sys
from pathlib import Path

from setuptools import setup
from setuptools.command.build_py import build_py
from setuptools.dist import Distribution

try:
    from setuptools.command.bdist_wheel import bdist_wheel
except ImportError:  # setuptools < 70.1
    from wheel.bdist_wheel import bdist_wheel

HERE = Path(__file__).resolve().parent
CSRC = HERE / "csrc"
LIBRARY = "libairport_finder_spinel.so"


def spinel_flags():
    """The cflags and defines `spinel --print-build` named for this C."""
    flags = []
    for line in (CSRC / "build_flags.txt").read_text().splitlines():
        kind, _, value = line.partition(" ")
        if kind in ("cflag", "define"):
            flags.append(value)
    return flags


class BuildLibrary(build_py):
    def run(self):
        super().run()
        from setuptools._distutils.ccompiler import new_compiler
        from setuptools._distutils.sysconfig import customize_compiler

        if not (CSRC / "build_flags.txt").exists():
            sys.exit("csrc/ is missing: run ../ext/build.sh (needs Spinel) first")
        cc = new_compiler()
        customize_compiler(cc)
        build_temp = Path(self.get_finalized_command("build").build_temp)
        objects = cc.compile(
            sorted(str(p.relative_to(HERE)) for p in CSRC.glob("*.c")),
            output_dir=str(build_temp),
            include_dirs=[str(CSRC)],
            # Spinel's own flags last: -ffp-contract=off keeps the arithmetic
            # (and so the answers) the same as the crate's. -g0 drops the
            # debug info Python's CFLAGS ask for: megabytes, and build paths.
            extra_preargs=["-fPIC", "-fvisibility=hidden", "-ffunction-sections",
                           "-fdata-sections", "-w"],
            extra_postargs=["-O2", "-g0"] + spinel_flags(),
        )
        strip_unused = "-Wl,-dead_strip" if sys.platform == "darwin" else "-Wl,--gc-sections"
        out = Path(self.build_lib) / "superwings_spinel" / LIBRARY
        cc.link_shared_object(objects, str(out), libraries=["m"], extra_postargs=[strip_unused])


class BinaryDistribution(Distribution):
    def has_ext_modules(self):
        return True


class PlatformWheel(bdist_wheel):
    def finalize_options(self):
        super().finalize_options()
        self.root_is_pure = False

    def get_tag(self):
        return ("py3", "none", super().get_tag()[2])


setup(
    distclass=BinaryDistribution,
    cmdclass={"build_py": BuildLibrary, "bdist_wheel": PlatformWheel},
)
