use std::{
    fs::{self, File},
    io::{BufRead, BufReader, BufWriter, Write},
    path::{Path, PathBuf},
};

use miette::{Context, IntoDiagnostic};

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

    pub fn copy_to_site_packages(&self, dest: &Path) -> miette::Result<()> {
        let dest_pth = dest.join(self.src.file_name().expect(".pth must be a file"));

        if let Some(prefix) = self.prefix.as_deref() {
            self.prefix_and_write_pth(dest_pth, prefix)
        } else {
            fs::copy(self.src.as_path(), dest_pth)
                .map(|_| ())
                .into_diagnostic()
                .wrap_err("Unable to copy .pth file to site-packages")
        }
    }

    fn prefix_and_write_pth<P>(&self, dest: P, prefix: &str) -> miette::Result<()>
    where
        P: AsRef<Path>,
    {
        let source_pth = File::open(self.src.as_path())
            .into_diagnostic()
            .wrap_err("Unable to open source .pth file")?;
        let dest_pth = File::create(dest)
            .into_diagnostic()
            .wrap_err("Unable to create destination .pth file")?;

        let mut reader = BufReader::new(source_pth);
        let mut writer = BufWriter::new(dest_pth);

        let mut line = String::new();
        while reader.read_line(&mut line).unwrap() > 0 {
            let entry = Path::new(prefix).join(Path::new(line.trim()));
            line.clear();
            writeln!(writer, "{}", entry.to_string_lossy())
                .into_diagnostic()
                .wrap_err("Unable to write new .pth file entry with prefix")?;
        }

        Ok(())
    }
}
