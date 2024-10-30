use std::{
    fs::{self, DirEntry, File},
    io::{BufRead, BufReader, BufWriter, Read, Write},
    path::{Path, PathBuf},
};

use miette::{miette, Context, IntoDiagnostic, LabeledSpan, MietteDiagnostic, Severity};

/// Strategy that will be used when creating the virtual env symlink and
/// a collision is found.
#[derive(Default, Debug)]
pub enum SymlinkCollisionResolutionStrategy {
    /// Collisions cause a hard error.
    #[default]
    Error,

    /// The last file to provide a target wins.
    /// If inner is true, then a warning is produced, otherwise the last target silently wins.
    LastWins(bool),
}

/// Options for the creation of the `site-packages` folder layout.
#[derive(Default, Debug)]
pub struct SitePackageOptions {
    /// Destination path, where the `site-package` folder lives.
    pub dest: PathBuf,

    /// Collision strategy determining the action taken when sylinks in the venv collide.
    pub collision_strategy: SymlinkCollisionResolutionStrategy,
}

pub struct PthFile {
    pub src: PathBuf,
    pub prefix: Option<String>,
}

impl PthFile {
    pub fn new(src: &Path, prefix: Option<String>) -> PthFile {
        Self {
            src: src.to_path_buf(),
            prefix,
        }
    }

    pub fn set_up_site_packages(&self, opts: SitePackageOptions) -> miette::Result<()> {
        let dest = &opts.dest;

        let source_pth = File::open(self.src.as_path())
            .into_diagnostic()
            .wrap_err("Unable to open source .pth file")?;
        let dest_pth = File::create(dest.join(self.src.file_name().expect(".pth must be a file")))
            .into_diagnostic()
            .wrap_err("Unable to create destination .pth file")?;

        let mut reader = BufReader::new(source_pth);
        let mut writer = BufWriter::new(dest_pth);

        let mut line = String::new();
        let path_prefix = self.prefix.as_ref().map(|pre| Path::new(pre));

        while reader.read_line(&mut line).unwrap() > 0 {
            let entry = path_prefix
                .map(|pre| pre.join(line.trim()))
                .unwrap_or_else(|| PathBuf::from(line.trim()));

            line.clear();

            match entry.file_name() {
     
                Some(name) if name == "site-packages" => {
                    println!("{:#?}", dest.join(entry.clone()));
                    let src_dir = dest
                        .join(entry)
                        .canonicalize()
                        .into_diagnostic()
                        .wrap_err("Unable to get full source dir path")?;
                    create_symlinks(&src_dir, &src_dir, &dest, &opts.collision_strategy)?;
                }
                _ => {
                    writeln!(writer, "{}", entry.to_string_lossy())
                        .into_diagnostic()
                        .wrap_err("Unable to write new .pth file entry")?;
                }
            }
        }

        Ok(())
    }
}

fn create_symlinks(
    dir: &Path,
    root_dir: &Path,
    dst_dir: &Path,
    collision_strategy: &SymlinkCollisionResolutionStrategy,
) -> miette::Result<()> {
    // Create this directory at the destination.
    let tgt_dir = dst_dir.join(dir.strip_prefix(root_dir).unwrap());
    std::fs::create_dir_all(&tgt_dir)
        .into_diagnostic()
        .wrap_err(format!(
            "Unable to create parent directory for symlink: {}",
            tgt_dir.to_string_lossy()
        ))?;

    // Recurse.
    let read_dir = fs::read_dir(dir).into_diagnostic().wrap_err(format!(
        "Unable to read directory {}",
        dir.to_string_lossy()
    ))?;

    for entry in read_dir {
        let entry = entry.into_diagnostic().wrap_err(format!(
            "Unable to read directory entry {}",
            dir.to_string_lossy()
        ))?;

        let path = entry.path();

        // If this path is a directory, recurse into it, else symlink the file now.
        // We must ignore the `__init__.py` file in the root_dir because these are Bazel inserted
        // `__init__.py` files in the root site-packages directory. The site-packages directory
        // itself is not a regular package and is not supposed to have an `__init__.py` file.
        if path.is_dir() {
            create_symlinks(&path, root_dir, dst_dir, collision_strategy)?;
        } else if dir != root_dir || entry.file_name() != "__init__.py" {
            create_symlink(&entry, root_dir, dst_dir, collision_strategy)?;
        }
    }
    Ok(())
}

fn create_symlink(
    e: &DirEntry,
    root_dir: &Path,
    dst_dir: &Path,
    collision_strategy: &SymlinkCollisionResolutionStrategy,
) -> miette::Result<()> {
    let tgt = e.path();
    let link = dst_dir.join(tgt.strip_prefix(root_dir).unwrap());

    fn conflict_report(link: &Path, tgt: &Path, severity: Severity) -> miette::Report {
        const SITE_PACKAGES: &str = "site-packages/";

        let link_str = link.to_str().unwrap();
        let tgt_str = tgt.to_str().unwrap();

        let link_span_range = link
            .to_str()
            .and_then(|s| s.split_once(SITE_PACKAGES))
            .map(|s| s.1)
            .map(|s| (link_str.len() - s.len() - SITE_PACKAGES.len())..link_str.len())
            .unwrap();

        let conflict_span_range = tgt
            .to_str()
            .and_then(|s| s.split_once(SITE_PACKAGES))
            .map(|s| s.1)
            .map(|s| {
                (link_str.len() + tgt_str.len() - s.len() - SITE_PACKAGES.len() + 1)
                    ..tgt_str.len() + link_str.len() + 1
            })
            .unwrap();

        let mut diag = MietteDiagnostic::new("Conflicting symlinks found when attempting to create venv. More than one package provides the file at these paths".to_string())
            .with_severity(severity)
            .with_labels([
                LabeledSpan::at(link_span_range, "Existing file in virtual environment"),
                LabeledSpan::at(conflict_span_range, "Next file to link"),
            ]);

        diag = if severity == Severity::Error {
            diag.with_help("Set `package_collisions = \"warning\"` on the binary or test rule to downgrade this error to a warning")
        } else {
            diag.with_help("Set `package_collisions = \"ignore\"` on the binary or test rule to ignore this warning")
        };

        miette!(diag).with_source_code(format!(
            "{}\n{}",
            link.to_str().unwrap(),
            tgt.to_str().unwrap()
        ))
    }

    if link.exists() {
        // If the link already exists and is the same file, then there is no need to link this new one.
        // Assume that if the files are the same, then there is no need to warn or error.
        if is_same_file(&link, &tgt)? {
            return Ok(());
        }

        match collision_strategy {
            SymlinkCollisionResolutionStrategy::LastWins(warn) => {
                fs::remove_file(&link)
                    .into_diagnostic()
                    .wrap_err(
                        miette!(
                            "Unable to remove conflicting symlink in site-packages. Existing symlink {} conflicts with new target {}",
                            link.to_string_lossy(),
                            tgt.to_string_lossy()
                        )
                    )?;

                if *warn {
                    let conflicts = conflict_report(&link, &tgt, Severity::Warning);
                    eprintln!("{:?}", conflicts);
                }
            }
            SymlinkCollisionResolutionStrategy::Error => {
                // If the link already exists, then there is going to be a conflict.
                let conflicts = conflict_report(&link, &tgt, Severity::Error);
                return Err(conflicts);
            }
        };
    }

    std::os::unix::fs::symlink(&tgt, &link)
        .into_diagnostic()
        .wrap_err(format!(
            "Unable to create symlink: {} -> {}",
            tgt.to_string_lossy(),
            link.to_string_lossy()
        ))?;

    Ok(())
}

fn is_same_file(p1: &Path, p2: &Path) -> miette::Result<bool> {
    let f1 = File::open(p1)
        .into_diagnostic()
        .wrap_err(format!("Unable to open file {}", p1.to_string_lossy()))?;
    let f2 = File::open(p2)
        .into_diagnostic()
        .wrap_err(format!("Unable to open file {}", p2.to_string_lossy()))?;

    // Check file size is the same.
    if f1.metadata().unwrap().len() != f2.metadata().unwrap().len() {
        return Ok(false);
    }

    // Compare bytes from the two files in pairs, given that they have the same number of bytes.
    let buf1 = BufReader::new(f1);
    let buf2 = BufReader::new(f2);
    for (b1, b2) in buf1.bytes().zip(buf2.bytes()) {
        if b1.unwrap() != b2.unwrap() {
            return Ok(false);
        }
    }

    return Ok(true);
}
