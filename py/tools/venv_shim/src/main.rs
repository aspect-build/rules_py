use miette::{miette, IntoDiagnostic};
use runfiles::Runfiles; // Depended on out of rules_rust
use std::env::{self, args, var};
use std::fs;
use std::io::{self, BufRead};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;

const PYVENV: &str = "pyvenv.cfg";

fn find_venv_root() -> miette::Result<(PathBuf, PathBuf)> {
    if let Ok(it) = var("VIRTUAL_ENV") {
        let root = PathBuf::from(it);
        let cfg = root.join(PYVENV);
        if cfg.exists() {
            return Ok((root, cfg));
        }
        // FIXME: Else warn that the VIRTUAL_ENV is invalid before continuing
    }

    if let Some(this) = args().next() {
        let this = PathBuf::from(this);
        if let Some(parent) = this.parent().and_then(|it| it.parent()) {
            let cfg = parent.join(PYVENV);
            if cfg.exists() {
                return Ok((parent.to_path_buf(), cfg));
            }
        }
    }

    return Err(miette!("Unable to identify a virtualenv home!"));
}

#[derive(Debug)]
enum InterpreterConfig {
    Runfiles { rpath: String, repo: String },
    External { version: String },
}

#[derive(Debug)]
#[allow(unused_attributes)]
struct PyCfg {
    root: PathBuf,
    cfg: PathBuf,
    version_info: String,
    interpreter: InterpreterConfig,
}

fn parse_venv_cfg(venv_root: &Path, cfg_path: &Path) -> miette::Result<PyCfg> {
    let file = fs::File::open(cfg_path).into_diagnostic()?;

    let mut version: Option<String> = None;
    let mut bazel_interpreter: Option<String> = None;
    let mut bazel_repo: Option<String> = None;

    // FIXME: Errors possible here?
    let reader = io::BufReader::new(file);

    for line in reader.lines() {
        let line = line.into_diagnostic()?;
        if let Some((key, value)) = line.split_once("=") {
            let key = key.trim();
            let value = value.trim();
            match key {
                "version_info" => {
                    version = Some(value.to_string());
                }
                "aspect_runfiles_interpreter" => {
                    bazel_interpreter = Some(value.to_string());
                }
                "aspect_runfiles_repo" => {
                    bazel_repo = Some(value.to_string());
                }
                // We don't care about other keys
                &_ => {}
            }
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
        }),
        // FIXME: Kinda useless copy in this case
        (Some(version), None, None) => Ok(PyCfg {
            root: venv_root.to_path_buf(),
            cfg: cfg_path.to_path_buf(),
            version_info: version.to_owned(),
            interpreter: InterpreterConfig::External {
                version: parse_version_info(&version).unwrap(),
            },
        }),
        (None, _, _) => Err(miette!(
            "Invalid pyvenv.cfg file! no interpreter version specified!"
        )),
        _ => Err(miette!(
            "Invalid pyvenv.cfg file! runfiles interpreter incompletely configured!"
        )),
    }
}

fn parse_version_info(version_str: &String) -> Option<String> {
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
            let Some(python_executables) = find_python_executables(&version, &cfg.root.join("bin"))
            else {
                return Err(miette!(
                    "No suitable Python interpreter found in PATH matching version '{}'.",
                    &version,
                ));
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

            // FIXME: Do we still need to offset beyond one?
            let Some(actual_interpreter_path) = python_executables.get(0) else {
                return Err(miette!("Unable to find another interpreter!",));
            };

            Ok(actual_interpreter_path.to_owned())
        }
        InterpreterConfig::Runfiles { rpath, repo } => {
            let r = Runfiles::create().unwrap();
            if let Some(interpreter) = r.rlocation_from(rpath.as_str(), &repo) {
                return Ok(PathBuf::from(interpreter));
            } else {
                return Err(miette!(format!(
                    "Unable to identify an interpreter for venv {:?}",
                    cfg.interpreter,
                )));
            }
        }
    }
}

fn main() -> miette::Result<()> {
    let (venv_root, venv_cfg) = find_venv_root()?;

    let venv_config = parse_venv_cfg(&venv_root, &venv_cfg)?;

    // The logical path of the interpreter
    let venv_interpreter = venv_root.join("bin/python3");

    let actual_interpreter = find_actual_interpreter(&venv_config)?;

    let args: Vec<_> = env::args().collect();

    let exec_args = &args[1..];

    #[cfg(feature = "debug")]
    eprintln!(
        "[aspect] Attempting to execute: {:?} with argv[0] as {:?} and args as {:?}",
        &actual_interpreter_path, &venv_interpreter_path, exec_args,
    );

    let mut cmd = Command::new(&actual_interpreter);

    // Pass along our args
    cmd.args(exec_args);

    // Lie about the value of argv0 to hoodwink the interpreter as to its
    // location on Linux-based platforms.
    cmd.arg0(&venv_interpreter);

    // Psuedo-`activate`
    cmd.env("VIRTUAL_ENV", &venv_root.to_str().unwrap());
    let venv_bin = (&venv_root).join("bin").to_str().unwrap().to_owned();
    if let Ok(current_path) = var("PATH") {
        if current_path.find(&venv_bin).is_none() {
            cmd.env("PATH", format!("{}:{}", venv_bin, current_path));
        }
    }

    // Set the executable pointer for MacOS, but we do it consistently
    cmd.env("PYTHONEXECUTABLE", &venv_interpreter);

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
    Err(miette!(format!(
        "Failed to exec target {}, {}",
        actual_interpreter.display(),
        err,
    )))
}
