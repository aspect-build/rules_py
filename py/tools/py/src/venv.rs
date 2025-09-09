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
///             ./_00_virtualenv.pth    t
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

/// Poppulate the virtualenv with files from installed packages.
///
/// Bazel handles symlinks inside TreeArtifacts at least as of 8.4.0 and before
/// by converting them into copies of the link targets. This prevents us from
/// creating a forrest of symlinks directly as `rules_python` does. Instead we
/// settle for copying files out of the install external repos and into the venv.
///
/// This is inefficient but it does have the advantage of avoiding potential
/// issues around `realpath(__file__)` causing escapes from the venv root.
///
/// In order to handle internal imports (eg. not from external `pip`) we also
/// generate a `_aspect.bzlpth` file which contains Bazel label (label prefixes
/// technically) which can be materialized into import roots against the
/// runfiles structure at interpreter startup time. This allows for behavior
/// similar to the original `rules_python` strategy of just shoving a bunch of
/// stuff into the `$PYTHONPATH` while sidestepping issues around blowing up the
/// env/system arg limits.
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
///             ./_aspect.py            t
///             ./_aspect.bzlpth        t
///             ./<included subtrees>

// TODO: Need to rework this so that what gets copied vs what gets added to the
// pth is controlled by some sort of pluggable policy.
pub fn populate_venv_with_copies(
    repo: &str,
    venv: Virtualenv,
    pth_file: PthFile,
    bin_dir: PathBuf,
    collision_strategy: CollisionResolutionStrategy,
) -> miette::Result<()> {
    // Assumes that `create_empty_venv` has already been called to build out the virtualenv.
    let dest = &venv.site_dir;

    // Get $PWD, which is the build working directory.
    let action_src_dir = current_dir().into_diagnostic()?;
    let action_bin_dir = action_src_dir.join(bin_dir);

    #[cfg(feature = "debug")]
    eprintln!("action_src_dir: {}", &action_src_dir.to_str().unwrap());

    #[cfg(feature = "debug")]
    eprintln!("action_bin_dir: {}", &action_bin_dir.to_str().unwrap());

    // Add our own venv initialization plugin that's designed to handle the bzlpth mess
    fs::write(&venv.site_dir.join("_aspect.pth"), "import _aspect\n").into_diagnostic()?;
    fs::write(
        &venv.site_dir.join("_aspect.py"),
        include_str!("_aspect.py"),
    )
    .into_diagnostic()?;

    let dest_pth = File::create(dest.join("_aspect.bzlpth"))
        .into_diagnostic()
        .wrap_err("Unable to create destination .bzlpth file")?;

    let mut dest_pth_writer = BufWriter::new(dest_pth);
    dest_pth_writer
        .write(
            b"\
# Generated by Aspect py_venv_*
# Contains Bazel runfiles path suffixes to import roots
# See _aspect.py for the relevant processing machinery
",
        )
        .into_diagnostic()?;

    let source_pth = File::open(pth_file.src.as_path())
        .into_diagnostic()
        .wrap_err("Unable to open source .pth file")?;

    for line in BufReader::new(source_pth).lines().map_while(Result::ok) {
        #[cfg(feature = "debug")]
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

        let Some((entry_repo, entry_path)) = line.split_once("/") else {
            return Err(miette!("Invalid path file entry!"));
        };

        #[cfg(feature = "debug")]
        eprintln!("Got pth entry @{}//{}", entry_repo, entry_path);

        let mut entry = PathBuf::from(entry_path);

        // FIXME: Handle other wheel install dirs like bin?
        match entry.file_name().map(|it| it.to_str().unwrap()) {
            // FIXME: dist-packages is a Debian-ism that exists in some customer
            // environments. It would be better if we could manage to make this
            // decison a policy under user controll. Hard-coding for now.
            Some("site-packages") | Some("dist-packages") => {
                #[cfg(feature = "debug")]
                eprintln!("Entry is site-packages...");

                // If the entry is external then we have to adjust the path
                // FIXME: This isn't quite right outside of bzlmod
                if entry_repo != repo {
                    entry = PathBuf::from("external")
                        .join(PathBuf::from(entry_repo))
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
            }
            _ => {
                if entry_repo != repo {
                    eprintln!(
                        "Warning: @@{entry_repo}//{entry_path}/... included via pth rather than copy"
                    )
                }
                // The path to the runfiles root is _one more than_ the relative
                // oath from the venv's target dir to the root of the module
                // containing the venv.
                let path_to_runfiles =
                    diff_paths(&action_bin_dir, action_bin_dir.join(&venv.site_dir))
                        .unwrap()
                        .join("../");

                writeln!(dest_pth_writer, "# @{}", line).into_diagnostic()?;
                writeln!(
                    dest_pth_writer,
                    "{}",
                    path_to_runfiles // .runfiles
                        .join(entry_repo) // ${REPO}
                        .join(entry_path) // ${PATH}
                        .to_str()
                        .unwrap()
                )
                .into_diagnostic()?;
            }
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
    repo: &str,
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
