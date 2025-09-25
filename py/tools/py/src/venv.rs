use crate::{
    pth::{CollisionResolutionStrategy, SitePackageOptions},
    PthFile,
};
use itertools::Itertools;
use miette::{miette, Context, IntoDiagnostic};
use pathdiff::diff_paths;
use std::{
    collections::HashMap,
    env::current_dir,
    fs::{self, File},
    io::{BufRead, BufReader, BufWriter, SeekFrom, Write},
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
};
use std::{fmt::Debug, os::unix::fs as unix_fs};
use std::{
    io,
    io::{ErrorKind, Read, Seek},
};
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

fn link<A: AsRef<Path>, B: AsRef<Path>>(original: A, link: B) -> miette::Result<()> {
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

fn copy<A: AsRef<Path>, B: AsRef<Path>>(original: A, link: B) -> miette::Result<()> {
    let build_dir = current_dir().into_diagnostic()?;
    let original_abs = build_dir.join(&original);
    let link_abs = build_dir.join(&link);

    fs::create_dir_all(link_abs.parent().unwrap())
        .into_diagnostic()
        .wrap_err("Unable to create copy target dir")?;

    #[cfg(feature = "debug")]
    eprintln!(
        "C {} -> {}",
        link_abs.to_str().unwrap(),
        original_abs.to_str().unwrap(),
    );

    fs::copy(original_abs, link_abs)
        .into_diagnostic()
        .wrap_err(format!(
            "Failed to copy {} to {}",
            original.as_ref().to_str().unwrap(),
            link.as_ref().to_str().unwrap()
        ))?;

    Ok(())
}

// Matches entrypoints that have had their interpreter "fixed" by rules_python.
const SHEBANGS: [&[u8]; 6] = [
    // rules_python uses this as a placeholder.
    // https://github.com/bazel-contrib/rules_python/blob/cd6948a0f706e75fa0f3ebd35e485aeec3e299fc/python/private/pypi/whl_installer/wheel.py#L319C13-L319C24
    b"#!/dev/null",
    // Note that we don't need to cover the cases of `python3` or `python3.X`
    // because we search forwards for the first newline and use that as the
    // basis for truncation.
    //
    // This is the basis for the conventional "correct" shebang
    b"#!/usr/bin/env python",
    // These are common hardcoded interpreters which are arguably wrong but may
    // occur.
    b"#!python",
    b"#!/bin/python",
    b"#!/usr/bin/python",
    b"#!/usr/local/bin/python",
];

// This is a total kludge. It's a shebang which uses the shell in order to
// identify the "python3" file in the same directory and punt to that.
const RELOCATABLE_SHEBANG: &[u8] = b"\
#!/bin/sh
'''exec' \"$(dirname -- \"$(realpath -- \"$0\")\")\"/'python3' \"$0\" \"$@\"
' '''
";

fn copy_and_patch_shebang<A: AsRef<Path>, B: AsRef<Path>>(
    original: A,
    link: B,
) -> miette::Result<()> {
    let mut src = File::open(original.as_ref()).into_diagnostic()?;

    let mut buf = [0u8; 64];
    let found_shebang = match src.read_exact(&mut buf) {
        // Must contain a shebang
        Ok(()) => SHEBANGS.iter().any(|it| buf.starts_with(it)),
        Err(error) => match error.kind() {
            ErrorKind::UnexpectedEof => false, // File too short to contain shebang.
            _ => Err(error).into_diagnostic()?,
        },
    };
    let newline: u64 = if found_shebang {
        buf.iter()
            .find_position(|it| **it == 0x0A)
            .map(|it| it.0 as u64)
            .unwrap_or(0u64)
    } else {
        0
    };

    let mut dst = File::create(link.as_ref()).into_diagnostic()?;
    if found_shebang {
        // Dump the relocatable shebang first
        dst.write_all(RELOCATABLE_SHEBANG).into_diagnostic()?;
    }

    // Copy everything _after_ the first newline into the dest file.
    src.seek(SeekFrom::Start(newline)).into_diagnostic()?;
    io::copy(&mut src, &mut dst).into_diagnostic()?;

    // Finally we need to sync permissions from the one to the other.
    let mut perms = fs::metadata(original).into_diagnostic()?.permissions();
    // Force the executable bit(s) if we copied something with a shebang.
    if found_shebang {
        perms.set_mode(0o755)
    }
    fs::set_permissions(link, perms).into_diagnostic()
}

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
            copy(&shim_path, &venv.python_bin).wrap_err("Unable to create interpreter shim")?;

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
            copy(python, &venv.python_bin).wrap_err("Unable to create interpreter")?;

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

        link(&venv.python_bin, python_n)?;
    }

    {
        let python_nm = venv.bin_dir.join(format!(
            "python{}.{}",
            venv.version_info.major, venv.version_info.minor,
        ));
        link(&venv.python_bin, python_nm)?;
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

#[derive(Debug, Clone)]
pub enum Command {
    // Implies create_dir_all for the dest's parents
    Copy { src: PathBuf, dest: PathBuf },
    // Implies create_dir_all for the dest's parents. Specialized for handling
    // binaries which _specifically_ go to the bin/ dir and may need their
    // shebang replaced with the relocatable one.
    CopyAndPatch { src: PathBuf, dest: PathBuf },
    // Implies create_dir_all for the dest's parents
    Symlink { src: PathBuf, dest: PathBuf },
    PthEntry { path: PathBuf },
}

pub trait PthEntryHandler {
    fn plan(
        &self,
        venv: &Virtualenv,
        bin_dir: &Path,
        entry_repo: &str,
        entry_path: &Path,
    ) -> miette::Result<Vec<Command>>;
}

/// Just put all import roots into a `.pth` file and call it a day. Minimum I/O
/// load, generally correct. Doesn't handle bin dirs or try to decide whether
/// the current import path represents a "package install".
///
/// This is appropriate for 1stparty code, and if applied to 3rdparty code then
/// the default `rules_python` $PYTHONPATH behavior is effectively emulated.
pub struct PthStrategy;
impl PthEntryHandler for PthStrategy {
    fn plan(
        &self,
        venv: &Virtualenv,
        bin_dir: &Path,
        entry_repo: &str,
        entry_path: &Path,
    ) -> miette::Result<Vec<Command>> {
        let action_src_dir = current_dir().into_diagnostic()?;
        let action_bin_dir = action_src_dir.join(bin_dir);

        // This diff goes up to the root of the _main repo's runfiles, need to go up one more.
        let path_to_runfiles = diff_paths(&action_bin_dir, action_bin_dir.join(&venv.site_dir))
            .unwrap()
            .join("..");

        Ok(vec![Command::PthEntry {
            path: path_to_runfiles.join(entry_repo).join(entry_path),
        }])
    }
}

/// A really bad but functional idea.
///
/// Just copy everything into the venv. Has horrible I/O characteristics and
/// will trash your Bazel cache, but you can do this. Pth and symlinks are
/// generally much better choices.
#[derive(Copy, Clone)]
pub struct CopyStrategy;
impl PthEntryHandler for CopyStrategy {
    fn plan(
        &self,
        venv: &Virtualenv,
        bin_dir: &Path,
        entry_repo: &str,
        entry_path: &Path,
    ) -> miette::Result<Vec<Command>> {
        // Assumes that `create_empty_venv` has already been called to build out the virtualenv.
        let dest = &venv.site_dir;
        let action_src_dir = current_dir().into_diagnostic()?;
        let action_bin_dir = action_src_dir.join(bin_dir);

        let mut plan: Vec<Command> = Vec::new();

        for prefix in [&action_src_dir, &action_bin_dir] {
            let src_dir = prefix.join(entry_repo).join(&entry_path);
            if src_dir.exists() {
                for entry in WalkDir::new(&src_dir) {
                    if let Ok(entry) = entry {
                        // We ignore directories; they are created implicitly.
                        if entry.file_type().is_dir() {
                            continue;
                        }
                        plan.push(Command::Copy {
                            src: entry.clone().into_path(),
                            dest: dest.join(entry.into_path().strip_prefix(&src_dir).unwrap()),
                        })
                    }
                }
            }
        }

        Ok(plan)
    }
}

/// A slightly better idea.
///
/// Just copy _and patch_ binaries into the venv so they become usable.
#[derive(Clone)]
pub struct CopyAndPatchStrategy;
impl PthEntryHandler for CopyAndPatchStrategy {
    fn plan(
        &self,
        venv: &Virtualenv,
        bin_dir: &Path,
        entry_repo: &str,
        entry_path: &Path,
    ) -> miette::Result<Vec<Command>> {
        // Assumes that `create_empty_venv` has already been called to build out the virtualenv.
        let dest = &venv.site_dir;
        let action_src_dir = current_dir().into_diagnostic()?;
        let action_bin_dir = action_src_dir.join(bin_dir);

        let mut plan: Vec<Command> = Vec::new();

        for prefix in [&action_src_dir, &action_bin_dir] {
            let src_dir = prefix.join(entry_repo).join(&entry_path);
            if src_dir.exists() {
                for entry in WalkDir::new(&src_dir) {
                    if let Ok(entry) = entry {
                        if entry.file_type().is_dir() && entry.clone().into_path() != src_dir {
                            return Err(miette!("Bindir contained unsupported subdirs!"));
                        }
                        plan.push(Command::CopyAndPatch {
                            src: entry.clone().into_path(),
                            dest: dest.join(entry.into_path().strip_prefix(&src_dir).unwrap()),
                        })
                    }
                }
            }
        }

        Ok(plan)
    }
}

/// A better idea.
///
/// Rather than copying everything into the venv, instead lay out a symlin
/// forrest. Still creates a bunch of nodes in the filesystem, but will at least
/// do so very very cheaply.
#[derive(Clone)]
pub struct SymlinkStrategy;
impl PthEntryHandler for SymlinkStrategy {
    fn plan(
        &self,
        venv: &Virtualenv,
        bin_dir: &Path,
        entry_repo: &str,
        entry_path: &Path,
    ) -> miette::Result<Vec<Command>> {
        // Assumes that `create_empty_venv` has already been called to build out the virtualenv.
        let dest = &venv.site_dir;
        let action_src_dir = current_dir().into_diagnostic()?;
        let main_repo = action_src_dir.file_name().unwrap();
        let action_bin_dir = action_src_dir.join(bin_dir);

        let mut plan: Vec<Command> = Vec::new();

        for prefix in [&action_src_dir, &action_bin_dir] {
            let mut src_dir = prefix.to_owned();
            if main_repo != entry_repo {
                src_dir = src_dir.join("external").join(&entry_repo)
            }
            src_dir = src_dir.join(&entry_path);
            if src_dir.exists() {
                for entry in WalkDir::new(&src_dir) {
                    if let Ok(entry) = entry {
                        if entry.file_type().is_dir() {
                            continue;
                        }
                        plan.push(Command::Symlink {
                            src: entry.clone().into_path(),
                            dest: dest.join(entry.into_path().strip_prefix(&src_dir).unwrap()),
                        })
                    }
                }
            }
        }

        Ok(plan)
    }
}

#[derive(Clone)]
pub struct FirstpartyThirdpartyStrategy<A: PthEntryHandler, B: PthEntryHandler> {
    pub firstparty: A,
    pub thirdparty: B,
}
impl<A: PthEntryHandler, B: PthEntryHandler> PthEntryHandler
    for FirstpartyThirdpartyStrategy<A, B>
{
    fn plan(
        &self,
        venv: &Virtualenv,
        bin_dir: &Path,
        entry_repo: &str,
        entry_path: &Path,
    ) -> miette::Result<Vec<Command>> {
        let action_src_dir = current_dir().into_diagnostic()?;
        let main_repo = action_src_dir.file_name().unwrap();
        let strat: &dyn PthEntryHandler = if entry_repo != main_repo {
            &self.thirdparty
        } else {
            &self.firstparty
        };
        strat.plan(venv, bin_dir, entry_repo, entry_path)
    }
}

#[derive(Clone)]
pub struct SrcSiteStrategy<A: PthEntryHandler, B: PthEntryHandler, C: AsRef<Path>> {
    pub src_strategy: A,
    pub site_suffixes: Vec<C>,
    pub site_strategy: B,
}
impl<A: PthEntryHandler, B: PthEntryHandler, C: AsRef<Path>> PthEntryHandler
    for SrcSiteStrategy<A, B, C>
{
    fn plan(
        &self,
        venv: &Virtualenv,
        bin_dir: &Path,
        entry_repo: &str,
        entry_path: &Path,
    ) -> miette::Result<Vec<Command>> {
        if self
            .site_suffixes
            .iter()
            .any(|it| entry_path.as_ref().ends_with(it))
        {
            return self
                .site_strategy
                .plan(venv, bin_dir, entry_repo, entry_path);
        } else {
            return self
                .src_strategy
                .plan(venv, bin_dir, entry_repo, entry_path);
        }
    }
}

#[derive(Clone)]
pub struct StrategyWithBindir<A: PthEntryHandler, B: PthEntryHandler> {
    pub root_strategy: A,
    pub bin_strategy: B,
}
impl<A: PthEntryHandler, B: PthEntryHandler> PthEntryHandler for StrategyWithBindir<A, B> {
    fn plan(
        &self,
        venv: &Virtualenv,
        bin_dir: &Path,
        entry_repo: &str,
        entry_path: &Path,
    ) -> miette::Result<Vec<Command>> {
        // Assumes that `create_empty_venv` has already been called to build out the virtualenv.
        let action_src_dir = current_dir().into_diagnostic()?;
        let action_bin_dir = action_src_dir.join(&bin_dir);

        let mut plan: Vec<Command> = Vec::new();
        plan.append(
            &mut self
                .root_strategy
                .plan(venv, &bin_dir, entry_repo, &entry_path)?,
        );

        let entry_bin = entry_path.parent().unwrap().join("bin");
        let found_bin_dir = [&action_src_dir, &action_bin_dir]
            .iter()
            .map(|pfx| pfx.join(entry_repo).join(&entry_bin))
            .any(|p| p.exists());
        if found_bin_dir {
            plan.append(
                &mut self
                    .bin_strategy
                    .plan(venv, bin_dir, entry_repo, &entry_bin)?,
            );
        }

        Ok(plan)
    }
}

pub fn populate_venv(
    venv: Virtualenv,
    pth_file: PthFile,
    bin_dir: impl AsRef<Path>,
    population_strategy: &dyn PthEntryHandler,
    collision_strategy: CollisionResolutionStrategy,
) -> miette::Result<()> {
    let mut plan: Vec<Command> = Vec::new();

    let source_pth = File::open(pth_file.src.as_path())
        .into_diagnostic()
        .wrap_err("Unable to open source .pth file")?;

    for line in BufReader::new(source_pth).lines().map_while(Result::ok) {
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

        plan.append(&mut population_strategy.plan(
            &venv,
            bin_dir.as_ref(),
            entry_repo,
            entry_path.as_ref(),
        )?);
    }

    let mut planned_destinations: HashMap<PathBuf, Vec<Command>> = HashMap::new();
    for command in &plan {
        match command {
            // Prevent commands from accidentally recursing into the venv, for
            // instance symlinking or copying out of the venv back into itself.
            Command::Copy { src, .. }
            | Command::CopyAndPatch { src, .. }
            | Command::Symlink { src, .. }
                if (src.starts_with(&venv.home_dir)) =>
            {
                continue;
            }
            // Group remaining commands by their dest path.
            Command::Copy { dest, .. }
            | Command::CopyAndPatch { dest, .. }
            | Command::Symlink { dest, .. }
            | Command::PthEntry { path: dest } => {
                planned_destinations
                    .entry(dest.clone())
                    .or_insert_with(Vec::new)
                    .push(command.clone());
            }
        };
    }

    // Check for collisions and report all of them
    let mut had_collision = false;
    let emit_error = match collision_strategy {
        CollisionResolutionStrategy::Error => true,
        CollisionResolutionStrategy::LastWins(it) => it,
    };

    // Drain the plan, we'll refill it to contain only last-wins instructions.
    plan = Vec::new();

    for (dest, sources) in planned_destinations.iter() {
        // We ignore __init__.py files at import roots. They're entirely
        // erroneous and a result of --legacy_creat_init_files which has all
        // sorts of problems.
        if dest.ends_with("site-packages/__init__.py")
            || dest.ends_with("dist-packages/__init__.py")
        {
            continue;
        }

        // Refill the plan
        plan.push(sources.last().unwrap().clone());

        // Handle duplicates
        if sources.len() > 1 {
            if dest.ends_with("__init__.py") {
                // FIXME: Take care of __init__.py files colliding here.
                //
                // __init__.py files are extremely troublesome because there are a
                // bunch of possible marker files, some of which have the same
                // logical behavior and some of which very much do not.
                //
                // Possible __init__.py content with no operational value
                // - empty
                // - whitespace
                // - shebang
                // - comment
                //
                // Possible __init__.py content with operational value
                // - docstring
                // - arbitrary code
                //   - __all__ manipulation
                //   - imports
                //   - extend_path https://docs.python.org/3/library/pkgutil.html#pkgutil.extend_path
                //
                // It's obviously correct to ignore an __init__.py collision if
                // all the colliding files have the same content. It doesn't
                // matter which one we pick. In any other case there isn't a
                // generally reasonable argument for ignoring files. Maybe we
                // could fully normalize files containing comments, but that
                // seems like a waste of effort.
            }
            had_collision = true;
            eprintln!("Collision detected at destination: {}", dest.display());
            for source in sources {
                match source {
                    Command::Copy { src, .. } | Command::CopyAndPatch { src, .. } => {
                        if emit_error {
                            eprintln!("  - Source: {} (Copy)", src.display())
                        }
                    }
                    Command::Symlink { src, .. } => {
                        if emit_error {
                            eprintln!("  - Source: {} (Symlink)", src.display())
                        }
                    }
                    _ => {}
                }
            }
        }
    }

    if had_collision && collision_strategy == CollisionResolutionStrategy::Error {
        return Err(miette!("Multiple collisions detected. Aborting."));
    }

    let dest_pth = File::create(&venv.site_dir.join("_aspect.pth"))
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

    // The plan has now been uniq'd by destination, execute it
    for command in plan {
        match command {
            Command::Copy { src, dest } => {
                fs::create_dir_all(&dest.parent().unwrap()).into_diagnostic()?;
                fs::copy(&src, &dest).into_diagnostic()?;
            }
            Command::CopyAndPatch { src, dest } => {
                fs::create_dir_all(&dest.parent().unwrap()).into_diagnostic()?;
                copy_and_patch_shebang(src, dest)?;
            }
            Command::Symlink { src, dest } => {
                fs::create_dir_all(&dest.parent().unwrap()).into_diagnostic()?;

                // The sandboxing strategy for actions is to create a forest of
                // symlinks. If we create a symlink (dest) pointing to a symlink
                // (src) we're assuming that the src won't be removed sometime
                // down the line. But sandboxes are ephemeral, so this leaves us
                // open to heisenbugs.
                //
                // What Bazel does guarantee is the _relative tree structure_
                // between our output file(s) and the input(s) used to generate
                // them. So while we can't sanely just write absolute paths into
                // symlinks we can write reative paths.
                //
                // Note that the relative path we need is the relative path from
                // the _dir of the destination_ to the source file, since the
                // way symlinks are resolved is that the readlink value is
                // joined to the dirname. Without explicitly taking the parent
                // we're off by 1.
                let resolved = diff_paths(&src, &dest.parent().unwrap()).unwrap();
                unix_fs::symlink(&resolved, &dest).into_diagnostic()?;
            }
            Command::PthEntry { path } => {
                writeln!(dest_pth_writer, "{}", path.to_str().unwrap()).into_diagnostic()?;
            }
        }
    }

    Ok(())
}
