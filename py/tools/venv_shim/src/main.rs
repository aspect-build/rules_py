use miette::{miette, Context, IntoDiagnostic};
use std::env;
use std::env::VarError;
use std::fs;
use std::io::{self, BufRead};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;

const COUNTER_VAR: &str = "ASPECT_SHIM_SKIP";

fn find_pyvenv_cfg(start_path: &Path) -> Option<PathBuf> {
    let parent = start_path.parent()?.parent()?;
    let cfg_path = parent.join("pyvenv.cfg");
    if cfg_path.exists() && cfg_path.is_file() {
        Some(cfg_path)
    } else {
        None
    }
}

fn extract_pyvenv_version_info(cfg_path: &Path) -> Result<Option<String>, io::Error> {
    let file = fs::File::open(cfg_path)?;
    let reader = io::BufReader::new(file);
    for line in reader.lines() {
        let line = line?;
        if let Some((key, value)) = line.split_once("=") {
            let key = key.trim();
            let value = value.trim();
            if key == "version_info" {
                return Ok(Some(value.to_string()));
            }
        }
    }
    Ok(None)
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

fn main() -> miette::Result<()> {
    let venv_home_path = env::var("VIRTUAL_ENV")
        .map(PathBuf::from)
        .into_diagnostic()
        .map_err(|e| {
            miette!(
                help = format!(
                    "The activate script should be available as {:?}",
                    env::current_exe()
                        .unwrap()
                        .parent()
                        .unwrap()
                        .join("activate")
                ),
                "{e}",
            )
            .wrap_err("$VIRTUAL_ENV was unbound! A venv must be activated")
        })?;

    let venv_interpreter_path: PathBuf = env::var("PYTHONEXECUTABLE")
        .map(PathBuf::from)
        .or_else(|_| Ok::<PathBuf, VarError>(venv_home_path.join("bin/python")))
        .into_diagnostic()?;

    let excluded_interpreters_dir = &venv_home_path.join("bin");

    let args: Vec<_> = env::args().collect();

    #[cfg(feature = "debug")]
    eprintln!(
        "[aspect] Current executable path: {:?}",
        &venv_interpreter_path
    );

    let Some(pyvenv_cfg_path) = find_pyvenv_cfg(&venv_interpreter_path) else {
        return Err(miette!(
            help = format!("VIRTUAL_ENV was {:?}", &venv_home_path),
            "The virtual environment is either incorrectly structured or was incorrectly detected",
        )
        .wrap_err("pyvenv.cfg not found!"));
    };

    #[cfg(feature = "debug")]
    eprintln!("[aspect] Found pyvenv.cfg at: {:?}", &pyvenv_cfg_path);

    let version_info_result = extract_pyvenv_version_info(&pyvenv_cfg_path)
        .into_diagnostic()
        .wrap_err(format!(
            "Failed to parse pyvenv.cfg {}",
            &pyvenv_cfg_path.to_str().unwrap(),
        ))
        .unwrap();

    let Some(version_info) = version_info_result else {
        return Err(miette!(
            help = format!("pyvenv.cfg must specify the version_info= key"),
            "The virtual environment is incorrectly built or was incorrectly detected"
        )
        .wrap_err("version_info key not found in pyvenv.cfg."));
    };

    #[cfg(feature = "debug")]
    eprintln!("[aspect] version_info from pyvenv.cfg: {:?}", &version_info);

    let Some(target_python_version) = parse_version_info(&version_info) else {
        return Err(miette!(
            help = format!("Provided version info was {:?}", &version_info),
            "Could not parse version_info as `x.y.z`"
        )
        .wrap_err("Unable to determine interpreter revision"));
    };

    #[cfg(feature = "debug")]
    eprintln!(
        "[aspect] Parsed target Python version (major.minor): {}",
        &target_python_version
    );

    #[cfg(feature = "debug")]
    eprintln!("[aspect] Ignoring dir {:?}", &excluded_interpreters_dir);

    let Some(python_executables) =
        find_python_executables(&target_python_version, excluded_interpreters_dir)
    else {
        return Err(miette!(
            "No suitable Python interpreter found in PATH matching version '{}'.",
            &version_info,
        ));
    };

    #[cfg(feature = "debug")]
    {
        eprintln!("[aspect] Found potential Python interpreters in PATH with matching version:");
        for exe in &python_executables {
            eprintln!("[aspect] - {:?}", exe);
        }
    }

    // Attempt to break infinite recursion through this shim by counting up
    // the number of times we've come back to this shim and incrementing it
    // until we hit something on the path that DOESN'T come back here, or we
    // run out of path entries.
    let index: usize = {
        match env::var(COUNTER_VAR) {
            // Whatever the previous value was didn't work because we're
            // back here, so increment.
            Ok(it) => it.parse::<usize>().unwrap() + 1,
            _ => 0,
        }
    };

    let Some(actual_interpreter_path) = python_executables.get(index) else {
        return Err(miette!(
            "Unable to find another interpreter at index {}",
            index
        ));
    };

    let exec_args = &args[1..];

    #[cfg(feature = "debug")]
    eprintln!(
        "[aspect] Attempting to execute: {:?} with argv[0] as {:?} and args as {:?}",
        &actual_interpreter_path, &venv_interpreter_path, exec_args,
    );

    let mut cmd = Command::new(actual_interpreter_path);
    cmd.args(exec_args);

    // Lie about the value of argv0 to hoodwink the interpreter as to its
    // location on Linux-based platforms.
    cmd.arg0(&venv_interpreter_path);

    // On MacOS however, there are facilities for asking the C runtime/OS
    // what the real name of the interpreter executable is, and that value
    // is preferred while argv[0] is ignored. So we need to use a different
    // mechanism to lie to the target interpreter about its own path.
    //
    // https://github.com/python/cpython/blob/68e72cf3a80362d0a2d57ff0c9f02553c378e537/Modules/getpath.c#L778
    // https://docs.python.org/3/using/cmdline.html#envvar-PYTHONEXECUTABLE
    if cfg!(target_os = "macos") {
        cmd.env("PYTHONEXECUTABLE", &venv_interpreter_path);
    }

    // Re-export the counter so it'll go up
    cmd.env(COUNTER_VAR, index.to_string());

    let _ = cmd.exec();

    Ok(())
}
