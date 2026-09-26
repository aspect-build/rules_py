"""
Build backend compatibility helper for sdist wheel builds.

Extracted into its own module so it can be unit-tested independently of
the build_helper.py script entry point.
"""

import importlib.metadata
from os import path


def ensure_build_backend(src_dir):
    """Patch pyproject.toml and generate setup.cfg if needed for buildability.

    When the declared build backend (e.g. hatchling) is not importable in the
    build venv, rewrites pyproject.toml to use setuptools.build_meta. Also
    generates setup.cfg for setuptools < 61.0 which does not support the
    PEP 621 [project] table.
    """
    pyproject_path = path.join(src_dir, "pyproject.toml")
    if not path.exists(pyproject_path):
        return

    with open(pyproject_path) as f:
        lines = f.readlines()

    name = None
    version = None
    build_backend = None
    in_project = False
    in_build_system = False
    in_project_scripts = False
    has_src_layout = path.isdir(path.join(src_dir, "src"))
    scripts = {}

    for line in lines:
        stripped = line.strip()
        if stripped == "[project]":
            in_project, in_build_system, in_project_scripts = True, False, False
            continue
        elif stripped == "[build-system]":
            in_build_system, in_project, in_project_scripts = True, False, False
            continue
        elif stripped == "[project.scripts]":
            in_project_scripts, in_project, in_build_system = True, False, False
            continue
        elif stripped.startswith("["):
            in_project = in_build_system = in_project_scripts = False
            continue
        if in_project:
            if stripped.startswith("name"):
                _, _, val = stripped.partition("=")
                name = val.strip().strip('"').strip("'")
            elif stripped.startswith("version"):
                _, _, val = stripped.partition("=")
                version = val.strip().strip('"').strip("'")
        elif in_build_system:
            if stripped.startswith("build-backend"):
                _, _, val = stripped.partition("=")
                build_backend = val.strip().strip('"').strip("'")
        elif in_project_scripts:
            if "=" in stripped:
                sname, _, sval = stripped.partition("=")
                scripts[sname.strip().strip('"').strip("'")] = sval.strip().strip('"').strip("'")

    backend_available = True
    if build_backend and build_backend != "setuptools.build_meta":
        backend_module = build_backend.split(":")[0].split(".")[0]
        try:
            __import__(backend_module)
        except ImportError:
            backend_available = False

    if not backend_available:
        new_lines = []
        in_build_system_section = False
        for line in lines:
            stripped = line.strip()
            if stripped == "[build-system]":
                in_build_system_section = True
                new_lines.append("[build-system]\n")
                new_lines.append('requires = ["setuptools", "wheel"]\n')
                new_lines.append('build-backend = "setuptools.build_meta"\n')
                continue
            elif stripped.startswith("[") and in_build_system_section:
                in_build_system_section = False
            if in_build_system_section:
                continue
            new_lines.append(line)
        with open(pyproject_path, "w") as f:
            f.writelines(new_lines)
        build_backend = "setuptools.build_meta"

    if build_backend == "setuptools.build_meta" or build_backend is None:
        try:
            st_ver = tuple(int(x) for x in importlib.metadata.version("setuptools").split(".")[:2])
        except Exception:
            st_ver = (0, 0)

        setup_cfg_path = path.join(src_dir, "setup.cfg")
        if st_ver < (61, 0) and name and version and not path.exists(setup_cfg_path):
            cfg = "[metadata]\nname = {}\nversion = {}\n".format(name, version)
            if has_src_layout:
                cfg += "\n[options]\npackage_dir =\n    = src\npackages = find:\n\n[options.packages.find]\nwhere = src\n"
            else:
                cfg += "\n[options]\npackages = find:\n"
            cfg += "\n[options.package_data]\n* = *\n"
            if scripts:
                cfg += "\n[options.entry_points]\nconsole_scripts =\n"
                for sname, sval in scripts.items():
                    cfg += "    {} = {}\n".format(sname, sval)
            with open(setup_cfg_path, "w") as f:
                f.write(cfg)
