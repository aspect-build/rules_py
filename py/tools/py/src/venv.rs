use crate::{
    pth::{CollisionResolutionStrategy, SitePackageOptions},
    PthFile,
};
use miette::{miette, Context, IntoDiagnostic};
use pathdiff::diff_paths;
use sha256::try_digest;
use std::{
    env::current_dir,
    fs::{self, File},
    io::{BufRead, BufReader, BufWriter, Write},
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
};
use std::{ffi::OsStr, os::unix::fs as unix_fs};
use walkdir::WalkDir;

pub fn create_venv(
    python: &Path,
    location: &Path,
    pth_file: Option<PthFile>,
    collision_strategy: CollisionResolutionStrategy,
    venv_name: &str,
) -> miette::Result<()> {
    if location.exists() {
        // Clear down the an old venv if there is one present.
        fs::remove_dir_all(location)
            .into_diagnostic()
            .wrap_err("Unable to remove venv_root directory")?;
    }

    // Create all the dirs down to the venv base
    fs::create_dir_all(location)
        .into_diagnostic()
        .wrap_err("Unable to create base venv directory")?;

    let venv_location = fs::canonicalize(location)
        .into_diagnostic()
        .wrap_err("Unable to determine absolute directory to venv directory")?;

    // Need a way of providing our own cache here that drops, we leave the caching up to
    // bazel.
    // The temp dir will be cleaned up when the cache goes out of scope.
    let cache = uv_cache::Cache::temp().into_diagnostic()?;

    let interpreter = uv_python::Interpreter::query(&python, &cache).into_diagnostic()?;

    let venv = uv_virtualenv::create_venv(
        &venv_location,
        interpreter,
        uv_virtualenv::Prompt::Static(venv_name.to_string()),
        false,
        false,
        false,
        false,
    )
    .into_diagnostic()?;

    if let Some(pth) = pth_file {
        let site_package_path = venv
            .site_packages()
            .nth(0)
            .expect("Should have a site-packages directory");

        let site_packages_options = SitePackageOptions {
            dest: venv_location.join(site_package_path),
            collision_strategy,
        };

        pth.set_up_site_packages_dynamic(site_packages_options)?
    }

    Ok(())
}

#[derive(Clone, Copy)]
pub struct PythonVersionInfo {
    major: u32,
    minor: u32,
    patch: u32,
}

impl PythonVersionInfo {
    pub fn from_str(it: &str) -> miette::Result<PythonVersionInfo> {
        match it.split(".").collect::<Vec<_>>().as_slice() {
            [major, minor] => Ok(PythonVersionInfo {
                major: major.parse().unwrap(),
                minor: minor.parse().unwrap(),
                patch: 0,
            }),
            [major, minor, patch] => Ok(PythonVersionInfo {
                major: major.parse().unwrap(),
                minor: minor.parse().unwrap(),
                patch: patch.parse().unwrap(),
            }),
            _ => Err(miette!("X.Y or X.Y.Z required!")),
        }
    }
}

pub struct Virtualenv {
    /// Fields:
    ///   `home_dir`:
    ///     The path of the "root" of the venv.
    ///     This is `../` of the where the "interpreter" exists
    ///
    ///   `bin_dir`:
    ///     The path of the site-packages tree.
    ///     Presumably ${home}/bin
    ///
    ///   `site_dir`:
    ///     The path of the site-packages tree.
    ///     Presumably ${home}/lib/python${python_version.major}.${python_version.minor}/site-packages
    ///
    ///   `python_bin`:
    ///     The path of the venv's interpreter.
    ///     Presumably ${bin_dir}/python3
    home_dir: PathBuf,
    version_info: PythonVersionInfo,
    bin_dir: PathBuf,
    site_dir: PathBuf,
    python_bin: PathBuf,
}

fn link(original: &PathBuf, link: &PathBuf) -> miette::Result<()> {
    let build_dir = current_dir().into_diagnostic()?;
    let original_abs = &build_dir.join(&original);
    let link_abs = &build_dir.join(&link);

    let original_relative = diff_paths(&original_abs, link_abs.parent().unwrap()).unwrap();

    fs::create_dir_all(link_abs.parent().unwrap())
        .into_diagnostic()
        .wrap_err("Unable to create link target dir")?;

    #[cfg(feature = "debug")]
    eprintln!(
        "L {} -> {}",
        link_abs.to_str().unwrap(),
        original_relative.to_str().unwrap(),
    );

    return unix_fs::symlink(original_relative, link_abs).into_diagnostic();
}

fn _copy(original: &PathBuf, link: &PathBuf) -> miette::Result<()> {
    let build_dir = current_dir().into_diagnostic()?;
    let original_abs = build_dir.join(original);
    let link_abs = build_dir.join(link);

    fs::create_dir_all(link_abs.parent().unwrap())
        .into_diagnostic()
        .wrap_err("Unable to create copy target dir")?;

    #[cfg(feature = "debug")]
    eprintln!(
        "C {} -> {}",
        link_abs.to_str().unwrap(),
        original_abs.to_str().unwrap(),
    );

    fs::copy(original_abs, link_abs).into_diagnostic()?;

    Ok(())
}

fn copy(original: &PathBuf, link: &PathBuf) -> miette::Result<()> {
    return _copy(original, link).wrap_err(format!(
        "Failed to copy {} to {}",
        original.to_str().unwrap(),
        link.to_str().unwrap()
    ));
}

const RELOCATABLE_SHEBANG: &str = "\
#!/bin/sh
'''exec' \"$(dirname -- \"$(realpath -- \"$0\")\")\"/'python3' \"$0\" \"$@\"
' '''
";

/// We used to go out to UV for this. Unfortunately due to the needs of
/// creating relocatable virtualenvs at Bazel action time, we can't "just"
/// use UV since it has hard-coded expectations around resolving interpreter
/// paths in ways we specifically want to avoid. So instead we've vendored a
/// bunch of that logic and do it manually.
///
/// The tree we want to create is as follows:
///
///     ./<venv>/
///       ./pyvenv.cfg                  t
///       ./bin/
///         ./python                    l ${PYTHON}
///         ./python3                   l ./python
///         ./python3.${VERSION_MINOR}  l ./python
///       ./lib                         d
///         ./python3.${VERSION_MINOR}  d
///           ./site-packages           d
///             ./_virtualenv.py        t
///             ./_virtualenv.pth       t
///
///
/// Issues:
/// - Do we _have_ to include activate scripts?
/// - Do we _have_ to include a versioned symlink?
pub fn create_empty_venv<'a>(
    repo: &'a str,
    python: &'a Path,
    version: PythonVersionInfo,
    location: &'a Path,
    env_file: Option<&'a Path>,
    venv_shim: Option<&'a Path>,
    debug: bool,
    include_system_site_packages: bool,
    include_user_site_packages: bool,
) -> miette::Result<Virtualenv> {
    let build_dir = current_dir().into_diagnostic()?;
    let home_dir = &build_dir.join(location.to_path_buf());

    let venv = Virtualenv {
        version_info: version,
        home_dir: home_dir.clone(),
        bin_dir: home_dir.clone().join("bin"),
        site_dir: home_dir.clone().join(format!(
            "lib/python{}.{}/site-packages",
            version.major, version.minor,
        )),
        python_bin: location.join("bin/python"),
    };

    let build_dir = current_dir().into_diagnostic()?;

    let home_dir_abs = &build_dir.join(&venv.home_dir);

    if home_dir_abs.exists() {
        // Clear down the an old venv if there is one present.
        fs::remove_dir_all(&home_dir_abs)
            .into_diagnostic()
            .wrap_err("Unable to remove venv_root directory")?;
    }

    // Create all the dirs down to the venv base
    fs::create_dir_all(&home_dir_abs)
        .into_diagnostic()
        .wrap_err("Unable to create base venv directory")?;

    let using_runfiles_interpreter = !python.exists() && venv_shim.is_some();

    let interpreter_cfg_snippet = if using_runfiles_interpreter {
        format!(
            "\
# Non-standard extension keys used by the Aspect shim
aspect-runfiles-interpreter = {0}
aspect-runfiles-repo = {1}
",
            python.display(),
            repo
        )
    } else {
        "".to_owned()
    };

    // Create the `pyvenv.cfg` file
    // FIXME: Should this come from the ruleset?
    fs::write(
        &venv.home_dir.join("pyvenv.cfg"),
        include_str!("pyvenv.cfg.tmpl")
            .replace("{{MAJOR}}", &venv.version_info.major.to_string())
            .replace("{{MINOR}}", &venv.version_info.minor.to_string())
            .replace("{{PATCH}}", &venv.version_info.patch.to_string())
            .replace("{{INTERPRETER}}", &interpreter_cfg_snippet)
            .replace(
                "{{INCLUDE_SYSTEM_SITE}}",
                &include_system_site_packages.to_string(),
            )
            .replace(
                "{{INCLUDE_USER_SITE}}",
                &include_user_site_packages.to_string(),
            ),
    )
    .into_diagnostic()?;

    fs::create_dir_all(&venv.bin_dir)
        .into_diagnostic()
        .wrap_err("Unable to create venv bin directory")?;

    // Create the `./bin/python` symlink. The other interpreter links will point
    // to this symlink, and this symlink needs to point out of the venv to an
    // interpreter binary.
    //
    // Assume that the path to `python` is relative to the _home_ of the venv,
    // and add the extra `..` to that path to drop the bin dir.

    if !python.exists() && venv_shim.is_none() {
        Err(miette!(
            "Specified interpreter {} doesn't exist!",
            python.to_str().unwrap()
        ))?
    }

    // If we've been provided with a venv shim, that gets put in place as
    // bin/python. Otherwise we copy the Python here
    match venv_shim {
        Some(ref shim_path) => {
            copy(&shim_path.to_path_buf(), &venv.python_bin)
                .wrap_err("Unable to create interpreter shim")?;

            let mut shim_perms = fs::metadata(&shim_path)
                .into_diagnostic()
                .wrap_err("Unable to read permissions for the interpreter shim")?
                .permissions();

            shim_perms.set_mode(0o755); // executable

            fs::set_permissions(&venv.python_bin, shim_perms)
                .into_diagnostic()
                .wrap_err("Unable to chmod interpreter shim")?;
        }

        None => {
            copy(&python.to_path_buf(), &venv.python_bin)
                .wrap_err("Unable to create interpreter")?;

            let mut interpreter_perms = fs::metadata(python)
                .into_diagnostic()
                .wrap_err("Unable to read permissions for the interpreter")?
                .permissions();

            interpreter_perms.set_mode(0o755); // executable

            fs::set_permissions(&venv.python_bin, interpreter_perms)
                .into_diagnostic()
                .wrap_err("Unable to chmod interpreter")?;
        }
    }
    // Create the two local links back to the python bin.

    {
        let python_n = venv
            .bin_dir
            .join(format!("python{}", venv.version_info.major));

        link(&venv.python_bin, &python_n)?;
    }

    {
        let python_nm = venv.bin_dir.join(format!(
            "python{}.{}",
            venv.version_info.major, venv.version_info.minor,
        ));
        link(&venv.python_bin, &python_nm)?;
    }

    {
        let envvars: String = match env_file {
            Some(env_file) => fs::read_to_string(env_file)
                .into_diagnostic()
                .wrap_err("Unable to read specified envvars file!")?,
            None => "".to_string(),
        };

        let envvars_unset = &envvars
            .lines()
            .filter_map(|line| line.find('=').map(|idx| line[..idx].trim()))
            .map(|var| format!("    unset {}", var))
            .collect::<Vec<_>>()
            .join("\n");

        fs::write(
            venv.bin_dir.join("activate"),
            include_str!("activate.tmpl")
                .replace("{{ENVVARS}}", &envvars)
                .replace("{{ENVVARS_UNSET}}", envvars_unset)
                .replace("{{DEBUG}}", if debug { &"set -x\n" } else { &"\n" }),
        )
        .into_diagnostic()
        .wrap_err("Unable to create activate script")?;
    }

    // Create the site dir
    fs::create_dir_all(&venv.site_dir)
        .into_diagnostic()
        .wrap_err("Unable to create venv site directory")?;

    // Populate the site dir with the required venv bits. Note that we're _only_
    // going to create the two conventional virtualenv stub files. Anything else
    // will need to be filled in by further processing.
    //
    // FIXME: Should the user be able to provide a custom venv patch?
    fs::write(
        &venv.site_dir.join("_virtualenv.py"),
        include_str!("_virtualenv.py"),
    )
    .into_diagnostic()?;

    fs::write(
        &venv.site_dir.join("_virtualenv.pth"),
        "import _virtualenv\n",
    )
    .into_diagnostic()?;

    Ok(venv)
}

/// The tricky bit is that we then need to create _dangling at creation time_
/// symlinks to where `.runfiles` entries _will_ be once the current action
/// completes.
///
/// The input `.pth` file specifies paths in the format
///
///     <workspace name>/<path>
///
/// These paths can exist in one of four places
/// 1. `./`                                 (source files in the same workspace)
/// 2. `./external`                         (source files in a different workspace)
/// 3. `./bazel-out/fastbuild/bin`          (generated files in this workspace)
/// 4. `./bazel-out/fastbuild/bin/external` (generated files in a different workspace)
///
/// In filling out a static symlink venv we have to:
///
/// 0. Be told by the caller what a relative path _from the venv root_ back up to the
///
/// 1. Go over every entry in the computed `.pth` list
///
/// 2. Identify entries which end in `site-packages`
///
/// 3. Compute a `.runfiles` time location for the root of that import
///
/// 4. For each of the two possible roots of that import (./, ./bazel-bin/,)
///    walk the directory tree there
///
/// 5. For every entry in that directory tree, take the path of that entry `e`
///
/// 6. Relativeize the path of the entry to the import root, `ip`
///
/// 7. Relativize the path of the entry to the `.runfiles` time workspace root `rp`
///
/// 6. Create an _unverified_ _dangling_ symlink in the venv.
///
///    At the time that we create these links the targets won't have been
///    emplaced yet. Bazel will create them when the `.runfiles` directory is
///    materialized by assembling all the input files.
///
///    The link needs to go up the depth of the target plus one to drop `_main`
///    or any other workspace name plus four for the site-packages prefix plus
///    the depth of the `ip` then back down to the workspace-relative path of
///    the target file.
pub fn populate_venv_with_copies(
    venv: Virtualenv,
    pth_file: PthFile,
    bin_dir: PathBuf,
    collision_strategy: CollisionResolutionStrategy,
) -> miette::Result<()> {
    // Assumes that `create_empty_venv` has already been called to build out the virtualenv.
    let dest = &venv.site_dir;

    // Get $PWD, which is the build working directory.
    let action_src_dir = current_dir().into_diagnostic()?;
    let main_module = action_src_dir.file_name().unwrap();
    let action_bin_dir = action_src_dir.join(bin_dir);

    #[cfg(feature = "debug")]
    eprintln!("action_src_dir: {}", &action_src_dir.to_str().unwrap());

    #[cfg(feature = "debug")]
    eprintln!("action_bin_dir: {}", &action_bin_dir.to_str().unwrap());

    let source_pth = File::open(pth_file.src.as_path())
        .into_diagnostic()
        .wrap_err("Unable to open source .pth file")?;

    let dest_pth = File::create(dest.join("_aspect.pth"))
        .into_diagnostic()
        .wrap_err("Unable to create destination .pth file")?;

    let mut dest_pth_writer = BufWriter::new(dest_pth);
    dest_pth_writer
        .write(
            b"\
# Generated by Aspect py_binary
# Contains relative import paths to non site-package trees within the .runfiles
",
        )
        .into_diagnostic()?;

    for line in BufReader::new(source_pth).lines().map_while(Result::ok) {
        //#[cfg(feature = "debug")]
        eprintln!("Got pth line {}", &line);

        let line = line.trim().to_string();
        // Entries should be of the form `<workspace>/<path>`, but may not have
        // a trailing `/` in the case of the default workspace root import that
        // sadly we're stuck with for now.
        let line = if line.find("/").is_some() {
            line
        } else {
            format!("{}/", line)
        };

        let Some((workspace, entry_path)) = line.split_once("/") else {
            return Err(miette!("Invalid path file entry!"));
        };

        #[cfg(feature = "debug")]
        eprintln!("Got pth entry @{}//{}", workspace, entry_path);

        let mut entry = PathBuf::from(entry_path);

        // FIXME: Handle other wheel install dirs like bin?
        if entry.file_name() == Some(OsStr::new("site-packages")) {
            #[cfg(feature = "debug")]
            eprintln!("Entry is site-packages...");

            // If the entry is external then we have to adjust the path
            if workspace != main_module {
                entry = PathBuf::from("external")
                    .join(PathBuf::from(workspace))
                    .join(entry)
            }

            // Copy library sources in
            for prefix in [&action_src_dir, &action_bin_dir] {
                let src_dir = prefix.join(&entry);
                if src_dir.exists() {
                    create_tree(&src_dir, &venv.site_dir, &collision_strategy)?;
                } else {
                    #[cfg(feature = "debug")]
                    eprintln!("Unable to find srcs under {}", src_dir.to_str().unwrap());
                }
            }

            // Copy scripts (bin entries) in
            let bin_dir = entry.parent().unwrap().join("bin");
            for prefix in [&action_src_dir, &action_bin_dir] {
                let src_dir = prefix.join(&bin_dir);
                if src_dir.exists() {
                    create_tree(&src_dir, &venv.bin_dir, &collision_strategy)?;
                }
            }
        } else {
            // Need to insert an appropriate pth file entry. Pth file lines
            // are relativized to the site dir [1] so here we need to take
            // the path from the site dir back to the root of the runfiles
            // tree and then append the entry to that relative path.
            //
            // This is the path from the venv's site-packages destination
            // "back up to" the bazel-bin dir we're building into, plus one
            // level.
            //
            // [1] https://github.com/python/cpython/blob/ce31ae5209c976d28d1c21fcbb06c0ae5e50a896/Lib/site.py#L215

            // aspect-build/rules_py#610
            //
            //   While these relative paths seem to work fine for _internal_
            //   runfiles within the `_main` workspace, problems occur when we
            //   try to take relative paths to _other_ workspaces because bzlmod
            //   may munge the directory names to be something that doesn't
            //   exist.
            let path_to_runfiles =
                diff_paths(&action_bin_dir, action_bin_dir.join(&venv.site_dir)).unwrap();

            writeln!(dest_pth_writer, "# @{}", line).into_diagnostic()?;
            writeln!(
                dest_pth_writer,
                "{}",
                path_to_runfiles.join(entry).to_str().unwrap()
            )
            .into_diagnostic()?;
        }
    }

    Ok(())
}

/// As an alternative to creating a unified symlink tree, create a `.pth` file
/// in the virtualenv which will use relative paths from the site-packages tree
/// to the configured import roots. At runtime this will cause the booting
/// interpreter to traverse up out of the venv and insert other workspaces'
/// site-packages trees (and potentially other import roots) onto the path.

#[expect(unused_variables)]
pub fn populate_venv_with_pth(
    venv: Virtualenv,
    pth_file: PthFile,
    bin_dir: PathBuf,
    collision_strategy: CollisionResolutionStrategy,
) -> miette::Result<()> {
    // Assumes that `create_empty_venv` has already been called to build out the virtualenv.

    Ok(())
}

/// TODO (arrdem 2025-06-04):
///   This needs to be refactored into a multi-pass solution for error handling
///   Pass 1: Collect sources, group by destination key
///   Pass 2: Report collision error(s) all at once
///   Pass 3: Create links

pub fn create_tree(
    original: &Path,
    link_dir: &Path,
    collision_strategy: &CollisionResolutionStrategy,
) -> miette::Result<()> {
    for entry in WalkDir::new(original) {
        if let Ok(entry) = entry {
            let original_entry = entry.into_path();
            let relative_entry = diff_paths(&original_entry, &original).unwrap();
            let link_entry = link_dir.join(&relative_entry);

            // link() makes dirs for us, but maybe it shouldn't. Do it manually here
            if original_entry.canonicalize().unwrap().is_dir() {
                continue;
            }
            // Specifically avoid linking in a <root>/__init__.py file
            else if relative_entry == PathBuf::from("__init__.py") {
                continue;
            }
            // Handle collisions, probably conflicting empty __init__.py files from Bazel
            else if link_entry.exists() {
                // If the _content_ of the files is the same then we have a
                // false collision, otherwise we have to do collision handling.

                let new_hash = try_digest(&original_entry).into_diagnostic()?;
                let existing_hash = try_digest(&link_entry).into_diagnostic()?;

                if new_hash != existing_hash {
                    match *collision_strategy {
                        CollisionResolutionStrategy::Error => {
                            return Err(miette!(
                                "Collision detected on venv element {}!",
                                relative_entry.to_str().unwrap()
                            ))
                        }
                        CollisionResolutionStrategy::LastWins(true) => {
                            eprintln!("Warning: Collision detected on venv element {}!\n  Last one wins is configured, continuing",
                            relative_entry.to_str().unwrap()
                        )
                        }
                        _ => {}
                    }
                }
            }

            // In the case of copying bin entries, we need to patch them. Yay.
            if link_dir.file_name() == Some(OsStr::new("bin")) {
                let mut content = fs::read_to_string(original_entry).into_diagnostic()?;
                if content.starts_with("#!/dev/null") {
                    content.replace_range(..0, &RELOCATABLE_SHEBANG);
                }
                fs::write(&link_entry, content).into_diagnostic()?;
            }
            // Normal case of needing to link a file :smile:
            else {
                copy(&original_entry, &link_entry)?;
            }
        }
    }

    Ok(())
}
