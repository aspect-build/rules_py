use std::{
    fs::{self, DirEntry, File},
    io::{BufRead, BufReader, BufWriter, Read, Write},
    path::{Path, PathBuf},
};

use miette::{miette, Context, IntoDiagnostic};

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

    pub fn set_up_site_packages(&self, dest: &Path) -> miette::Result<()> {
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
                    let src_dir = dest
                        .join(entry)
                        .canonicalize()
                        .into_diagnostic()
                        .wrap_err("Unable to get full source dir path")?;
                    create_symlinks(&src_dir, &src_dir, &dest)?;
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

fn create_symlinks(dir: &Path, root_dir: &Path, dst_dir: &Path) -> miette::Result<()> {
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
            create_symlinks(&path, root_dir, dst_dir)?;
        } else if dir != root_dir || entry.file_name() != "__init__.py" {
            create_symlink(&entry, root_dir, dst_dir)?;
        }
    }
    Ok(())
}

fn create_symlink(e: &DirEntry, root_dir: &Path, dst_dir: &Path) -> miette::Result<()> {
    let tgt = e.path();
    let link = dst_dir.join(tgt.strip_prefix(root_dir).unwrap());

    // If the link already exists, do not return an error if the link is for an `__init__.py` file
    // with the same content as the new destination. Some packages that should ideally be namespace
    // packages have copies of `__init__.py` files in their distributions. For example, all the
    // Nvidia PyPI packages have the same `nvidia/__init__.py`. So we need to either overwrite the
    // previous symlink, or check that the new location also has the same content.
    if link.exists()
        && link.file_name().is_some_and(|x| x == "__init__.py")
        && is_same_file(link.as_path(), tgt.as_path())?
    {
        return Ok(());
    }

    // Is the link at the root of the `site-packages`?
    // We can get into situations where files in wheels are at the root of the wheel,
    // while this is valid, it leads to errors being thrown here as the symlinks will
    // already exist. In `pip`, the last file wins, so the logic is the same here.
    if link.exists() && link.parent().is_some_and(|x| x.ends_with("site-packages")) {
        // File is being placed at the root of the `site-packages`, remove the link.
        fs::remove_file(&link)
            .into_diagnostic()
            .wrap_err(
                miette!(
                    "Unable to remove conflicting symlink in site-packages root. Existing symlink {} conflicts with new target {}",
                    link.to_string_lossy(),
                    tgt.to_string_lossy()
                )
            )?
    }

    // If the link already exists, then there is going to be a conflict.
    // Bail early here before attempting to link as to provide a better error message.
    if link.exists() {
        let path_to_conflict = link
            .to_str()
            .and_then(|s| s.split_once("site-packages/"))
            .map(|s| s.1)
            .unwrap();
        let next_conflict = tgt
            .to_str()
            .and_then(|s| s.split_once(".runfiles/"))
            .map(|s| s.1)
            .unwrap();
        return Err(
            miette!(format!("site-packages/{}", path_to_conflict))
            .wrap_err(format!("{}", next_conflict))
            .wrap_err("Conflicting symlinks found when attempting to create venv. More than one package provides the file at these paths")
        );
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
