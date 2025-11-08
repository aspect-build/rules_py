use clap::{arg, Arg, ArgAction, ArgMatches, Command};
use miette::{IntoDiagnostic, Result};

fn build_parser() -> Command {
    Command::new("python_like_parser")
        .disable_version_flag(true)
        .disable_help_flag(true)
        .dont_delimit_trailing_values(true)
        .allow_hyphen_values(true)
        .arg(
            Arg::new("bytes_warning_level")
                .short('b')
                .action(ArgAction::Count),
        )
        .arg(
            Arg::new("dont_write_bytecode")
                .short('B')
                .action(ArgAction::SetTrue),
        )
        .arg(
            Arg::new("command")
                .short('c')
                .value_name("cmd")
                .conflicts_with("module"),
        )
        .arg(
            Arg::new("debug_parser")
                .short('d')
                .action(ArgAction::SetTrue),
        )
        .arg(Arg::new("ignore_env").short('E').action(ArgAction::SetTrue))
        .arg(
            Arg::new("help")
                .short('h')
                .long("help")
                .action(ArgAction::Help),
        )
        .arg(Arg::new("inspect").short('i').action(ArgAction::SetTrue))
        .arg(Arg::new("isolate").short('I').action(ArgAction::SetTrue))
        .arg(
            Arg::new("module")
                .short('m')
                .value_name("mod")
                .conflicts_with("command"),
        )
        .arg(
            Arg::new("optimize_level")
                .short('O')
                .action(ArgAction::Count),
        )
        .arg(Arg::new("quiet").short('q').action(ArgAction::SetTrue))
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
        .arg(Arg::new("unbuffered").short('u').action(ArgAction::SetTrue))
        .arg(Arg::new("verbosity").short('v').action(ArgAction::Count))
        .arg(
            Arg::new("version")
                .short('V')
                .long("version")
                .action(ArgAction::Count),
        )
        .arg(
            Arg::new("warnings")
                .short('W')
                .value_name("arg")
                .action(ArgAction::Append),
        )
        .arg(
            Arg::new("skip_first_line")
                .short('x')
                .action(ArgAction::SetTrue),
        )
        .arg(
            Arg::new("extended_options")
                .short('X')
                .value_name("opt")
                .action(ArgAction::Append),
        )
        .arg(
            arg!(<args> ...)
                .trailing_var_arg(true)
                .required(false)
                .allow_hyphen_values(true),
        )
}

pub struct ArgState {
    pub bytes_warning_level: u8,
    pub dont_write_bytecode: bool,
    pub command: Option<String>,
    pub debug_parser: bool,
    pub ignore_env: bool,
    pub help: bool,
    pub inspect: bool,
    pub isolate: bool,
    pub module: Option<String>,
    pub optimize_level: u8,
    pub quiet: bool,
    pub no_user_site: bool,
    pub no_import_site: bool,
    pub unbuffered: bool,
    pub verbosity: u8,
    pub version: u8,
    pub warnings: Vec<String>,
    pub skip_first_line: bool,
    pub extended_options: Vec<String>,
    pub remaining_args: Vec<String>,
}

fn extract_state(matches: &ArgMatches) -> ArgState {
    ArgState {
        bytes_warning_level: *matches.get_one::<u8>("bytes_warning_level").unwrap_or(&0),
        dont_write_bytecode: *matches
            .get_one::<bool>("dont_write_bytecode")
            .unwrap_or(&false),
        command: matches.get_one::<String>("command").cloned(),
        debug_parser: *matches.get_one::<bool>("debug_parser").unwrap_or(&false),
        // E and I are crucial for transformation
        ignore_env: *matches.get_one::<bool>("ignore_env").unwrap_or(&false),
        isolate: *matches.get_one::<bool>("isolate").unwrap_or(&false),

        help: *matches.get_one::<bool>("help").unwrap_or(&false),
        inspect: *matches.get_one::<bool>("inspect").unwrap_or(&false),
        module: matches.get_one::<String>("module").cloned(),
        optimize_level: *matches.get_one::<u8>("optimize_level").unwrap_or(&0),
        quiet: *matches.get_one::<bool>("quiet").unwrap_or(&false),

        // s is crucial for transformation
        no_user_site: *matches.get_one::<bool>("no_user_site").unwrap_or(&false),

        no_import_site: *matches.get_one::<bool>("no_import_site").unwrap_or(&false),
        unbuffered: *matches.get_one::<bool>("unbuffered").unwrap_or(&false),
        verbosity: *matches.get_one::<u8>("verbosity").unwrap_or(&0),
        version: *matches.get_one::<u8>("version").unwrap_or(&0),
        skip_first_line: *matches.get_one::<bool>("skip_first_line").unwrap_or(&false),

        // For multiple values, clone the Vec
        warnings: matches
            .get_many::<String>("warnings")
            .unwrap_or_default()
            .cloned()
            .collect(),
        extended_options: matches
            .get_many::<String>("extended_options")
            .unwrap_or_default()
            .cloned()
            .collect(),

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

    if parsed_args.bytes_warning_level == 1 {
        argv.push(String::from("-b"));
    } else if parsed_args.bytes_warning_level >= 2 {
        argv.push(String::from("-bb"));
    }

    push_flag(&mut argv, 'B', parsed_args.dont_write_bytecode);
    push_flag(&mut argv, 'd', parsed_args.debug_parser);
    push_flag(&mut argv, 'h', parsed_args.help);
    push_flag(&mut argv, 'i', parsed_args.inspect);

    // -I replacement logic: -I is never pushed, its effects (-E and -s) are handled separately.
    // -E removal: -E is never pushd
    // -s inclusion logic: we ALWAYS push -s
    push_flag(&mut argv, 's', true);

    push_flag(&mut argv, 'S', parsed_args.no_import_site);
    push_flag(&mut argv, 'u', parsed_args.unbuffered);
    push_flag(&mut argv, 'q', parsed_args.quiet);
    push_flag(&mut argv, 'x', parsed_args.skip_first_line);

    if let Some(cmd) = &parsed_args.command {
        argv.push(String::from("-c"));
        argv.push(cmd.clone());
    }
    if let Some(module) = &parsed_args.module {
        argv.push(String::from("-m"));
        argv.push(module.clone());
    }
    if parsed_args.optimize_level == 1 {
        argv.push(String::from("-O"));
    } else if parsed_args.optimize_level >= 2 {
        argv.push(String::from("-OO"));
    }

    for _ in 0..parsed_args.verbosity {
        argv.push(String::from("-v"));
    }
    if parsed_args.version == 1 {
        argv.push(String::from("-V"));
    } else if parsed_args.version >= 2 {
        argv.push(String::from("-VV"));
    }

    for warning in &parsed_args.warnings {
        argv.push(String::from("-W"));
        argv.push(warning.clone());
    }
    for opt in &parsed_args.extended_options {
        argv.push(String::from("-X"));
        argv.push(opt.clone());
    }

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
    fn basic_add_s() {
        // We expect to ADD the -s flag
        let orig = vec!["python", "-c", "exit(0)", "arg1"];
        let expected = vec!["python", "-s", "-c", "exit(0)", "arg1"];
        let reparsed = reparse_args(&orig);
        assert!(reparsed.is_ok(), "Args failed to parse {:?}", reparsed);
        assert!(expected == reparsed.unwrap(), "Didn't add -s");
    }

    #[test]
    fn basic_m_preserved() {
        // We expect to ADD the -s flag
        let orig = vec!["python", "-m", "build", "--unknown", "arg1"];
        let expected = vec!["python", "-s", "-m", "build", "--unknown", "arg1"];
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
            "-s",
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
            "-s",
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
