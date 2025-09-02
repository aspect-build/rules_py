use miette::IntoDiagnostic;
use runfiles::Runfiles;
// Depended on out of rules_rust
use std::env;
use std::ffi::OsStr;
use std::fs;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;

const PYVENV: &str = "pyvenv.cfg";

fn find_venv_root(exec_name: impl AsRef<Path>) -> miette::Result<(PathBuf, PathBuf)> {
    if let Ok(it) = env::var("VIRTUAL_ENV") {
        let root = PathBuf::from(it);
        let cfg = root.join(PYVENV);
        if cfg.exists() {
            return Ok((root, cfg));
        } else {
            eprintln!("Warning: $VIRTUAL_ENV is set but seems to be invalid; ignoring")
        }
    }

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

fn parse_venv_cfg(venv_root: &Path, cfg_path: &Path) -> miette::Result<PyCfg> {
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

fn find_actual_interpreter(cfg: &PyCfg) -> miette::Result<PathBuf> {
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
            let r = Runfiles::create().unwrap();
            if let Some(interpreter) = r.rlocation_from(rpath.as_str(), &repo) {
                Ok(PathBuf::from(interpreter))
            } else {
                miette::bail!(format!(
                    "Unable to identify an interpreter for venv {:?}",
                    cfg.interpreter,
                ));
            }
        }
    }
}

fn main() -> miette::Result<()> {
    let all_args: Vec<_> = env::args().collect();
    let Some((exec_name, exec_args)) = all_args.split_first() else {
        miette::bail!("could not discover an execution command-line");
    };

    let (venv_root, venv_cfg) = find_venv_root(exec_name)?;

    let venv_config = parse_venv_cfg(&venv_root, &venv_cfg)?;

    // The logical path of the interpreter
    let venv_interpreter = venv_root.join("bin/python3");

    let actual_interpreter = find_actual_interpreter(&venv_config)?;

    #[cfg(feature = "debug")]
    eprintln!(
        "[aspect] Attempting to execute: {:?} with argv[0] as {:?} and args as {:?}",
        &actual_interpreter_path, &venv_interpreter_path, exec_args,
    );

    let mut cmd = Command::new(&actual_interpreter);
    let cmd = cmd
        // Pass along our args
        .args(exec_args)
        // Lie about the value of argv0 to hoodwink the interpreter as to its
        // location on Linux-based platforms.
        .arg0(&venv_interpreter)
        // Pseudo-`activate`
        .env("VIRTUAL_ENV", &venv_root);

    let venv_bin = (&venv_root).join("bin");
    // TODO(arrdem|myrrlyn): PATHSEP is : on Unix and ; on Windows
    let mut path_segments = env::var("PATH")
        .into_diagnostic()? // if the variable is unset or not-utf-8, quit
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

    // Set the executable pointer for MacOS, but we do it consistently
    cmd.env("PYTHONEXECUTABLE", &venv_interpreter);

    // Similar to `-s` but this avoids us having to muck with the argv in ways
    // that could be visible to the called program.
    if !venv_config.user_site {
        cmd.env("PYTHONNOUSERSITE", "1");
    }

    // Set the interpreter home to the resolved install base. This works around
    // the home = property in the pyvenv.cfg being wrong because we don't
    // (currently) have a good way to map the interpreter rlocation to a
    // relative path.
    cmd.env(
        "PYTHONHOME",
        &actual_interpreter.parent().unwrap().parent().unwrap(),
    );

    // And punt
    let err = cmd.exec();
    miette::bail!(
        "Failed to exec target {}, {}",
        actual_interpreter.display(),
        err,
    )
}
