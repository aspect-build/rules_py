use miette::miette;
use std::env;
use std::fs;
use std::io::{self, BufRead};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;

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
        return file_name.ends_with(&format!("python{}", version_from_cfg));
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
        .filter(|potential_executable| compare_versions(version_from_cfg, &potential_executable))
        .collect();

    if binaries.len() > 0 {
        Some(binaries)
    } else {
        None
    }
}

fn main() -> miette::Result<()> {
    let current_exe = env::current_exe().unwrap();
    let args: Vec<_> = env::args().collect();

    #[cfg(feature = "debug")]
    println!("[aspect] Current executable path: {:?}", current_exe);

    let pyvenv_cfg_path = match find_pyvenv_cfg(&current_exe) {
        Some(path) => {
            #[cfg(feature = "debug")]
            eprintln!("[aspect] Found pyvenv.cfg at: {:?}", path);
            path
        }
        None => {
            return Err(miette!("pyvenv.cfg not found one directory level up."));
        }
    };

    let version_info_result = extract_pyvenv_version_info(&pyvenv_cfg_path).unwrap();
    let version_info = match version_info_result {
        Some(v) => {
            #[cfg(feature = "debug")]
            eprintln!("[aspect] version_info from pyvenv.cfg: {}", v);
            v
        }
        None => {
            return Err(miette!("version_info key not found in pyvenv.cfg."));
        }
    };

    let target_python_version = match parse_version_info(&version_info) {
        Some(v) => {
            #[cfg(feature = "debug")]
            eprintln!("[aspect] Parsed target Python version (major.minor): {}", v);
            v
        }
        None => {
            return Err(miette!("Could not parse version_info as x.y."));
        }
    };

    let exclude_dir = current_exe.parent().unwrap();
    if let Some(python_executables) = find_python_executables(&target_python_version, exclude_dir) {
        #[cfg(feature = "debug")]
        {
            eprintln!(
                "[aspect] Found potential Python interpreters in PATH with matching version:"
            );
            for exe in &python_executables {
                println!("[aspect] - {:?}", exe);
            }
        }

        let interpreter_path = &python_executables[0];
        let exe_path = current_exe.to_string_lossy().into_owned();
        let exec_args = &args[1..];

        #[cfg(feature = "debug")]
        eprintln!(
            "[aspect] Attempting to execute: {:?} with argv[0] as {:?} and args as {:?}",
            interpreter_path, exe_path, exec_args,
        );

        let mut cmd = Command::new(interpreter_path);
        cmd.args(exec_args);

        // Lie about the value of argv0 to hoodwink the interpreter as to its
        // location on Linux-based platforms.
        if cfg!(target_os = "linux") {
            cmd.arg0(&exe_path);
        }

        // On MacOS however, there are facilities for asking the C runtime/OS
        // what the real name of the interpreter executable is, and that value
        // is preferred while argv[0] is ignored. So we need to use a different
        // mechanism to lie to the target interpreter about its own path.
        //
        // https://github.com/python/cpython/blob/68e72cf3a80362d0a2d57ff0c9f02553c378e537/Modules/getpath.c#L778
        // https://docs.python.org/3/using/cmdline.html#envvar-PYTHONEXECUTABLE
        if cfg!(target_os = "macos") {
            cmd.env("PYTHONEXECUTABLE", exe_path);
        }

        let _ = cmd.exec();

        return Ok(());
    } else {
        return Err(miette!(
            "No suitable Python interpreter found in PATH matching version '{}'.",
            &version_info,
        ));
    }
}
