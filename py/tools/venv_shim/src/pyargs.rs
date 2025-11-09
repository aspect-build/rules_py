use clap::{arg, Arg, ArgAction, ArgMatches, Command};
use miette::{IntoDiagnostic, Result};

fn build_parser() -> Command {
    Command::new("python_like_parser")
        .disable_version_flag(true)
        .disable_help_flag(true)
        .dont_delimit_trailing_values(true)
        .allow_hyphen_values(true)
        .arg(Arg::new("ignore_env").short('E').action(ArgAction::SetTrue))
        .arg(Arg::new("isolate").short('I').action(ArgAction::SetTrue))
        .arg(
            Arg::new("no_user_site")
                .short('s')
                .action(ArgAction::SetTrue),
        )
        .arg(
            Arg::new("no_import_site")
                .short('S')
                .action(ArgAction::SetTrue),
        )
        .arg(
            arg!(<args> ...)
                .trailing_var_arg(true)
                .required(false)
                .allow_hyphen_values(true),
        )
}

pub struct ArgState {
    pub ignore_env: bool,
    pub isolate: bool,
    pub no_import_site: bool,
    pub no_user_site: bool,
    pub remaining_args: Vec<String>,
}

fn extract_state(matches: &ArgMatches) -> ArgState {
    ArgState {
        // E and I are crucial for transformation
        ignore_env: *matches.get_one::<bool>("ignore_env").unwrap_or(&false),
        isolate: *matches.get_one::<bool>("isolate").unwrap_or(&false),

        // s is crucial for transformation
        no_user_site: *matches.get_one::<bool>("no_user_site").unwrap_or(&false),

        no_import_site: *matches.get_one::<bool>("no_import_site").unwrap_or(&false),

        remaining_args: matches
            .get_many::<String>("args")
            .unwrap_or_default()
            .map(|it| it.to_string())
            .collect::<Vec<_>>(),
    }
}

pub fn reparse_args(original_argv: &Vec<&str>) -> Result<Vec<String>> {
    let parser = build_parser();
    let matches = parser
        .try_get_matches_from(original_argv)
        .into_diagnostic()?;
    let parsed_args = extract_state(&matches);

    let mut argv: Vec<String> = Vec::new();
    let push_flag = |argv: &mut Vec<String>, flag: char, is_set: bool| {
        if is_set {
            argv.push(format!("-{}", flag));
        }
    };

    // Retain the original argv binary
    argv.push(original_argv[0].to_string());

    // -I replacement logic: -I is never pushed, its effects (-E and -s) are handled separately.
    // -E removal: -E is never pushd
    // -s inclusion logic: we ALWAYS push -s
    push_flag(
        &mut argv,
        's',
        parsed_args.no_user_site | parsed_args.isolate,
    );

    push_flag(&mut argv, 'S', parsed_args.no_import_site);

    argv.extend(parsed_args.remaining_args.iter().cloned());

    Ok(argv)
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn basic_args_preserved1() {
        let orig = vec!["python", "-B", "-s", "script.py", "arg1"];
        let reparsed = reparse_args(&orig);
        assert!(reparsed.is_ok(), "Args failed to parse {:?}", reparsed);
        let reparsed = reparsed.unwrap();
        assert!(
            orig == reparsed,
            "Args shouldn't have changed, got {:?}",
            reparsed
        );
    }

    #[test]
    fn basic_args_preserved2() {
        let orig = vec!["python", "-s", "-c", "exit(0)", "arg1"];
        let reparsed = reparse_args(&orig);
        assert!(&reparsed.is_ok(), "Args failed to parse {:?}", reparsed);
        let reparsed = reparsed.unwrap();
        assert!(
            orig == reparsed,
            "Args shouldn't have changed, got {:?}",
            reparsed
        );
    }

    #[test]
    fn basic_binary_preserved() {
        let orig = vec![
            "/some/arbitrary/path/python",
            "-B",
            "-s",
            "script.py",
            "arg1",
        ];
        let reparsed = reparse_args(&orig);
        assert!(reparsed.is_ok(), "Args failed to parse {:?}", reparsed);
        let reparsed = reparsed.unwrap();
        assert!(
            orig == reparsed,
            "Args shouldn't have changed, got {:?}",
            reparsed
        );
    }

    #[test]
    fn basic_s_remains() {
        // We expect to not modify the -s flag
        let orig = vec!["python", "-s", "-c", "exit(0)", "arg1"];
        let reparsed = reparse_args(&orig);
        assert!(reparsed.is_ok(), "Args failed to parse {:?}", reparsed);
        assert!(orig == reparsed.unwrap(), "Args shouldn't have changed");
    }

    #[test]
    fn basic_e_gets_unset() {
        // We expect to REMOVE the -E flag
        let orig = vec!["python", "-E", "-s", "-c", "exit(0)", "arg1"];
        let expected = vec!["python", "-s", "-c", "exit(0)", "arg1"];
        let reparsed = reparse_args(&orig);
        assert!(reparsed.is_ok(), "Args failed to parse {:?}", reparsed);
        assert!(expected == reparsed.unwrap(), "-E wasn't unset");
    }

    #[test]
    fn basic_i_becomes_s() {
        // We expect to CONVERT the -I flag to -E (which we ignore) and -s (which we keep)
        let orig = vec!["python", "-I", "-c", "exit(0)", "arg1"];
        let expected = vec!["python", "-s", "-c", "exit(0)", "arg1"];
        let reparsed = reparse_args(&orig);
        assert!(reparsed.is_ok(), "Args failed to parse {:?}", reparsed);
        assert!(expected == reparsed.unwrap(), "Didn't translate -I to -s");
    }

    #[test]
    fn basic_m_preserved() {
        // We expect to ADD the -s flag
        let orig = vec!["python", "-m", "build", "--unknown", "arg1"];
        let expected = vec!["python", "-m", "build", "--unknown", "arg1"];
        let reparsed = reparse_args(&orig);
        assert!(reparsed.is_ok(), "Args failed to parse {:?}", reparsed);
        assert!(expected == reparsed.unwrap(), "Didn't add -s");
    }

    #[test]
    fn basic_trailing_args_preserved() {
        let orig = vec![
            "python3",
            "uv/private/sdist_build/build_helper.py",
            "bazel-out/darwin_arm64-fastbuild/bin/external/+uv+sbuild__pypi__default__bravado_core/src",
            "bazel-out/darwin_arm64-fastbuild/bin/external/+uv+sbuild__pypi__default__bravado_core/build"
        ];
        let expected =  vec![
            "python3",
            "uv/private/sdist_build/build_helper.py",
            "bazel-out/darwin_arm64-fastbuild/bin/external/+uv+sbuild__pypi__default__bravado_core/src",
            "bazel-out/darwin_arm64-fastbuild/bin/external/+uv+sbuild__pypi__default__bravado_core/build"
        ];
        let reparsed = reparse_args(&orig);
        assert!(reparsed.is_ok(), "Args failed to parse {:?}", reparsed);
        let reparsed = reparsed.unwrap();
        assert!(
            expected == reparsed,
            "Something happened to the args, got {:?}",
            reparsed
        );
    }

    #[test]
    fn m_preserved_s_added_varargs_preserved() {
        let orig = vec![
            "python3",
            "-m",
            "build",
            "--no-isolation",
            "--out-dir",
            "bazel-out/darwin_arm64-fastbuild/bin/external/+uv+sbuild__pypi__default__bravado_core/build",
            "bazel-out/darwin_arm64-fastbuild/bin/external/+uv+sbuild__pypi__default__bravado_core/src",
        ];
        let expected =  vec![
            "python3",
            "-m",
            "build",
            "--no-isolation",
            "--out-dir",
            "bazel-out/darwin_arm64-fastbuild/bin/external/+uv+sbuild__pypi__default__bravado_core/build",
            "bazel-out/darwin_arm64-fastbuild/bin/external/+uv+sbuild__pypi__default__bravado_core/src",
        ];
        let reparsed = reparse_args(&orig);
        assert!(reparsed.is_ok(), "Args failed to parse {:?}", reparsed);
        let reparsed = reparsed.unwrap();
        assert!(
            expected == reparsed,
            "Something happened to the args, got {:?}",
            reparsed
        );
    }
}
