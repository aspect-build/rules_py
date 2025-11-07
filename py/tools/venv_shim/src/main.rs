mod pyargs;

use miette::{miette, Context, IntoDiagnostic, Result};
use runfiles::Runfiles;
use which::which;
// Depended on out of rules_rust
use std::env::{self, current_exe};
use std::ffi::OsStr;
use std::fs;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;

const PYVENV: &str = "pyvenv.cfg";

fn find_venv_root(exec_name: impl AsRef<Path>) -> Result<(PathBuf, PathBuf)> {
    let exec_name = exec_name.as_ref().to_owned();
    if let Some(parent) = exec_name.parent().and_then(|it| it.parent()) {
        let cfg = parent.join(PYVENV);
        if cfg.exists() {
            return Ok((parent.to_path_buf(), cfg));
        }
    }

    miette::bail!("Unable to identify a virtualenv home!");
}

#[derive(Debug)]
enum InterpreterConfig {
    Runfiles { rpath: String, repo: String },
    External { version: String },
}

#[derive(Debug)]
#[expect(dead_code)]
struct PyCfg {
    root: PathBuf,
    cfg: PathBuf,
    version_info: String,
    interpreter: InterpreterConfig,
    user_site: bool,
}

fn parse_venv_cfg(venv_root: &Path, cfg_path: &Path) -> Result<PyCfg> {
    let mut version: Option<String> = None;
    let mut bazel_interpreter: Option<String> = None;
    let mut bazel_repo: Option<String> = None;
    let mut user_site: Option<bool> = None;

    let cfg_file = fs::read_to_string(cfg_path).into_diagnostic()?;

    for (key, value) in cfg_file.lines().flat_map(|s| s.split_once("=")) {
        let key = key.trim();
        let value = value.trim();
        match key {
            "version_info" => {
                version = Some(value.to_string());
            }
            "aspect-runfiles-interpreter" => {
                bazel_interpreter = Some(value.to_string());
            }
            "aspect-runfiles-repo" => {
                bazel_repo = Some(value.to_string());
            }
            "aspect-include-user-site-packages" => {
                user_site = value.parse().ok();
            }
            // We don't care about other keys
            _ => continue,
        }
    }

    match (version, bazel_interpreter, bazel_repo) {
        (Some(version), Some(rloc), Some(repo)) => Ok(PyCfg {
            root: venv_root.to_path_buf(),
            cfg: cfg_path.to_path_buf(),
            version_info: version,
            interpreter: InterpreterConfig::Runfiles {
                rpath: rloc,
                repo: repo,
            },
            user_site: user_site.expect("User site flag not set!"),
        }),
        (Some(version), None, None) => Ok(PyCfg {
            root: venv_root.to_path_buf(),
            cfg: cfg_path.to_path_buf(),
            version_info: version.to_owned(),
            interpreter: InterpreterConfig::External {
                version: parse_version_info(&version).unwrap(),
            },
            user_site: user_site.expect("User site flag not set!"),
        }),
        (None, _, _) => miette::bail!("Invalid pyvenv.cfg file! no interpreter version specified!"),
        _ => {
            miette::bail!("Invalid pyvenv.cfg file! runfiles interpreter incompletely configured!")
        }
    }
}

fn parse_version_info(version_str: &str) -> Option<String> {
    // To avoid pulling in the regex crate, we're gonna do this by hand.
    let parts: Vec<_> = version_str.split(".").collect();
    match parts[..] {
        [major, minor, ..] => Some(format!("{}.{}", major, minor)),
        _ => None,
    }
}

fn compare_versions(version_from_cfg: &str, executable_path: &Path) -> bool {
    if let Some(file_name) = executable_path.file_name().and_then(|n| n.to_str()) {
        file_name.ends_with(&format!("python{}", version_from_cfg))
    } else {
        false
    }
}

fn find_python_executables(version_from_cfg: &str, exclude_dir: &Path) -> Option<Vec<PathBuf>> {
    let python_prefix = format!("python{}", version_from_cfg);
    let path_env = env::var_os("PATH")?;

    let binaries: Vec<_> = env::split_paths(&path_env)
        .filter_map(|path_dir| {
            let potential_executable = path_dir.join(&python_prefix);
            if potential_executable.exists() && potential_executable.is_file() {
                Some(potential_executable)
            } else {
                None
            }
        })
        .filter(|potential_executable| potential_executable.parent() != Some(exclude_dir))
        .filter(|potential_executable| compare_versions(version_from_cfg, potential_executable))
        .collect();

    if !binaries.is_empty() {
        Some(binaries)
    } else {
        None
    }
}

fn find_actual_interpreter(executable: impl AsRef<Path>, cfg: &PyCfg) -> Result<PathBuf> {
    match &cfg.interpreter {
        InterpreterConfig::External { version } => {
            // NOTE (reid@aspect.build):
            //
            //    Previously this codepath had machinery for walking the `$PATH`
            //    sequentially and handling re-entrant cases where the
            //    interpreter shim could accidentally re-select itself and
            //    recurse. This could cause infinite loops of this shim
            //    self-selecting without making progress.
            //
            //    The problem boils down to inconsistent canonicalization both
            //    of the `$PATH` entries and of the `argv[0]`/observed
            //    executable name. We rely on the executable name to find the
            //    bin dir to ignore, but doing so can incur canonicalization.
            //    Meanwhile `$PATH` entries are usually not canonicalized. This
            //    can produce behavior differences under Bazel, especially on
            //    Linux where more aggressive use of symlinks is made although
            //    production artifacts copied out of Bazel's sandboxing do ok.
            //
            //    To try and force progress (or at least an eventual failure)
            //    this code previously counted up using the offset counter to
            //    try each candidate interpreter successively.
            //
            //    That logic has optimistically been discarded. If this causes
            //    problems we'd put it back here.

            let Some(python_executables) = find_python_executables(&version, &cfg.root.join("bin"))
            else {
                miette::bail!(
                    "No suitable Python interpreter found in PATH matching version '{version}'."
                );
            };

            #[cfg(feature = "debug")]
            {
                eprintln!(
                    "[aspect] Found potential Python interpreters in PATH with matching version:"
                );
                for exe in &python_executables {
                    eprintln!("[aspect] - {:?}", exe);
                }
            }

            let Some(actual_interpreter_path) = python_executables.get(0) else {
                miette::bail!("Unable to find another interpreter!");
            };

            Ok(actual_interpreter_path.to_owned())
        }
        InterpreterConfig::Runfiles { rpath, repo } => {
            if let Ok(r) = Runfiles::create(&executable) {
                if let Some(interpreter) = r.rlocation_from(rpath.as_str(), &repo) {
                    Ok(PathBuf::from(interpreter))
                } else {
                    miette::bail!(format!(
                        "Unable to identify an interpreter for venv {:?}",
                        cfg.interpreter,
                    ));
                }
            } else {
                let exe_str = &executable.as_ref().to_str().unwrap();
                let action_root = if exe_str.contains("bazel-out") {
                    PathBuf::from(exe_str.split_once("bazel-out").unwrap().0)
                } else {
                    PathBuf::from(".")
                };
                for candidate in [
                    action_root.join("external").join(&rpath),
                    action_root
                        .join("bazel-out/k8-fastbuild/bin/external")
                        .join(&rpath),
                    action_root.join(&rpath),
                    action_root.join("bazel-out/k8-fastbuild/bin").join(&rpath),
                ] {
                    if candidate.exists() {
                        return Ok(candidate);
                    }
                }
                miette::bail!(format!(
                    "Unable to initialize runfiles and unable to identify action layout interpreter"
                ))
            }
        }
    }
}

fn main() -> Result<()> {
    let all_args: Vec<_> = env::args().collect();
    let Some((exec_name, exec_args)) = all_args.split_first() else {
        miette::bail!("could not discover an execution command-line");
    };

    // Alright this is a bit of a mess.
    //
    // There is a std::env::current_exe(), but it has platform dependent
    // behavior. Some platforms realpath the invocation binary, some don't, it's
    // a mess for our purposes when we REALLY want to avoid dereferencing links.
    //
    // So we have to do this manually. There are three cases:
    // 1. `/foo/bar/python3` via absolute path
    // 2. `./foo/bar/python3` via relative path
    // 3. `python3` via $PATH lookup
    //
    // If the `exec_name` (raw `argv[0]`) is absolute, use that. Otherwise try
    // to relativize, otherwise fall back to $PATH lookup.
    //
    // This lets us get a "raw" un-dereferenced path to the start of any
    // potential symlink chain so that we can then do our symlink chain dance.
    let mut executable = PathBuf::from(exec_name);
    #[cfg(feature = "debug")]
    eprintln!("interp {:?}", executable);
    let cwd = std::env::current_dir().into_diagnostic()?;
    if !executable.is_absolute() {
        let candidate = cwd.join(&executable);
        if candidate.exists()
            && !candidate.is_dir()
            && candidate.canonicalize().unwrap() == current_exe().unwrap().canonicalize().unwrap()
        {
            executable = candidate;
            #[cfg(feature = "debug")]
            eprintln!("       {:?}", executable);
        } else if let Ok(exe) = which(&exec_name) {
            executable = exe;
            #[cfg(feature = "debug")]
            eprintln!("       {:?}", executable);
        } else {
            return Err(miette!("Unable to identify the real interpreter path!"));
        }
    }

    // Now, if we _don't_ have the `.runfiles` part in the interpreter path,
    // then we have to go through the path parts and try resolving the _first_
    // link which sequentially exists in the path.
    let mut changed = true;
    while changed
        && !executable.components().any(|it| {
            it.as_os_str()
                .to_str()
                .expect(&format!("Failed to normalize {:?} as a str", it))
                .ends_with(".runfiles")
        })
    {
        changed = false;
        // Ancestors is in iterated .parent order, but we want to go the other
        // way. We want to resolve the deepest link first on the expectation
        // that the target file itself is likely a link which escapes a runfiles
        // tree, whereas some part of the invocation path is a symlink to the
        // venv tree within a runfiles tree. Ancestors isn't double ended so we
        // have to collect it first.
        for parent in executable.ancestors().collect::<Vec<_>>().into_iter().rev() {
            if parent.is_symlink() {
                // Find the stable tail we want to preserve
                let suffix = executable.strip_prefix(parent).into_diagnostic()?;
                // Resolve the link we identified
                let parent = parent
                    .parent()
                    .expect(&format!("Failed to take the parent of {:?}", parent))
                    .join(parent.read_link().into_diagnostic()?);
                // And join the tail to the resolved head
                executable = parent.join(suffix);
                #[cfg(feature = "debug")]
                eprintln!("       {:?}", executable);

                changed = true;
                break;
            }
        }
        if changed {
            break;
        }
    }

    #[cfg(feature = "debug")]
    eprintln!("final  {:?}", executable);

    // Now that we've identified where the .runfiles venv really is, we want to
    // use that as the basis for configuring our virtualenv and setting
    // everything else up.
    let (venv_root, venv_cfg) = find_venv_root(&executable)?;
    #[cfg(feature = "debug")]
    eprintln!("[aspect] venv root {:?} venv.cfg {:?}", venv_root, venv_cfg);

    let venv_config = parse_venv_cfg(&venv_root, &venv_cfg)?;
    #[cfg(feature = "debug")]
    eprintln!("[aspect] {:?}", venv_config);

    // The logical path of the interpreter
    let venv_interpreter = venv_root.join("bin/python3");
    #[cfg(feature = "debug")]
    eprintln!("[aspect] {:?}", venv_interpreter);

    let actual_interpreter = find_actual_interpreter(&executable, &venv_config)?
        .canonicalize()
        .into_diagnostic()?;

    #[cfg(feature = "debug")]
    eprintln!(
        "[aspect] Attempting to execute: {:?} with argv[0] as {:?} and args as {:?}",
        &actual_interpreter, &venv_interpreter, exec_args,
    );

    let mut cmd = Command::new(&actual_interpreter);
    let cmd = cmd
        // Pass along our args
        .args(pyargs::reparse_args(
            &exec_args.iter().map(|it| it.as_ref()).collect(),
        )?)
        // Lie about the value of argv0 to hoodwink the interpreter as to its
        // location on Linux-based platforms.
        .arg0(&venv_interpreter)
        // Pseudo-`activate`
        .env("VIRTUAL_ENV", &venv_root);

    let venv_bin = (&venv_root).join("bin");
    // TODO(arrdem|myrrlyn): PATHSEP is : on Unix and ; on Windows
    if let Ok(path) = env::var("PATH") {
        let mut path_segments = path
            .split(":") // break into individual entries
            .filter(|&p| !p.is_empty()) // skip over `::`, which is possible
            .map(ToOwned::to_owned) // we're dropping the big string, so own the fragments
            .collect::<Vec<_>>(); // and save them.
        let need_venv_in_path = path_segments
            .iter()
            .find(|&p| OsStr::new(p) == &venv_bin)
            .is_none();
        if need_venv_in_path {
            // append to back
            path_segments.push(venv_bin.to_string_lossy().into_owned());
            // then move venv_bin to the front of PATH
            path_segments.rotate_right(1);
            // and write into the child environment. this avoids an empty PATH causing us to write `{venv_bin}:` with a trailing colon
            cmd.env("PATH", path_segments.join(":"));
        }
    }

    // Set the executable pointer for MacOS, but we do it consistently
    cmd.env("PYTHONEXECUTABLE", &venv_interpreter);

    // Clobber VIRTUAL_ENV which may have been set by activate to an unresolved path
    cmd.env("VIRTUAL_ENV", &venv_root);

    // Similar to `-s` but this avoids us having to muck with the argv in ways
    // that could be visible to the called program.
    if !venv_config.user_site {
        cmd.env("PYTHONNOUSERSITE", "1");
    }

    // Set the interpreter home to the resolved install base. This works around
    // the home = property in the pyvenv.cfg being wrong because we don't
    // (currently) have a good way to map the interpreter rlocation to a
    // relative path.
    let home = &actual_interpreter
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .canonicalize()
        .into_diagnostic()
        .wrap_err("Failed to canonicalize the interpreter home")?;

    #[cfg(feature = "debug")]
    eprintln!("Setting PYTHONHOME to {home:?} for {actual_interpreter:?}");
    cmd.env("PYTHONHOME", home);

    let mut hasher = DefaultHasher::new();
    venv_interpreter.to_str().unwrap().hash(&mut hasher);
    home.to_str().unwrap().hash(&mut hasher);

    cmd.env("ASPECT_PY_VALIDITY", format!("{}", hasher.finish()));

    // For the future, we could read, validate and reuse the env state.
    //
    // if let Ok(home) = env::var("PYTHONHOME") {
    //     if let Ok(executable) = env::var("PYTHONEXECUTABLE") {
    //         if let Ok(checksum) = env::var("ASPECT_PY_VALIDITY") {
    //             let mut hasher = DefaultHasher::new();
    //             executable.hash(&mut hasher);
    //             home.hash(&mut hasher);
    //             if checksum == format!("{}", hasher.finish()) {
    //                 return Ok(PathBuf::from(home).join("bin/python3"));
    //             }
    //         }
    //     }
    // }

    // And punt
    let err = cmd.exec();
    miette::bail!(
        "Failed to exec target {}, {}",
        actual_interpreter.display(),
        err,
    )
}
