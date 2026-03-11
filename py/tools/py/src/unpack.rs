use std::{
    fs,
    path::{Path, PathBuf},
    str::FromStr,
    sync::LazyLock,
};

use crate::bazel_glob::BazelGlob;
use itertools::Itertools;
use miette::{Context, IntoDiagnostic, Result};
use percent_encoding::percent_decode_str;
use walkdir::WalkDir;

const RELOCATABLE_SHEBANG: &'static str = r#"/bin/sh
'''exec' "$(dirname -- "$(realpath -- "$0")")"/'python3' "$0" "$@"
' '''
"#;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RulesPythonFileKind {
    Src,
    Data,
    Neither,
}

static PYC_TEMP_FILE_GLOB: LazyLock<BazelGlob> =
    LazyLock::new(|| BazelGlob::parse("**/*.pyc.*").unwrap());
static DIST_INFO_RECORD_GLOB: LazyLock<BazelGlob> =
    LazyLock::new(|| BazelGlob::parse("**/*.dist-info/RECORD").unwrap());

fn excluded_file_kind(path: &Path) -> RulesPythonFileKind {
    if path.to_str() == Some("BUILD") || path.to_str() == Some("WORKSPACE") {
        return RulesPythonFileKind::Neither;
    }

    let extension = path.extension();
    if extension == Some("py".as_ref()) {
        return RulesPythonFileKind::Src;
    }

    if extension == Some("pyi".as_ref()) || extension == Some("pyc".as_ref()) {
        return RulesPythonFileKind::Neither;
    }

    if PYC_TEMP_FILE_GLOB.matches(path) || DIST_INFO_RECORD_GLOB.matches(path) {
        return RulesPythonFileKind::Neither;
    }

    RulesPythonFileKind::Data
}

fn remove_excluded_files(
    site_packages_dir: &Path,
    srcs_exclude_globs: &[String],
    data_exclude_globs: &[String],
) -> Result<()> {
    if srcs_exclude_globs.is_empty() && data_exclude_globs.is_empty() {
        return Ok(());
    }

    let srcs_exclude_globs = srcs_exclude_globs
        .iter()
        .map(|pattern| BazelGlob::parse(pattern))
        .collect::<Result<Vec<_>>>()?;
    let data_exclude_globs = data_exclude_globs
        .iter()
        .map(|pattern| BazelGlob::parse(pattern))
        .collect::<Result<Vec<_>>>()?;

    for entry in WalkDir::new(site_packages_dir) {
        let entry = entry.into_diagnostic()?;
        if entry.file_type().is_dir() {
            continue;
        }

        let path = entry.path().strip_prefix(site_packages_dir).unwrap();
        let match_path = Path::new("site-packages").join(path);

        let matching_glob = match excluded_file_kind(path) {
            RulesPythonFileKind::Src => srcs_exclude_globs
                .iter()
                .find(|glob| glob.matches(&match_path)),
            RulesPythonFileKind::Data => data_exclude_globs
                .iter()
                .find(|glob| glob.matches(&match_path)),
            RulesPythonFileKind::Neither => None,
        };

        if let Some(matching_glob) = matching_glob {
            fs::remove_file(entry.path())
                .into_diagnostic()
                .wrap_err_with(|| {
                    format!(
                        "Failed to remove excluded installed file '{}' matched by '{}'",
                        match_path.display(),
                        matching_glob
                    )
                })?;
        }
    }

    Ok(())
}

pub fn unpack_wheel(
    version_major: u8,
    version_minor: u8,
    location: &Path,
    wheel: &Path,
    srcs_exclude_globs: &[String],
    data_exclude_globs: &[String],
) -> Result<()> {
    let wheel = if wheel.is_file() {
        wheel.to_owned()
    } else {
        fs::read_dir(wheel)
            .into_diagnostic()?
            .filter_map(|res| res.ok())
            .map(|dir_entry| dir_entry.path())
            .filter_map(|path| {
                if path.extension().map_or(false, |ext| ext == "whl") {
                    Some(path)
                } else {
                    None
                }
            })
            .exactly_one()
            .into_diagnostic()
            .wrap_err_with(|| "Didn't find exactly one wheel file to install!")?
    };
    let wheel_file_reader = fs::File::open(&wheel).into_diagnostic()?;

    let temp = tempfile::tempdir().into_diagnostic()?;

    let _ = uv_extract::unzip(wheel_file_reader, temp.path()).into_diagnostic()?;

    let site_packages_dir = location
        .join("lib")
        .join(format!("python{}.{}", version_major, version_minor,))
        .join("site-packages");

    let scheme = uv_pypi_types::Scheme {
        purelib: site_packages_dir.to_path_buf(),
        platlib: site_packages_dir.to_path_buf(),
        // No windows support.
        scripts: location.join("bin"),
        data: site_packages_dir.to_path_buf(),
        include: location.join("lib").join("include"),
    };

    let layout = uv_install_wheel::Layout {
        sys_executable: PathBuf::from(RELOCATABLE_SHEBANG),
        python_version: (version_major, version_minor),
        // Don't stamp in the path to the interpreter into the generated bins
        // as we don't want an absolute path here.
        // Perhaps this should be set to just "python" so it picks up the one in the venv path?
        os_name: "".to_string(),
        scheme,
    };

    let filename = wheel
        .file_name()
        .and_then(|f| f.to_str())
        .expect("Expected to get filename from wheel path");
    let filename = percent_decode_str(filename).decode_utf8_lossy();
    let wheel_file_name =
        uv_distribution_filename::WheelFilename::from_str(&filename).into_diagnostic()?;

    uv_install_wheel::linker::install_wheel(
        &layout,
        false,
        temp.path(),
        &wheel_file_name,
        None,
        None,
        Some("aspect_rule_py"),
        uv_install_wheel::linker::LinkMode::Copy,
        &uv_install_wheel::linker::Locks::default(),
    )
    .into_diagnostic()?;

    remove_excluded_files(&site_packages_dir, srcs_exclude_globs, data_exclude_globs)?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use std::{fs, path::Path};

    use super::{excluded_file_kind, RulesPythonFileKind};

    #[test]
    fn kind_matches_source_classification() {
        assert_eq!(excluded_file_kind(Path::new("pkg/module.py")), RulesPythonFileKind::Src);
    }

    #[test]
    fn kind_matches_data_classification() {
        assert_eq!(
            excluded_file_kind(Path::new("pkg/templates/index.html")),
            RulesPythonFileKind::Data
        );
    }

    #[test]
    fn kind_preserves_non_src_non_data_files() {
        assert_eq!(
            excluded_file_kind(Path::new("pkg/module.pyi")),
            RulesPythonFileKind::Neither
        );
        assert_eq!(
            excluded_file_kind(Path::new("pkg/module.pyc")),
            RulesPythonFileKind::Neither
        );
        assert_eq!(
            excluded_file_kind(Path::new("pkg-1.0.dist-info/RECORD")),
            RulesPythonFileKind::Neither
        );
    }

    #[test]
    fn kind_matches_recursive_dist_info_record_glob() {
        assert_eq!(
            excluded_file_kind(Path::new("pkg/foo.dist-info/RECORD")),
            RulesPythonFileKind::Neither
        );
    }

    #[test]
    fn kind_only_matches_pyc_temp_files_by_file_name() {
        assert_eq!(
            excluded_file_kind(Path::new("pkg/cache.pyc.dir/data.txt")),
            RulesPythonFileKind::Data
        );
        assert_eq!(
            excluded_file_kind(Path::new("pkg/__pycache__/module.pyc.123")),
            RulesPythonFileKind::Neither
        );
    }

    #[test]
    fn kind_preserves_root_build_and_workspace_files() {
        assert_eq!(excluded_file_kind(Path::new("BUILD")), RulesPythonFileKind::Neither);
        assert_eq!(
            excluded_file_kind(Path::new("WORKSPACE")),
            RulesPythonFileKind::Neither
        );
    }

    #[test]
    fn remove_excluded_files_requires_site_packages_prefix_for_exact_paths() {
        let temp = tempfile::tempdir().unwrap();
        let site_packages_dir = temp.path().join("site-packages");
        let pkg_dir = site_packages_dir.join("pkg");

        fs::create_dir_all(&pkg_dir).unwrap();
        fs::write(pkg_dir.join("tests.py"), "").unwrap();

        super::remove_excluded_files(&site_packages_dir, &["pkg/tests.py".to_owned()], &[])
            .unwrap();

        assert!(pkg_dir.join("tests.py").exists());
    }

    #[test]
    fn remove_excluded_files_deletes_matching_file() {
        let temp = tempfile::tempdir().unwrap();
        let site_packages_dir = temp.path().join("site-packages");
        let pkg_dir = site_packages_dir.join("pkg");

        fs::create_dir_all(&pkg_dir).unwrap();
        fs::write(pkg_dir.join("tests.py"), "").unwrap();

        super::remove_excluded_files(
            &site_packages_dir,
            &["site-packages/pkg/tests.py".to_owned()],
            &[],
        )
        .unwrap();

        assert!(!pkg_dir.join("tests.py").exists());
    }

    #[test]
    fn remove_excluded_files_rejects_invalid_globs() {
        let temp = tempfile::tempdir().unwrap();
        let site_packages_dir = temp.path().join("site-packages");

        fs::create_dir_all(&site_packages_dir).unwrap();

        let error = super::remove_excluded_files(&site_packages_dir, &["foo**/bar".to_owned()], &[])
            .unwrap_err();

        assert_eq!(
            error.to_string(),
            "Error in glob: invalid glob pattern 'foo**/bar': recursive wildcard must be its own segment"
        );
    }
}
